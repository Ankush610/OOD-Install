# Docker + Slinky on an HPC cluster: why it doesn't work

```text
DOCKER + SLINKY / HPC CLUSTER — WHY IT DOESN'T WORK
(notes, 2026-09-07)

THE CORE PROBLEM
----------------
The docker group == passwordless root. Not "almost". The same thing.

The daemon runs as root. Group membership lets you talk to it via
/var/run/docker.sock (root:docker, group rw). Ask it for a container that
runs as root with the host disk mounted -> you are root over the real
filesystem. No sudo prompt, because you never asked the machine; you asked
the daemon, which was already root.

  docker run -v /:/host -it alpine chroot /host

Analogy: you don't hold the master key, you're on the list of people the
caretaker will unlock any door for, no questions asked.

CONSEQUENCE FOR MULTI-USER MACHINES
-----------------------------------
- Adding client-user to the docker group = adding them to sudoers, spelled
  differently. They can't type `sudo`, but they can edit the file that
  decides who can.
- Treat "in docker group" with exactly the trust level of "in sudo group".
- Fine on your own laptop / as the admin. Never for a tenant, client, or
  ordinary cluster user.
- (Gotcha: group applies at login. New group -> log out/in or fresh SSH,
  else it still says permission denied.)

WHY CLOUD PROVIDERS CAN OFFER "DOCKER"
--------------------------------------
They never share a daemon. Each job gets a throwaway VM. Escape the
container and become root -> it's your own machine, deleted when the job
ends. Containers separate software; VMs separate customers.
HPC is the opposite shape: many users, one real machine, one shared
filesystem, no per-user VM. The cloud trick does not transfer.

WHAT TO USE INSTEAD
-------------------
Apptainer (ex-Singularity) to RUN:
- one file, my.sif, on the shared FS; every node reads the same file
- runs as the user, own UID, home/scratch already visible
- root inside != root outside, structurally
- --nv for GPUs, works with MPI multi-node under Slurm
- no group to add anyone to, no daemon, no root

  srun --gres=gpu:1 apptainer exec --nv vllm.sif \
       python -m vllm.entrypoints.openai.api_server --model ...

Podman to BUILD:
- rootless by default, no daemon, no podman-group problem
- OCI all the way through: `podman build -f Dockerfile` on existing files
- weak at *running* on HPC: unpacked image store in $HOME kills quota and
  is slow/broken on Lustre/GPFS/NFS; needs subuid/subgid handed to every
  user; MPI under Slurm is awkward

  podman build -t myinfer .
  podman push myinfer registry/...
  apptainer build model.sif docker://registry/you/model:v1

Podman = the workshop. Apptainer = the delivery truck.

KUBERNETES / SLINKY ANGLE
-------------------------
- K8s dropped Docker in 2022; nodes run containerd or CRI-O. It needs the
  OCI *image format*, not the Docker daemon. No socket, no docker group.
  Permissions move to RBAC, which is actually granular.
- Users never touch a node: build image -> push to registry -> YAML ->
  kubectl apply. GPU via `nvidia.com/gpu: 1`.
- Build without Docker: podman build / buildah / kaniko (in-cluster).
- Apptainer does NOT plug into K8s. containerd cannot start a .sif. Old
  bridge projects are unmaintained — don't build on them. Apptainer
  *replaces* the K8s path on an HPC cluster; the image converts fine.

SCALING (the honest bit)
------------------------
- Scaling UP (one big model, many GPUs): Slurm wins. Multi-node, fast
  interconnect, all GPUs allocated together. Normal Slurm job.
- Scaling OUT (many users hitting an endpoint): Slurm has no concept of
  traffic. No replicas on load, no LB. A job starts, runs, ends; a service
  is supposed to stay up.
- Middle path on HPC: Ray on top of a Slurm allocation. Slurm gives N
  nodes, Ray Serve does replicas/autoscale/routing inside them.
- Blunt rule: inference as a *product* -> Kubernetes, ask for a namespace.
  Inference as research throughput -> Slurm + Apptainer already scales.
  Pick one, not both.

DECISION
--------
client-user is an admin -> docker group ok, know it means root.
client-user is a tenant  -> remove from docker group, give Apptainer.
```

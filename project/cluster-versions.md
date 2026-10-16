# Cluster versions

Cluster the yamls in ../../k8s/examples were written/tested against (captured 2026-09-21)

```text
Kubernetes   v1.36.3 (kubeadm-style), containerd 2.3.5 (master) / 2.3.4 (cn01, cn02), CNI: flannel
Nodes        master (control-plane, 192.168.40.102), cn01 (192.168.40.100), cn02 (192.168.40.101)
             each compute node: 48 CPU, ~188Gi RAM; OS PS-BOSS-OS_V1 (EL9, kernel 5.14.0-503.11.1.el9_5)
GPU          NVIDIA A30 (1 on cn01, 1 on cn02; Slurm Gres=gpu:a30:1) via gpu-operator v26.7.0 + NVIDIA DRA driver
DRA          resource.k8s.io/v1; DeviceClasses: dra.cpu, a30 (extendedResourceName nvidia.com/gpu),
             gpu.nvidia.com, mig.nvidia.com, vfio.gpu.nvidia.com
             CPU via dra-driver-cpu v0.2.0 -> request "deviceclass.resource.kubernetes.io/dra.cpu"
Scheduler    Slinky slurm-bridge 1.2.2 (helm release in ns "slurm"); pods use
             schedulerName: slurm-bridge-scheduler + slurmjob.slinky.slurm.net/* annotations
             workload namespace: slurm-bridge; toleration slinky.slurm.net/managed-node
Registry     master:5000 (plain in-cluster registry; images master:5000/<name>:<tag>)
Storage      no StorageClass, no IngressClass; PV/PVC are static NFS (RWX, nconnect=8, NFS_SERVER = master 192.168.40.102, it exports /home)
Networking   NodePort (MLflow 30500). MetalLB is configured (e.g. 192.168.40.200) but its controller is Pending (same taint problem)
Other        cert-manager v1.21.1, headlamp 0.45.0, keda 2.20.2 + prometheus (both Pending: no toleration for the node taints)
Monitoring   Prometheus 3.5.5 + node_exporter 1.12.1 under systemd (OOD-Install/9-monitoring, 2026-10-15), not in k8s

Notes
- Pod Security `restricted` blocks inline hostPath/nfs volumes -> use PV+PVC (see ../model-hub/tenancy.md).
- If a yaml fails on another cluster, first check: DRA API version/DeviceClass names, slurm-bridge version, registry host, NFS_SERVER.
```

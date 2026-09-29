# OOD-Install

Sets up, on a fresh Slurm + Kubernetes cluster (AlmaLinux 9):

- **LDAP** (389 DS + SSSD): one user list for every node, one password for everything
- **Open OnDemand 4.2**: the web portal, logging in with that password
- **MLflow 3.15.1**: one shared tracking server + model registry on Kubernetes, where each user sees only their own work
- **VS Code** in the browser: each user's own session, as them, on their own files

```
laptop ──ssh tunnel──> master (login node)                       cn01, cn02 … (compute)
                       ├── LDAP     389 DS   :389 / :636  ◄───── SSSD on every node
                       ├── OOD      Apache   :443
                       ├── MLflow   k8s pod  :30500 (NodePort) ◄── training jobs
                       └── VS Code  Slurm jobs, partition viewer (40 cores shared; 8 cores + 48 GB kept for SSH + services)
```

| Folder | What it sets up |
|---|---|
| [`site.conf`](site.conf) | **all** site values: hostnames, IPs, base DN, ports, registry. The only file to edit |
| [`1-ldap/`](1-ldap/README.md) | LDAP server on master, SSSD on every node, `add-user.sh` |
| [`2-ood/`](2-ood/README.md) | Open OnDemand with the LDAP login, self-signed TLS, Slurm cluster file |
| [`3-mlflow/`](3-mlflow/README.md) | MLflow image, the k8s deployment, job tokens, the OOD page ([how it works](3-mlflow/WORKFLOW.md)) |
| [`4-vscode/`](4-vscode/README.md) | code-server on the shared `/home`, a core-sharing `viewer` partition on master, the VS Code OOD app |

## Before you start

- AlmaLinux 9 on every node, root on each, and the internet on master (packages, PyPI, the OOD repo)
- Slurm working (`sinfo`, `srun hostname`), and `/home` shared from master to every node
- Kubernetes with `master` as a node, `kubectl` working as root (`/etc/kubernetes/admin.conf`)
- A container registry every k8s node can pull from (`REGISTRY`, e.g. `master:5000`), and `podman` on master
- `MASTER_HOST` resolving to `MASTER_IP` on every node (`/etc/hosts`)

## Install (in this order)

```bash
vi site.conf                                    # 0. every value, before anything else

# 1. users (LDAP)
sudo bash 1-ldap/1-server.sh                    # on master
sudo bash 1-ldap/import-local-users.sh --dry-run   # optional: only if master already has people as local users
sudo bash 1-ldap/2-client.sh                    # on master, then as root on EVERY compute node
sudo bash 1-ldap/add-user.sh <name>             # first user(s): asks for the password

# 2. web portal
sudo bash 2-ood/setup-ood.sh                    # on master, asks once for the local admin's web password

# 3. MLflow
bash      3-mlflow/1-build-image.sh             # on master, no root
sudo bash 3-mlflow/2-deploy.sh
sudo bash 3-mlflow/3-sync-tokens.sh             # job tokens for every LDAP user
sudo bash 3-mlflow/4-install-ood-app.sh         # then Restart Web Server in OOD

# 4. VS Code
sudo bash 4-vscode/1-install-code-server.sh
sudo bash 4-vscode/2-slurm-viewer.sh            # needs root ssh to the compute nodes
sudo bash 4-vscode/3-install-ood-app.sh         # then Restart Web Server in OOD
```

Every script is safe to rerun, stops at the first error, and ends with a check that says what to expect.
Each folder's README explains its steps and has a Symptom | Cause | Fix table.

## Every day

| Task | Command (on master) |
|---|---|
| add a person | `sudo bash 1-ldap/add-user.sh <name>`: LDAP entry, home, MLflow job token |
| reset a password | `sudo ldappasswd -x -H ldap://localhost -D "cn=Directory Manager" -y /root/.ldap-dm.pass -S uid=<name>,ou=People,<LDAP_BASE>` |
| a user changes their own | `passwd` over SSH (SSSD passes it to LDAP) |
| a new compute node | `sudo bash 1-ldap/2-client.sh` on it |
| upgrade MLflow | set `MLFLOW_VERSION` in `site.conf` + `mlflow==` in `3-mlflow/image/requirements.txt`, then `1-build-image.sh`, `2-deploy.sh` |

One password per person works for **SSH, Slurm, OOD and the MLflow UI**. Jobs log in to MLflow with a token in `~/.mlflow/credentials`, never a password.

## Open it from the laptop

```bash
sudo ssh -J <you>@<jump-host> -L 443:localhost:443 -L 30500:<MASTER_IP>:30500 <you>@<MASTER_HOST>
```

Then open **https://localhost** (OOD). The local port must be **443**, because OOD redirects every other port. `-L 30500:…` is for **Open MLflow**, which goes to MLflow directly (see [3-mlflow](3-mlflow/README.md)).

This cluster: `sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 -L 30500:192.168.40.102:30500 admin@master`

**After an OOD config change:** click **Restart Web Server** in OOD's top-right menu, because OOD caches its config per user.

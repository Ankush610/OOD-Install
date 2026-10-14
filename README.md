# OOD-Install

Sets up, on a fresh Slurm + Kubernetes cluster (AlmaLinux 9):

- **LDAP** (389 DS + SSSD): one user list for every node, one password for everything
- **Open OnDemand 4.2**: the web portal, logging in with that password
- **MLflow 3.15.1**: one shared tracking server + model registry on Kubernetes, where each user sees only their own work
- **VS Code** in the browser: each user's own session, as them, on their own files

```
laptop ──https/ssh──> LOGIN_HOST                    MASTER_HOST                          cn01, cn02 … (compute)
                      ├── OOD      Apache :443 ───► ├── LDAP     389 DS :636   ◄───── SSSD on every node
                      ├── SSH for users        ───► ├── Keycloak :8180 (LOGIN_IP only)
                      └── VS Code/Jupyter      ───► ├── MLflow   k8s pod :30500 ◄── training jobs
                          Slurm partition viewer    ├── k8s API :6443, Slurm controller, registry :5000, gateway
                                                    └── admin helper (root; the admin page's ssh key, LOGIN_IP only)
```
`LOGIN_HOST` defaults to `MASTER_HOST`: this test cluster is one machine, and the scripts take the same path either
way (they ssh as root from master to `LOGIN_HOST`, or run locally when it is the same machine). The login node never
gets root on master: only the admin page's restricted key, which runs nothing but the admin helper.

| Folder | What it sets up |
|---|---|
| [`site.conf`](site.conf) | **all** site values: hostnames, IPs, base DN, ports, registry. The only file to edit |
| [`0-registry/`](0-registry/README.md) | the container registry on master (podman → Kubernetes), containerd + podman on every node, `k8s-image` |
| [`1-ldap/`](1-ldap/README.md) | LDAP server on master, SSSD on every node, `add-user.sh` |
| [`2-ood/`](2-ood/README.md) | Open OnDemand with the LDAP login, self-signed TLS, Slurm cluster file |
| [`3-mlflow/`](3-mlflow/README.md) | MLflow image, the k8s deployment, job tokens, the OOD page ([how it works](3-mlflow/WORKFLOW.md)) |
| [`4-vscode/`](4-vscode/README.md) | code-server on the shared `/home`, a core-sharing `viewer` partition on master, the VS Code OOD app |

## Before you start

- AlmaLinux 9 on every node, root on each, and the internet on master (packages, PyPI, the OOD repo)
- Slurm working (`sinfo`, `srun hostname`), and `/home` shared from master to every node
- Kubernetes with `master` as a node, `kubectl` working as root (`/etc/kubernetes/admin.conf`)
- `podman` on master (and on login nodes), `containerd` + `crictl` on every k8s node
- `MASTER_HOST` resolving to `MASTER_IP` on every node (`/etc/hosts`)
- a separate `LOGIN_HOST`: root ssh from master to it, `/home` mounted, munge + `slurmd` installed (it runs the
  `viewer` partition), the `kubectl` binary (users' Model Hub calls), and these ports open **on master** for
  `LOGIN_IP`: 22 (admin helper), 636 (LDAPS), `KEYCLOAK_PORT` (`6-keycloak` opens it), 6443 (k8s API), 30500 (MLflow),
  6817-6819 (Slurm), 5000 (registry, for podman pushes); and 443 on the login node

## Install (in this order)

```bash
vi site.conf                                    # every value, before anything else

# 0. container registry (podman -> Kubernetes)
sudo bash 0-registry/setup-registry.sh          # master: needs root ssh to the other nodes

# 1. users (LDAP)
sudo bash 1-ldap/1-server.sh                    # master
sudo bash 1-ldap/import-local-users.sh --dry-run   # optional: only if master already has people as local users
sudo bash 1-ldap/2-client.sh                    # master, then as root on LOGIN_HOST and EVERY compute node
sudo bash 1-ldap/add-user.sh <name>             # master. First user(s): asks for the password

# 2. web portal
sudo bash 2-ood/setup-ood.sh                    # LOGIN_HOST, asks once for the local admin's web password

# 3. MLflow
bash      3-mlflow/1-build-image.sh             # master, no root
sudo bash 3-mlflow/2-deploy.sh                  # master (copies the proxy secret to LOGIN_HOST)
sudo bash 3-mlflow/3-sync-tokens.sh             # master: job tokens for every LDAP user
sudo bash 3-mlflow/4-install-ood-app.sh         # LOGIN_HOST, then Restart Web Server in OOD

# 4. VS Code
sudo bash 4-vscode/1-install-code-server.sh     # master (writes the shared /home)
sudo bash 4-vscode/2-slurm-viewer.sh            # master: the viewer node is LOGIN_HOST; needs root ssh to it + compute nodes
sudo bash 4-vscode/3-install-ood-app.sh         # LOGIN_HOST, then Restart Web Server in OOD
```
Later folders follow the same rule: everything under `/var/www/ood` or in Apache's config runs on `LOGIN_HOST`
(`5-model-hub/7-install-ood-app.sh`, `7-jupyter/2-install-ood-app.sh`, `8-admin/2-install-ood-app.sh`), the rest on
master (`6-keycloak/*`, `8-admin/1-install.sh`, the other `5-model-hub` scripts). Each script says so if run on the wrong one.

Every script is safe to rerun, stops at the first error, and ends with a check that says what to expect.
Each folder's README explains its steps and has a Symptom | Cause | Fix table.

## Every day

| Task | Command (on master) |
|---|---|
| add a person | `sudo bash 1-ldap/add-user.sh <name>`: LDAP entry, home, rootless-podman subuids, MLflow job token |
| reset a password | `sudo ldappasswd -x -H ldap://localhost -D "cn=Directory Manager" -y /root/.ldap-dm.pass -S uid=<name>,ou=People,<LDAP_BASE>` |
| a user changes their own | `passwd` over SSH (SSSD passes it to LDAP) |
| a new compute node | `sudo bash 1-ldap/2-client.sh` on it |
| upgrade MLflow | set `MLFLOW_VERSION` in `site.conf` + `mlflow==` in `3-mlflow/image/requirements.txt`, then `1-build-image.sh`, `2-deploy.sh` |

One password per person works for **SSH, Slurm, OOD and the MLflow UI**. Jobs log in to MLflow with a token in `~/.mlflow/credentials`, never a password.

## Open it from the laptop

**Production:** users open OOD's own address (`https://<OOD_SERVERNAME>`) in the browser; no ssh. Everything users
run on the cluster is reached through OOD (VS Code, Model Hub, their own web apps via `/rnode/<host>/<port>/`).
The one exception today is the MLflow web UI on `MASTER_IP:MLFLOW_PORT` (see below).

**This test cluster only** (it sits behind a jump host):

```bash
sudo ssh -J <you>@<jump-host> -L 443:localhost:443 -L 30500:<MASTER_IP>:30500 <you>@<LOGIN_HOST>
```

Then open **https://localhost** (OOD). The local port must be **443**, because OOD redirects every other port. `-L 30500:…` is for **Open MLflow**, which goes to MLflow directly (see [3-mlflow](3-mlflow/README.md)). In production that port must instead be reachable from users' network (open item: OOD's `/node` proxy drops the `Authorization` header MLflow's login needs).

This cluster: `sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 -L 30500:192.168.40.102:30500 admin@master`

**After an OOD config change:** click **Restart Web Server** in OOD's top-right menu, because OOD caches its config per user.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Idempotent root bash scripts that install Open OnDemand 4.2 on a Slurm cluster's `master` node (AlmaLinux 9), plus an OOD Batch Connect app that gives each user their own MLflow server. Nothing builds or runs locally. The scripts are copied to `master` and run there as root, so you can't test them from this machine.

Topology: laptop → `network-node` (10.208.34.138) → `master` (OOD, Slurm controller, MLflow sessions) + `cn01`/`cn02` (training). Access is through `sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 admin@master`, then `https://localhost`. The local port must be 443 because OOD redirects every other port.

## Commands

Run order on master (all scripts can be rerun safely):
```bash
sudo bash OOD-Setup/setup-ood.sh
sudo bash OOD-Mlflow/1-slurm-viewer.sh
sudo bash OOD-Mlflow/2-mlflow-app.sh
sudo bash OOD-Mlflow/remove-mlflow.sh [--restore]   # move app + venv to ~/temp-backup for a clean-reinstall test
```

There are no tests or linters. Local sanity checks:
```bash
bash -n OOD-Setup/setup-ood.sh OOD-Mlflow/*.sh
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' OOD-Mlflow/apps/mlflow_gc/passenger_wsgi.py
```
After you change any app or config file on the server, click **Restart Web Server** in OOD. OOD caches config per user.

## Architecture

- **`OOD-Setup/setup-ood.sh`** writes `/etc/ood/config/ood_portal.yml` (htpasswd auth, self-signed cert, `node_uri: /node` proxy) and `/etc/ood/config/clusters.d/<CLUSTER_ID>.yml` (Slurm adapter with explicit `bin:`/`conf:`). Don't add a `cluster:` line to the cluster file. It makes OOD pass `--clusters`, which needs slurmdbd.
- **`OOD-Mlflow/1-slurm-viewer.sh`** adds `master` to `slurm.conf` as partition `viewer`, scps the file to the compute nodes, and restarts the daemons. MLflow sessions run there, so they never take up training nodes.
- **`OOD-Mlflow/2-mlflow-app.sh`** builds the shared venv `/home/apps/mlflow-venv` (Python 3.12, because MLflow ≥ 3.2 needs ≥ 3.10) and copies `apps/*` to `/var/www/ood/apps/sys/`. It rewrites `cluster:` in `form.yml` with `sed` and runs `chmod +x` on `script.sh.erb`. The `cluster:` value in the repo copy of `form.yml` is a placeholder. Edit `apps/`, then rerun the script. Don't edit the deployed copy.
- **`apps/mlflow`** (Batch Connect): `before.sh.erb` picks the node IP and a free port. `script.sh.erb` runs `mlflow server` on the per-user `~/mlflow/mlflow.db` + `~/mlflow/artifacts`. `view.html.erb` renders the session card.
- **`apps/mlflow_gc`** (Passenger WSGI, stdlib only) sits behind the card's **Clean** POST. It finds the user's newest session that still answers by reading `~/ondemand/data/sys/dashboard/batch_connect/sys/mlflow/output/*/connection.yml`, lists the trash through the REST API, and then runs `mlflow gc`. It runs as the user in their PUN. `touch passenger_wsgi.py` reloads it.

## Values that must match across files

- `CLUSTER_ID` in `setup-ood.sh` == `CLUSTER_ID` in `2-mlflow-app.sh` (currently `aistack`; the READMEs still say `dummy`).
- The venv path `/home/apps/mlflow-venv` is hardcoded in `2-mlflow-app.sh`, `script.sh.erb`, `passenger_wsgi.py`, and `remove-mlflow.sh`.
- Session resources `--mem=2G`/1 CPU in `submit.yml.erb` go with `VIEWER_CPUS`/`VIEWER_MEM_MB` in `1-slurm-viewer.sh`. Change them together.
- `MLFLOW_VERSION` must be ≥ the `mlflow-skinny` version in the training containers. DB upgrades are one-way.

## MLflow flags that must stay

- `--static-prefix /node/$host/$port`: the UI and the API both sit behind OOD's proxy path. The tracking URI is the full `http://<ip>:<port>/node/<ip>/<port>`.
- `--workers 1`: more workers run out of memory at 2 GB.
- `--allowed-hosts "*"`: MLflow 3.x only answers localhost by default.
- Training containers ship `mlflow-skinny`, which can't open SQLite. Always give clients the HTTP tracking URI.

## Conventions

- Scripts use `set -euo pipefail`, keep their config variables at the top, and print numbered `== N.` steps with a final check (`curl` status codes, `sinfo`/`srun`).
- `# ponytail:` comments mark deliberate shortcuts that have a known limit.
- The READMEs keep a Symptom | Cause | Fix troubleshooting table. When you fix a new failure mode, add a row.
- Known gap: MLflow has no auth, so anyone on 192.168.40.x can reach another user's session. The plan is to add MLflow auth after OOD moves from htpasswd to Dex.

## Sibling repo

`../AI-stack-Project` holds design notes (`Plans/`) and K8s manifests (`yamls/`) for the wider cluster: Slinky slurm-bridge, DRA GPUs, a `master:5000` registry, and static NFS PVs. `yamls/cluster-conf.txt` records the cluster versions the manifests were tested against.

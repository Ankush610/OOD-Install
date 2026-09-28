# MLflow-Auth

ONE shared MLflow 3.15.1 server with login, running as an always-on k8s service on `master` (the login node), not a Slurm job. Each user sees only their own experiments and models (`default_permission = NO_PERMISSIONS`). OOD gets a page, **Interactive Apps -> MLflow (shared)**, with no per-user session to launch.

| Folder | What it does |
|---|---|
| `mlflow-server/` | image with the same packages as `/home/apps/mlflow-venv` (podman), Deployment in namespace `mlflow`, pinned to master, hostPath data + NodePort `30500` |
| `mlflow-auth/` | `users.txt` -> MLflow user + OOD htpasswd + `~user/.mlflow/credentials` (one password for everything) |
| `ood-app/` | the OOD page: server status, tracking URI + **Copy**, **Open MLflow** (direct, port 30500) |

See [WORKFLOW.md](WORKFLOW.md) for diagrams: the big picture, adding a user, a training run, the model registry, and who sees what.

 (on master)

```bash
bash mlflow-server/build-image.sh        # as admin. Again after every venv upgrade
bash mlflow-server/deploy.sh             # as admin (uid 1000 owns /home/apps/mlflow-shared)
sudo bash mlflow-auth/sync-users.sh      # again after every users.txt change
sudo bash ood-app/install-app.sh         # then Restart Web Server in OOD
```

`mlflow-auth/users.txt` holds `username:password`, one per line, and is git-ignored. Passwords need **12+ characters** (MLflow rule). The user must already exist on Linux.

## For users

```bash
export MLFLOW_TRACKING_URI=http://192.168.40.102:30500/node/192.168.40.102/30500
python train.py
```
The URI never changes. The login comes from `~/.mlflow/credentials`, so it's never in the script.

**Web UI:** **Open MLflow** on the OOD page opens MLflow **directly** on port 30500, and MLflow asks for your MLflow username and password. It can't go through OOD's `/node` proxy, because OOD strips the `Authorization` header (it forwards only `X-Forwarded-User`), so MLflow would always answer 401. From the laptop, the tunnel needs the MLflow port too:

```bash
sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 -L 30500:192.168.40.102:30500 admin@master
```
then open `http://localhost:30500/node/192.168.40.102/30500/`. The different port also means the browser keeps this login separate from the OOD one.

## Values that must match

- `192.168.40.102`, `30500` and `--static-prefix /node/192.168.40.102/30500`: `mlflow.yaml` (args, probes, Service nodePort), `deploy.sh`, `sync-users.sh`, `passenger_wsgi.py`
- image tag in `mlflow.yaml` == the `mlflow==` line in `requirements.txt` (printed by `build-image.sh`)
- `runAsUser: 1000` == the owner of `/home/apps/mlflow-shared`

## Admin

- admin password: `/home/apps/mlflow-shared/admin.pass`
- logs: `kubectl -n mlflow logs deploy/mlflow`
- empty everyone's trash (no Clean button yet): `kubectl -n mlflow exec deploy/mlflow -- mlflow gc --backend-store-uri sqlite:////data/mlflow.db --artifacts-destination /data/artifacts`
- log in to the MLflow UI as `admin` with the password in `admin.pass` to manage users and permissions

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sync-users.sh`: `FAILED`, log shows `users/create` **400** | password under 12 characters | longer password in `users.txt` (the script now prints SKIP for it) |
| `deploy.sh`: rollout timed out, event `failed calling webhook "pods.slinky.slurm.net" ... connection refused` | slurm-bridge admission pod is down, and its webhook blocks new pods in every namespace except `kube-system`/`slurm` | its pods need a toleration for `slinky.slurm.net/managed-node` (added by `kubectl patch`, lost on `helm upgrade`: put it in the chart values) |
| `deploy.sh`: `namespace mlflow ... is being terminated` | a deleted namespace hangs on KEDA's broken `external.metrics.k8s.io` API | once it is empty, clear its finalizer: `kubectl get ns mlflow -o json \| jq ".spec.finalizers=[]" \| kubectl replace --raw /api/v1/namespaces/mlflow/finalize -f -` |
| MLflow UI keeps refusing a correct password | opened through OOD's `/node/...` on port 443: OOD strips the password before MLflow sees it | use **Open MLflow** (port 30500, direct) and add `-L 30500:192.168.40.102:30500` to the tunnel |
| Open MLflow: page can't be reached | tunnel lacks the MLflow port | add `-L 30500:192.168.40.102:30500` to the ssh command |

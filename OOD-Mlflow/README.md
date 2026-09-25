# OOD-Mlflow

Adds **Interactive Apps -> MLflow**. Each user gets their own MLflow 3.15.1 server, started as a small Slurm job on `master`.

- **Software:** one shared install, `/home/apps/mlflow-venv` (Python 3.12)
- **Data:** per user, `~/mlflow/mlflow.db` + `~/mlflow/artifacts/`, private because home directories are `700`
- **Runs on:** `master`, in partition `viewer` (1 CPU / 2 GB per session), so training keeps all of `cn01`/`cn02`

## Run (after OOD-Setup)

```bash
sudo bash 1-slurm-viewer.sh    # master joins Slurm as partition "viewer" (12 CPUs / 24 GB = ~10 sessions)
sudo bash 2-mlflow-app.sh      # installs MLflow, copies apps/ into /var/www/ood/apps/sys/
```

Then **Restart Web Server** in OOD, and go to **Interactive Apps -> MLflow -> Launch**.

To change the app, edit the files in `apps/`, then rerun `2-mlflow-app.sh`.

**Test a clean reinstall:**

1. Delete your MLflow sessions in OOD
2. Run `sudo bash remove-mlflow.sh`. It moves the two app folders and the venv into `~/temp-backup`. Users' `~/mlflow` data and the `viewer` partition stay.
3. Run `sudo bash 2-mlflow-app.sh`
4. If it works, run `sudo rm -rf ~/temp-backup`. If it's broken, run `sudo bash remove-mlflow.sh --restore`

| File | Job |
|---|---|
| `apps/mlflow/form.yml` | launch form (hours). `cluster:` is filled in from `CLUSTER_ID` in `2-mlflow-app.sh` |
| `apps/mlflow/submit.yml.erb` | Slurm: `-p viewer --cpus-per-task=1 --mem=2G` |
| `apps/mlflow/template/before.sh.erb` | picks the node IP and a free port |
| `apps/mlflow/template/script.sh.erb` | `mlflow server` on `~/mlflow` (must stay executable) |
| `apps/mlflow/template/after.sh.erb` | waits until MLflow answers |
| `apps/mlflow/view.html.erb` | session card: tracking URI + **Copy**, orange **Clean** row, **Open MLflow** |
| `apps/mlflow_gc/passenger_wsgi.py` | helper behind **Clean**: finds the user's running session, lists the trash, runs `mlflow gc` |

`mlflow server` flags that matter: `--static-prefix /node/$host/$port` (UI **and** API sit behind OOD's proxy path), `--workers 1` (4 workers run out of memory at 2 GB), and `--allowed-hosts "*"` (MLflow 3.x only answers `localhost` by default).

## For users

1. **Launch** MLflow, then wait for **Running**
2. On the session card, **Copy** the tracking URI:
   `export MLFLOW_TRACKING_URI=http://<ip>:<port>/node/<ip>/<port>`. It works inside the cluster only. From the laptop, use **Open MLflow**.
3. Keep the session running longer than your training job. The port changes every launch.
4. **Clean** (orange row) permanently empties the MLflow trash, so a deleted experiment's name can be reused. Hover **(i)** for why.

`run.sh` can find the current session by itself:

```bash
conn=$(ls -t ~/ondemand/data/sys/dashboard/batch_connect/sys/mlflow/output/*/connection.yml 2>/dev/null | head -1)
[ -n "$conn" ] || { echo "Launch MLflow in OnDemand first." >&2; exit 1; }
host=$(awk '/^host:/{print $2}' "$conn"); port=$(awk '/^port:/{print $2}' "$conn")
export MLFLOW_TRACKING_URI="http://$host:$port/node/$host/$port"
curl -sf -o /dev/null --max-time 5 "$MLFLOW_TRACKING_URI/api/2.0/mlflow/experiments/search?max_results=1" \
  || { echo "MLflow at $MLFLOW_TRACKING_URI is not answering." >&2; exit 1; }
```

## Upgrading MLflow

Set `MLFLOW_VERSION` in `2-mlflow-app.sh`, make sure no MLflow sessions are running (`squeue -p viewer`), then rerun it.
Keep the server **at or above** the containers' `mlflow-skinny` version.
Each user's `mlflow.db` upgrades itself on the next launch, and there's no going back.
Afterwards, run the `curl` check above again and watch memory with `sstat -j <jobid>.batch --format=MaxRSS`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| session stuck at "Starting", `script.sh: Permission denied` | `script.sh.erb` isn't executable | rerun `2-mlflow-app.sh`, then launch a new session |
| `Killed`, `oom_kill events` in `output.log` | too little memory for the workers | `--workers 1` (already set). Raise `--mem` and `VIEWER_MEM_MB` together |
| training stays pending while MLflow runs | MLflow sat on a compute node, or a job without `--mem` got the whole node's RAM | use partition `viewer` (already set). Add `DefMemPerCPU=2048` to `slurm.conf` |
| `No matching distribution found for mlflow==3.15.1` | venv built with Python 3.9. MLflow >= 3.2 needs 3.10+ | delete the venv and rerun `2-mlflow-app.sh`, which uses `python3.12` |
| training: **404** at `mlflow.set_experiment()`, then `Broken pipe` on cn02 | wrong tracking URI | 3.15.1 needs the full `/node/<ip>/<port>` path. Copy it from the card |
| training: `KeyError: 'sqlite'` | containers have `mlflow-skinny`, which can't open SQLite | always use the HTTP tracking URI |
| Clean: `Tracking URL is not set` | `mlflow gc` needs the running server for artifacts | Clean only works on a running session (by design) |
| Clean: "No running MLflow session" | no session answering | launch MLflow, then Clean |
| `Security middleware ... localhost-only` | `--allowed-hosts` missing | keep `--allowed-hosts "*"` in `script.sh.erb` |

**Known gap (test setup):** MLflow has no login, and anyone on `192.168.40.x` who guesses the IP and port can open another user's MLflow. Add MLflow auth after OOD moves to Dex, because it would clash with the htpasswd login.

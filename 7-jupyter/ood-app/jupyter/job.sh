#!/usr/bin/env bash
# One JupyterLab session as THIS user: it sees exactly what they can see on disk, nothing more.
# Started by the page (passenger_wsgi.py, shared with 4-vscode) with sbatch. ${...} are filled in from
# ../../../site.conf by ../../2-install-ood-app.sh. Settings: ~/.jupyter (theirs, kept between sessions).
set -euo pipefail
info=$HOME/.jupyter-sessions/$SLURM_JOB_ID.json   # where to connect; the page shows "Starting" until it exists
cd "$HOME"
# Terminals and kernels should behave like an SSH login. This session is itself a Slurm job, so its
# SLURM_*/SBATCH_* variables would leak into every sbatch/srun typed there and clash with the new job's
# own (e.g. "SLURM_MEM_PER_CPU ... and SLURM_MEM_PER_NODE are mutually exclusive"). Slurm still ends this job.
unset $(compgen -v | grep -E '^(SLURM_|SBATCH_|SRUN_|SALLOC_)') 2>/dev/null
# The node's IP, so OOD's /node proxy can reach it without DNS; a port nothing answers on; a token only
# this user can read (Connect opens /lab?token=<it>). Jupyter reads $JUPYTER_TOKEN.
host=$(hostname -I | awk '{print $1}')
while :; do port=$(( RANDOM % 40000 + 20000 )); (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null || break; done
JUPYTER_TOKEN=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9)
export JUPYTER_TOKEN
# One kernel per training image, read now: a SIF added to the folder shows up in the next session. Same as the
# training scripts (apptainer exec --nv; on a node without GPUs --nv only warns). Every training SIF has ipykernel.
kdir=${info%.json}.kernels                         # (SLURM_JOB_ID is unset above)
for sif in "${CONTAINERS_ROOT}"/training/*/*.sif; do
  [ -f "$sif" ] || continue
  name=$(basename "$sif" .sif)
  mkdir -p "$kdir/kernels/$name"
  printf '{"argv": ["%s", "exec", "--nv", "%s", "python", "-m", "ipykernel_launcher", "-f", "{connection_file}"],\n "display_name": "%s (container)", "language": "python"}\n' \
    "${APPTAINER}" "$sif" "$name" > "$kdir/kernels/$name/kernel.json"
done
export JUPYTER_PATH=$kdir${JUPYTER_PATH:+:$JUPYTER_PATH}
trap 'rm -rf "$info" "$kdir"' EXIT
# base_url = the /node path: Jupyter builds its links with it, so it works behind OOD's proxy unchanged.
# allow_origin: only pages from OOD may open kernels (websockets) or call the API with the login cookie.
# Idle: a kernel that is idle with no browser attached is stopped, then the server once nothing is left.
# A cell still running counts as busy, so long training in a notebook keeps the session alive.
"${JUPYTER_ROOT}/current/bin/jupyter" lab \
  --no-browser \
  --ip=0.0.0.0 \
  --port="$port" \
  --ServerApp.port_retries=0 \
  --ServerApp.base_url="/node/$host/$port/" \
  --ServerApp.root_dir="$HOME" \
  --ServerApp.allow_origin="${JUPYTER_ORIGIN}" \
  --ServerApp.shutdown_no_activity_timeout=${JUPYTER_IDLE_SECONDS} \
  --MappingKernelManager.cull_idle_timeout=${JUPYTER_IDLE_SECONDS} \
  --MappingKernelManager.cull_interval=300 \
  --LabApp.check_for_updates_class=jupyterlab.NeverCheckForUpdate &
pid=$!
for i in $(seq 120); do
  (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && break
  kill -0 $pid 2>/dev/null && [ "$i" -lt 120 ] || { echo "jupyter did not start"; exit 1; }
  sleep 1
done
(umask 077; printf '{"host": "%s", "port": %d, "password": "%s"}\n' "$host" "$port" "$JUPYTER_TOKEN" > "$info")
echo "jupyter ready on $host:$port"
wait $pid

#!/usr/bin/env bash
# One VS Code (code-server) session as THIS user: it sees exactly what they can see on disk, nothing more.
# Started by the page (passenger_wsgi.py) with sbatch. ${...} are filled in from ../../../site.conf by ../../3-install-ood-app.sh.
# Extensions + settings: ~/.local/share/code-server (theirs, kept between sessions).
set -euo pipefail
info=$HOME/.vscode-sessions/$SLURM_JOB_ID.json   # where to connect; the page shows "Starting" until it exists
cd "$HOME"
# Terminals inside VS Code should behave like an SSH login. This session is itself a Slurm job, so its
# SLURM_*/SBATCH_* variables would leak into every sbatch/srun typed there and clash with the new job's
# own (e.g. "SLURM_MEM_PER_CPU ... and SLURM_MEM_PER_NODE are mutually exclusive"). Slurm still ends this job.
unset $(compgen -v | grep -E '^(SLURM_|SBATCH_|SRUN_|SALLOC_)') 2>/dev/null
# Set inside a VS Code terminal; code-server would then just hand the folder to that editor and exit.
unset VSCODE_IPC_HOOK_CLI
# The node's IP, so OOD's /rnode proxy can reach it without DNS; a port nothing answers on; a password only
# this user can read (the page posts it to code-server's login on Connect). code-server reads $PASSWORD.
host=$(hostname -I | awk '{print $1}')
while :; do port=$(( RANDOM % 40000 + 20000 )); (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null || break; done
PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9)
export PASSWORD
trap 'rm -f "$info"' EXIT
"${CODE_SERVER_ROOT}/current/bin/code-server" \
  --auth password \
  --bind-addr "0.0.0.0:$port" \
  --disable-telemetry \
  --disable-update-check \
  --disable-workspace-trust \
  --idle-timeout-seconds ${VSCODE_IDLE_SECONDS} &
pid=$!
for i in $(seq 120); do
  (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && break
  kill -0 $pid 2>/dev/null && [ "$i" -lt 120 ] || { echo "code-server did not start"; exit 1; }
  sleep 1
done
(umask 077; printf '{"host": "%s", "port": %d, "password": "%s"}\n' "$host" "$port" "$PASSWORD" > "$info")
echo "code-server ready on $host:$port"
wait $pid

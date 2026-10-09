#!/usr/bin/env bash
# Install the "VS Code" OOD page (Passenger app, Model Hub look): copies ood-app/vscode to /var/www/ood/apps/sys/vscode,
#   fills ${...} in job.sh from ../site.conf, writes site.json (partitions, GPU sizes from Slurm).
# Edit ood-app/ and rerun; never edit the installed copy.
# Run on master after 1 and 2: sudo bash 3-install-ood-app.sh     then Restart Web Server in OOD
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
# sudo resets PATH to /usr/sbin:/usr/bin (misses a Slurm under /usr/local) and drops SLURM_CONF
# (then the tools look for a config in DNS: "resolve_ctls_from_dns_srv ... Unknown host")
export PATH="$SLURM_BIN:${SLURM_BIN%/bin}/sbin:$PATH" SLURM_CONF
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
APPS=/var/www/ood/apps/sys
APP=$APPS/vscode

echo "== 1. Checks"
[ -d "$APPS" ] || { echo "No $APPS: run ../2-ood/setup-ood.sh first." >&2; exit 1; }
[ -x "$CODE_SERVER_ROOT/current/bin/code-server" ] || { echo "No code-server: run 1-install-code-server.sh first." >&2; exit 1; }
sinfo -h -p "$VIEWER_PARTITION" >/dev/null || { echo "No partition $VIEWER_PARTITION: run 2-slurm-viewer.sh first." >&2; exit 1; }

echo "== 2. GPUs, as Slurm reports them (GPU_PARTITION=$GPU_PARTITION)"
GPU_TYPE= GPU_MAX=0 CPUS_PER_GPU=0 MEM_PER_GPU_MB=0
found=$(sinfo -h -N -o "%P|%N|%G|%c|%m" | bash "$HERE/gpu-detect.sh" "$GPU_PARTITION")   # stops here on an error
eval "$found"
if [ -n "$GPU_PARTITION" ]; then
  echo "partition $GPU_PARTITION: up to $GPU_MAX x $GPU_TYPE per node; each GPU comes with $CPUS_PER_GPU CPUs + $(( MEM_PER_GPU_MB / 1024 )) GB"
else
  echo "no GPU partition: the form offers Editor only"
fi

echo "== 3. Copy -> $APP, job.sh from site.conf, site.json for the page"
rm -rf "$APP"
cp -r "$HERE/ood-app/vscode" "$APP"
rm -rf "$APP/__pycache__"
export CODE_SERVER_ROOT VSCODE_IDLE_SECONDS
envsubst '$CODE_SERVER_ROOT $VSCODE_IDLE_SECONDS' < "$HERE/ood-app/vscode/job.sh" > "$APP/job.sh"
python3 -c 'import json,sys; a=sys.argv; json.dump({"app": "vscode", "slurm_bin": a[2], "slurm_conf": a[11], "viewer_partition": a[3], "mem": a[4],
  "idle_seconds": int(a[5]), "gpu_partition": a[6], "gpu_type": a[7], "gpu_max": int(a[8]) if a[6] else 0,
  "cpus_per_gpu": int(a[9]), "mem_per_gpu_mb": int(a[10])}, open(a[1], "w"), indent=1)' \
  "$APP/site.json" "$SLURM_BIN" "$VIEWER_PARTITION" "$VSCODE_MEM" "$VSCODE_IDLE_SECONDS" \
  "$GPU_PARTITION" "$GPU_TYPE" "$GPU_MAX" "$CPUS_PER_GPU" "$MEM_PER_GPU_MB" "$SLURM_CONF"
chmod -R a+rX "$APP"
chmod a+rx "$APP/job.sh"                        # sbatch runs it as the user
touch "$APP/passenger_wsgi.py"                  # reload it in running web servers

echo "== 4. Check"
grep -n '\${\(CODE_SERVER_ROOT\|VSCODE_\)' "$APP/job.sh" && { echo "unfilled values above" >&2; exit 1; }
bash -n "$APP/job.sh" && echo "job.sh: OK"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APP/passenger_wsgi.py" && echo "passenger_wsgi.py: OK"
cat "$APP/site.json"; echo
[ -d /var/www/ood/apps/sys/model_hub ] || echo "WARNING: no Model Hub app: the page borrows its look (Bootstrap, style.css) from it"
echo "Done. In OOD: Restart Web Server, then Interactive Apps -> VS Code."

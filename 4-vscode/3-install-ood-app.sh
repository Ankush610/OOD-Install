#!/usr/bin/env bash
# Install the "VS Code" OOD Interactive App: fills ${...} in ood-app/vscode from ../site.conf and copies it
# to /var/www/ood/apps/sys/vscode. Edit ood-app/ and rerun; never edit the installed copy.
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

echo "== 3. Render + copy -> $APP"
export CLUSTER_ID CODE_SERVER_ROOT GPU_PARTITION GPU_MAX CPUS_PER_GPU MEM_PER_GPU_MB VIEWER_PARTITION VSCODE_MEM VSCODE_IDLE_SECONDS
vars='$CLUSTER_ID $CODE_SERVER_ROOT $GPU_PARTITION $GPU_MAX $CPUS_PER_GPU $MEM_PER_GPU_MB $VIEWER_PARTITION $VSCODE_MEM $VSCODE_IDLE_SECONDS'
rm -rf "$APP"
cp -r "$HERE/ood-app/vscode" "$APP"
find "$APP" -type f | while read -r f; do envsubst "$vars" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
# one select option per GPU count, in place of the GPU_OPTIONS marker line
opts=$(for n in $(seq 1 "$GPU_MAX"); do printf '      - ["GPU node: %d x %s", "gpu%d"]\n' "$n" "$GPU_TYPE" "$n"; done)
python3 -c 'import sys; p, o = sys.argv[1], sys.argv[2]; s = open(p).read(); open(p, "w").write("".join(o + "\n" if "GPU_OPTIONS" in l else l for l in s.splitlines(True)) if o else "".join(l for l in s.splitlines(True) if "GPU_OPTIONS" not in l))' "$APP/form.yml" "$opts"
chmod +x "$APP/template/script.sh.erb"          # OOD runs it as the job script
chmod -R a+rX "$APP"

echo "== 4. Check"
grep -rn '\${\(CLUSTER_ID\|CODE_SERVER_ROOT\|GPU_\|CPUS_PER\|MEM_PER\|VIEWER_\|VSCODE_\)' "$APP" && { echo "unfilled values above" >&2; exit 1; }
grep '^cluster:' "$APP/form.yml"
[ -f "/etc/ood/config/clusters.d/$CLUSTER_ID.yml" ] || echo "WARNING: no clusters.d/$CLUSTER_ID.yml, the app won't show up"
echo "Done. In OOD: Restart Web Server, then Interactive Apps -> VS Code -> Launch."

#!/usr/bin/env bash
# One node's part of the monitoring: node_exporter + the collectors that feed its textfile folder.
# 1-install.sh runs it as root on every node (ssh ... bash -s < node-setup.sh), with these variables:
#   SRC         MONITOR_ROOT (shared /home): node_exporter release + collectors/ are copied from here
#   NODE_REL    node_exporter release folder name         PORT       node_exporter's port
#   MASTER_IP   the only address let in to PORT          MONITOR_UNITS  regex of systemd units to report (site.conf)
#   GPU_NODE=1  Slurm lists GPUs here -> gpu-metrics every 15 s     GPU_TYPES  e.g. "a30" ("" = every GPU)
#   SLURM=1     this is master -> slurm-metrics every 30 s           SLURM_BIN, SLURM_CONF  for scontrol/squeue
# Prints one line about this node. Safe to rerun: changes only what differs.
set -euo pipefail
: "${SRC:?}" "${NODE_REL:?}" "${PORT:?}" "${MASTER_IP:?}" "${MONITOR_UNITS:?}"
GPU_NODE=${GPU_NODE:-} GPU_TYPES=${GPU_TYPES:-} SLURM=${SLURM:-}
LIB=/usr/local/libexec/aistack-monitoring
TXT=/var/lib/node_exporter/textfile        # node's own disk: a hung NFS must not stall the exporter
UNITS=/etc/systemd/system
notes=() restart=

[ -x "$SRC/$NODE_REL/node_exporter" ] || { echo "no $SRC/$NODE_REL here: is the shared /home mounted?"; exit 1; }
need=(curl); [ -z "$SLURM" ] || need+=(python3)
for p in "${need[@]}"; do command -v "$p" >/dev/null || dnf -y -q install "$p" >/dev/null || { echo "can't install $p"; exit 1; }; done
id node_exporter >/dev/null 2>&1 || useradd -r -M -d / -s /sbin/nologin -c "Prometheus node exporter" node_exporter
install -d -m 755 "$LIB"
install -d -m 755 -o node_exporter -g node_exporter "$TXT"

copy() {  # copy <src> <dest>: only when different; sets restart for node_exporter itself
  cmp -s "$1" "$2" && return; install -D -m 755 "$1" "$2"; [ "$2" != /usr/local/bin/node_exporter ] || restart=1   # -D: some nodes have no /usr/local/bin
}
unit() {  # unit <name>: stdin -> $UNITS/<name> when different
  local new; new=$(cat)
  [ "$(cat "$UNITS/$1" 2>/dev/null)" = "$new" ] && return
  printf '%s\n' "$new" > "$UNITS/$1"; systemctl daemon-reload; [ "$1" != node_exporter.service ] || restart=1
}
drop() {  # drop <collector>: no longer wanted on this node (e.g. its GPUs left Slurm)
  [ -e "$UNITS/$1.timer" ] || return 0
  systemctl disable -q --now "$1.timer" 2>/dev/null || true
  rm -f "$UNITS/$1.timer" "$UNITS/$1.service" "$TXT/${1%-metrics}.prom" "$LIB/$1"; systemctl daemon-reload
}
collector() {  # collector <name> <every> <command> [Environment= lines]: oneshot service + timer, run once now
  local name=$1 every=$2 cmd=$3; shift 3
  unit "$name.service" <<EOF
# Written by OOD-Install/9-monitoring (node-setup.sh). Output: $TXT/${name%-metrics}.prom, read by node_exporter.
[Unit]
Description=$name for node_exporter

[Service]
Type=oneshot
User=node_exporter
Group=node_exporter
ExecStart=$cmd
$(printf '%s\n' "$@")
TimeoutStartSec=60
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
EOF
  unit "$name.timer" <<EOF
# Written by OOD-Install/9-monitoring (node-setup.sh)
[Unit]
Description=Run $name every $every

[Timer]
OnBootSec=15s
OnUnitActiveSec=$every
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
  systemctl enable -q --now "$name.timer"
  systemctl start "$name.service" || true     # a failure is in the metrics (…_collector_ok 0) and the journal
}

# services to watch HERE: the MONITOR_UNITS this node has enabled (generated = podman quadlets like keycloak).
# Installed-but-disabled ones (nfs-server on a compute node) would read as "down" forever.
watch=$(for u in $(systemctl list-units --all --type=service --plain --no-legend | awk '{print $1}' | grep -E "^($MONITOR_UNITS)[.]service$"); do
  case $(systemctl is-enabled "$u" 2>/dev/null) in enabled|generated) echo "${u%.service}";; esac
done | sort | paste -sd'|')
copy "$SRC/$NODE_REL/node_exporter" /usr/local/bin/node_exporter
unit node_exporter.service <<EOF
# Written by OOD-Install/9-monitoring (node-setup.sh). Scraped by Prometheus on $MASTER_IP only (firewalld).
[Unit]
Description=Prometheus node exporter (CPU, RAM, disk, network + $TXT/*.prom)
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:$PORT --collector.textfile.directory=$TXT ${watch:+--collector.systemd --collector.systemd.unit-include=($watch)[.]service}
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now node_exporter
[ -z "$restart" ] || systemctl restart node_exporter

if [ -n "$GPU_NODE" ]; then
  copy "$SRC/collectors/gpu-metrics.sh" "$LIB/gpu-metrics"
  collector gpu-metrics 15s "$LIB/gpu-metrics $TXT/gpu.prom" "Environment=GPU_TYPES=$GPU_TYPES"
  command -v nvidia-smi >/dev/null || notes+=("WARNING: Slurm says GPUs, but no nvidia-smi: gpu_collector_ok 0 until the NVIDIA driver is installed")
else drop gpu-metrics; fi

if [ -n "$SLURM" ]; then
  copy "$SRC/collectors/slurm-metrics.py" "$LIB/slurm-metrics"
  collector slurm-metrics 30s "$LIB/slurm-metrics $TXT/slurm.prom" \
    "Environment=PATH=$SLURM_BIN:/usr/bin:/bin" "Environment=SLURM_CONF=$SLURM_CONF"
else drop slurm-metrics; fi

if systemctl is-active -q firewalld; then
  rule="rule family=ipv4 source address=$MASTER_IP port port=$PORT protocol=tcp accept"
  firewall-cmd -q --permanent --query-rich-rule="$rule" || { firewall-cmd -q --permanent --add-rich-rule="$rule"; firewall-cmd -q --reload; }
else notes+=("WARNING: firewalld is off: port $PORT is open to the whole network"); fi

for _ in 1 2 3 4 5; do m=$(curl -sf "http://localhost:$PORT/metrics" || true); [ -n "$m" ] && break; sleep 1; done
[ -n "$m" ] || { echo "node_exporter doesn't answer on :$PORT (journalctl -u node_exporter)"; exit 1; }
summary="node_exporter ok, services: ${watch:-none}"
[ -z "$GPU_NODE" ] || summary+=", GPUs: $(grep -c '^gpu_memory_total_bytes' <<<"$m" || true) (collector ok=$(awk '/^gpu_collector_ok/ {print $2}' <<<"$m"))"
[ -z "$SLURM" ] || summary+=", Slurm collector ok=$(awk '/^slurm_collector_ok/ {print $2}' <<<"$m")"
echo "$summary"; for n in "${notes[@]}"; do echo "  $n"; done

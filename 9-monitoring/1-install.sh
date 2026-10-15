#!/usr/bin/env bash
# Cluster monitoring: ONE Prometheus on master, the single place every app reads cluster metrics from
# (OOD, Model Hub, anything later) at PROM_URL. Everything it collects comes from what this script installs:
#   node_exporter   every node (MASTER_HOST, LOGIN_NODES, COMPUTE_NODES): CPU, RAM, disk, network, plus files from
#   gpu-metrics     every node Slurm lists GPUs on, every 15 s: nvidia-smi -> use, memory, temperature, power
#   slurm-metrics   master, every 30 s: scontrol/squeue -> node state, CPUs/RAM/GPUs reserved, jobs per user
# Plain binaries + systemd, no containers, no k8s, no change to Slurm's config. Prometheus is read-only (no
# admin/lifecycle API), port open to LOGIN_IP and master; node_exporter's to master only.
# Installs what is ours (+ curl/python3/tar from dnf if missing). Only CHECKS what belongs to the cluster: Slurm,
# the NVIDIA driver, firewalld (never turned on), root ssh, the shared /home. Unreachable nodes: skipped, rerun later.
# Safe to rerun: changes only what differs, keeps the data.
# Run on master: sudo bash 1-install.sh       Needs internet once (or the release files put in MONITOR_ROOT by hand).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
export PATH="$SLURM_BIN:${SLURM_BIN%/bin}/sbin:$PATH" SLURM_CONF   # sudo drops both (see 4-vscode)
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST." >&2; exit 1; }
ETC=/etc/prometheus
PROM_REL=prometheus-$PROMETHEUS_VERSION.linux-amd64
NODE_REL=node_exporter-$NODE_EXPORTER_VERSION.linux-amd64
nodes=$(printf '%s\n' "$MASTER_HOST" $LOGIN_NODES $COMPUTE_NODES | awk '!seen[$0]++')
missed=()
on() {  # on <node> <script> [VAR=value ...]: run the script as root there (locally on this host); false if unreachable
  local n=$1 f=$2; shift 2
  if [ "$n" = "$(hostname -s)" ]; then env "$@" bash -s < "$f"
  else ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$n" "$(printf '%q ' env "$@") bash -s" < "$f"; fi
}

echo "== 1. Checks"
for p in curl python3 tar; do command -v $p >/dev/null || { echo "installing $p"; dnf -y -q install $p >/dev/null; }; done
sinfo -h -o %P >/dev/null 2>&1 && scontrol show config >/dev/null 2>&1 ||
  { echo "Slurm doesn't answer here (sinfo/scontrol): this monitoring reads node and job state from it." >&2; exit 1; }
systemctl -q is-active prometheus 2>/dev/null || ! ss -Hltn "sport = :$PROM_PORT" | grep -q . ||
  { echo "Port $PROM_PORT is taken by another program: stop it, or pick another PROM_PORT in site.conf." >&2; exit 1; }
# GPU nodes = the hosts Slurm has gres gpu on; their types (gpu:a30:1 -> a30) pick which GPUs count
declare -A gpu_types=()
while IFS='|' read -r host gres; do
  [[ $gres == *gpu* ]] || continue
  gpu_types[$host]=$(grep -oE 'gpu:[^:(,]+:[0-9]+' <<<"$gres" | cut -d: -f2 | sort -u | paste -sd'|' || true)
done < <(sinfo -h -N -o '%n|%G' | sort -u)
for h in "${!gpu_types[@]}"; do
  grep -qx "$h" <<<"$nodes" || echo "WARNING: Slurm has GPUs on $h, which isn't in site.conf (COMPUTE_NODES): not monitored"
done
echo "nodes: $(echo $nodes)   GPU nodes (Slurm): $(for h in "${!gpu_types[@]}"; do printf '%s(%s) ' "$h" "${gpu_types[$h]:-any}"; done)"

echo "== 2. Releases + collectors in $MONITOR_ROOT (shared /home: the nodes install from here)"
fetch() {  # fetch <repo> <release dir> <version> <sha256>: a tarball already in MONITOR_ROOT (hand-copied) is used as is
  local tgz=$MONITOR_ROOT/$2.tar.gz url=https://github.com/prometheus/$1/releases/download/v$3/$2.tar.gz
  [ -d "$MONITOR_ROOT/$2" ] && { echo "already there: $2"; return; }
  if [ ! -f "$tgz" ]; then
    curl -sfI -m 10 https://github.com >/dev/null ||
      { echo "No internet here. Download $url on another machine, copy it to $tgz, rerun." >&2; exit 1; }
    curl -fsSL --retry 3 -o "$tgz" "$url"
  fi
  echo "$4  $tgz" | sha256sum -c --quiet - ||
    { rm -f "$tgz"; echo "$2: checksum doesn't match site.conf. Wrong version/sha256 pair?" >&2; exit 1; }
  tar xzf "$tgz" -C "$MONITOR_ROOT" && rm -f "$tgz"
  echo "verified + unpacked: $2"
}
install -d -m 755 "$MONITOR_ROOT" "$MONITOR_ROOT/collectors"
fetch prometheus "$PROM_REL" "$PROMETHEUS_VERSION" "$PROMETHEUS_SHA256"
fetch node_exporter "$NODE_REL" "$NODE_EXPORTER_VERSION" "$NODE_EXPORTER_SHA256"
install -m 755 "$HERE/gpu-metrics.sh" "$HERE/slurm-metrics.py" "$MONITOR_ROOT/collectors/"
chmod -R a+rX "$MONITOR_ROOT"

echo "== 3. Every node: node_exporter (:$NODE_EXPORTER_PORT, only $MASTER_IP may scrape) + its collectors"
for n in $nodes; do
  args=(SRC="$MONITOR_ROOT" NODE_REL="$NODE_REL" PORT="$NODE_EXPORTER_PORT" MASTER_IP="$MASTER_IP")
  [ -z "${gpu_types[$n]+x}" ] || args+=(GPU_NODE=1 GPU_TYPES="${gpu_types[$n]}")
  [ "$n" != "$MASTER_HOST" ] || args+=(SLURM=1 SLURM_BIN="$SLURM_BIN" SLURM_CONF="$SLURM_CONF")
  if out=$(on "$n" "$HERE/node-setup.sh" "${args[@]}" 2>&1); then printf '%s: %s\n' "$n" "$out"
  else printf 'SKIPPED %s: %s\n' "$n" "$(tail -n 2 <<<"$out" | tr -d '\r' | tr '\n' ' ')"; missed+=("$n"); fi
done

echo "== 4. Prometheus $PROMETHEUS_VERSION on $PROM_URL (data $PROM_DATA, kept $PROM_RETENTION / max $PROM_RETENTION_SIZE)"
id prometheus >/dev/null 2>&1 || useradd -r -M -d "$PROM_DATA" -s /sbin/nologin -c "Prometheus" prometheus
install -d -m 755 "$ETC"
install -d -m 750 -o prometheus -g prometheus "$PROM_DATA"
new_bin=
for b in prometheus promtool; do
  cmp -s "$MONITOR_ROOT/$PROM_REL/$b" "/usr/local/bin/$b" || { install -m 755 "$MONITOR_ROOT/$PROM_REL/$b" "/usr/local/bin/$b"; new_bin=1; }
done
put() {  # put <file>: stdin -> $ETC/<file>; prints "<file> " if it changed
  local new; new=$(cat)
  [ "$(cat "$ETC/$1" 2>/dev/null)" = "$new" ] || { printf '%s\n' "$new" > "$ETC/$1"; printf '%s ' "$1"; }
  chmod 644 "$ETC/$1"
}
changed=$(put rules.yml < "$HERE/rules.yml")
changed+=$(put prometheus.yml <<EOF
# Written by OOD-Install/9-monitoring/1-install.sh from site.conf: edit those, not this file (a rerun overwrites it).
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels: {cluster: $CLUSTER_ID}
rule_files: [$ETC/rules.yml]

scrape_configs:
  - job_name: prometheus
    static_configs: [{targets: ['$MASTER_IP:$PROM_PORT'], labels: {node: $MASTER_HOST}}]

  # every node's node_exporter; its textfile folder adds gpu_* (GPU nodes) and slurm_* (master) series
  - job_name: node
    static_configs: [{targets: [$(for n in $nodes; do printf "'%s:%s', " "$n" "$NODE_EXPORTER_PORT"; done | sed 's/, $//')]}]
    relabel_configs:
      - {source_labels: [__address__], regex: '([^:]+):[0-9]+', target_label: node}
    metric_relabel_configs:
      # slurm_* series name the node they describe ("node" = its hostname), not master where they're collected:
      # Prometheus renames such a clashing label to exported_node; put it back
      - {source_labels: [exported_node], regex: '(.+)', target_label: node}
      - {regex: exported_node, action: labeldrop}
EOF
)
/usr/local/bin/promtool check config --syntax-only "$ETC/prometheus.yml" >/dev/null &&
  /usr/local/bin/promtool check rules "$ETC/rules.yml" >/dev/null ||
  { echo "promtool rejects $ETC/prometheus.yml or rules.yml (a running Prometheus keeps the old one)." >&2; exit 1; }
unit=$(cat <<EOF
# Written by OOD-Install/9-monitoring/1-install.sh. Query API (read-only): $PROM_URL/api/v1/query
[Unit]
Description=Prometheus (cluster metrics: nodes, GPUs, Slurm)
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=$ETC/prometheus.yml --storage.tsdb.path=$PROM_DATA --storage.tsdb.retention.time=$PROM_RETENTION --storage.tsdb.retention.size=$PROM_RETENTION_SIZE --web.listen-address=$MASTER_IP:$PROM_PORT
# config or rules changed: reread without a restart (no gap in the data)
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
TimeoutStopSec=120
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$PROM_DATA

[Install]
WantedBy=multi-user.target
EOF
)
if [ "$(cat /etc/systemd/system/prometheus.service 2>/dev/null)" != "$unit" ]; then
  printf '%s\n' "$unit" > /etc/systemd/system/prometheus.service; systemctl daemon-reload
  systemctl enable -q prometheus; systemctl restart prometheus; echo "unit written: (re)started"
elif ! systemctl -q is-active prometheus; then systemctl enable -q --now prometheus; echo "started"
elif [ -n "$new_bin" ]; then systemctl restart prometheus; echo "new version: restarted"
elif [ -n "$changed" ]; then systemctl reload prometheus; echo "reloaded: $changed"
else echo "running, nothing changed"; fi
if systemctl is-active -q firewalld; then
  rule="rule family=ipv4 source address=$LOGIN_IP port port=$PROM_PORT protocol=tcp accept"
  firewall-cmd -q --permanent --query-rich-rule="$rule" || { firewall-cmd -q --permanent --add-rich-rule="$rule"; firewall-cmd -q --reload; }
  echo "firewalld: port $PROM_PORT only from $LOGIN_IP (and master itself)"
else echo "WARNING: firewalld is off on $MASTER_HOST: port $PROM_PORT is open to the whole network"; fi
for _ in $(seq 30); do curl -sf -o /dev/null "$PROM_URL/-/ready" && break; sleep 2; done
curl -sf -o /dev/null "$PROM_URL/-/ready" || { echo "Prometheus not ready after 1 min: journalctl -u prometheus -n 50" >&2; exit 1; }

echo "== 5. Check (first scrapes take ~15 s)"
sleep 20
PROM_URL=$PROM_URL python3 - <<'PY'
import json, os, urllib.parse, urllib.request
url = os.environ["PROM_URL"]
def q(expr):
    with urllib.request.urlopen(f"{url}/api/v1/query?" + urllib.parse.urlencode({"query": expr}), timeout=10) as r:
        return json.load(r)["data"]["result"]
def by_node(expr, fmt):
    return {r["metric"].get("node"): fmt(float(r["value"][1])) for r in q(expr)}
with urllib.request.urlopen(f"{url}/api/v1/targets?state=active", timeout=10) as r:
    targets = json.load(r)["data"]["activeTargets"]
up = {t["labels"].get("node"): (t["health"], t["lastError"]) for t in targets if t["labels"]["job"] == "node"}
pct = lambda v: f"{v * 100:.0f}%"
cpu, ram = by_node("node:cpu_used:ratio", pct), by_node("node:mem_used:ratio", pct)
state = {r["metric"]["node"]: r["metric"]["state"] for r in q("slurm_node_info")}
gpus = {}
for r in q("gpu:util:ratio"):
    gpus.setdefault(r["metric"]["node"], []).append(f'{r["metric"]["name"].replace("NVIDIA ", "")} {pct(float(r["value"][1]))}')
print("  (CPU is a 5-min average: right after a (re)start it reads too high until Prometheus has 5 min of data)")
print(f"  {'node':10} {'exporter':9} {'CPU':>5} {'RAM':>5}  {'Slurm':22} GPUs (use)")
for n in sorted(set(up) | set(state)):
    h, err = up.get(n, ("-", ""))
    print(f"  {n:10} {h:9} {cpu.get(n, '-'):>5} {ram.get(n, '-'):>5}  {state.get(n, '-'):22} {', '.join(gpus.get(n, [])) or '-'}"
          + (f"   ({err[:60]})" if err else ""))
seen, slurm = q("count(gpu:util:ratio)"), q("sum(slurm_node_gpus)")
print(f"  GPUs seen: {seen[0]['value'][1] if seen else 0}, in Slurm: {slurm[0]['value'][1] if slurm else '?'} (fewer seen = a GPU node is down)")
bad = [f'{r["metric"]["__name__"]} on {r["metric"].get("node")}' for r in q("gpu_collector_ok == 0 or slurm_collector_ok == 0")]
print("  collectors: " + ("all ok" if not bad else "FAILING: " + ", ".join(bad) + " (journalctl -u gpu-metrics / slurm-metrics there)"))
PY
echo
echo "Apps read: $PROM_URL/api/v1/query?query=node:cpu_used:ratio   (named queries: $ETC/rules.yml)"
echo "Web UI:    $PROM_URL (from $LOGIN_HOST, or ssh -L $PROM_PORT:$MASTER_IP:$PROM_PORT)"
echo "Stop/start: systemctl stop|start prometheus   (data stays in $PROM_DATA)"
[ ${#missed[@]} -eq 0 ] || echo "SKIPPED (unreachable): ${missed[*]}. Rerun this script when they're back."

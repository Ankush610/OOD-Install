#!/usr/bin/env bash
# This node's GPUs, from nvidia-smi, for node_exporter's textfile collector. gpu-metrics.timer runs it every 15 s.
# Only the GPU types Slurm schedules count (GPU_TYPES, e.g. "a30|h100", set by 1-install.sh): a display card
# next to them (an RTX A400 here) is not a GPU anyone can get. Empty GPU_TYPES = every GPU.
# nvidia-smi fails -> the file says gpu_collector_ok 0 and has no GPU numbers (no stale values).
# Usage: gpu-metrics.sh [out.prom]   (no argument: print to stdout, for testing)
set -uo pipefail
out=${1:-/dev/stdout}

csv=$(timeout 10 nvidia-smi --format=csv,noheader,nounits \
  --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw 2>&1) && ok=1 || ok=0

text=$(awk -F', *' -v ok="$ok" -v types="${GPU_TYPES:-}" '
  function add(m, v) { if (v ~ /^[0-9.]+$/) rows[m] = rows[m] sprintf("%s{%s} %s\n", m, l, v) }
  ok && NF >= 8 && (types == "" || tolower($2) ~ ("(^|[^a-z0-9])(" tolower(types) ")([^a-z0-9]|$)")) {
    l = sprintf("gpu=\"%s\",name=\"%s\",uuid=\"%s\"", $1, $2, $3)
    add("gpu_utilization_ratio", $4 == "" ? "" : $4 / 100)
    add("gpu_memory_used_bytes", $5 * 1048576)        # nvidia-smi says MiB
    add("gpu_memory_total_bytes", $6 * 1048576)
    add("gpu_temperature_celsius", $7)
    add("gpu_power_watts", $8)                        # "[N/A]" on some cards: left out
  }
  END {
    split("gpu_utilization_ratio gpu_memory_used_bytes gpu_memory_total_bytes gpu_temperature_celsius gpu_power_watts", ms, " ")
    for (i = 1; i <= 5; i++) if (ms[i] in rows) printf "# TYPE %s gauge\n%s", ms[i], rows[ms[i]]
    printf "# TYPE gpu_collector_ok gauge\ngpu_collector_ok %d\n", ok
  }' <<<"$csv")

# write next to the target, then rename: node_exporter never reads a half-written file
if [ "$out" = /dev/stdout ]; then printf '%s\n' "$text"
else tmp=$(mktemp "$out.XXXXXX") && printf '%s\n' "$text" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$out"; fi
[ "$ok" = 1 ] || { echo "nvidia-smi failed: $csv" >&2; exit 1; }

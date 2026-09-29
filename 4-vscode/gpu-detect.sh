#!/usr/bin/env bash
# Ask Slurm which partition has GPUs, of what type, how many per node, and each GPU's fair share of CPU/RAM.
# Reads `sinfo -h -N -o "%P|%N|%G|%c|%m"` on stdin (so it can be tested with made-up clusters), prints shell vars:
#   GPU_PARTITION  GPU_TYPE  GPU_MAX  CPUS_PER_GPU  MEM_PER_GPU_MB      (GPU_PARTITION="" = no GPUs found)
# Usage: sinfo -h -N -o "%P|%N|%G|%c|%m" | bash gpu-detect.sh <auto|partition name|"">
set -euo pipefail
# the script goes in -c: stdin is the sinfo data
python3 -c "$(cat <<'EOF'
import re, sys
want = sys.argv[1]
nodes = {}                                     # partition -> [(gpus, type, cpus, mem_mb)]
default = None
for line in sys.stdin:
    part, node, gres, cpus, mem = line.strip().split("|")
    if part.endswith("*"):
        part = part[:-1]; default = part
    # gres like gpu:a30:1   gpu:h100:8(S:0-1)   gpu:8   gpu:a30:1,shard:4
    m = re.search(r"\bgpu(?::([^:(,]+))?:(\d+)", gres)
    if m and int(m.group(2)) > 0:
        nodes.setdefault(part, []).append((int(m.group(2)), (m.group(1) or "GPU").upper(), int(cpus), int(mem)))
if want == "":
    pick = None
elif want == "auto":                           # Slurm's default partition if it has GPUs, else the first that does
    pick = default if default in nodes else next(iter(nodes), None)
else:
    if want not in nodes:
        sys.exit(f"partition {want!r} has no GPUs (GPU partitions: {', '.join(nodes) or 'none'})")
    pick = want
if not pick:
    print('GPU_PARTITION=""'); sys.exit()
rows = nodes[pick]
# ponytail: sizes from the smallest node, so a session fits on any node of the partition; mixed GPU types show as one label
gmax = max(r[0] for r in rows)
cpg = min(r[2] // r[0] for r in rows)
mpg = min(r[3] * 9 // 10 // r[0] for r in rows)   # 90% of RAM, the rest for the OS
types = "/".join(sorted({r[1] for r in rows}))
print(f'GPU_PARTITION="{pick}" GPU_TYPE="{types}" GPU_MAX={gmax} CPUS_PER_GPU={max(cpg, 1)} MEM_PER_GPU_MB={mpg}')
EOF
)" "${1-auto}"

#!/usr/bin/env bash
# Give master to Slurm as partition VIEWER_PARTITION for OOD tool sessions (VS Code "editor only"),
# while SSH logins and master's own services keep a fixed share that Slurm never hands out:
#   NodeName=master  <real hardware from slurmd -C>  CoreSpecCount=<reserved cores>  MemSpecLimit=<reserved MB>
#   PartitionName=viewer ... OverSubscribe=FORCE:<n>   up to n sessions share one core (idle editors ~0 CPU)
# Memory stays reserved per session (VSCODE_MEM), so (RAM - reserved) / VSCODE_MEM is the real session limit.
# Run on master: sudo bash 2-slurm-viewer.sh      Safe to rerun. Needs root ssh to the compute nodes.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
# sudo resets PATH to /usr/sbin:/usr/bin (misses a Slurm under /usr/local) and drops SLURM_CONF
# (then the tools look for a config in DNS: "resolve_ctls_from_dns_srv ... Unknown host")
export PATH="$SLURM_BIN:${SLURM_BIN%/bin}/sbin:$PATH" SLURM_CONF
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST." >&2; exit 1; }
CONF=$SLURM_CONF

echo "== 1. Checks + master's hardware"
systemctl is-active munge
systemctl cat slurmd >/dev/null    # no unit on master? copy slurmd.service from a compute node
hw=$(slurmd -C | head -1)          # NodeName=<host> CPUs=.. Boards=.. SocketsPerBoard=.. ... RealMemory=..
[[ "$hw" == "NodeName=$MASTER_HOST "* ]] || { echo "slurmd -C says: $hw" >&2; exit 1; }
cpus=$(sed -n 's/.* CPUs=\([0-9]*\).*/\1/p' <<<"$hw")
mem=$(sed -n 's/.* RealMemory=\([0-9]*\).*/\1/p' <<<"$hw")
mem=$(( mem * 98 / 100 ))          # a little under what the kernel reports, so a reboot/kernel change never drains the node
(( VIEWER_RESERVED_CORES < cpus && VIEWER_RESERVED_MEM_MB < mem )) ||
  { echo "Reservation ($VIEWER_RESERVED_CORES cores, $VIEWER_RESERVED_MEM_MB MB) leaves nothing of $cpus cores / $mem MB." >&2; exit 1; }
NODE="$(sed 's/ RealMemory=[0-9]*//' <<<"$hw") RealMemory=$mem CoreSpecCount=$VIEWER_RESERVED_CORES MemSpecLimit=$VIEWER_RESERVED_MEM_MB"
PART="PartitionName=$VIEWER_PARTITION Nodes=$MASTER_HOST Default=NO MaxTime=12:00:00 OverSubscribe=FORCE:$VIEWER_OVERSUBSCRIBE"
cores=$(( cpus - VIEWER_RESERVED_CORES )); gb=$(( (mem - VIEWER_RESERVED_MEM_MB) / 1024 ))
echo "master: $cpus cores, $mem MB -> Slurm gets $cores cores / ~${gb} GB, SSH + services keep $VIEWER_RESERVED_CORES cores / $(( VIEWER_RESERVED_MEM_MB / 1024 )) GB"

echo "== 2. $CONF"
BAK=$CONF.bak.$(date +%F-%H%M%S); cp "$CONF" "$BAK"
if grep -q "^NodeName=$MASTER_HOST " "$CONF"; then sed -i "s|^NodeName=$MASTER_HOST .*|$NODE|" "$CONF"; else echo "$NODE" >> "$CONF"; fi
if grep -q "^PartitionName=$VIEWER_PARTITION " "$CONF"; then sed -i "s|^PartitionName=$VIEWER_PARTITION .*|$PART|" "$CONF"; else echo "$PART" >> "$CONF"; fi
grep -E "^(NodeName=$MASTER_HOST|PartitionName=$VIEWER_PARTITION) " "$CONF"
if cmp -s "$CONF" "$BAK"; then rm -f "$BAK"; echo "no change to the file"; else echo "backup: $BAK"; fi

echo "== 3. Same slurm.conf on every node (a node that's down gets it when it's back)"
missed=()
for n in $COMPUTE_NODES; do
  if scp -q -o ConnectTimeout=5 -o BatchMode=yes "$CONF" "root@$n:$CONF"; then echo "copied to $n"
  else echo "SKIPPED $n (unreachable)"; missed+=("$n"); fi
done

echo "== 4. Apply (running jobs survive)"
# Compare with what slurmctld RUNS with, not with the old file: a rerun after a half-finished run
# finds the file already edited, but the controller still on the old node size.
running=$(scontrol show node "$MASTER_HOST" 2>/dev/null)
if ! grep -q "CPUTot=$cpus " <<<"$running" || ! grep -q "RealMemory=$mem " <<<"$running" ||
   ! grep -q "CoreSpecCount=$VIEWER_RESERVED_CORES " <<<"$running" || ! grep -q "MemSpecLimit=$VIEWER_RESERVED_MEM_MB" <<<"$running"; then
  echo "master's resources changed: restarting slurmctld and master's slurmd"
  # new node resources need the controller and master's slurmd restarted
  systemctl restart slurmctld
  systemctl enable --now slurmd
  systemctl restart slurmd
fi
scontrol reconfigure               # every daemon rereads slurm.conf

echo "== 5. Check"
sleep 3
scontrol show node "$MASTER_HOST" | grep -oE "(CPUTot|CPUEfctv|RealMemory|CoreSpecCount|MemSpecLimit|State)=[^ ]*" | tr '\n' ' '; echo
sinfo -p "$VIEWER_PARTITION" -o "%P %N %c %m %h %l"      # %h: FORCE:$VIEWER_OVERSUBSCRIBE
timeout 60 srun -p "$VIEWER_PARTITION" -t 1 --mem=100M hostname      # expect: $MASTER_HOST
echo
if [ ${#missed[@]} -gt 0 ]; then
  echo "NOT copied to: ${missed[*]}. When they're back: rerun this script (or scp $CONF root@<node>:$CONF)."
  echo "Until then those nodes still have the old slurm.conf (Slurm logs a config mismatch for them)."
fi
echo "Done. Next: sudo bash 3-install-ood-app.sh"

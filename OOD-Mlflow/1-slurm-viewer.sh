#!/usr/bin/env bash
# Add master to Slurm as a small node in its own partition "viewer",
# so MLflow sessions never take a compute node.
# Run on master: sudo bash 1-slurm-viewer.sh
set -euo pipefail

VIEWER_NODE=master                # must match `hostname -s`
VIEWER_CPUS=12                    # 1 CPU per MLflow session
VIEWER_MEM_MB=24576               # 2 GB per session -> ~10 users at once, plus headroom
COMPUTE_NODES="cn01 cn02"
SLURM_CONF=/etc/slurm/slurm.conf

echo "== 1. Checks"
command -v slurmd >/dev/null || ls /usr/local/sbin/slurmd >/dev/null
systemctl cat slurmd >/dev/null   # no unit? copy slurmd.service from a compute node
systemctl is-active munge

echo "== 2. slurm.conf"
if ! grep -q "^NodeName=${VIEWER_NODE} " "$SLURM_CONF"; then
  cp "$SLURM_CONF" "$SLURM_CONF.bak.$(date +%F-%H%M)"
  cat >> "$SLURM_CONF" <<EOF
NodeName=${VIEWER_NODE} CPUs=${VIEWER_CPUS} RealMemory=${VIEWER_MEM_MB}
PartitionName=viewer Nodes=${VIEWER_NODE} Default=NO MaxTime=12:00:00
EOF
else
  echo "already has NodeName=${VIEWER_NODE}, leaving it"
fi

echo "== 3. Same slurm.conf everywhere, restart"
for n in $COMPUTE_NODES; do scp "$SLURM_CONF" "root@${n}:${SLURM_CONF}"; done
systemctl restart slurmctld
systemctl enable --now slurmd
systemctl restart slurmd
for n in $COMPUTE_NODES; do ssh "root@${n}" systemctl restart slurmd; done

echo "== 4. Check"
sleep 3
sinfo -p viewer
srun -p viewer hostname           # expect: master
echo "Done."

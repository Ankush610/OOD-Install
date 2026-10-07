#!/usr/bin/env bash
# Prove the per-user rules with two real users, acting AS them (their own kubeconfig, their own RBAC):
#   pods run as their owner, users can't touch each other's namespace, one GPU per user, pods become Slurm jobs.
# Uses the pause image every node already has (containerd's sandbox image), so it works offline.
# Run on master after 2-sync-users.sh:  sudo bash 3-test-tenancy.sh <userA> <userB>
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
export PATH="$SLURM_BIN:$PATH" SLURM_CONF
[ "$(id -u)" = 0 ] || { echo "Run with sudo (reads the users' kubeconfigs)." >&2; exit 1; }
A=${1:?usage: sudo bash 3-test-tenancy.sh <userA> <userB>}; B=${2:?usage: sudo bash 3-test-tenancy.sh <userA> <userB>}
IMG=$(sed -n "s/^\s*sandbox\s*=\s*'\(.*\)'/\1/p" /etc/containerd/config.toml | head -1); IMG=${IMG:-registry.k8s.io/pause:3.10.1}
uidA=$(id -u "$A"); gidA=$(id -g "$A"); uidB=$(id -u "$B")
kA() { kubectl --kubeconfig "$(getent passwd "$A" | cut -d: -f6)/.kube/aistack.config" "$@"; }
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; echo "      $2" | head -3; fail=$((fail+1)); }
expect_ok()   { local out; if out=$("${@:2}" 2>&1); then ok "$1"; else bad "$1" "$out"; fi; }
expect_deny() { local out; if out=$("${@:3}" 2>&1); then bad "$1 (was allowed)" "$out"
                elif grep -qiE "$2" <<<"$out"; then ok "$1"; else bad "$1 (denied for another reason)" "$out"; fi; }

pod() {  # pod <name> <ns> <uid> <gid> [gpu|claim:<name>]  -> pod YAML on stdout
  local res="{ requests: { cpu: 100m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }" claims=""
  [ "${5-}" = gpu ] && res="{ requests: { cpu: 100m, memory: 64Mi, nvidia.com/gpu: 1 }, limits: { cpu: 100m, memory: 64Mi, nvidia.com/gpu: 1 } }"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels: { app: mh-test }
  # pod-has-time-limit: every pod here is a Slurm job, so it needs a time limit (minutes) and must share the node
  annotations: { slurmjob.slinky.slurm.net/timelimit: "${TL:-10}", slurmjob.slinky.slurm.net/exclusive: "false" }
spec:
  tolerations: [{ key: slinky.slurm.net/managed-node, operator: Exists, effect: NoExecute }]
  securityContext: { runAsUser: $3, runAsGroup: $4, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: c
    image: $IMG
    imagePullPolicy: IfNotPresent
    securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
    resources: $res
EOF
}
claim() {  # claim <name> <ns> <deviceclass>
  cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata: { name: $1, namespace: $2 }
spec: { devices: { requests: [{ name: g, exactly: { deviceClassName: $3 } }] } }
EOF
}

echo "== $A ($uidA) vs $B ($uidB), image $IMG"
kA delete pod -l app=mh-test --wait=false >/dev/null 2>&1

echo "-- RBAC"
expect_ok   "$A can list pods in u-$A"                              kA -n "u-$A" get pods
expect_deny "$A can't list pods in u-$B"             "forbidden"     kA -n "u-$B" get pods
expect_deny "$A can't create pods in u-$B"           "forbidden"     kA create --dry-run=server -f <(pod t u-"$B" "$uidB" "$uidB")
expect_deny "$A can't relabel u-$A (e.g. its uid)"   "forbidden"     kA label ns "u-$A" aistack/uid=0 --overwrite
expect_deny "$A can't create PersistentVolumes"      "^no"           kA auth can-i create persistentvolumes

echo "-- Pod UID policy"
expect_ok   "pod as $A in u-$A is accepted"                          kA create --dry-run=server -f <(pod t u-"$A" "$uidA" "$gidA")
expect_deny "pod as $B ($uidB) in u-$A is rejected"  "uid/gid|runAsUser" kA create --dry-run=server -f <(pod t u-"$A" "$uidB" "$gidA")
expect_deny "pod as root in u-$A is rejected"        "uid/gid|runAsUser|runAsNonRoot" kA create --dry-run=server -f <(pod t u-"$A" 0 0)
expect_deny "pod with no securityContext rejected"   "uid/gid|runAsUser|runAsNonRoot|securityContext" \
            kA create --dry-run=server -f <(pod t u-"$A" "$uidA" "$gidA" | sed '/^  securityContext:/d')

echo "-- Time limit policy (max $(kubectl get ns "u-$A" -o jsonpath='{.metadata.labels.aistack/max-hours}') h for $A)"
maxh=$(kubectl get ns "u-$A" -o jsonpath='{.metadata.labels.aistack/max-hours}')
expect_deny "pod with no time limit rejected"         "timelimit"   kA create --dry-run=server -f <(pod t u-"$A" "$uidA" "$gidA" | sed '/slurmjob/d; /^  annotations:/d')
expect_deny "pod over the max ($((maxh + 1)) h) rejected"  "over your maximum" kA create --dry-run=server -f <(TL=$(( (maxh + 1) * 60 )) pod t u-"$A" "$uidA" "$gidA")
expect_ok   "pod at the max ($maxh h) accepted"                     kA create --dry-run=server -f <(TL=$(( maxh * 60 )) pod t u-"$A" "$uidA" "$gidA")
expect_deny "pod asking for the whole node rejected"  "exclusive"   kA create --dry-run=server -f <(pod t u-"$A" "$uidA" "$gidA" | sed 's/exclusive: "false"/exclusive: "true"/')

echo "-- slurm-bridge: a real pod becomes a Slurm job"
kA create -f <(pod mh-test-cpu u-"$A" "$uidA" "$gidA") >/dev/null
for _ in $(seq 30); do ph=$(kA -n "u-$A" get pod mh-test-cpu -o jsonpath='{.status.phase}'); [ "$ph" = Running ] && break; sleep 2; done
sched=$(kA -n "u-$A" get pod mh-test-cpu -o jsonpath='{.spec.schedulerName} {.spec.nodeName}')
if [ "$ph" = Running ] && [[ $sched == slurm-bridge-scheduler* ]]; then ok "cpu pod Running via slurm-bridge ($sched)"
else bad "cpu pod via slurm-bridge" "phase=$ph scheduler/node=$sched"; fi
squeue -h -p "$BRIDGE_PARTITION" -o '%i %j %u %T %N' | sed 's/^/      slurm: /'

echo "-- GPU quota ($(kubectl get ns "u-$A" -o jsonpath='{.metadata.labels.aistack/gpus}') for $A)"
kA create -f <(pod mh-test-gpu u-"$A" "$uidA" "$gidA" gpu) >/dev/null 2>&1 && ok "first GPU pod accepted (may wait for a free GPU)" \
  || bad "first GPU pod accepted" "$(kA create --dry-run=server -f <(pod x u-"$A" "$uidA" "$gidA" gpu) 2>&1)"
expect_deny "second GPU pod rejected"                "exceeded quota" kA create --dry-run=server -f <(pod mh-test-gpu2 u-"$A" "$uidA" "$gidA" gpu)
for cls in $(kubectl get deviceclass -o json | python3 -c '
import json,sys
for d in json.load(sys.stdin)["items"]:
    sel=" ".join(s.get("cel",{}).get("expression","") for s in d["spec"].get("selectors",[]))
    if "gpu.nvidia.com" in sel: print(d["metadata"]["name"])'); do
  expect_deny "direct ResourceClaim on '$cls' rejected" "exceeded quota" kA create --dry-run=server -f <(claim c u-"$A" "$cls")
done

echo "-- Clean up"
kA -n "u-$A" delete pod -l app=mh-test --wait=false
echo
echo "Result: $pass passed, $fail failed"
[ "$fail" = 0 ]

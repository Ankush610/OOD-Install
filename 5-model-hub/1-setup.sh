#!/usr/bin/env bash
# Model Hub, once per cluster: the modelhub account + MODELS_ROOT, the pod UID policy, one GPU DeviceClass
# per Slurm GPU type, and DynamicResources in slurm-bridge's scheduler (rerun after every slurm-bridge helm upgrade).
# Safe to rerun. Per-user parts (namespace, quota, kubeconfig) are 2-sync-users.sh.
# Run on master: sudo bash 1-setup.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
export PATH="$SLURM_BIN:$PATH" SLURM_CONF                    # sudo drops both
[ "$(id -u)" = 0 ] || { echo "Run with sudo (creates $MODELHUB_USER, owns $MODELS_ROOT)." >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

echo "== 1. Checks"
kubectl get node "$MASTER_HOST" >/dev/null
sinfo -h -p "$BRIDGE_PARTITION" -o %P | grep -q . || { echo "No Slurm partition $BRIDGE_PARTITION." >&2; exit 1; }
python3 "$HERE/gpu-classes.py" --test >/dev/null

echo "== 2. Service account $MODELHUB_USER ($MODELHUB_UID) owns $MODELS_ROOT"
owner=$(getent passwd "$MODELHUB_UID" | cut -d: -f1 || true)
if [ -z "$owner" ]; then
  groupadd -r -g "$MODELHUB_UID" "$MODELHUB_USER"
  useradd -r -u "$MODELHUB_UID" -g "$MODELHUB_UID" -d "$MODELS_ROOT" -M -s /sbin/nologin -c "Model Hub weights" "$MODELHUB_USER"
elif [ "$owner" != "$MODELHUB_USER" ]; then
  echo "UID $MODELHUB_UID already belongs to '$owner'. Pick a free MODELHUB_UID below $MIN_UID in site.conf." >&2; exit 1
fi
install -d -m 755 -o "$MODELHUB_UID" -g "$MODELHUB_UID" "$MODELS_ROOT" "$MODELS_ROOT/base"
ls -ld "$MODELS_ROOT" "$MODELS_ROOT/base"

echo "== 3. Pod UID policy (pods in u-<user> run as that user)"
kubectl apply -f "$HERE/onboarding/uid-policy.yaml"

echo "== 4. GPU DeviceClasses (Slurm GPU type -> exact DRA product name)"
gres=$(sinfo -h -p "$BRIDGE_PARTITION" -o %G | sort -u)
products=$(kubectl get resourceslices -o jsonpath='{range .items[?(@.spec.driver=="gpu.nvidia.com")]}{range .spec.devices[*]}{.attributes.productName.string}{"\n"}{end}{end}' | sort -u)
echo "Slurm: $(echo $gres)   DRA: $(echo "$products" | paste -sd, -)"
yaml=$(python3 "$HERE/gpu-classes.py" $gres <<<"$products")
if [ -n "$yaml" ]; then
  kubectl apply -f - <<<"$yaml"
else
  echo "No GPU class made: no GPU node is up, or Slurm's types don't match DRA's product names (see WARNING above)."
fi

echo "== 5. slurm-bridge scheduler: DynamicResources plugin (nvidia.com/gpu -> DRA claim -> GPU in the pod)"
# The chart's scheduler profile disables every default plugin (multiPoint '*') and has no value to add one back,
# so every `helm upgrade` of slurm-bridge drops DynamicResources again: rerun this script after one.
# Without it Slurm reserves the GPU but the pod's ResourceClaim is never allocated: no /dev/nvidia* in the pod.
cm=$(kubectl -n "$BRIDGE_NS" get cm scheduler-config -o json)
if grep -q DynamicResources <<<"$cm"; then
  echo "already enabled"
else
  python3 -c '
import json, re, sys
cm = json.load(sys.stdin)
key = "scheduler-config.yaml"
new, n = re.subn(r"^( *)multiPoint:\n", lambda m: f"{m[1]}multiPoint:\n{m[1]}  enabled:\n{m[1]}  - name: \x27DynamicResources\x27\n",
                 cm["data"][key], count=1, flags=re.M)
if not n:
    sys.exit("no multiPoint: in scheduler-config; chart changed, add DynamicResources by hand")
cm["data"][key] = new
print(json.dumps(cm))' <<<"$cm" | kubectl replace -f -
  kubectl -n "$BRIDGE_NS" rollout restart deploy/slurm-bridge-scheduler
  kubectl -n "$BRIDGE_NS" rollout status deploy/slurm-bridge-scheduler --timeout=120s
fi

echo "== 6. model-register -> /home/apps/bin (shared /home: once for every node, on everyone's PATH)"
install -d -m 755 /home/apps/bin
sed -e "s#@MODELS_ROOT@#$MODELS_ROOT#g" -e "s#@MLFLOW_DATA@#$MLFLOW_DATA#g" -e "s#@APPTAINER@#$APPTAINER#g" \
    -e "s#@ML_TRAIN_SIF@#$ML_TRAIN_SIF#g" -e "s#@MLFLOW_URI@#$MLFLOW_URI#g" "$HERE/model-register" > /home/apps/bin/model-register.new
chmod 755 /home/apps/bin/model-register.new && mv /home/apps/bin/model-register.new /home/apps/bin/model-register

echo "== 7. Check"
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding pod-runs-as-namespace-owner
kubectl get deviceclass -o custom-columns=CLASS:.metadata.name,MAPS:.spec.extendedResourceName
kubectl -n "$BRIDGE_NS" get cm scheduler-config -o jsonpath='{.data.scheduler-config\.yaml}' | grep -A2 'multiPoint:'
grep -q @ /home/apps/bin/model-register && echo "WARNING: model-register still has an unfilled @VAR@" >&2
echo
echo "Next: put base models under $MODELS_ROOT/base (as $MODELHUB_USER), then sudo bash 2-sync-users.sh"
echo "Admin base model: sudo /home/apps/bin/model-register --public $MODELS_ROOT/base/<org>/<model> <name>, then sudo bash ../3-mlflow/3-sync-tokens.sh"

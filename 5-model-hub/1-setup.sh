#!/usr/bin/env bash
# Model Hub, once per cluster: the modelhub account + MODELS_ROOT, the pod UID policy, and one GPU DeviceClass
# per Slurm GPU type. Safe to rerun. Per-user parts (namespace, quota, kubeconfig) are 2-sync-users.sh.
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

echo "== 5. Check"
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding pod-runs-as-namespace-owner
kubectl get deviceclass -o custom-columns=CLASS:.metadata.name,MAPS:.spec.extendedResourceName
echo
echo "Next: put base models under $MODELS_ROOT/base (as $MODELHUB_USER), then sudo bash 2-sync-users.sh"

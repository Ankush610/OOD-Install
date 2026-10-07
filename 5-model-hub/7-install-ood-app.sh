#!/usr/bin/env bash
# Install the Model Hub OOD app (runs as each logged-in user; see ood-app/model_hub/passenger_wsgi.py).
# site.json: MLflow URI, serving images (images/built.env), GPU types (sinfo), partition, hours, MODELS_ROOT.
# Run on master after 4-images.sh: sudo bash 7-install-ood-app.sh      then Restart Web Server in OOD
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
export PATH="$SLURM_BIN:$PATH" SLURM_CONF
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
APPS=/var/www/ood/apps/sys
APP=$APPS/model_hub
[ -d "$APPS" ] || { echo "No $APPS: run ../2-ood/setup-ood.sh first." >&2; exit 1; }
[ -f "$HERE/images/built.env" ] || { echo "No images/built.env: run 4-images.sh first." >&2; exit 1; }
source "$HERE/images/built.env"

echo "== 1. Copy the app (+ render.py, which builds the k8s objects)"
rm -rf "$APP"
cp -r "$HERE/ood-app/model_hub" "$APP"
cp "$HERE/render.py" "$APP/"
rm -rf "$APP/__pycache__"

echo "== 2. site.json"
gpu_types=$(sinfo -h -p "$BRIDGE_PARTITION" -o %G | grep -oE 'gpu:[^:(,]+:[0-9]+' | cut -d: -f2 | sort -u | paste -sd,)
python3 - "$APP/site.json" "$HERE/images" <<PY
import json, sys
# what each serving image has, for the model page's "trained with vs served with" check: the pinned libraries
# (images/<name>/constraints.txt, made by 4-images.sh) + mlflow (the image tag starts with its version)
def libs(name, image):
    pins = dict(l.strip().split("==", 1) for l in open(f"{sys.argv[2]}/{name}/constraints.txt") if "==" in l)
    return {**pins, "mlflow": image.rsplit(":", 1)[1].split("-")[0]}
json.dump({
    "image_libs": {"ml": libs("mlflow-serve-ml", "$MLFLOW_SERVE_ML"), "torch": libs("mlflow-serve-torch", "$MLFLOW_SERVE_TORCH")},
    "mlflow_uri": "$MLFLOW_URI",
    "mlflow_ui": {"port": $MLFLOW_PORT, "prefix": "$MLFLOW_PREFIX", "sso": "$OOD_AUTH" == "keycloak"},
    "images": {"ml": "$MLFLOW_SERVE_ML", "torch": "$MLFLOW_SERVE_TORCH", "vllm": "$VLLM_OPENAI"},
    "gpu_types": [t for t in "$gpu_types".split(",") if t],
    "partition": "$BRIDGE_PARTITION",
    "endpoint_hours": $ENDPOINT_HOURS,
    "models_root": "$MODELS_ROOT",
    "ssh": {"login": "$MASTER_HOST", "jump": "$SSH_JUMP"},
}, open(sys.argv[1], "w"), indent=1)
PY
chmod -R a+rX "$APP"
# Passenger restarts a running Python app (in every user's web server) when tmp/restart.txt changes;
# without it, users who already opened Model Hub keep the old code in memory until they Restart Web Server
install -d -m 755 "$APP/tmp" && touch "$APP/tmp/restart.txt"

echo "== 3. Check"
cat "$APP/site.json"; echo
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APP/passenger_wsgi.py" && echo "passenger_wsgi.py: OK"
echo "Done. In OOD: Restart Web Server, then Interactive Apps -> Model Hub."

#!/usr/bin/env bash
# Build the MLflow server image from the same packages as the shared venv and push it to the local registry.
# Run on master (no root needed): bash build-image.sh
set -euo pipefail

VENV=/home/apps/mlflow-venv                  # made by OOD-Mlflow/2-mlflow-app.sh
REGISTRY=master:5000
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== 1. requirements.txt from $VENV"
"$VENV/bin/pip" freeze --exclude-editable > "$HERE/requirements.txt"
MLFLOW_VERSION=$(sed -n 's/^mlflow==//p' "$HERE/requirements.txt")
[ -n "$MLFLOW_VERSION" ] || { echo "mlflow is not installed in $VENV." >&2; exit 1; }
IMAGE=$REGISTRY/mlflow-server:$MLFLOW_VERSION

echo "== 2. podman build $IMAGE"
podman build -t "$IMAGE" -f "$HERE/Containerfile" "$HERE"

echo "== 3. push"
podman push "$IMAGE"

echo "== 4. Check"
podman run --rm "$IMAGE" --version
curl -s "http://$REGISTRY/v2/mlflow-server/tags/list"; echo
grep -q "image: $IMAGE" "$HERE/mlflow.yaml" || echo "NOTE: set  image: $IMAGE  in mlflow.yaml"

#!/usr/bin/env bash
# Build the MLflow server image (image/: pinned packages + ldap_auth.py) and push it to the registry.
#   bash 1-build-image.sh                     build from image/requirements.txt as committed
#   bash 1-build-image.sh --from-venv <venv>  first rewrite requirements.txt from an existing venv's pip freeze
# Run on master, no root needed. After a change to image/ or MLFLOW_VERSION, bump the tag in site.conf.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
REQ=$HERE/image/requirements.txt

if [ "${1:-}" = "--from-venv" ]; then
  VENV=${2:?usage: bash 1-build-image.sh --from-venv <venv dir>}
  echo "== 0. requirements.txt from $VENV"
  "$VENV/bin/pip" freeze --exclude-editable > "$REQ"
fi

echo "== 1. Versions"
have=$(sed -n 's/^mlflow==//p' "$REQ")
[ "$have" = "$MLFLOW_VERSION" ] ||
  { echo "image/requirements.txt pins mlflow==$have, site.conf says MLFLOW_VERSION=$MLFLOW_VERSION. Make them equal." >&2; exit 1; }
echo "mlflow $MLFLOW_VERSION -> $MLFLOW_IMAGE"

echo "== 2. podman build"
podman build -t "$MLFLOW_IMAGE" -f "$HERE/image/Containerfile" "$HERE/image"

echo "== 3. push"
podman push "$MLFLOW_IMAGE"

echo "== 4. Check"
podman run --rm "$MLFLOW_IMAGE" --version
# find_spec, not import: importing ldap_auth pulls in the MLflow auth store, which needs the live config
podman run --rm --entrypoint python "$MLFLOW_IMAGE" -c 'import ldap3, importlib.util as u; assert u.find_spec("ldap_auth")' &&
  echo "ldap3 + ldap_auth.py: OK"
repo=${MLFLOW_IMAGE#*/}; curl -s "http://$REGISTRY/v2/${repo%:*}/tags/list"; echo
echo "Done. Next: sudo bash 2-deploy.sh"

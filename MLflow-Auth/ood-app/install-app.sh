#!/usr/bin/env bash
# Install the "MLflow (shared)" OOD app: a page with the tracking URI and Open MLflow, no Slurm.
# Run on master from this folder: sudo bash install-app.sh
set -euo pipefail

APPS=/var/www/ood/apps/sys
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== 1. Copy app"
cp -r "$HERE/apps/mlflow_k8s" "$APPS/"
chmod -R a+rX "$APPS/mlflow_k8s"
touch "$APPS/mlflow_k8s/passenger_wsgi.py"         # reload it in running web servers

echo "== 2. Check"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APPS/mlflow_k8s/passenger_wsgi.py"
echo "Done. In OOD: Restart Web Server, then Interactive Apps -> MLflow (shared)."

#!/usr/bin/env bash
# Install the "MLflow (shared)" OOD page: server status, tracking URI + Copy, Open MLflow.
# Run on master after ../2-ood: sudo bash 4-install-ood-app.sh     then Restart Web Server in OOD
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
APPS=/var/www/ood/apps/sys
APP=$APPS/mlflow_k8s

echo "== 1. Copy app + its settings (site.json, from site.conf)"
[ -d "$APPS" ] || { echo "No $APPS: run ../2-ood/setup-ood.sh first." >&2; exit 1; }
rm -rf "$APP"
cp -r "$HERE/ood-app/mlflow_k8s" "$APP"
rm -rf "$APP/__pycache__"
python3 -c 'import json,sys; json.dump({"host": sys.argv[1], "port": int(sys.argv[2]), "prefix": sys.argv[3]}, open(sys.argv[4], "w"))' \
  "$MASTER_IP" "$MLFLOW_PORT" "$MLFLOW_PREFIX" "$APP/site.json"
chmod -R a+rX "$APP"
touch "$APP/passenger_wsgi.py"                      # reload it in running web servers

echo "== 2. Check"
cat "$APP/site.json"; echo
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APP/passenger_wsgi.py" && echo "passenger_wsgi.py: OK"
echo "Done. In OOD: Restart Web Server, then Interactive Apps -> MLflow (shared)."

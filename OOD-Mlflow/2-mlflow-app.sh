#!/usr/bin/env bash
# Install shared MLflow and the OOD apps (MLflow session + Clean button helper).
# Run on master, from this folder: sudo bash 2-mlflow-app.sh
set -euo pipefail

MLFLOW_VERSION=3.15.1             # keep >= the mlflow-skinny version in training containers
VENV=/home/apps/mlflow-venv       # referenced by apps/mlflow/template/script.sh.erb and apps/mlflow_gc
APPS=/var/www/ood/apps/sys
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== 1. MLflow ${MLFLOW_VERSION} in ${VENV} (needs Python >= 3.10)"
dnf install -y python3.12
mkdir -p /home/apps
chmod 755 /home/apps
[ -x "$VENV/bin/python" ] || python3.12 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip "mlflow==${MLFLOW_VERSION}"
chmod -R a+rX "$VENV"

echo "== 2. OOD apps"
cp -r "$HERE/apps/mlflow" "$HERE/apps/mlflow_gc" "$APPS/"
chmod +x "$APPS/mlflow/template/script.sh.erb"
chmod -R a+rX "$APPS/mlflow" "$APPS/mlflow_gc"
touch "$APPS/mlflow_gc/passenger_wsgi.py"   # reload the helper in running web servers

echo "== 3. Check"
"$VENV/bin/mlflow" --version
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APPS/mlflow_gc/passenger_wsgi.py"
cat <<EOF

Done. In OOD: Restart Web Server, then Interactive Apps -> MLflow -> Launch.
EOF

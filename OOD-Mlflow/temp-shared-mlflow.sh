#!/usr/bin/env bash
# TEMP test: ONE shared MLflow server where each user sees only their own experiments/models.
# Run on master as the account that will own the data (not root): bash temp-shared-mlflow.sh
# Stop with Ctrl+C. Delete $DATA to start over.
set -euo pipefail

VENV=/home/apps/mlflow-venv                       # same venv as 2-mlflow-app.sh
DATA=/home/apps/mlflow-shared                     # only the server account can read this
PORT=${PORT:-5000}
ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -hex 12)}

mkdir -p "$DATA/artifacts"
chmod 700 "$DATA"                                 # users must go through the server, never NFS

cat > "$DATA/basic_auth.ini" <<EOF
[mlflow]
default_permission = NO_PERMISSIONS
database_uri = sqlite:///$DATA/auth.db
admin_username = admin
admin_password = $ADMIN_PASS
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
EOF
chmod 600 "$DATA/basic_auth.ini"

export MLFLOW_AUTH_CONFIG_PATH="$DATA/basic_auth.ini"
export MLFLOW_FLASK_SERVER_SECRET_KEY=$(openssl rand -hex 32)

echo "UI:     http://$(hostname -I | awk '{print $1}'):$PORT"
echo "admin:  admin / $ADMIN_PASS   (only used on first start; after that it lives in auth.db)"
echo "add a user:"
echo "  curl -u admin:$ADMIN_PASS -X POST http://localhost:$PORT/api/2.0/mlflow/users/create \\"
echo "       -H 'Content-Type: application/json' -d '{\"username\":\"alice\",\"password\":\"<pw>\"}'"

source "$VENV/bin/activate"
exec mlflow server --app-name basic-auth \
  --backend-store-uri "sqlite:///$DATA/mlflow.db" \
  --artifacts-destination "$DATA/artifacts" \
  --host 0.0.0.0 --port "$PORT" \
  --workers 1 \
  --allowed-hosts "*"

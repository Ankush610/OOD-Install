#!/usr/bin/env bash
# Deploy the shared MLflow pod (mlflow.yaml) on k8s. Safe to rerun, data and users survive.
# Run on master as the account that owns $DATA (admin, uid 1000 = runAsUser in mlflow.yaml): bash deploy.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DATA=/home/apps/mlflow-shared                     # hostPath in mlflow.yaml
URI=http://192.168.40.102:30500/node/192.168.40.102/30500

mkdir -p "$DATA/artifacts"
chmod 700 "$DATA"                                 # users must go through the server, never NFS

echo "== 1. Admin password (kept in $DATA/admin.pass)"
if [ ! -f "$DATA/admin.pass" ]; then
  [ ! -f "$DATA/auth.db" ] || : "${ADMIN_PASS:?auth.db already exists: run once with ADMIN_PASS=<admin password from the first start>}"
  (umask 077; echo "${ADMIN_PASS:-$(openssl rand -hex 12)}" > "$DATA/admin.pass")
fi
ADMIN_PASS=$(cat "$DATA/admin.pass")

(umask 077; cat > "$DATA/basic_auth.ini" <<EOF
[mlflow]
default_permission = NO_PERMISSIONS
database_uri = sqlite:////data/auth.db
admin_username = admin
admin_password = $ADMIN_PASS
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
EOF
)

echo "== 2. namespace, secret, pod (namespace mlflow, on master)"
kubectl apply -f "$HERE/mlflow.yaml"
kubectl -n mlflow get secret mlflow >/dev/null 2>&1 ||
  kubectl -n mlflow create secret generic mlflow --from-literal=flask-secret-key="$(openssl rand -hex 32)"
kubectl -n mlflow rollout restart deploy/mlflow  # pick up a new basic_auth.ini / image
kubectl -n mlflow rollout status deploy/mlflow --timeout=180s

echo "== 3. Check"
kubectl -n mlflow get pod -l app=mlflow -o wide; kubectl -n mlflow get svc mlflow
echo "health        -> $(curl -s -o /dev/null -w '%{http_code}' "$URI/health")   (expect 200)"
echo "api, no login -> $(curl -s -o /dev/null -w '%{http_code}' "$URI/api/2.0/mlflow/experiments/search?max_results=1")   (expect 401)"
echo "api, admin    -> $(curl -s -o /dev/null -w '%{http_code}' -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASS") "$URI/api/2.0/mlflow/users/get?username=admin")   (expect 200)"
cat <<EOF

Done. Tracking URI: $URI
Next: sudo bash ../mlflow-auth/sync-users.sh
EOF

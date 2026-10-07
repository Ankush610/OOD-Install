#!/usr/bin/env bash
# Deploy the shared MLflow pod on k8s from mlflow.yaml + ../site.conf. Safe to rerun: data and users survive.
# Run on master after 1-build-image.sh: sudo bash 2-deploy.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (creates $MLFLOW_USER, owns $MLFLOW_DATA)." >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}   # kubeadm's admin config on the control plane

echo "== 1. Checks"
[ -s "$LDAP_CA" ] || { echo "No $LDAP_CA: run ../1-ldap/1-server.sh first." >&2; exit 1; }
kubectl get node "$MASTER_HOST" >/dev/null
repo=${MLFLOW_IMAGE#*/}
curl -sf "http://$REGISTRY/v2/${repo%:*}/tags/list" | grep -q "\"${MLFLOW_IMAGE##*:}\"" ||
  { echo "$MLFLOW_IMAGE is not in the registry: run 1-build-image.sh first." >&2; exit 1; }

echo "== 2. Service account $MLFLOW_USER ($MLFLOW_UID) owns $MLFLOW_DATA"
owner=$(getent passwd "$MLFLOW_UID" | cut -d: -f1 || true)
if [ -z "$owner" ]; then
  groupadd -r -g "$MLFLOW_UID" "$MLFLOW_USER"
  useradd -r -u "$MLFLOW_UID" -g "$MLFLOW_UID" -d "$MLFLOW_DATA" -M -s /sbin/nologin -c "MLflow server" "$MLFLOW_USER"
elif [ "$owner" != "$MLFLOW_USER" ]; then
  echo "UID $MLFLOW_UID already belongs to '$owner'. Pick a free MLFLOW_UID below $MIN_UID in site.conf." >&2; exit 1
fi
mkdir -p "$MLFLOW_DATA/artifacts"
chown -R "$MLFLOW_UID:$MLFLOW_UID" "$MLFLOW_DATA"
chmod 700 "$MLFLOW_DATA"                          # users go through the server (permission checks), never the disk

echo "== 3. MLflow admin password ($MLFLOW_DATA/admin.pass) + auth config"
if [ ! -f "$MLFLOW_DATA/admin.pass" ]; then
  [ ! -f "$MLFLOW_DATA/auth.db" ] || : "${ADMIN_PASS:?auth.db already exists: rerun with ADMIN_PASS=<the MLflow admin password>}"
  (umask 077; echo "${ADMIN_PASS:-$(openssl rand -hex 12)}" > "$MLFLOW_DATA/admin.pass")
fi
ADMIN_PASS=$(cat "$MLFLOW_DATA/admin.pass")
# ldap_auth: people log in with their LDAP password; auth.db holds the admin and the job tokens
(umask 077; cat > "$MLFLOW_DATA/basic_auth.ini" <<EOF
[mlflow]
default_permission = NO_PERMISSIONS
database_uri = sqlite:////data/auth.db
admin_username = admin
admin_password = $ADMIN_PASS
authorization_function = ldap_auth:authenticate_request
EOF
)
# single sign-on: OOD's Apache sends this with the logged-in user (2-ood/setup-ood.sh, OOD_AUTH=keycloak)
[ -s "$MLFLOW_DATA/proxy.secret" ] || (umask 077; openssl rand -hex 32 | tr -d '\n' > "$MLFLOW_DATA/proxy.secret")
chown "$MLFLOW_UID:$MLFLOW_UID" "$MLFLOW_DATA/admin.pass" "$MLFLOW_DATA/basic_auth.ini" "$MLFLOW_DATA/proxy.secret"

echo "== 4. Apply (namespace mlflow, pinned to $MASTER_HOST)"
export MASTER_HOST MASTER_IP MLFLOW_IMAGE MLFLOW_PORT MLFLOW_PREFIX MLFLOW_DATA MLFLOW_UID LDAP_URI LDAP_BASE LDAP_CA
vars='$MASTER_HOST $MASTER_IP $MLFLOW_IMAGE $MLFLOW_PORT $MLFLOW_PREFIX $MLFLOW_DATA $MLFLOW_UID $LDAP_URI $LDAP_BASE $LDAP_CA'
envsubst "$vars" < "$HERE/mlflow.yaml" | kubectl apply -f -
kubectl -n mlflow get secret mlflow >/dev/null 2>&1 ||
  kubectl -n mlflow create secret generic mlflow --from-literal=flask-secret-key="$(openssl rand -hex 32)"
kubectl -n mlflow rollout restart deploy/mlflow  # pick up a new basic_auth.ini / image
kubectl -n mlflow rollout status deploy/mlflow --timeout=180s

echo "== 5. Check"
kubectl -n mlflow get pod -l app=mlflow -o wide; kubectl -n mlflow get svc mlflow
echo "health        -> $(curl -s -o /dev/null -w '%{http_code}' "$MLFLOW_URI/health")   (expect 200)"
echo "api, no login -> $(curl -s -o /dev/null -w '%{http_code}' "$MLFLOW_URI/api/2.0/mlflow/experiments/search?max_results=1")   (expect 401)"
echo "api, admin    -> $(curl -s -o /dev/null -w '%{http_code}' -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASS") "$MLFLOW_URI/api/2.0/mlflow/users/get?username=admin")   (expect 200)"
cat <<EOF

Done. Tracking URI: $MLFLOW_URI
Next: sudo bash 3-sync-tokens.sh
EOF
if [ "$OOD_AUTH" = keycloak ] && ! grep -q X-MLflow-Proxy-Secret /etc/ood/config/ood_portal.yml 2>/dev/null; then
  echo "OOD_AUTH=keycloak: also rerun ../2-ood/setup-ood.sh, so the web UI opens through OOD without a second password."
fi

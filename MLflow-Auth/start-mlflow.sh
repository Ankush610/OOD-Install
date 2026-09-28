#!/usr/bin/env bash
# ONE shared MLflow server where each user sees only their own experiments/models.
# Starts MLflow, then creates every user in users.txt (or resets their password to the one in the file).
# Already running? It only syncs users.txt, so rerun it after adding a user.
# Run on master as the account that will own the data (not root): bash start-mlflow.sh
# Stop with Ctrl+C. Data, users and the admin password live in $DATA and survive restarts.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
VENV=/home/apps/mlflow-venv                       # same venv as 2-mlflow-app.sh, needs mlflow[auth]
DATA=/home/apps/mlflow-shared                     # only the server account can read this
PORT=${PORT:-5050}
USERS=${USERS:-$HERE/users.txt}                   # one "username:password" per line
URL=http://localhost:$PORT
API=$URL/api/2.0/mlflow/users

mkdir -p "$DATA/artifacts"
chmod 700 "$DATA"                                 # users must go through the server, never NFS
chmod 600 "$USERS"

echo "== 1. Admin password (kept in $DATA/admin.pass)"
if [ ! -f "$DATA/admin.pass" ]; then
  [ ! -f "$DATA/auth.db" ] || : "${ADMIN_PASS:?auth.db already exists: run once with ADMIN_PASS=<admin password from the first start>}"
  (umask 077; echo "${ADMIN_PASS:-$(openssl rand -hex 12)}" > "$DATA/admin.pass")
fi
ADMIN_PASS=$(cat "$DATA/admin.pass")

cat > "$DATA/basic_auth.ini" <<EOF
[mlflow]
default_permission = NO_PERMISSIONS
database_uri = sqlite:///$DATA/auth.db
admin_username = admin
admin_password = $ADMIN_PASS
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
EOF
chmod 600 "$DATA/basic_auth.ini"

echo "== 2. MLflow on port $PORT"
up() { [ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/")" != 000 ]; }
SERVER_PID=
if up; then
  echo "already running, only syncing users"
else
  export MLFLOW_AUTH_CONFIG_PATH="$DATA/basic_auth.ini"
  export MLFLOW_FLASK_SERVER_SECRET_KEY=$(openssl rand -hex 32)
  "$VENV/bin/mlflow" server --app-name basic-auth \
    --backend-store-uri "sqlite:///$DATA/mlflow.db" \
    --artifacts-destination "$DATA/artifacts" \
    --host 0.0.0.0 --port "$PORT" \
    --workers 1 \
    --allowed-hosts "*" &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null' EXIT     # background jobs ignore Ctrl+C, so stop it ourselves
  for _ in $(seq 60); do
    up && break
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "MLflow exited, see the error above." >&2; exit 1; }
    sleep 1
  done
  up || { echo "MLflow did not answer within 60 s." >&2; exit 1; }
fi

curl -sf -o /dev/null -u "admin:$ADMIN_PASS" "$API/get?username=admin" || {
  rm -f "$DATA/admin.pass"
  echo "admin login failed: rerun with ADMIN_PASS=<admin password from the first start>." >&2
  exit 1
}

echo "== 3. Users from $USERS"
call() {  # call <METHOD> <endpoint> <user> <pass>  -> prints HTTP code
  local body
  body=$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$3" "$4")
  curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PASS" -X "$1" "$API/$2" \
       -H 'Content-Type: application/json' -d "$body"
}
while IFS=: read -r user pass || [ -n "$user" ]; do
  [[ -z "$user" || "$user" == \#* ]] && continue
  [ -n "$pass" ] || { echo "SKIP    $user (no password)"; continue; }
  if [ "$(call POST create "$user" "$pass")" = 200 ]; then
    echo "added   $user"
  elif [ "$(call PATCH update-password "$user" "$pass")" = 200 ]; then
    echo "updated $user"
  else
    echo "FAILED  $user"
  fi
done < "$USERS"

echo "== 4. Ready"
echo "UI:     http://$(hostname -I | awk '{print $1}'):$PORT"
echo "admin:  admin / $ADMIN_PASS"
[ -z "$SERVER_PID" ] || wait "$SERVER_PID"

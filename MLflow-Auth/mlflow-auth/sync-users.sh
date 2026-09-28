#!/usr/bin/env bash
# Give every user in users.txt ONE password for both OOD and MLflow, plus ~/.mlflow/credentials for their jobs.
# New user: add a line to users.txt and rerun. Changed password: edit the line and rerun.
# Run on master after ../mlflow-server/deploy.sh: sudo bash sync-users.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
USERS=${USERS:-$HERE/users.txt}                   # one "username:password" per line
DATA=/home/apps/mlflow-shared                     # admin.pass lives here (deploy.sh)
API=http://192.168.40.102:30500/node/192.168.40.102/30500/api/2.0/mlflow/users
HTPASSWD=/etc/ood/htpasswd                        # OOD login (OOD-Setup/setup-ood.sh)

[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes $HTPASSWD and users' home dirs)." >&2; exit 1; }
chmod 600 "$USERS"
ADMIN_PASS=$(cat "$DATA/admin.pass")
curl -sf -o /dev/null -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASS") "$API/get?username=admin" ||
  { echo "MLflow at $API does not answer or admin login fails. Run ../mlflow-server/deploy.sh first." >&2; exit 1; }

call() {  # call <METHOD> <endpoint> <user> <pass>  -> prints HTTP code (passwords stay out of ps)
  python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$3" "$4" |
    curl -s -o /dev/null -w '%{http_code}' -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASS") \
         -X "$1" "$API/$2" -H 'Content-Type: application/json' --data-binary @-
}

while IFS=: read -r user pass || [ -n "$user" ]; do
  [[ -z "$user" || "$user" == \#* ]] && continue
  [ -n "$pass" ] || { echo "SKIP    $user (no password)"; continue; }
  [ ${#pass} -ge 12 ] || { echo "SKIP    $user (MLflow needs a password of 12+ characters)"; continue; }
  home=$(getent passwd "$user" | cut -d: -f6) || { echo "SKIP    $user (no Linux user, OOD needs one)"; continue; }

  if [ "$(call POST create "$user" "$pass")" = 200 ]; then
    state=added
  elif [ "$(call PATCH update-password "$user" "$pass")" = 200 ]; then
    state=updated
  else
    echo "FAILED  $user (MLflow)"; continue
  fi

  printf '%s\n' "$pass" | htpasswd -i "$HTPASSWD" "$user" 2>/dev/null

  install -d -m 700 -o "$user" -g "$(id -gn "$user")" "$home/.mlflow"
  (umask 077; printf '[mlflow]\nmlflow_tracking_username = %s\nmlflow_tracking_password = %s\n' "$user" "$pass" \
     > "$home/.mlflow/credentials")
  chown "$user:$(id -gn "$user")" "$home/.mlflow/credentials"

  echo "$state $user"
done < "$USERS"

cat <<EOF

Done. Each user now logs in to OOD with the password from $(basename "$USERS"),
and their jobs only need:  export MLFLOW_TRACKING_URI=${API%/api/2.0/mlflow/users}
EOF

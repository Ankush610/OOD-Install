#!/usr/bin/env bash
# Create every user in users.txt on the shared MLflow. If a user already exists, reset their password.
# Safe to rerun after editing users.txt. MLflow must be running (start-mlflow.sh).
# Run on master: ADMIN_PASS=<admin password> bash add-users.sh [users-file]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FILE=${1:-$HERE/users.txt}
URL=${URL:-http://localhost:${PORT:-5050}}/api/2.0/mlflow/users
: "${ADMIN_PASS:?set ADMIN_PASS=<admin password from the first start>}"

chmod 600 "$FILE"
curl -sf -o /dev/null -u "admin:$ADMIN_PASS" "$URL/get?username=admin" ||
  { echo "Can't log in as admin at $URL: server down or wrong ADMIN_PASS." >&2; exit 1; }

call() {  # call <METHOD> <endpoint> <user> <pass>  -> prints HTTP code
  local body
  body=$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$3" "$4")
  curl -s -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PASS" -X "$1" "$URL/$2" \
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
done < "$FILE"

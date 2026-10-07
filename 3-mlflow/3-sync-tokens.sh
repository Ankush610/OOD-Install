#!/usr/bin/env bash
# Give every LDAP user an MLflow account and a job token in ~/.mlflow/credentials.
# People log in to the MLflow UI with their LDAP password (image/ldap_auth.py). Jobs can't type a password,
# so they use a random token instead: it keeps working when the person changes their password, and the
# real password is never written to a file. Safe to rerun: a token that still works is left alone.
# Run on master after 2-deploy.sh (../1-ldap/add-user.sh also runs it): sudo bash 3-sync-tokens.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
API=$MLFLOW_URI/api/2.0/mlflow

[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes users' home dirs)." >&2; exit 1; }
ADMIN_PASS=$(cat "$MLFLOW_DATA/admin.pass")
curl -sf -o /dev/null -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASS") "$API/users/get?username=admin" ||
  { echo "MLflow at $MLFLOW_URI does not answer or admin login fails. Run 2-deploy.sh first." >&2; exit 1; }

admin_call() {  # admin_call <METHOD> <endpoint> <user> <pass>  -> HTTP code (passwords stay out of ps)
  python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$3" "$4" |
    curl -s -o /dev/null -w '%{http_code}' -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASS") \
         -X "$1" "$API/users/$2" -H 'Content-Type: application/json' --data-binary @-
}
token_works() {  # token_works <user> <token>: any logged-in user may search (they just see only their own)
  [ "$(curl -s -o /dev/null -w '%{http_code}' -K <(printf 'user = "%s:%s"\n' "$1" "$2") \
        "$API/experiments/search?max_results=1")" = 200 ]
}

users=$(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid |
        awk '/^uid: /{print $2}')
[ -n "$users" ] || { echo "No users in LDAP (ou=People,$LDAP_BASE)." >&2; exit 1; }

for user in $users; do
  home=$(getent passwd "$user" | cut -d: -f6) || { echo "SKIP    $user (not resolvable, is SSSD running?)"; continue; }
  group=$(id -gn "$user")
  creds=$home/.mlflow/credentials
  old=$( [ -f "$creds" ] && awk -F' = ' '/^mlflow_tracking_password/{print $2}' "$creds" || true)
  if [ -n "$old" ] && token_works "$user" "$old"; then
    echo "ok      $user"; continue
  fi

  token=$(openssl rand -hex 24)                   # 48 chars, above MLflow's 12-character minimum
  if [ "$(admin_call POST create "$user" "$token")" = 200 ]; then state="added  "
  elif [ "$(admin_call PATCH update-password "$user" "$token")" = 200 ]; then state="token  "
  else echo "FAILED  $user (MLflow)"; continue; fi

  install -d -m 700 -o "$user" -g "$group" "$home/.mlflow"
  (umask 077; printf '[mlflow]\nmlflow_tracking_username = %s\nmlflow_tracking_password = %s\n' "$user" "$token" > "$creds")
  chown "$user:$group" "$creds"
  echo "$state $user"
done

# Public models (MLflow tag public=true, set by the model's owner; build-plan step 6b): read access for every user, so
# "just deploy Qwen" works. default_permission is NO_PERMISSIONS, so each user needs their own grant; rerun = new users.
echo "== Public models: read access for every user"
admin_curl() { curl -s -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASS") "$@"; }
admin_curl -G "$API/registered-models/search" --data-urlencode "filter=tags.public = 'true'" --data-urlencode max_results=1000 |
  python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin).get("registered_models", [])]' |
while read -r model; do
  new=0 had=0 failed=""
  for user in $users; do
    out=$(python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "resource_type": "registered_model",
                                                         "resource_id": sys.argv[2], "permission": "READ"}))' "$user" "$model" |
          admin_curl -w '\n%{http_code}' -X POST "${API%/2.0/mlflow}/3.0/mlflow/users/permissions/grant" \
                     -H 'Content-Type: application/json' --data-binary @-)
    case $out in
      *$'\n'200) new=$((new + 1)) ;;
      *RESOURCE_ALREADY_EXISTS*) had=$((had + 1)) ;;
      *) failed+=" $user" ;;
    esac
  done
  echo "public  $model: $new granted, $had already had it${failed:+, FAILED:$failed}"
done

cat <<EOF

Done. MLflow UI: log in with your LDAP (SSH/OOD) password.
Jobs: export MLFLOW_TRACKING_URI=$MLFLOW_URI   (the token in ~/.mlflow/credentials is used automatically)
EOF

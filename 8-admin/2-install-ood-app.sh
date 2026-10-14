#!/usr/bin/env bash
# Install the admin page as an OOD app (Interactive Apps -> Admin). Only OOD_ADMIN can read its folder, so OOD shows it
# to nobody else; the app itself refuses anyone else too, and every action goes through ADMIN_HELPER on master, over
# the ssh key ADMIN_KEY (1-install.sh made both).
# Looks like Model Hub: it takes Model Hub's style.css and Bootstrap copy (5-model-hub/ood-app/model_hub/public).
# Run on LOGIN_HOST after 1-install.sh (on master): sudo bash 2-install-ood-app.sh      then Restart Web Server in OOD (as the admin)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$LOGIN_HOST" ] || { echo "Run this on $LOGIN_HOST (LOGIN_HOST)." >&2; exit 1; }
APPS=/var/www/ood/apps/sys
APP=$APPS/aistack_admin
MH=$HERE/../5-model-hub/ood-app/model_hub/public
[ -d "$APPS" ] || { echo "No $APPS: run ../2-ood/setup-ood.sh first." >&2; exit 1; }
[ -s "$ADMIN_KEY" ] || { echo "No $ADMIN_KEY: run 1-install.sh on $MASTER_HOST first." >&2; exit 1; }
SSH_ADMIN=(ssh -F none -i "$ADMIN_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
           -o UserKnownHostsFile="$ADMIN_KEY.known_hosts" "root@$MASTER_HOST")   # = 1-install.sh
GROUP=$(id -gn "$OOD_ADMIN")

echo "== 1. Copy the app (+ Model Hub's style.css and Bootstrap)"
rm -rf "$APP"
cp -r "$HERE/ood-app/aistack_admin" "$APP"
cp -r "$MH/vendor" "$MH/style.css" "$APP/public/"
rm -rf "$APP/__pycache__"
python3 -c 'import json,sys; json.dump({"admin": sys.argv[2], "ssh": sys.argv[3:]}, open(sys.argv[1], "w"))' \
  "$APP/site.json" "$OOD_ADMIN" "${SSH_ADMIN[@]}"

echo "== 2. Only $OOD_ADMIN (group $GROUP) can read it: OOD lists apps by whether the user can read their folder"
chown -R "root:$GROUP" "$APP"
find "$APP" -type d -exec chmod 750 {} +
find "$APP" -type f -exec chmod 640 {} +
install -d -m 750 -o root -g "$GROUP" "$APP/tmp" && touch "$APP/tmp/restart.txt"   # Passenger reloads the app

echo "== 3. Check"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APP/passenger_wsgi.py" && echo "passenger_wsgi.py: OK"
# OOD ignores a manifest it can't parse without a word (the app then has no category: not in any menu)
python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); assert m["category"] == "Interactive Apps", m' "$APP/manifest.yml" &&
  echo "manifest.yml: OK (Interactive Apps)"
sudo -u "$OOD_ADMIN" test -r "$APP/manifest.yml" && echo "$OOD_ADMIN can read it: OK"
out=$(sudo -u "$OOD_ADMIN" "${SSH_ADMIN[@]}" teams 2>&1) && echo "$OOD_ADMIN reaches the helper on $MASTER_HOST: OK" ||
  { echo "WRONG: $OOD_ADMIN can't reach the helper: $out (rerun 1-install.sh on $MASTER_HOST)" >&2; exit 1; }
other=$(LDAPTLS_CACERT=$LDAP_CA ldapsearch -x -LLL -H "$LDAP_URI" -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid | sed -n 's/^uid: //p' | head -1)
if [ -n "$other" ]; then
  sudo -u "$other" test -r "$APP/manifest.yml" && { echo "WRONG: $other can read $APP" >&2; exit 1; }
  echo "$other can't see it: OK"
fi
echo "Done. As $OOD_ADMIN in OOD: Restart Web Server, then Interactive Apps -> Admin."

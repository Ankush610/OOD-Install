#!/usr/bin/env bash
# Install the admin page as an OOD app (Interactive Apps -> Admin). Only OOD_ADMIN can read its folder, so OOD shows it
# to nobody else; the app itself refuses anyone else too, and every action goes through ADMIN_HELPER (1-install.sh).
# Looks like Model Hub: it takes Model Hub's style.css and Bootstrap copy (5-model-hub/ood-app/model_hub/public).
# Run on master after 1-install.sh: sudo bash 2-install-ood-app.sh      then Restart Web Server in OOD (as the admin)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
APPS=/var/www/ood/apps/sys
APP=$APPS/aistack_admin
MH=$HERE/../5-model-hub/ood-app/model_hub/public
[ -d "$APPS" ] || { echo "No $APPS: run ../2-ood/setup-ood.sh first." >&2; exit 1; }
[ -x "$ADMIN_HELPER" ] || { echo "No $ADMIN_HELPER: run 1-install.sh first." >&2; exit 1; }
GROUP=$(id -gn "$OOD_ADMIN")

echo "== 1. Copy the app (+ Model Hub's style.css and Bootstrap)"
rm -rf "$APP"
cp -r "$HERE/ood-app/aistack_admin" "$APP"
cp -r "$MH/vendor" "$MH/style.css" "$APP/public/"
rm -rf "$APP/__pycache__"
printf '{"admin": "%s", "helper": "%s", "sudo": ["sudo", "-n"]}\n' "$OOD_ADMIN" "$ADMIN_HELPER" > "$APP/site.json"

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
other=$(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid | sed -n 's/^uid: //p' | head -1)
if [ -n "$other" ]; then
  sudo -u "$other" test -r "$APP/manifest.yml" && { echo "WRONG: $other can read $APP" >&2; exit 1; }
  echo "$other can't see it: OK"
fi
echo "Done. As $OOD_ADMIN in OOD: Restart Web Server, then Interactive Apps -> Admin."

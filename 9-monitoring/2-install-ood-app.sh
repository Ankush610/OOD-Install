#!/usr/bin/env bash
# Install "Cluster monitor" as an OOD app (Interactive Apps -> Cluster monitor), for every user. Its home page card is in
# ../2-ood/branding/_ai_tools.html.erb (installed by ../2-ood/setup-ood.sh). Read-only: it shows what Prometheus
# (1-install.sh, on master) knows: every node's state, CPUs, memory and GPUs, who runs where, problems.
# Looks like Model Hub: it takes Model Hub's style.css and Bootstrap copy (5-model-hub/ood-app/model_hub/public).
# Run on LOGIN_HOST after 1-install.sh (on master): sudo bash 2-install-ood-app.sh     then Restart Web Server in OOD
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$LOGIN_HOST" ] || { echo "Run this on $LOGIN_HOST (LOGIN_HOST)." >&2; exit 1; }
APPS=/var/www/ood/apps/sys
APP=$APPS/cluster_status
MH=$HERE/../5-model-hub/ood-app/model_hub/public
[ -d "$APPS" ] || { echo "No $APPS: run ../2-ood/setup-ood.sh first." >&2; exit 1; }
[ -f "$MH/style.css" ] || { echo "No $MH/style.css (Model Hub's look): is the whole OOD-Install folder here?" >&2; exit 1; }

echo "== 1. Prometheus answers here ($PROM_URL)"
curl -sf -o /dev/null "$PROM_URL/-/ready" ||
  { echo "Prometheus doesn't answer at $PROM_URL from $LOGIN_HOST: run 1-install.sh on $MASTER_HOST (or check the firewall: it must let $LOGIN_IP in)." >&2; exit 1; }
echo "ok"

echo "== 2. Copy the app (+ Model Hub's style.css and Bootstrap) to $APP"
rm -rf "$APP"
cp -r "$HERE/ood-app/cluster_status" "$APP"
cp -r "$MH/vendor" "$MH/style.css" "$APP/public/"
rm -rf "$APP/__pycache__"
python3 -c 'import json,sys; json.dump({"prom_url": sys.argv[2], "login_partition": sys.argv[3]}, open(sys.argv[1], "w"))' \
  "$APP/site.json" "$PROM_URL" "$VIEWER_PARTITION"
# every user may open it (OOD lists an app for whoever can read its folder)
chown -R root:root "$APP"
find "$APP" -type d -exec chmod 755 {} +
find "$APP" -type f -exec chmod 644 {} +
install -d -m 755 "$APP/tmp" && touch "$APP/tmp/restart.txt"   # Passenger reloads the app

echo "== 3. Check"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APP/passenger_wsgi.py" && echo "passenger_wsgi.py: OK"
# OOD ignores a manifest it can't parse without a word (the app then has no category: not in any menu)
python3 -c 'import sys, yaml; m = yaml.safe_load(open(sys.argv[1])); assert (m["category"], m["subcategory"]) == ("Interactive Apps", "Servers"), m' "$APP/manifest.yml" &&
  echo "manifest.yml: OK (Interactive Apps menu)"
# the backend as a normal user would run it: the same answer the page gets
user=$(LDAPTLS_CACERT=$LDAP_CA ldapsearch -x -LLL -H "$LDAP_URI" -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid 2>/dev/null |
       sed -n 's/^uid: //p' | head -1 || true)
user=${user:-nobody}
sudo -u "$user" python3 - "$APP" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import passenger_wsgi as p
out = {}
d = json.loads(b"".join(p.application({"REQUEST_METHOD": "GET", "PATH_INFO": "/api/status"}, lambda s, h: out.update(s=s))))
if not out["s"].startswith("200"):
    sys.exit(f"WRONG: api/status says {out['s']}: {d.get('error')}")
gpus = sum(len(n["gpus"]) for n in d["nodes"])
print(f"api/status as {d['user']}: OK, {len(d['nodes'])} nodes, {gpus} GPUs, {sum(a['state'] == 'firing' for a in d['alerts'])} problems")
for n in d["nodes"]:
    print(f"  {n['node']:12} {n['type']:6} {n['state']:24} {'reporting' if n['up'] else 'NOT reporting'}")
PY
echo "Done. In OOD: Help -> Restart Web Server, then Interactive Apps -> Cluster monitor (the home page card comes from ../2-ood/setup-ood.sh)."

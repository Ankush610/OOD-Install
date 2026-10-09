#!/usr/bin/env bash
# Realm $KEYCLOAK_REALM: the users log in here. Users and groups come from LDAP, read-only: LDAP checks the
# password, and adding/removing/changing people stays 1-ldap/add-user.sh. No sign-up, no password reset here.
# Safe to rerun (updates the settings, then syncs every LDAP user and group).
# Run on master after 1-install.sh: sudo bash 2-realm.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (reads the Keycloak admin password)." >&2; exit 1; }
export KC_URL=http://127.0.0.1:$KEYCLOAK_PORT$KEYCLOAK_PATH KEYCLOAK_ADMIN KEYCLOAK_DATA KEYCLOAK_REALM LDAP_BASE PORTAL_TITLE
# Keycloak and LDAP are both on master: the password check never leaves the machine (like OOD's ldap://localhost)
export KC_LDAP_URL=ldap://127.0.0.1:389

echo "== 1. Realm $KEYCLOAK_REALM + LDAP users and groups"
python3 "$HERE/kc.py" realm

echo "== 2. Check"
n=$(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid | grep -c '^uid:' || true)
echo "LDAP has $n users; the sync above should say the same number (imported + updated)."
cat <<EOF

Try it as a user (any LDAP account), in the browser:
  https://$OOD_SERVERNAME$KEYCLOAK_PATH/realms/$KEYCLOAK_REALM/account     -> log in with the LDAP password
Or from master (asks for the password, nothing on the command line):
  read -rsp 'password: ' P; echo; printf '%s' "\$P" | curl -sk --data-urlencode grant_type=password \\
    --data-urlencode client_id=admin-cli --data-urlencode username=\$USER --data-urlencode password@- \\
    https://localhost$KEYCLOAK_PATH/realms/$KEYCLOAK_REALM/protocol/openid-connect/token | head -c 60; echo; unset P
  (expect {"access_token":... ; a wrong password gives "Invalid user credentials")

Admin console: https://$OOD_SERVERNAME$KEYCLOAK_PATH/admin   user $KEYCLOAK_ADMIN, password: sudo cat $KEYCLOAK_DATA/admin.pass
EOF

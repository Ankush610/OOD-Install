#!/usr/bin/env bash
# Realm $KEYCLOAK_REALM: the users log in here. Users and groups come from LDAP: LDAP checks the password, and
# adding/removing people stays 1-ldap/add-user.sh / remove-user.sh. Keycloak may write ONE thing to LDAP: a password
# (a new user's first login replaces the one-time password; anyone can change theirs in the account page). It binds
# as KC_LDAP_BIND_DN, which an LDAP access rule allows to write userPassword under ou=People and nothing else.
# No sign-up, no e-mail reset.
# Safe to rerun (updates the settings, then syncs every LDAP user and group).
# Run on master after 1-install.sh: sudo bash 2-realm.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (reads the Keycloak admin password)." >&2; exit 1; }
export KC_URL=http://127.0.0.1:$KEYCLOAK_PORT$KEYCLOAK_PATH KEYCLOAK_ADMIN KEYCLOAK_DATA KEYCLOAK_REALM LDAP_BASE PORTAL_TITLE
# Keycloak and LDAP are both on master. ldaps (to the certificate's name, MASTER_HOST): 389 DS refuses password
# changes on a plain connection. Keycloak trusts LDAP_CA because 1-install.sh mounts it into the container.
export KC_LDAP_URL=ldaps://$MASTER_HOST:636 KC_LDAP_BIND_DN="cn=keycloak-passwords,$LDAP_BASE"
grep -q ldap-ca.crt /etc/containers/systemd/keycloak.container 2>/dev/null ||
  { echo "Keycloak doesn't trust LDAP's CA yet: run 1-install.sh first (it restarts Keycloak with it)." >&2; exit 1; }
export LDAPTLS_CACERT=$LDAP_CA
DM=(-x -H "$LDAP_URI" -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE")
PW=$KEYCLOAK_DATA/ldap.pass

echo "== 0. LDAP account $KC_LDAP_BIND_DN: may set passwords, nothing else"
[ -s "$PW" ] || (umask 077; openssl rand -hex 24 | tr -d '\n' > "$PW")
if ! ldapsearch -x -LLL -H ldap://localhost -b "$KC_LDAP_BIND_DN" -s base dn >/dev/null 2>&1; then
  printf 'dn: %s\nobjectClass: top\nobjectClass: applicationProcess\nobjectClass: simpleSecurityObject\ncn: keycloak-passwords\nuserPassword: %s\n' \
    "$KC_LDAP_BIND_DN" "$(cat "$PW")" | ldapadd "${DM[@]}" >/dev/null
  echo "created"
elif ! ldapwhoami -x -H "$LDAP_URI" -D "$KC_LDAP_BIND_DN" -y "$PW" >/dev/null 2>&1; then
  # the file was replaced (e.g. a restore): LDAP takes the file's password
  printf 'dn: %s\nchangetype: modify\nreplace: userPassword\nuserPassword: %s\n' "$KC_LDAP_BIND_DN" "$(cat "$PW")" |
    ldapmodify "${DM[@]}" >/dev/null
  echo "password reset from $PW"
fi
if ! ldapsearch "${DM[@]}" -LLL -o ldif-wrap=no -b "ou=People,$LDAP_BASE" -s base aci | grep -qF 'acl "keycloak sets passwords"'; then
  printf 'dn: ou=People,%s\nchangetype: modify\nadd: aci\naci: (targetattr="userPassword")(version 3.0; acl "keycloak sets passwords"; allow (write) userdn="ldap:///%s";)\n' \
    "$LDAP_BASE" "$KC_LDAP_BIND_DN" | ldapmodify "${DM[@]}" >/dev/null
  echo "access rule added on ou=People"
fi
ldapwhoami -x -H "$LDAP_URI" -D "$KC_LDAP_BIND_DN" -y "$PW" >/dev/null && echo "binds over ldaps: OK"

echo "== 1. Realm $KEYCLOAK_REALM + LDAP users and groups"
python3 "$HERE/kc.py" realm

echo "== 2. Check"
# the account must NOT change anything but passwords: try a harmless attribute on the first user (refused = right)
u=$(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' dn | sed -n 's/^dn: //p' | head -1)
if [ -n "$u" ]; then
  if printf 'dn: %s\nchangetype: modify\nreplace: description\ndescription: keycloak-acl-test\n' "$u" |
       ldapmodify -x -H "$LDAP_URI" -D "$KC_LDAP_BIND_DN" -y "$PW" >/dev/null 2>&1; then
    echo "WRONG: $KC_LDAP_BIND_DN could change 'description' of $u: check the access rules on ou=People" >&2; exit 1
  fi
  echo "it can't change other attributes (description on $u: refused, as it should be)"
fi
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

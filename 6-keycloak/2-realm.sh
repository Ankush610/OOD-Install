#!/usr/bin/env bash
# Realm $KEYCLOAK_REALM: the users log in here. Users and groups come from LDAP: LDAP checks the password, and
# adding/removing people stays 1-ldap/add-user.sh / remove-user.sh. Keycloak may write ONE thing to LDAP: a password
# (a new user's first login replaces the one-time password; anyone can change theirs in the account page). It binds
# as KC_LDAP_BIND_DN, which an LDAP access rule allows to write userPassword under ou=People and nothing else.
# No sign-up, no e-mail reset. Also OOD's client "ood" (its secret goes to LOGIN_HOST) and OOD_ADMIN as a local user.
# Safe to rerun (updates the settings, then syncs every LDAP user and group).
# Run on master after 1-install.sh: sudo bash 2-realm.sh     Needs root ssh to LOGIN_HOST.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (reads the Keycloak admin password)." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST." >&2; exit 1; }
export KC_URL=$KEYCLOAK_URL KEYCLOAK_ADMIN KEYCLOAK_DATA KEYCLOAK_REALM LDAP_BASE PORTAL_TITLE
on() {  # on <node> <command>: as root, here or over ssh (stdin goes along)
  if [ "$1" = "$(hostname -s)" ]; then bash -c "$2"; else ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$1" "$2"; fi
}
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

echo "== 2. OOD's login: client ood (secret -> $LOGIN_HOST:$OOD_OIDC_SECRET) + $OOD_ADMIN as a local Keycloak user"
# here and not in setup-ood.sh: only master can read the Keycloak admin password. The secret goes over stdin.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
python3 "$HERE/kc.py" client ood "https://${OOD_SERVERNAME}" "$tmp"
on "$LOGIN_HOST" "install -d -m 755 ${OOD_OIDC_SECRET%/*} && umask 077 && cat > $OOD_OIDC_SECRET && chmod 600 $OOD_OIDC_SECRET" < "$tmp"
echo "secret copied to $LOGIN_HOST:$OOD_OIDC_SECRET (root only)"
# not in LDAP, so Keycloak keeps its password itself; asked once, only when the user doesn't exist yet
if python3 "$HERE/kc.py" local-user "$OOD_ADMIN" </dev/null 2>/dev/null | grep -q exists; then
  echo "${OOD_ADMIN}: already a local Keycloak user"
else
  read -rsp "New Keycloak password for ${OOD_ADMIN} (8+ characters): " pw; echo
  printf '%s' "$pw" | python3 "$HERE/kc.py" local-user "$OOD_ADMIN"; unset pw
fi

echo "== 3. Check"
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
Or from $LOGIN_HOST (asks for the password, nothing on the command line):
  read -rsp 'password: ' P; echo; printf '%s' "\$P" | curl -sk --data-urlencode grant_type=password \\
    --data-urlencode client_id=admin-cli --data-urlencode username=\$USER --data-urlencode password@- \\
    https://localhost$KEYCLOAK_PATH/realms/$KEYCLOAK_REALM/protocol/openid-connect/token | head -c 60; echo; unset P
  (expect {"access_token":... ; a wrong password gives "Invalid user credentials")

Admin console: https://$OOD_SERVERNAME$KEYCLOAK_PATH/admin   user $KEYCLOAK_ADMIN, password: sudo cat $KEYCLOAK_DATA/admin.pass
EOF

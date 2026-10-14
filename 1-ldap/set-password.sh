#!/usr/bin/env bash
# Give a person a new ONE-TIME password: it works at once for SSH, Slurm, OOD and MLflow, and their next web login
# asks them to choose their own (Keycloak, if installed). For a forgotten password.
# Run on master: sudo bash set-password.sh <username> < file-with-the-password    (one line on stdin)
# Used by menu.sh ("Set a new password") and the admin page (8-admin).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
U=${1:?usage: sudo bash set-password.sh <username>   (password: one line on stdin)}
[[ $U =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Bad username: $U" >&2; exit 1; }
DN="uid=$U,ou=People,$LDAP_BASE"
ldapsearch -x -LLL -H ldap://localhost -b "$DN" -s base uid 2>/dev/null | grep -q '^uid:' ||
  { echo "No LDAP user '$U' (local accounts: passwd)." >&2; exit 1; }
IFS= read -r PW || true
[ ${#PW} -ge 8 ] || { echo "Password too short (8+ characters)." >&2; exit 1; }

# 389 DS refuses password changes on a plain connection (error 13): ldaps
LDAPTLS_CACERT="$LDAP_CA" ldappasswd -x -H "$LDAP_URI" -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE" -T <(printf %s "$PW") "$DN"
echo "password of $U changed (SSH, Slurm, OOD, MLflow)"
if [ -f "$KEYCLOAK_DATA/admin.pass" ]; then
  KC_URL=$KEYCLOAK_URL KEYCLOAK_ADMIN=$KEYCLOAK_ADMIN KEYCLOAK_DATA=$KEYCLOAK_DATA \
    KEYCLOAK_REALM=$KEYCLOAK_REALM python3 "$HERE/../6-keycloak/kc.py" must-change "$U"
else
  echo "Keycloak not installed: it stays their password until they change it (passwd)."
fi

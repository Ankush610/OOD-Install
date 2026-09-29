#!/usr/bin/env bash
# OPTIONAL: copy people who already exist as local users on master into LDAP.
# Each keeps the same UID/GID (their files stay theirs), home, shell, and password (the /etc/shadow hash).
# Skipped: KEEP_LOCAL (site.conf), and service accounts (nologin/false shell).
# Nothing local is changed or deleted; this only ADDS to LDAP.
# Run on master after 1-server.sh: sudo bash import-local-users.sh [--dry-run]    Safe to rerun.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
DRY=${1:-}

keep() { [[ " $KEEP_LOCAL " == *" $1 "* ]]; }
service() { [[ "$1" == */nologin || "$1" == */false ]]; }

echo "== 1. Build LDIF from /etc/passwd, /etc/shadow, /etc/group"
LDIF=$(mktemp); trap 'rm -f "$LDIF"' EXIT
chmod 600 "$LDIF"                                  # holds password hashes
users=(); skipped=()
while IFS=: read -r u _ uid gid _ home shell; do
  (( uid >= MIN_UID && uid <= MAX_UID )) || continue
  if keep "$u" || service "$shell"; then skipped+=("$u"); continue; fi
  hash=$(awk -F: -v u="$u" '$1==u {print $2}' /etc/shadow)
  users+=("$u")
  cat >> "$LDIF" <<EOF
dn: uid=$u,ou=People,$LDAP_BASE
objectClass: top
objectClass: inetOrgPerson
objectClass: posixAccount
uid: $u
cn: $u
sn: $u
uidNumber: $uid
gidNumber: $gid
homeDirectory: $home
loginShell: $shell
EOF
  # "!!" or "*" = no password set (locked): leave it without one, they can't log in either way
  [[ "$hash" == \$* ]] && echo "userPassword: {CRYPT}$hash" >> "$LDIF"
  echo >> "$LDIF"
done < /etc/passwd

while IFS=: read -r g _ gid members; do
  (( gid >= MIN_UID && gid <= MAX_UID )) || continue
  [[ " ${skipped[*]} " == *" $g "* ]] && continue
  cat >> "$LDIF" <<EOF
dn: cn=$g,ou=Groups,$LDAP_BASE
objectClass: top
objectClass: groupOfNames
objectClass: posixGroup
cn: $g
gidNumber: $gid
EOF
  for m in ${members//,/ }; do echo "memberUid: $m" >> "$LDIF"; done
  echo >> "$LDIF"
done < /etc/group

echo "import:     ${users[*]:-none}"
echo "stay local: ${skipped[*]:-none}"
if [ "$DRY" = "--dry-run" ]; then
  sed 's/^userPassword: .*/userPassword: {CRYPT}<hash hidden>/' "$LDIF"
  echo "Dry run: nothing written."
  exit 0
fi
[ ${#users[@]} -gt 0 ] || { echo "Nobody to import."; exit 0; }

echo "== 2. Add to LDAP (existing entries are skipped, not changed)"
ldapadd -c -x -H ldap://localhost -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE" -f "$LDIF" 2>&1 |
  grep -E '^adding|Already exists' | sed 's/^ldap_add: //' || true

echo "== 3. Check: every user in LDAP with the same UID as locally"
bad=0
for u in "${users[@]}"; do
  local_uid=$(id -u "$u")
  ldap_uid=$(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" "uid=$u" uidNumber | awk '/^uidNumber:/{print $2}')
  if [ "$local_uid" = "$ldap_uid" ]; then echo "ok    $u $ldap_uid"; else echo "WRONG $u local=$local_uid ldap=${ldap_uid:-missing}"; bad=1; fi
done
[ $bad = 0 ] || { echo "Fix the entries above before 2-client.sh." >&2; exit 1; }
echo
echo "Done. Next: sudo bash 2-client.sh   (on $MASTER_HOST, then on: $COMPUTE_NODES)"

#!/usr/bin/env bash
# The admin page's root helper (build-plan step 8): aistack-admin.py -> ADMIN_HELPER (root-owned), and a sudoers rule
# that lets OOD_ADMIN, and nobody else, run it without a password. The helper does a fixed list of actions and checks
# every argument (see its top). Safe to rerun (a changed helper is copied again).
# Run on master: sudo bash 1-install.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OOD=$(cd "$HERE/.." && pwd)
source "$OOD/site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST." >&2; exit 1; }
id "$OOD_ADMIN" >/dev/null 2>&1 || { echo "No local account $OOD_ADMIN (OOD_ADMIN)." >&2; exit 1; }
RULE=/etc/sudoers.d/aistack-admin

echo "== 1. Helper $ADMIN_HELPER (root-owned copy; it runs the scripts in $OOD)"
# ponytail: the scripts it calls live in $OOD, writable by its owner; fine while only OOD_ADMIN (who has full sudo
# anyway) may run the helper. Before anyone else gets admin rights, OOD-Install must be root-owned (step 9).
python3 "$HERE/aistack-admin.py" --test
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
sed "s|@OOD_INSTALL@|$OOD|" "$HERE/aistack-admin.py" > "$tmp"
if ! cmp -s "$tmp" "$ADMIN_HELPER"; then
  install -o root -g root -m 755 "$tmp" "$ADMIN_HELPER"; echo "installed"
else
  echo "unchanged"
fi

echo "== 2. sudo rule: $OOD_ADMIN may run it, no password ($RULE)"
printf '# Written by OOD-Install/8-admin/1-install.sh: the admin page runs as %s and calls the helper.\n%s ALL=(root) NOPASSWD: %s\n' \
  "$OOD_ADMIN" "$OOD_ADMIN" "$ADMIN_HELPER" > "$tmp"
visudo -cqf "$tmp" || { echo "visudo refused the rule: nothing changed" >&2; exit 1; }
cmp -s "$tmp" "$RULE" || { install -o root -g root -m 440 "$tmp" "$RULE"; echo "written"; }

echo "== 3. Log $ADMIN_LOG (root only)"
touch "$ADMIN_LOG"; chown root:root "$ADMIN_LOG"; chmod 600 "$ADMIN_LOG"

echo "== 4. Check"
out=$(sudo -u "$OOD_ADMIN" sudo -n "$ADMIN_HELPER" teams) && echo "$OOD_ADMIN, no password: $out" ||
  { echo "WRONG: $OOD_ADMIN can't run it: $out" >&2; exit 1; }
other=$(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid | sed -n 's/^uid: //p' | head -1)
if [ -n "$other" ]; then
  if sudo -u "$other" sudo -n "$ADMIN_HELPER" teams >/dev/null 2>&1; then
    echo "WRONG: $other could run it too: check $RULE and the other sudo rules" >&2; exit 1
  fi
  echo "$other (an LDAP user): refused, as it should be"
fi
cat <<EOF

From the terminal (as $OOD_ADMIN):  sudo $ADMIN_HELPER endpoints        (no argument: the list of actions)
What was done:                     sudo tail $ADMIN_LOG
EOF

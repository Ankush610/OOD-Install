#!/usr/bin/env bash
# The admin page's root helper (build-plan step 8): aistack-admin.py -> ADMIN_HELPER (root-owned, on master), a sudoers
# rule that lets OOD_ADMIN, and nobody else, run it without a password (terminal on master), and the page's way in from
# LOGIN_HOST: an ssh key only OOD_ADMIN can read there (ADMIN_KEY), which master's root accepts from LOGIN_IP alone and
# for nothing but `ADMIN_HELPER --ssh`. The helper does a fixed list of actions and checks every argument (see its top).
# Safe to rerun (a changed helper is copied again, the key is kept).
# Run on master: sudo bash 1-install.sh      Needs root ssh to LOGIN_HOST (master -> login; login never gets root here).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OOD=$(cd "$HERE/.." && pwd)
source "$OOD/site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST." >&2; exit 1; }
id "$OOD_ADMIN" >/dev/null 2>&1 || { echo "No local account $OOD_ADMIN (OOD_ADMIN)." >&2; exit 1; }
RULE=/etc/sudoers.d/aistack-admin
AUTH=/root/.ssh/authorized_keys
SSH_ADMIN=(ssh -F none -i "$ADMIN_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
           -o UserKnownHostsFile="$ADMIN_KEY.known_hosts" "root@$MASTER_HOST")   # = site.json "ssh" (2-install-ood-app.sh)
on() {  # on <node> <command>: as root, here or over ssh
  if [ "$1" = "$(hostname -s)" ]; then bash -c "$2"; else ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$1" "$2"; fi
}

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

echo "== 4. The page's ssh key: $LOGIN_HOST:$ADMIN_KEY (only $OOD_ADMIN reads it) -> $AUTH here"
# made on LOGIN_HOST, so the private key never travels; master's host keys go along, so the page checks it reaches master
known=$(sed "s/^/$MASTER_HOST,$MASTER_IP /" /etc/ssh/ssh_host_*_key.pub | cut -d' ' -f1-3)
pub=$(on "$LOGIN_HOST" "set -e; id $OOD_ADMIN >/dev/null; install -d -m 755 ${ADMIN_KEY%/*}
  [ -f $ADMIN_KEY ] || ssh-keygen -q -t ed25519 -N '' -C aistack-admin -f $ADMIN_KEY
  chown $OOD_ADMIN $ADMIN_KEY; chmod 600 $ADMIN_KEY
  printf '%s\n' '$known' > $ADMIN_KEY.known_hosts; chmod 644 $ADMIN_KEY.known_hosts
  cat $ADMIN_KEY.pub")
[[ $pub == ssh-ed25519\ * ]] || { echo "No key from $LOGIN_HOST: $pub" >&2; exit 1; }
# restrict: no shell, pty or forwarding; command=: whatever the client asks, only the helper runs (it reads the request
# from SSH_ORIGINAL_COMMAND); from=: only from the login node. Other lines in the file are kept.
install -d -m 700 /root/.ssh; touch "$AUTH"; chmod 600 "$AUTH"
{ grep -v ' aistack-admin$' "$AUTH" || true
  echo "restrict,from=\"$LOGIN_IP\",command=\"$ADMIN_HELPER --ssh\" $(cut -d' ' -f1-2 <<<"$pub") aistack-admin"; } > "$tmp"
cmp -s "$tmp" "$AUTH" || { cat "$tmp" > "$AUTH"; echo "written"; }      # cat: keeps the file's SELinux label
restorecon "$AUTH" 2>/dev/null || true

echo "== 5. Check"
out=$(on "$LOGIN_HOST" "sudo -u $OOD_ADMIN ${SSH_ADMIN[*]} teams" 2>&1) && echo "$OOD_ADMIN on $LOGIN_HOST, over its key: $out" ||
  { echo "WRONG: $OOD_ADMIN on $LOGIN_HOST can't reach the helper: $out (sshd: PermitRootLogin must allow keys)" >&2; exit 1; }
out=$(on "$LOGIN_HOST" "sudo -u $OOD_ADMIN ${SSH_ADMIN[*]} id" 2>&1) &&
  { echo "WRONG: the key ran 'id': $out" >&2; exit 1; }
echo "the key runs nothing but the helper ('id': $out)"
out=$(sudo -u "$OOD_ADMIN" sudo -n "$ADMIN_HELPER" teams) && echo "$OOD_ADMIN here, sudo, no password: $out" ||
  { echo "WRONG: $OOD_ADMIN can't run it: $out" >&2; exit 1; }
other=$(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid | sed -n 's/^uid: //p' | head -1)
if [ -n "$other" ]; then
  if sudo -u "$other" sudo -n "$ADMIN_HELPER" teams >/dev/null 2>&1; then
    echo "WRONG: $other could run it too: check $RULE and the other sudo rules" >&2; exit 1
  fi
  on "$LOGIN_HOST" "sudo -u $other test -r $ADMIN_KEY" && { echo "WRONG: $other can read $LOGIN_HOST:$ADMIN_KEY" >&2; exit 1; }
  echo "$other (an LDAP user): sudo refused, can't read the key, as it should be"
fi
cat <<EOF

From the terminal (as $OOD_ADMIN):  sudo $ADMIN_HELPER endpoints        (no argument: the list of actions)
  on $LOGIN_HOST:                   ${SSH_ADMIN[*]} endpoints
What was done:                     sudo tail $ADMIN_LOG
EOF

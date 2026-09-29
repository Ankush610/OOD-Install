#!/usr/bin/env bash
# LDAP server (389 Directory Server) on master, with an empty tree:
#   $LDAP_BASE
#   ├── ou=People     users
#   └── ou=Groups     groups
# Ports 389 (ldap) and 636 (ldaps) only, so it doesn't clash with OOD on 80/443.
# Run on master: sudo bash 1-server.sh      Safe to rerun.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST (site.conf)." >&2; exit 1; }

echo "== 1. Packages"
dnf install -y 389-ds-base openldap-clients

echo "== 2. Directory Manager password (kept in $LDAP_DM_PASS_FILE)"
if [ ! -s "$LDAP_DM_PASS_FILE" ]; then
  (umask 077; openssl rand -hex 16 | tr -d '\n' > "$LDAP_DM_PASS_FILE")
fi
# ldap* -y sends the file byte for byte: a trailing newline would become part of the password
(umask 077; printf '%s' "$(cat "$LDAP_DM_PASS_FILE")" > "$LDAP_DM_PASS_FILE.tmp") && mv "$LDAP_DM_PASS_FILE.tmp" "$LDAP_DM_PASS_FILE"
DM_PASS=$(cat "$LDAP_DM_PASS_FILE")

echo "== 3. Instance slapd-$LDAP_INSTANCE"
if dsctl "$LDAP_INSTANCE" status >/dev/null 2>&1; then
  echo "already exists"
else
  INF=$(mktemp); trap 'rm -f "$INF"' EXIT
  (umask 077; cat > "$INF" <<EOF
[general]
config_version = 2
full_machine_name = $MASTER_HOST

[slapd]
instance_name = $LDAP_INSTANCE
root_dn = $LDAP_DM
root_password = $DM_PASS
port = 389
secure_port = 636
self_sign_cert = True

[backend-userroot]
suffix = $LDAP_BASE
sample_entries = no
create_suffix_entry = True
EOF
)
  dscreate from-file "$INF"
fi
systemctl enable --now "dirsrv@$LDAP_INSTANCE"

echo "== 4. Tree + access rules"
ldapwhoami -x -H ldap://localhost -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE" >/dev/null ||
  { echo "Directory Manager login failed: $LDAP_DM_PASS_FILE does not match the instance password." >&2; exit 1; }
# Anyone may read users and groups except passwords (SSSD needs this); each user may change their own password.
# -c: keep going when an entry or rule already exists (reruns); step 7 checks the result.
ldapmodify -c -x -H ldap://localhost -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE" <<EOF || true
dn: ou=People,$LDAP_BASE
changetype: add
objectClass: organizationalUnit
ou: People

dn: ou=Groups,$LDAP_BASE
changetype: add
objectClass: organizationalUnit
ou: Groups

dn: $LDAP_BASE
changetype: modify
add: aci
aci: (targetattr!="userPassword")(version 3.0; acl "read users and groups"; allow (read, search, compare) userdn="ldap:///anyone";)
aci: (targetattr="userPassword")(version 3.0; acl "change own password"; allow (write) userdn="ldap:///self";)
EOF

echo "== 5. Share the CA certificate with the nodes ($LDAP_CA)"
mkdir -p "$(dirname "$LDAP_CA")"
if [ -f "/etc/dirsrv/slapd-$LDAP_INSTANCE/ca.crt" ]; then
  cp "/etc/dirsrv/slapd-$LDAP_INSTANCE/ca.crt" "$LDAP_CA"
else
  certutil -L -d "/etc/dirsrv/slapd-$LDAP_INSTANCE" -n "Self-Signed-CA" -a > "$LDAP_CA"
fi
chmod 644 "$LDAP_CA"

echo "== 6. Firewall"
if systemctl is-active -q firewalld; then
  firewall-cmd --permanent --add-service=ldap --add-service=ldaps
  firewall-cmd --reload
else
  echo "firewalld not running, nothing to open"
fi

echo "== 7. Check"
dsctl "$LDAP_INSTANCE" status
for ou in People Groups; do
  ldapsearch -x -LLL -H ldap://localhost -b "ou=$ou,$LDAP_BASE" -s base dn >/dev/null 2>&1 &&
    echo "ou=$ou: OK" || { echo "ou=$ou missing, see step 4" >&2; exit 1; }
done
LDAPTLS_CACERT="$LDAP_CA" ldapsearch -x -LLL -H "$LDAP_URI" -b "$LDAP_BASE" -s base dn >/dev/null &&
  echo "ldaps with the shared CA: OK" || { echo "ldaps with the shared CA FAILED" >&2; exit 1; }
cat <<EOF

Done. Next:
  sudo bash import-local-users.sh --dry-run    only if this cluster already has local users
  sudo bash 2-client.sh                        on $MASTER_HOST, then on: $COMPUTE_NODES
EOF

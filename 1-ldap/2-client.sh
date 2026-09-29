#!/usr/bin/env bash
# Make THIS node take users and passwords from LDAP (SSSD), so SSH and Slurm jobs know every user,
# with the same UID on every node. Local accounts keep working next to it.
# Run as root on master first, then on every compute node (this repo and the CA are on the shared /home):
#   sudo bash 2-client.sh      Safe to rerun.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
[ -s "$LDAP_CA" ] || { echo "No $LDAP_CA. Run 1-server.sh on $MASTER_HOST first (and is /home mounted?)." >&2; exit 1; }
CA=/etc/pki/ca-trust/source/anchors/$LDAP_INSTANCE-ldap-ca.crt

echo "== 1. Packages"
dnf install -y sssd sssd-ldap oddjob-mkhomedir openldap-clients

echo "== 2. Trust the LDAP server's CA"
cp "$LDAP_CA" "$CA"
update-ca-trust

echo "== 3. No local account may hold an LDAP UID/GID under another name"
# Local files are asked first (nsswitch: files sss), so a clash would hand that LDAP user's files to the
# local account. Typical culprit: a service account (e.g. node_exporter) created at UID 1000+.
ldap_ids=$(LDAPTLS_CACERT="$CA" ldapsearch -x -LLL -H "$LDAP_URI" -b "$LDAP_BASE" '(|(objectClass=posixAccount)(objectClass=posixGroup))' uid cn uidNumber gidNumber |
  awk '/^dn:/{n=""} /^uid: /{n=$2} /^cn: /{if(n=="")n=$2} /^uidNumber: /{print "u", $2, n} /^gidNumber: /{print "g", $2, n}')
clash=0
while read -r kind id name; do
  [ -n "$kind" ] || continue
  if [ "$kind" = u ]; then local_name=$(awk -F: -v i="$id" '$3==i{print $1; exit}' /etc/passwd)
  else local_name=$(awk -F: -v i="$id" '$3==i{print $1; exit}' /etc/group); fi
  if [ -n "$local_name" ] && [ "$local_name" != "$name" ]; then
    echo "CLASH: local $([ $kind = u ] && echo user || echo group) '$local_name' has $([ $kind = u ] && echo UID || echo GID) $id, which is '$name' in LDAP"; clash=1
  fi
done <<< "$ldap_ids"
[ $clash = 0 ] || { echo "Give those local accounts a free system ID first (README, Troubleshooting), then rerun." >&2; exit 1; }
echo "no clashes"

echo "== 4. /etc/sssd/sssd.conf"
[ -f /etc/sssd/sssd.conf ] && [ ! -f /etc/sssd/sssd.conf.pre-ldap ] && cp -p /etc/sssd/sssd.conf /etc/sssd/sssd.conf.pre-ldap
(umask 077; cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam
domains = $LDAP_INSTANCE

[domain/$LDAP_INSTANCE]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap
ldap_uri = $LDAP_URI
ldap_search_base = $LDAP_BASE
ldap_user_search_base = ou=People,$LDAP_BASE
ldap_group_search_base = ou=Groups,$LDAP_BASE
ldap_schema = rfc2307
ldap_tls_cacert = $CA
ldap_tls_reqcert = demand
cache_credentials = true
enumerate = false
EOF
)
# SSSD refuses to start unless root:root 0600. Set it explicitly: root's primary group isn't always "root".
chown root:root /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf

echo "== 5. Switch the login stack to SSSD (authselect keeps a backup)"
authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd
systemctl restart sssd

echo "== 6. Check"
systemctl is-active sssd
sss_cache -E
first=$(LDAPTLS_CACERT="$CA" ldapsearch -x -LLL -H "$LDAP_URI" -b "ou=People,$LDAP_BASE" uid | awk '/^uid:/{print $2; exit}')
if [ -z "$first" ]; then
  echo "LDAP has no users yet. After add-user.sh on $MASTER_HOST: getent passwd <name> on this node."
else
  echo "LDAP user $first as SSSD sees it (-s sss: from LDAP, not /etc/passwd):"
  getent -s sss passwd "$first" || { echo "SSSD cannot see LDAP users. See: journalctl -u sssd" >&2; exit 1; }
  id "$first"
fi
echo
echo "Done on $(hostname -s). Undo: authselect select local --force; systemctl stop sssd"

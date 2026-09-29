#!/usr/bin/env bash
# Install Open OnDemand on master. Web login = the LDAP password (same as SSH), with a local htpasswd
# login for OOD_ADMIN that still works when LDAP is down. Self-signed certificate.
# Run on master after ../1-ldap: sudo bash setup-ood.sh     (asks once for OOD_ADMIN's web password)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }

CERT=/etc/pki/tls/certs/ood.crt
KEY=/etc/pki/tls/private/ood.key
PORTAL=/etc/ood/config/ood_portal.yml
HTPASSWD=/etc/ood/htpasswd

ldapsearch -x -LLL -H ldap://localhost -b "$LDAP_BASE" -s base dn >/dev/null 2>&1 ||
  { echo "No LDAP on localhost ($LDAP_BASE). Run ../1-ldap/1-server.sh first." >&2; exit 1; }

echo "== 1. Repos"
dnf config-manager --set-enabled crb
dnf install -y epel-release
dnf module enable -y ruby:3.3 nodejs:22
rpm --import https://yum.osc.edu/ondemand/RPM-GPG-KEY-ondemand-SHA512
rpm -q ondemand-release-web >/dev/null 2>&1 ||
  dnf install -y "https://yum.osc.edu/ondemand/${OOD_VERSION}/ondemand-release-web-${OOD_VERSION}-1.el9.noarch.rpm"

echo "== 2. cyrus-sasl wants GID 76 for group saslauth; create it ourselves if 76 is taken"
if ! getent group saslauth >/dev/null && getent group 76 >/dev/null; then
  groupadd -r saslauth
fi

echo "== 3. Packages (mod_ldap: Apache checks web passwords against LDAP)"
dnf install -y ondemand mod_ssl mod_ldap httpd-tools

echo "== 4. Self-signed certificate"
[ -f "$CERT" ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -subj "/CN=${OOD_SERVERNAME}"

echo "== 5. Local web login for ${OOD_ADMIN} (fallback when LDAP is down)"
id "$OOD_ADMIN" >/dev/null
[ -f "$HTPASSWD" ] || htpasswd -c "$HTPASSWD" "$OOD_ADMIN"

echo "== 6. Portal config"
[ -f "$PORTAL.orig" ] || cp "$PORTAL" "$PORTAL.orig"
# ldap BEFORE file: Apache stops at the first provider that knows the user, so LDAP decides for
# everyone in it; only accounts LDAP doesn't know (OOD_ADMIN) fall through to htpasswd.
# ldap://localhost: Apache and LDAP are both on master, so the password never leaves the machine.
cat > "$PORTAL" <<EOF
servername: ${OOD_SERVERNAME}
port: 443
ssl:
  - 'SSLCertificateFile "${CERT}"'
  - 'SSLCertificateKeyFile "${KEY}"'
auth:
  - 'AuthType Basic'
  - 'AuthName "Open OnDemand"'
  - 'AuthBasicProvider ldap file'
  - 'AuthLDAPURL "ldap://localhost/ou=People,${LDAP_BASE}?uid?one"'
  - 'AuthUserFile "${HTPASSWD}"'
  - 'Require valid-user'
# proxy for interactive apps
node_uri: '/node'
rnode_uri: '/rnode'
EOF
/opt/ood/ood-portal-generator/sbin/update_ood_portal

echo "== 7. Cluster config"
mkdir -p /etc/ood/config/clusters.d
# No "cluster:" line: it makes OOD pass --clusters to Slurm, which needs slurmdbd.
cat > "/etc/ood/config/clusters.d/${CLUSTER_ID}.yml" <<EOF
v2:
  metadata:
    title: "${CLUSTER_TITLE}"
  login:
    host: "${MASTER_HOST}"
  job:
    adapter: "slurm"
    bin: "${SLURM_BIN}"
    conf: "${SLURM_CONF}"
EOF

echo "== 8. Start web server, open https"
systemctl enable httpd
systemctl restart httpd
if systemctl is-active -q firewalld; then
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
fi

echo "== 9. Check"
rpm -q ondemand mod_ldap
echo "/                   -> $(curl -skI -o /dev/null -w '%{http_code}' https://localhost/)   (expect 302)"
echo "/pun/sys/dashboard  -> $(curl -skI -o /dev/null -w '%{http_code}' https://localhost/pun/sys/dashboard)   (expect 401)"
cat <<EOF

Done. Test an LDAP login (asks for the password, expect 200):
  curl -sk -o /dev/null -w '%{http_code}\n' -u <ldap-user> https://localhost/pun/sys/dashboard
From the laptop: tunnel local port 443 to ${MASTER_HOST}:443, then open https://${OOD_SERVERNAME}
EOF

#!/usr/bin/env bash
# Install Open OnDemand on the login node (test setup: htpasswd login, self-signed cert).
# Run on master: sudo bash setup-ood.sh
set -euo pipefail

OOD_VERSION=4.2
SERVERNAME=localhost              # the exact host users type in the browser
OOD_USER=admin                    # first web login, must be a real Linux user
CLUSTER_ID=aistack                  # cluster file name + ID, apps refer to it in form.yml
CLUSTER_TITLE="AI-Stack"     # name users see in the Clusters menu
LOGIN_HOST=master
SLURM_BIN=/usr/local/bin          # folder of sbatch (`which sbatch`)
SLURM_CONF=/etc/slurm/slurm.conf  # `echo $SLURM_CONF`

CERT=/etc/pki/tls/certs/ood.crt
KEY=/etc/pki/tls/private/ood.key
PORTAL=/etc/ood/config/ood_portal.yml

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

echo "== 3. Packages"
dnf install -y ondemand mod_ssl httpd-tools

echo "== 4. Self-signed certificate"
[ -f "$CERT" ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -subj "/CN=${SERVERNAME}"

echo "== 5. Web login for ${OOD_USER}"
id "$OOD_USER" >/dev/null
[ -f /etc/ood/htpasswd ] || htpasswd -c /etc/ood/htpasswd "$OOD_USER"

echo "== 6. Portal config"
[ -f "$PORTAL.orig" ] || cp "$PORTAL" "$PORTAL.orig"
cat > "$PORTAL" <<EOF
servername: ${SERVERNAME}
port: 443
ssl:
  - 'SSLCertificateFile "${CERT}"'
  - 'SSLCertificateKeyFile "${KEY}"'
auth:
  - 'AuthType Basic'
  - 'AuthName "Open OnDemand"'
  - 'AuthBasicProvider file'
  - 'AuthUserFile "/etc/ood/htpasswd"'
  - 'Require valid-user'
# proxy to interactive apps (MLflow, Jupyter...)
node_uri: '/node'
rnode_uri: '/rnode'
EOF
/opt/ood/ood-portal-generator/sbin/update_ood_portal

echo "== 7. Cluster config"
mkdir -p /etc/ood/config/clusters.d
cat > "/etc/ood/config/clusters.d/${CLUSTER_ID}.yml" <<EOF
v2:
  metadata:
    title: "${CLUSTER_TITLE}"
  login:
    host: "${LOGIN_HOST}"
  job:
    adapter: "slurm"
    bin: "${SLURM_BIN}"
    conf: "${SLURM_CONF}"
EOF

echo "== 8. Start web server, open https"
systemctl enable httpd
systemctl restart httpd
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

echo "== 9. Check"
rpm -q ondemand cyrus-sasl
echo "/                   -> $(curl -skI -o /dev/null -w '%{http_code}' https://localhost/)   (expect 302)"
echo "/pun/sys/dashboard  -> $(curl -skI -o /dev/null -w '%{http_code}' https://localhost/pun/sys/dashboard)   (expect 401)"
cat <<EOF

Done. From the laptop:
  sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 ${OOD_USER}@${LOGIN_HOST}
  then open https://${SERVERNAME} and log in as ${OOD_USER}
EOF

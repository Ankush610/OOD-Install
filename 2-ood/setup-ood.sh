#!/usr/bin/env bash
# Install Open OnDemand on master. Self-signed certificate. Web login, chosen by OOD_AUTH in site.conf:
#   ldap      Apache asks for the LDAP password itself (same as SSH); htpasswd login for OOD_ADMIN when LDAP is down
#   keycloak  Apache sends the browser to Keycloak (../6-keycloak) and trusts its login (OpenID Connect,
#             mod_auth_openidc): one login for OOD, MLflow, Model Hub. OOD_ADMIN is a local Keycloak user
# Switching back and forth = change OOD_AUTH, rerun this script.
# Run on master after ../1-ldap (and ../6-keycloak for keycloak): sudo bash setup-ood.sh
#   (asks once for OOD_ADMIN's web password)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }

CERT=/etc/pki/tls/certs/ood.crt
KEY=/etc/pki/tls/private/ood.key
PORTAL=/etc/ood/config/ood_portal.yml
HTPASSWD=/etc/ood/htpasswd

OIDC_SECRET=/etc/ood/oidc-client.secret
OIDC_PASSPHRASE=/etc/ood/oidc-crypto.passphrase
KC_INTERNAL=http://127.0.0.1:$KEYCLOAK_PORT$KEYCLOAK_PATH

ldapsearch -x -LLL -H ldap://localhost -b "$LDAP_BASE" -s base dn >/dev/null 2>&1 ||
  { echo "No LDAP on localhost ($LDAP_BASE). Run ../1-ldap/1-server.sh first." >&2; exit 1; }
case $OOD_AUTH in
  ldap) ;;
  keycloak)
    curl -sf -o /dev/null "$KC_INTERNAL/realms/$KEYCLOAK_REALM/.well-known/openid-configuration" ||
      { echo "OOD_AUTH=keycloak, but realm $KEYCLOAK_REALM doesn't answer: run ../6-keycloak/1-install.sh and 2-realm.sh." >&2; exit 1; } ;;
  *) echo "OOD_AUTH must be ldap or keycloak (site.conf), not '$OOD_AUTH'." >&2; exit 1 ;;
esac

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

echo "== 3. Packages (mod_ldap: Apache checks LDAP passwords; mod_auth_openidc: Keycloak login)"
dnf install -y ondemand mod_ssl mod_ldap httpd-tools mod_auth_openidc

echo "== 4. Self-signed certificate"
[ -f "$CERT" ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" -subj "/CN=${OOD_SERVERNAME}"

echo "== 5. Local web login for ${OOD_ADMIN} (fallback when LDAP is down)"
id "$OOD_ADMIN" >/dev/null
if [ "$OOD_AUTH" = ldap ]; then
  [ -f "$HTPASSWD" ] || htpasswd -c "$HTPASSWD" "$OOD_ADMIN"
else
  export KC_URL=$KC_INTERNAL KEYCLOAK_ADMIN KEYCLOAK_DATA KEYCLOAK_REALM
  # not in LDAP, so Keycloak keeps its password itself; asked once, only when the user doesn't exist yet
  if python3 "$HERE/../6-keycloak/kc.py" local-user "$OOD_ADMIN" </dev/null 2>/dev/null | grep -q exists; then
    echo "${OOD_ADMIN}: already a local Keycloak user"
  else
    read -rsp "New Keycloak password for ${OOD_ADMIN} (8+ characters): " pw; echo
    printf '%s' "$pw" | python3 "$HERE/../6-keycloak/kc.py" local-user "$OOD_ADMIN"; unset pw
  fi
fi

echo "== 6. Portal config"
[ -f "$PORTAL.orig" ] || cp "$PORTAL" "$PORTAL.orig"
# ldap BEFORE file: Apache stops at the first provider that knows the user, so LDAP decides for
# everyone in it; only accounts LDAP doesn't know (OOD_ADMIN) fall through to htpasswd.
# ldap://localhost: Apache and LDAP are both on master, so the password never leaves the machine.
if [ "$OOD_AUTH" = ldap ]; then
  auth="auth:
  - 'AuthType Basic'
  - 'AuthName \"${PORTAL_TITLE}\"'
  - 'AuthBasicProvider ldap file'
  - 'AuthLDAPURL \"ldap://localhost/ou=People,${LDAP_BASE}?uid?one\"'
  - 'AuthUserFile \"${HTPASSWD}\"'
  - 'Require valid-user'"
else
  python3 "$HERE/../6-keycloak/kc.py" client ood "https://${OOD_SERVERNAME}" "$OIDC_SECRET"
  [ -s "$OIDC_PASSPHRASE" ] || (umask 077; openssl rand -hex 32 | tr -d '\n' > "$OIDC_PASSPHRASE")
  # Apache talks to Keycloak on 127.0.0.1 (no certificate problem); Keycloak still names its public address
  # (https://$OOD_SERVERNAME$KEYCLOAK_PATH) as the issuer and the browser login page.
  # preferred_username = the LDAP uid = the Linux user OOD runs the session as (no user map needed).
  # logout: /oidc?logout= ends the Keycloak session too, then comes back to OOD.
  auth="auth:
  - 'AuthType openid-connect'
  - 'Require valid-user'
oidc_uri: '/oidc'
oidc_provider_metadata_url: '${KC_INTERNAL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration'
oidc_client_id: 'ood'
oidc_client_secret: '$(cat "$OIDC_SECRET")'
oidc_crypto_passphrase: '$(cat "$OIDC_PASSPHRASE")'
oidc_remote_user_claim: 'preferred_username'
oidc_scope: 'openid profile'
oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
oidc_settings:
  OIDCPassClaimsAs: 'environment'
  OIDCStripCookies: 'mod_auth_openidc_session mod_auth_openidc_session_chunks mod_auth_openidc_session_0 mod_auth_openidc_session_1'
  OIDCPKCEMethod: 'S256'
logout_redirect: '/oidc?logout=https%3A%2F%2F${OOD_SERVERNAME}%2F'"
fi
# MLflow single sign-on (OOD_AUTH=keycloak): OOD's /node proxy already reaches MLflow at its prefix and sends the
# logged-in user as X-Forwarded-User. MLflow trusts that only with this secret, which Apache adds on MLflow's
# path alone (a <Location> merges with OOD's /node <LocationMatch>), so other /node apps never see it.
mlflow_sso=""
if [ "$OOD_AUTH" = keycloak ]; then
  if [[ $MLFLOW_PREFIX != /node/* ]]; then
    echo "MLflow SSO skipped: MLFLOW_PREFIX ($MLFLOW_PREFIX) is not under /node/, so OOD doesn't proxy MLflow."
  elif [ -s "$MLFLOW_DATA/proxy.secret" ]; then
    mlflow_sso="
  - '<Location \"${MLFLOW_PREFIX}\">'
  - '  RequestHeader set X-MLflow-Proxy-Secret \"$(cat "$MLFLOW_DATA/proxy.secret")\"'
  - '</Location>'"
  else
    echo "MLflow SSO skipped: no $MLFLOW_DATA/proxy.secret yet. Run ../3-mlflow/2-deploy.sh, then rerun this script."
  fi
fi
(umask 077; cat > "$PORTAL" <<EOF
servername: ${OOD_SERVERNAME}
port: 443
ssl:
  - 'SSLCertificateFile "${CERT}"'
  - 'SSLCertificateKeyFile "${KEY}"'
${auth}
# proxy for interactive apps
node_uri: '/node'
rnode_uri: '/rnode'
# Keycloak (6-keycloak) listens on 127.0.0.1 only; browsers reach it here, with OOD's certificate on port 443.
# No login on this path: Keycloak IS the login page. Until 6-keycloak is installed it just answers 503.
custom_vhost_directives:
  - '<Location "${KEYCLOAK_PATH}">'
  - '  ProxyPass "http://127.0.0.1:${KEYCLOAK_PORT}${KEYCLOAK_PATH}"'
  - '  ProxyPassReverse "http://127.0.0.1:${KEYCLOAK_PORT}${KEYCLOAK_PATH}"'
  - '  RequestHeader set X-Forwarded-Proto "https"'
  - '  RequestHeader set X-Forwarded-Port "443"'
  - '</Location>'${mlflow_sso}
EOF
)
chmod 600 "$PORTAL"                               # holds the OIDC client secret when OOD_AUTH=keycloak
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

echo "== 8. Look: ${PORTAL_TITLE} name, navy top bar, no OOD branding, login page background on home"
# all through OOD's own settings; nothing in OOD's files is patched (survives OOD upgrades)
install -d /var/www/ood/public/ai-factory
install -m 644 "$HERE/branding/ai-factory.css" /var/www/ood/public/ai-factory/
install -m 644 "$HERE/../6-keycloak/theme/ai-factory/login/resources/img/bg.jpg" /var/www/ood/public/ai-factory/
cat > /etc/ood/config/ondemand.d/ai-factory.yml <<YML
# Written by OOD-Install/2-ood/setup-ood.sh. Users see changes after "Restart Web Server".
dashboard_title: "${PORTAL_TITLE}"
navbar_type: dark
brand_bg_color: "${PORTAL_COLOR}"
brand_link_active_bg_color: "rgba(0, 0, 0, 0.3)"
disable_dashboard_welcome_message: true     # the Open OnDemand logo + "OnDemand provides ..." text
custom_css_files: ["ai-factory/ai-factory.css"]
YML

echo "== 9. Start web server, open https"
# a broken config would take OOD down on restart: check first
apachectl configtest || { echo "Apache config error (see above): web server NOT restarted." >&2; exit 1; }
systemctl enable httpd
systemctl restart httpd
if systemctl is-active -q firewalld; then
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
fi

echo "== 10. Check"
rpm -q ondemand mod_ldap
echo "/                   -> $(curl -skI -o /dev/null -w '%{http_code}' https://localhost/)   (expect 302)"
if [ "$OOD_AUTH" = ldap ]; then
  echo "/pun/sys/dashboard  -> $(curl -skI -o /dev/null -w '%{http_code}' https://localhost/pun/sys/dashboard)   (expect 401: asks for the LDAP password)"
else
  loc=$(curl -sk -o /dev/null -w '%{redirect_url}' https://localhost/pun/sys/dashboard)
  echo "/pun/sys/dashboard  -> ${loc%%\?*}   (expect https://${OOD_SERVERNAME}${KEYCLOAK_PATH}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth)"
fi
echo "${KEYCLOAK_PATH}/realms/master -> $(curl -sk -o /dev/null -w '%{http_code}' https://localhost${KEYCLOAK_PATH}/realms/master)   (expect 200 once 6-keycloak is installed, 503 before)"
cat <<EOF

Done (OOD_AUTH=${OOD_AUTH}). Test in the browser: https://${OOD_SERVERNAME}  -> log in with an LDAP user's password
  (keycloak: a Keycloak login page first; then OOD opens; "Log Out" in OOD logs out of Keycloak too).
From the laptop: tunnel local port 443 to ${MASTER_HOST}:443, then open https://${OOD_SERVERNAME}
EOF

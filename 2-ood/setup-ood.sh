#!/usr/bin/env bash
# Install Open OnDemand on LOGIN_HOST. Self-signed certificate. Web login, chosen by OOD_AUTH in site.conf:
#   ldap      Apache asks for the LDAP password itself (same as SSH); htpasswd login for OOD_ADMIN when LDAP is down
#   keycloak  Apache sends the browser to Keycloak (../6-keycloak) and trusts its login (OpenID Connect,
#             mod_auth_openidc): one login for OOD, MLflow, Model Hub. OOD_ADMIN is a local Keycloak user
# Switching back and forth = change OOD_AUTH, rerun this script.
# Run on LOGIN_HOST after ../1-ldap (and ../6-keycloak on master for keycloak): sudo bash setup-ood.sh
#   (ldap: asks once for OOD_ADMIN's web password)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$LOGIN_HOST" ] || { echo "Run this on $LOGIN_HOST (LOGIN_HOST)." >&2; exit 1; }
export LDAPTLS_CACERT=$LDAP_CA

CERT=$OOD_CERT
KEY=/etc/pki/tls/private/ood.key
PORTAL=/etc/ood/config/ood_portal.yml
HTPASSWD=/etc/ood/htpasswd

OIDC_PASSPHRASE=/etc/ood/oidc-crypto.passphrase

ldapsearch -x -LLL -H "$LDAP_URI" -b "$LDAP_BASE" -s base dn >/dev/null 2>&1 ||
  { echo "No answer from $LDAP_URI ($LDAP_BASE). Run ../1-ldap/1-server.sh on $MASTER_HOST, 2-client.sh here." >&2; exit 1; }
case $OOD_AUTH in
  ldap) ;;
  keycloak)
    curl -sf -o /dev/null "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/.well-known/openid-configuration" ||
      { echo "OOD_AUTH=keycloak, but realm $KEYCLOAK_REALM doesn't answer at $KEYCLOAK_URL: run ../6-keycloak/1-install.sh and 2-realm.sh on $MASTER_HOST." >&2; exit 1; }
    [ -s "$OOD_OIDC_SECRET" ] ||
      { echo "No $OOD_OIDC_SECRET: run ../6-keycloak/2-realm.sh on $MASTER_HOST (it makes client ood and copies the secret here)." >&2; exit 1; } ;;
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
  echo "keycloak: ${OOD_ADMIN} is a local Keycloak user (made by ../6-keycloak/2-realm.sh on $MASTER_HOST)"
fi

echo "== 6. Portal config"
[ -f "$PORTAL.orig" ] || cp "$PORTAL" "$PORTAL.orig"
# ldap BEFORE file: Apache stops at the first provider that knows the user, so LDAP decides for
# everyone in it; only accounts LDAP doesn't know (OOD_ADMIN) fall through to htpasswd.
# ldaps to MASTER_HOST (the certificate's name): the password crosses the network encrypted. Apache trusts
# LDAP_CA through LDAPTrustedGlobalCert, a server-wide directive, so it gets its own conf.d file.
printf '# Written by OOD-Install/2-ood/setup-ood.sh: AuthLDAPURL is ldaps to %s\nLDAPTrustedGlobalCert CA_BASE64 "%s"\n' \
  "$MASTER_HOST" "$LDAP_CA" > /etc/httpd/conf.d/ood-ldap-ca.conf
if [ "$OOD_AUTH" = ldap ]; then
  auth="auth:
  - 'AuthType Basic'
  - 'AuthName \"${PORTAL_TITLE}\"'
  - 'AuthBasicProvider ldap file'
  - 'AuthLDAPURL \"${LDAP_URI}/ou=People,${LDAP_BASE}?uid?one\"'
  - 'AuthUserFile \"${HTPASSWD}\"'
  - 'Require valid-user'"
else
  [ -s "$OIDC_PASSPHRASE" ] || (umask 077; openssl rand -hex 32 | tr -d '\n' > "$OIDC_PASSPHRASE")
  # Apache talks to Keycloak on KEYCLOAK_URL (master, plain HTTP); Keycloak still names its public address
  # (https://$OOD_SERVERNAME$KEYCLOAK_PATH) as the issuer and the browser login page.
  # preferred_username = the LDAP uid = the Linux user OOD runs the session as (no user map needed).
  # logout: /oidc?logout= ends the Keycloak session too, then comes back to OOD.
  auth="auth:
  - 'AuthType openid-connect'
  - 'Require valid-user'
oidc_uri: '/oidc'
oidc_provider_metadata_url: '${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration'
oidc_client_id: 'ood'
oidc_client_secret: '$(cat "$OOD_OIDC_SECRET")'
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
  elif [ -s "$MLFLOW_PROXY_SECRET" ]; then
    mlflow_sso="
  - '<Location \"${MLFLOW_PREFIX}\">'
  - '  RequestHeader set X-MLflow-Proxy-Secret \"$(cat "$MLFLOW_PROXY_SECRET")\"'
  - '</Location>'"
  else
    echo "MLflow SSO skipped: no $MLFLOW_PROXY_SECRET yet. Run ../3-mlflow/2-deploy.sh on $MASTER_HOST (it copies it here), then rerun this script."
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
# Keycloak (6-keycloak) runs on master (KEYCLOAK_URL, only this node let in); browsers reach it here, with OOD's certificate on port 443.
# No login on this path: Keycloak IS the login page. Until 6-keycloak is installed it just answers 503.
custom_vhost_directives:
  - '<Location "${KEYCLOAK_PATH}">'
  - '  ProxyPass "${KEYCLOAK_URL}"'
  - '  ProxyPassReverse "${KEYCLOAK_URL}"'
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
    host: "${LOGIN_HOST}"
  job:
    adapter: "slurm"
    bin: "${SLURM_BIN}"
    conf: "${SLURM_CONF}"
EOF

echo "== 8. Look: C-DAC logo + tab icon, navy top bar (also on our app pages), no OOD branding, login page background on home"
# all through OOD's own settings; nothing in OOD's files is patched (survives OOD upgrades)
install -d /var/www/ood/public/ai-factory
install -m 644 "$HERE"/branding/{ai-factory.css,cdac-logo.svg,favicon.ico} /var/www/ood/public/ai-factory/
# top bar of our app pages (VS Code, Jupyter, MLflow, Model Hub): same colour as OOD's, from PORTAL_COLOR
{ echo ":root { --portal-color: ${PORTAL_COLOR}; }"; cat "$HERE/branding/app-bar.css"; } > /var/www/ood/public/ai-factory/app-bar.css
chmod 644 /var/www/ood/public/ai-factory/app-bar.css
install -m 644 "$HERE/../6-keycloak/theme/ai-factory/login/resources/img/bg.jpg" /var/www/ood/public/ai-factory/
# icons of the home page cards: the apps' own set (Bootstrap Icons, Model Hub's copy); OOD itself only has Font Awesome
rm -rf /var/www/ood/public/ai-factory/bootstrap-icons
cp -r "$HERE/../5-model-hub/ood-app/model_hub/public/vendor/bootstrap-icons" /var/www/ood/public/ai-factory/
chmod -R a+rX /var/www/ood/public/ai-factory/bootstrap-icons
# home page: our tools as cards, a dashboard widget (OOD loads views from /etc/ood/config/apps/dashboard/views)
install -d /etc/ood/config/apps/dashboard/views/widgets
OOD_ADMIN=$OOD_ADMIN envsubst '$OOD_ADMIN' < "$HERE/branding/_ai_tools.html.erb" > /etc/ood/config/apps/dashboard/views/widgets/_ai_tools.html.erb
chmod 644 /etc/ood/config/apps/dashboard/views/widgets/_ai_tools.html.erb
# top bar: a bell left of Help with the admin's messages (8-admin writes them to ADMIN_NOTICES). OOD has no setting
# for it: the same views folder takes the place of its (empty here) Develop menu. x / Clear all -> app aistack_notices
install -d /etc/ood/config/apps/dashboard/views/layouts/nav
ADMIN_NOTICES=$ADMIN_NOTICES envsubst '$ADMIN_NOTICES' < "$HERE/branding/_notifications.html.erb" \
  > /etc/ood/config/apps/dashboard/views/layouts/nav/_develop_dropdown.html.erb
chmod 644 /etc/ood/config/apps/dashboard/views/layouts/nav/_develop_dropdown.html.erb
rm -rf /var/www/ood/apps/sys/aistack_notices
install -d -m 755 /var/www/ood/apps/sys/aistack_notices/tmp
install -m 644 "$HERE"/notices/{manifest.yml,passenger_wsgi.py} /var/www/ood/apps/sys/aistack_notices/
printf '{"notices": "%s"}\n' "$ADMIN_NOTICES" > /var/www/ood/apps/sys/aistack_notices/site.json
chmod 644 /var/www/ood/apps/sys/aistack_notices/site.json
touch /var/www/ood/apps/sys/aistack_notices/tmp/restart.txt      # Passenger reloads it in running web servers
# a new sys app gets its nginx config (shared by all users) only from OOD's "Initialize App" page on the first visit:
# the bell only POSTs in the background and would get a 404. Stage it now, then reload the running per-user servers
/opt/ood/nginx_stage/sbin/nginx_stage app --user="$OOD_ADMIN" --sub-uri=/pun --sub-request=/sys/aistack_notices --skip-nginx
for u in $(/opt/ood/nginx_stage/sbin/nginx_stage nginx_list); do
  /opt/ood/nginx_stage/sbin/nginx_stage nginx --user="$u" --signal=reload >/dev/null || true
done
cat > /etc/ood/config/ondemand.d/ai-factory.yml <<YML
# Written by OOD-Install/2-ood/setup-ood.sh. Users see changes after "Restart Web Server".
dashboard_title: "${PORTAL_TITLE}"           # tab title + the logo's alt text
dashboard_header_img_logo: "/public/ai-factory/cdac-logo.svg"   # C-DAC logo in the top bar instead of the title
# the dashboard takes favicon.ico (and custom_css_files) from public_url: point it at our folder,
# so OOD's own /var/www/ood/public/favicon.ico stays untouched
public_url: "/public/ai-factory"
navbar_type: dark
brand_bg_color: "${PORTAL_COLOR}"
brand_link_active_bg_color: "rgba(0, 0, 0, 0.3)"
disable_dashboard_welcome_message: true     # the Open OnDemand logo + "OnDemand provides ..." text
custom_css_files: ["bootstrap-icons/bootstrap-icons.min.css", "ai-factory.css"]   # relative to public_url
# home page = only our tool cards (views/widgets/_ai_tools.html.erb), grouped in sections
dashboard_layout:
  rows:
    - columns:
        - width: 12
          widgets: [ai_tools]
# top bar: no Jobs, My Interactive Sessions, All Apps. Interactive Apps = every app in subcategory "Servers"
# (Jupyter, VS Code, MLflow, Model Hub, and any new one), so OOD's Desktop (subcategory "Desktops") is left out.
nav_bar:
  - files
  - clusters
  - title: "Interactive Apps"
    links:
      - group: "Servers"
      - apps: [{ category: "Interactive Apps", subcategory: "Servers" }]
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
From the laptop: tunnel local port 443 to ${LOGIN_HOST}:443, then open https://${OOD_SERVERNAME}
EOF

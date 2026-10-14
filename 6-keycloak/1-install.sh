#!/usr/bin/env bash
# Keycloak on master: one login (OpenID Connect) for OOD, MLflow and Model Hub. Users and passwords stay in LDAP.
# Two podman containers under systemd (quadlets), both as KEYCLOAK_USER:
#   keycloak-db   Postgres on 127.0.0.1, data in $KEYCLOAK_DATA/db (master's local disk)
#   keycloak      Keycloak, KEYCLOAK_URL (MASTER_IP; firewalld lets in only LOGIN_IP); browsers come in through
#                 OOD's Apache on LOGIN_HOST at https://$OOD_SERVERNAME$KEYCLOAK_PATH (../2-ood/setup-ood.sh adds that proxy)
# systemd, not k8s: login must keep working when k8s has a problem (same reason the registry runs this way).
# Safe to rerun: data, passwords and the admin survive. The realm (users from LDAP) is 2-realm.sh.
# Run on master after ../0-registry, ../1-ldap and ../2-ood (on LOGIN_HOST): sudo bash 1-install.sh   Needs root ssh to LOGIN_HOST.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (creates $KEYCLOAK_USER, writes systemd units)." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST." >&2; exit 1; }
UNITS=/etc/containers/systemd
ENVDIR=/etc/keycloak
OOD_CRT=/etc/pki/tls/certs/keycloak-trusts-ood.crt   # master's copy of LOGIN_HOST's OOD_CERT (cert_t, like the original)
export KC_URL=$KEYCLOAK_URL KEYCLOAK_ADMIN KEYCLOAK_DATA
on() {  # on <node> <command>: as root, here or over ssh
  if [ "$1" = "$(hostname -s)" ]; then bash -c "$2"; else ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$1" "$2"; fi
}

echo "== 1. Checks"
command -v podman >/dev/null || { echo "No podman." >&2; exit 1; }
[ -x /usr/libexec/podman/quadlet ] || { echo "podman has no quadlet support (needs podman >= 4.4)." >&2; exit 1; }
curl -sf "http://$REGISTRY/v2/" >/dev/null || { echo "Registry $REGISTRY doesn't answer: run ../0-registry first." >&2; exit 1; }
ldapsearch -x -LLL -H ldap://localhost -b "$LDAP_BASE" -s base dn >/dev/null 2>&1 ||
  { echo "No LDAP on localhost ($LDAP_BASE): run ../1-ldap/1-server.sh first." >&2; exit 1; }
# OOD's certificate lives on LOGIN_HOST: master fetches it (a public certificate; master -> login, never the other way)
ood_crt=$(on "$LOGIN_HOST" "cat $OOD_CERT") && [ -n "$ood_crt" ] ||
  { echo "No OOD certificate $OOD_CERT on $LOGIN_HOST: run ../2-ood/setup-ood.sh there first." >&2; exit 1; }
# a port in use is fine only if it's ours (a rerun); anything else (e.g. another Postgres on 5432) must move
systemctl -q is-active keycloak-db.service keycloak.service 2>/dev/null ||
  for p in "$KEYCLOAK_PORT" "$KEYCLOAK_MGMT_PORT" "$KEYCLOAK_DB_PORT"; do
    ! ss -Hltn "sport = :$p" | grep -q . ||
      { echo "Port $p is taken by another program: pick a free one in site.conf (KEYCLOAK_*PORT)." >&2; exit 1; }
  done

echo "== 2. Service account $KEYCLOAK_USER ($KEYCLOAK_UID) owns $KEYCLOAK_DATA"
owner=$(getent passwd "$KEYCLOAK_UID" | cut -d: -f1 || true)
if [ -z "$owner" ]; then
  groupadd -r -g "$KEYCLOAK_UID" "$KEYCLOAK_USER"
  useradd -r -u "$KEYCLOAK_UID" -g "$KEYCLOAK_UID" -d "$KEYCLOAK_DATA" -M -s /sbin/nologin -c "Keycloak" "$KEYCLOAK_USER"
elif [ "$owner" != "$KEYCLOAK_USER" ]; then
  echo "UID $KEYCLOAK_UID already belongs to '$owner'. Pick a free KEYCLOAK_UID below $MIN_UID in site.conf." >&2; exit 1
fi
install -d -m 700 -o "$KEYCLOAK_UID" -g "$KEYCLOAK_UID" "$KEYCLOAK_DATA" "$KEYCLOAK_DATA/db"

echo "== 3. Passwords (root only: $KEYCLOAK_DATA/*.pass, $ENVDIR/*.env)"
for f in admin bootstrap db; do
  [ -s "$KEYCLOAK_DATA/$f.pass" ] || (umask 077; openssl rand -hex 24 | tr -d '\n' > "$KEYCLOAK_DATA/$f.pass")
  chown root:root "$KEYCLOAK_DATA/$f.pass"; chmod 600 "$KEYCLOAK_DATA/$f.pass"
done
install -d -m 700 "$ENVDIR"
# podman reads these as root before starting the containers; the passwords never appear on a command line
(umask 077
 printf 'POSTGRES_USER=keycloak\nPOSTGRES_DB=keycloak\nPOSTGRES_PASSWORD=%s\n' "$(cat "$KEYCLOAK_DATA/db.pass")" > "$ENVDIR/db.env"
 # KC_BOOTSTRAP_*: used only on the very first start (empty database) to make a temporary admin; kc.py replaces it
 printf 'KC_DB_PASSWORD=%s\nKC_BOOTSTRAP_ADMIN_USERNAME=kc-bootstrap\nKC_BOOTSTRAP_ADMIN_PASSWORD=%s\n' \
   "$(cat "$KEYCLOAK_DATA/db.pass")" "$(cat "$KEYCLOAK_DATA/bootstrap.pass")" > "$ENVDIR/keycloak.env")

echo "== 4. Images in $REGISTRY (offline-safe: the containers never pull from the internet)"
tag_in_registry() { local r=${1#*/}; curl -sf "http://$REGISTRY/v2/${r%:*}/tags/list" | grep -q "\"${r##*:}\""; }
if tag_in_registry "$KEYCLOAK_DB_IMAGE"; then echo "already in $REGISTRY: $KEYCLOAK_DB_IMAGE"
else
  podman pull -q "docker.io/library/${KEYCLOAK_DB_IMAGE##*/}" >/dev/null
  podman tag "docker.io/library/${KEYCLOAK_DB_IMAGE##*/}" "$KEYCLOAK_DB_IMAGE" && podman push -q "$KEYCLOAK_DB_IMAGE"
  echo "mirrored $KEYCLOAK_DB_IMAGE"
fi
if tag_in_registry "$KEYCLOAK_IMAGE"; then echo "already in $REGISTRY: $KEYCLOAK_IMAGE"
else
  podman build -q --build-arg KEYCLOAK_VERSION="$KEYCLOAK_VERSION" --build-arg KEYCLOAK_PATH="$KEYCLOAK_PATH" \
    -t "$KEYCLOAK_IMAGE" "$HERE/image" >/dev/null && podman push -q "$KEYCLOAK_IMAGE"
  echo "built $KEYCLOAK_IMAGE"
fi

echo "== 5. systemd units ($UNITS/keycloak-db.container, keycloak.container)"
unit() {  # unit <file> : writes stdin there; prints the name if it changed
  local new; new=$(cat)
  [ "$(cat "$UNITS/$1" 2>/dev/null)" = "$new" ] && return
  printf '%s\n' "$new" > "$UNITS/$1"; echo "$1"
}
install -d "$UNITS"
changed=$(
# login page look (theme/ai-factory): root-owned copy on master's disk, mounted read-only; a change restarts Keycloak
if ! diff -rq "$HERE/theme" "$KEYCLOAK_DATA/themes" >/dev/null 2>&1; then
  rm -rf "$KEYCLOAK_DATA/themes"; (umask 022; cp -r "$HERE/theme" "$KEYCLOAK_DATA/themes"); echo themes
fi
# a renewed OOD certificate restarts Keycloak too (it reads its truststore at start)
[ "$(cat "$OOD_CRT" 2>/dev/null)" = "$ood_crt" ] || { printf '%s\n' "$ood_crt" > "$OOD_CRT"; chmod 644 "$OOD_CRT"; echo ood.crt; }
unit keycloak-db.container <<EOF
# Written by OOD-Install/6-keycloak/1-install.sh. Keycloak's database.
[Unit]
Description=Keycloak database (Postgres)

[Container]
ContainerName=keycloak-db
Image=$KEYCLOAK_DB_IMAGE
Network=host
User=$KEYCLOAK_UID
Group=$KEYCLOAK_UID
Volume=$KEYCLOAK_DATA/db:/var/lib/postgresql/data
EnvironmentFile=$ENVDIR/db.env
Exec=postgres -c listen_addresses=127.0.0.1 -c port=$KEYCLOAK_DB_PORT
HealthCmd=pg_isready -U keycloak -h 127.0.0.1 -p $KEYCLOAK_DB_PORT

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
unit keycloak.container <<EOF
# Written by OOD-Install/6-keycloak/1-install.sh. Browsers: https://$OOD_SERVERNAME$KEYCLOAK_PATH (OOD's Apache).
[Unit]
Description=Keycloak (login for OOD, MLflow, Model Hub)
Requires=keycloak-db.service
After=keycloak-db.service network-online.target

[Container]
ContainerName=keycloak
Image=$KEYCLOAK_IMAGE
Network=host
User=$KEYCLOAK_UID
Group=$KEYCLOAK_UID
# Keycloak writes temp files to /opt/keycloak/data; nothing in it needs to survive a restart (all state is in Postgres)
Tmpfs=/opt/keycloak/data:rw,mode=1777
Volume=$KEYCLOAK_DATA/themes:/opt/keycloak/themes:ro
# certificates Keycloak trusts: LDAP's CA (ldaps, the only way 389 DS accepts a password change; 2-realm.sh) and
# OOD's (Keycloak sends "this person is signed out" to https://OOD_SERVERNAME/oidc; kc.py client)
Volume=$LDAP_CA:/opt/keycloak/conf/truststores/ldap-ca.crt:ro
Volume=$OOD_CRT:/opt/keycloak/conf/truststores/ood.crt:ro
Environment=KC_TRUSTSTORE_PATHS=/opt/keycloak/conf/truststores
EnvironmentFile=$ENVDIR/keycloak.env
Environment=KC_DB_URL=jdbc:postgresql://127.0.0.1:$KEYCLOAK_DB_PORT/keycloak KC_DB_USERNAME=keycloak
# HTTP on MASTER_IP so OOD's Apache on LOGIN_HOST reaches it (firewalld: step 6); health/metrics stay on 127.0.0.1
# ponytail: plain HTTP between LOGIN_HOST and master carries the login form (passwords) and tokens over the cluster
# LAN; fine on a private rack, else give Keycloak a certificate (KC_HTTPS_*) and point KEYCLOAK_URL at https
Environment=KC_HTTP_ENABLED=true KC_HTTP_HOST=$MASTER_IP KC_HTTP_PORT=$KEYCLOAK_PORT
Environment=KC_HTTP_MANAGEMENT_HOST=127.0.0.1 KC_HTTP_MANAGEMENT_PORT=$KEYCLOAK_MGMT_PORT
# the address browsers use; Apache and the scripts call KEYCLOAK_URL (backchannel)
Environment=KC_HOSTNAME=https://$OOD_SERVERNAME$KEYCLOAK_PATH KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true KC_PROXY_HEADERS=xforwarded
# one server: no cluster traffic (otherwise it opens port 57800 on every interface)
Environment=KC_CACHE=local
Exec=start --optimized

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
)
systemctl daemon-reload
if [ -n "$changed" ]; then
  echo "changed: $(echo $changed)"; systemctl restart keycloak-db.service keycloak.service
else
  systemctl start keycloak-db.service keycloak.service
fi

echo "== 6. Firewall: Keycloak's port only for LOGIN_IP ($LOGIN_IP); master itself comes in over lo"
if systemctl is-active -q firewalld; then
  rule="rule family=ipv4 source address=$LOGIN_IP port port=$KEYCLOAK_PORT protocol=tcp accept"
  firewall-cmd -q --permanent --query-rich-rule="$rule" || { firewall-cmd -q --permanent --add-rich-rule="$rule"; firewall-cmd -q --reload; }
  echo "firewalld: $rule"
else
  echo "WARNING: firewalld isn't running: $MASTER_IP:$KEYCLOAK_PORT is open to the whole network, not just $LOGIN_IP"
fi

echo "== 7. Wait until Keycloak is ready"
for _ in $(seq 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$KEYCLOAK_MGMT_PORT$KEYCLOAK_PATH/health/ready")" = 200 ] && break
  sleep 3
done
curl -sf -o /dev/null "http://127.0.0.1:$KEYCLOAK_MGMT_PORT$KEYCLOAK_PATH/health/ready" ||
  { echo "Keycloak not ready after 3 min: journalctl -u keycloak -u keycloak-db -n 50" >&2; exit 1; }
echo "ready"

echo "== 8. Permanent admin $KEYCLOAK_ADMIN (password: $KEYCLOAK_DATA/admin.pass)"
python3 "$HERE/kc.py" admin

echo "== 9. Check"
systemctl is-active keycloak-db.service keycloak.service | paste -sd' ' | sed 's/^/units: /'
ss -Hltn | awk '{print $4}' | grep -E ":($KEYCLOAK_PORT|$KEYCLOAK_MGMT_PORT|$KEYCLOAK_DB_PORT)$" | paste -sd' ' |
  sed "s/^/listening (expect $MASTER_IP:$KEYCLOAK_PORT, the other two on 127.0.0.1): /"
code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$OOD_SERVERNAME:443:$LOGIN_IP" \
  "https://$OOD_SERVERNAME$KEYCLOAK_PATH/realms/master/.well-known/openid-configuration")
if [ "$code" = 200 ]; then echo "through OOD's Apache on $LOGIN_HOST: https://$OOD_SERVERNAME$KEYCLOAK_PATH  ok"
else echo "through OOD's Apache on $LOGIN_HOST: HTTP $code. Rerun ../2-ood/setup-ood.sh there (it adds the $KEYCLOAK_PATH proxy)."; fi
echo
echo "Next: sudo bash 2-realm.sh   (realm $KEYCLOAK_REALM with the LDAP users)"

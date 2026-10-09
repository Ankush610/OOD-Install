#!/usr/bin/env bash
# Keycloak on master: one login (OpenID Connect) for OOD, MLflow and Model Hub. Users and passwords stay in LDAP.
# Two podman containers under systemd (quadlets), both as KEYCLOAK_USER and on 127.0.0.1 only:
#   keycloak-db   Postgres, data in $KEYCLOAK_DATA/db (master's local disk)
#   keycloak      Keycloak, http://127.0.0.1:$KEYCLOAK_PORT$KEYCLOAK_PATH; browsers come in through OOD's Apache
#                 at https://$OOD_SERVERNAME$KEYCLOAK_PATH (../2-ood/setup-ood.sh adds that proxy)
# systemd, not k8s: login must keep working when k8s has a problem (same reason the registry runs this way).
# Safe to rerun: data, passwords and the admin survive. The realm (users from LDAP) is 2-realm.sh.
# Run on master after ../0-registry, ../1-ldap and ../2-ood: sudo bash 1-install.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (creates $KEYCLOAK_USER, writes systemd units)." >&2; exit 1; }
UNITS=/etc/containers/systemd
ENVDIR=/etc/keycloak
export KC_URL=http://127.0.0.1:$KEYCLOAK_PORT$KEYCLOAK_PATH KEYCLOAK_ADMIN KEYCLOAK_DATA

echo "== 1. Checks"
command -v podman >/dev/null || { echo "No podman." >&2; exit 1; }
[ -x /usr/libexec/podman/quadlet ] || { echo "podman has no quadlet support (needs podman >= 4.4)." >&2; exit 1; }
curl -sf "http://$REGISTRY/v2/" >/dev/null || { echo "Registry $REGISTRY doesn't answer: run ../0-registry first." >&2; exit 1; }
ldapsearch -x -LLL -H ldap://localhost -b "$LDAP_BASE" -s base dn >/dev/null 2>&1 ||
  { echo "No LDAP on localhost ($LDAP_BASE): run ../1-ldap/1-server.sh first." >&2; exit 1; }
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
EnvironmentFile=$ENVDIR/keycloak.env
Environment=KC_DB_URL=jdbc:postgresql://127.0.0.1:$KEYCLOAK_DB_PORT/keycloak KC_DB_USERNAME=keycloak
Environment=KC_HTTP_ENABLED=true KC_HTTP_HOST=127.0.0.1 KC_HTTP_PORT=$KEYCLOAK_PORT KC_HTTP_MANAGEMENT_PORT=$KEYCLOAK_MGMT_PORT
# the address browsers use; scripts and servers on master may use 127.0.0.1 (backchannel)
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

echo "== 6. Wait until Keycloak is ready"
for _ in $(seq 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$KEYCLOAK_MGMT_PORT$KEYCLOAK_PATH/health/ready")" = 200 ] && break
  sleep 3
done
curl -sf -o /dev/null "http://127.0.0.1:$KEYCLOAK_MGMT_PORT$KEYCLOAK_PATH/health/ready" ||
  { echo "Keycloak not ready after 3 min: journalctl -u keycloak -u keycloak-db -n 50" >&2; exit 1; }
echo "ready"

echo "== 7. Permanent admin $KEYCLOAK_ADMIN (password: $KEYCLOAK_DATA/admin.pass)"
python3 "$HERE/kc.py" admin

echo "== 8. Check"
systemctl is-active keycloak-db.service keycloak.service | paste -sd' ' | sed 's/^/units: /'
ss -Hltn | awk '{print $4}' | grep -E ":($KEYCLOAK_PORT|$KEYCLOAK_MGMT_PORT|$KEYCLOAK_DB_PORT)$" | paste -sd' ' | sed 's/^/listening (127.0.0.1 only): /'
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost$KEYCLOAK_PATH/realms/master/.well-known/openid-configuration")
if [ "$code" = 200 ]; then echo "through OOD's Apache: https://$OOD_SERVERNAME$KEYCLOAK_PATH  ok"
else echo "through OOD's Apache: HTTP $code. Rerun ../2-ood/setup-ood.sh (it adds the $KEYCLOAK_PATH proxy)."; fi
echo
echo "Next: sudo bash 2-realm.sh   (realm $KEYCLOAK_REALM with the LDAP users)"

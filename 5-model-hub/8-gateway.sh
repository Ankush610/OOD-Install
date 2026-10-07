#!/usr/bin/env bash
# The gateway: one HTTPS address (GATEWAY_URL) for calling any Model Hub endpoint, from a laptop or the cluster:
#   https://<GATEWAY>/<owner>/<endpoint>/<path>     with header  Authorization: Bearer <personal API key>
# Keys are made in Model Hub (My API key). For now only the owner may call an endpoint (sharing: later).
# What it installs (namespace GATEWAY_NS): nginx + auth.py in one pod on master, Service on GATEWAY_IP:443
# (MetalLB), a certificate (self-signed Rudra CA unless GATEWAY_TLS_SECRET names the customer's), and the read
# rights it needs (2-sync-users.sh binds them in each user namespace).
# Safe to rerun (applies changes, restarts the pod if its config changed).
# Run on master after 2-sync-users.sh: sudo bash 8-gateway.sh, then sudo bash 2-sync-users.sh (gateway read rights)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (pushes images as root's podman, reads the cluster admin config)." >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
G=$HERE/gateway

echo "== 1. Checks"
kubectl get node "$MASTER_HOST" >/dev/null
kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || [ -n "$GATEWAY_TLS_SECRET" ] ||
  { echo "No cert-manager: install it, or set GATEWAY_TLS_SECRET to a TLS Secret you made in $GATEWAY_NS." >&2; exit 1; }
kubectl get ipaddresspools.metallb.io -A -o jsonpath='{range .items[*]}{.spec.addresses[*]}{"\n"}{end}' | grep -q . ||
  { echo "No MetalLB address pool: GATEWAY_IP can't be handed out." >&2; exit 1; }
owner=$(kubectl get svc -A -o jsonpath="{range .items[?(@.spec.type==\"LoadBalancer\")]}{.metadata.namespace}/{.metadata.name} {.status.loadBalancer.ingress[0].ip}{\"\\n\"}{end}" |
        awk -v ip="$GATEWAY_IP" '$2 == ip {print $1}')
[ -z "$owner" ] || [ "$owner" = "$GATEWAY_NS/gateway" ] ||
  { echo "GATEWAY_IP $GATEWAY_IP is already used by $owner: pick another in site.conf." >&2; exit 1; }
python3 "$G/auth.py" --test >/dev/null

echo "== 2. Images in $REGISTRY"
mirror() {  # mirror <registry image> <upstream image>
  local r=${1#*/}
  if curl -sf "http://$REGISTRY/v2/${r%:*}/tags/list" | grep -q "\"${r##*:}\""; then echo "already in $REGISTRY: $1"; return; fi
  podman pull -q "$2" >/dev/null && podman tag "$2" "$1" && podman push -q "$1" && echo "mirrored $1"
}
mirror "$GATEWAY_NGINX_IMAGE" "docker.io/nginxinc/${GATEWAY_NGINX_IMAGE##*/}"
mirror "$GATEWAY_PY_IMAGE" "docker.io/library/${GATEWAY_PY_IMAGE##*/}"

echo "== 3. Certificate"
export GATEWAY_NS GATEWAY_IP CLUSTER_TITLE MASTER_HOST GATEWAY_NGINX_IMAGE GATEWAY_PY_IMAGE
kubectl get ns "$GATEWAY_NS" >/dev/null 2>&1 || kubectl create ns "$GATEWAY_NS" >/dev/null
if [ -n "$GATEWAY_TLS_SECRET" ]; then
  kubectl -n "$GATEWAY_NS" get secret "$GATEWAY_TLS_SECRET" >/dev/null ||
    { echo "GATEWAY_TLS_SECRET=$GATEWAY_TLS_SECRET: no such Secret in $GATEWAY_NS (kubectl -n $GATEWAY_NS create secret tls ...)." >&2; exit 1; }
  export TLS_SECRET=$GATEWAY_TLS_SECRET; echo "customer certificate: Secret $TLS_SECRET"
else
  export TLS_SECRET=gateway-tls GATEWAY_NAME=${GATEWAY_HOST:-$GATEWAY_IP}
  CERT_SANS="  ipAddresses: [\"$GATEWAY_IP\"]"
  [ -z "$GATEWAY_HOST" ] || CERT_SANS+=$'\n'"  dnsNames: [\"$GATEWAY_HOST\"]"
  export CERT_SANS
  envsubst '$GATEWAY_NS $CLUSTER_TITLE $GATEWAY_NAME $CERT_SANS' < "$G/tls.yaml" | kubectl apply -f - | sed 's/^/   /'
  kubectl -n "$GATEWAY_NS" wait --for=condition=Ready certificate/gateway-tls --timeout=120s >/dev/null
  echo "self-signed: Rudra CA -> gateway-tls for ${GATEWAY_NAME}"
fi

echo "== 4. Gateway (nginx + auth.py)"
DNS_IP=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
export NGINX_CONF AUTH_PY CONFIG_SHA
NGINX_CONF=$(DNS_IP=$DNS_IP envsubst '$DNS_IP' < "$G/nginx.conf" | sed 's/^/    /')
AUTH_PY=$(sed 's/^/    /' "$G/auth.py")
CONFIG_SHA=$(printf '%s%s' "$NGINX_CONF" "$AUTH_PY" | sha256sum | cut -c1-16)
envsubst '$GATEWAY_NS $GATEWAY_IP $MASTER_HOST $GATEWAY_NGINX_IMAGE $GATEWAY_PY_IMAGE $TLS_SECRET $NGINX_CONF $AUTH_PY $CONFIG_SHA' \
  < "$G/gateway.yaml" | kubectl apply -f - | sed 's/^/   /'
kubectl -n "$GATEWAY_NS" rollout status deploy/gateway --timeout=180s

echo "== 5. Check"
kubectl -n "$GATEWAY_NS" get pod -l app=gateway -o wide
kubectl -n "$GATEWAY_NS" get svc gateway
ca=$(mktemp); trap 'rm -f "$ca"' EXIT
if [ -z "$GATEWAY_TLS_SECRET" ]; then
  kubectl -n "$GATEWAY_NS" get secret rudra-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca"
  cacert=(--cacert "$ca" --resolve "${GATEWAY_HOST:-x}:443:$GATEWAY_IP")
else cacert=(); fi
for _ in $(seq 20); do curl -sf -o /dev/null "${cacert[@]}" "$GATEWAY_URL/healthz" && break; sleep 3; done
echo "health (certificate checked)  -> $(curl -s -o /dev/null -w '%{http_code}' "${cacert[@]}" "$GATEWAY_URL/healthz")   (expect 200)"
echo "a model, no key               -> $(curl -s -o /dev/null -w '%{http_code}' "${cacert[@]}" "$GATEWAY_URL/nobody/none/invocations")   (expect 401)"
cat <<EOF

Done. Gateway: $GATEWAY_URL
Next: sudo bash 2-sync-users.sh   (lets the gateway read keys + endpoints in every user namespace)
      sudo bash 7-install-ood-app.sh, Restart Web Server -> Model Hub -> My API key
EOF

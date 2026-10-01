#!/usr/bin/env bash
# The cluster's own container registry (REGISTRY, e.g. master:5000): how images built with podman reach Kubernetes.
# k8s runs containers with containerd, which can't see podman's images; both talk to this registry instead:
#   podman build/push (any user, rootless) ──> REGISTRY ──> containerd on every k8s node pulls (kubelet)
# Steps:
#   1. registry:2 container on master (rootful podman), storage REGISTRY_DATA, deletes allowed, back after reboot
#   2. containerd on every k8s node (MASTER_HOST + COMPUTE_NODES): pull from REGISTRY over plain HTTP
#   3. podman on master + LOGIN_NODES: trust REGISTRY (plain HTTP) for every user, no --tls-verify=false
#   4. k8s-image (build/push/mirror/ls helper) on the shared /home/apps/bin, on PATH for every login shell
#   5. check: push a test image, pull it on every k8s node, delete it again
# Plain HTTP is fine on a private cluster LAN only. Safe to rerun: changes only what differs; containerd is
# restarted only on nodes whose config changed (on master that bounces the control-plane pods ~1 min).
# Run on master: sudo bash setup-registry.sh       Needs root ssh to the other nodes (unreachable ones are skipped).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST." >&2; exit 1; }
[[ $REGISTRY == "$MASTER_HOST:"* ]] || { echo "REGISTRY ($REGISTRY) must be $MASTER_HOST:<port>: this script runs it there." >&2; exit 1; }
PORT=${REGISTRY##*:}
k8s_nodes=$(printf '%s\n' "$MASTER_HOST" $COMPUTE_NODES | awk '!seen[$0]++')
podman_nodes=$(printf '%s\n' "$MASTER_HOST" $LOGIN_NODES | awk '!seen[$0]++')
missed=()

on() {  # on <node> <script on stdin>: run as root there (locally on this host), false if unreachable
  if [ "$1" = "$(hostname -s)" ]; then bash -s
  else ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$1" bash -s; fi
}

echo "== 1. Registry container on $MASTER_HOST:$PORT (storage $REGISTRY_DATA)"
install -d -m 755 "$REGISTRY_DATA"
want="$REGISTRY_IMAGE|$REGISTRY_DATA:/var/lib/registry|delete=true|$PORT"
have=$(podman inspect registry --format \
  '{{.Config.Image}}|{{range .Mounts}}{{.Source}}:{{.Destination}}{{end}}|{{range .Config.Env}}{{if eq . "REGISTRY_STORAGE_DELETE_ENABLED=true"}}delete=true{{end}}{{end}}|{{range $p, $b := .HostConfig.PortBindings}}{{(index $b 0).HostPort}}{{end}}' 2>/dev/null || true)
if [ "$have" = "$want" ] && [ "$(podman inspect registry --format '{{.State.Running}}')" = true ]; then
  echo "running as wanted"
else
  [ -n "$have" ] && { echo "was: $have"; podman rm -f registry >/dev/null; }    # data stays in REGISTRY_DATA
  # deletes are off by default in registry:2 (DELETE answers 405); on, so old images can be removed
  podman run -d --name registry --restart=always -p "$PORT:5000" \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -v "$REGISTRY_DATA:/var/lib/registry" "$REGISTRY_IMAGE" >/dev/null
  echo "started $REGISTRY_IMAGE"
fi
# --restart=always only covers a crash; rootful podman starts such containers at boot via this unit
systemctl enable podman-restart.service >/dev/null 2>&1 && echo "podman-restart.service enabled (registry comes back after a reboot)"
for _ in $(seq 20); do curl -sf -o /dev/null "http://$REGISTRY/v2/" && break; sleep 1; done
curl -sf -o /dev/null "http://$REGISTRY/v2/" || { echo "registry doesn't answer on http://$REGISTRY/v2/" >&2; exit 1; }

echo "== 2. containerd pulls from $REGISTRY (every k8s node)"
for n in $k8s_nodes; do
  if out=$(on "$n" <<EOF 2>&1
set -e
f=/etc/containerd/config.toml; d=/etc/containerd/certs.d/$REGISTRY; changed=0
[ -f \$f ] || { containerd config default > \$f; changed=1; }
# containerd reads per-registry settings from certs.d/ only if config_path points there (2.x: two such lines)
if grep -Eq "^\s*config_path\s*=\s*(''|\"\")\s*\$" \$f; then
  cp \$f \$f.bak.\$(date +%F-%H%M%S)
  sed -Ei "s#^(\s*config_path\s*=\s*)(''|\"\")\s*\\\$#\1'/etc/containerd/certs.d'#" \$f; changed=1
fi
grep -q "config_path = ./etc/containerd/certs.d." \$f || { echo "no registry config_path in \$f: set it by hand (see README)"; exit 1; }
want='server = "http://$REGISTRY"

[host."http://$REGISTRY"]
  capabilities = ["pull", "resolve"]
  skip_verify = true'
if [ "\$(cat \$d/hosts.toml 2>/dev/null)" != "\$want" ]; then
  mkdir -p \$d; printf '%s\n' "\$want" > \$d/hosts.toml; changed=1
fi
if [ \$changed = 1 ]; then containerd config dump >/dev/null; systemctl restart containerd; echo "configured, containerd restarted"
else echo "already configured"; fi
EOF
  ); then echo "$n: $out"; else echo "$n: SKIPPED ($out)"; missed+=("$n"); fi
done

echo "== 3. podman trusts $REGISTRY for every user (master + login nodes)"
for n in $podman_nodes; do
  if on "$n" >/dev/null 2>&1 <<EOF
set -e
mkdir -p /etc/containers/registries.conf.d
printf '%s\n' '# The cluster registry on $MASTER_HOST: plain HTTP, private LAN only. Written by OOD-Install/0-registry.' \
  '[[registry]]' 'location = "$REGISTRY"' 'insecure = true' > /etc/containers/registries.conf.d/010-local-registry.conf
printf '%s\n' '# shared cluster tools on /home/apps' \
  'case ":\$PATH:" in *":/home/apps/bin:"*) ;; *) PATH="/home/apps/bin:\$PATH" ;; esac' > /etc/profile.d/apps-bin.sh
EOF
  then echo "$n: registries.conf.d/010-local-registry.conf + profile.d/apps-bin.sh"
  else echo "$n: SKIPPED (unreachable)"; missed+=("$n"); fi
done

echo "== 4. k8s-image -> /home/apps/bin (shared /home: once for every node)"
install -d -m 755 /home/apps/bin
sed "s#@REGISTRY@#$REGISTRY#" "$HERE/k8s-image" > /home/apps/bin/k8s-image.new
chmod 755 /home/apps/bin/k8s-image.new && mv /home/apps/bin/k8s-image.new /home/apps/bin/k8s-image
/home/apps/bin/k8s-image ls | sed 's/^/   /'

echo "== 5. Check: push a test image, pull it on every k8s node, delete it"
t=$REGISTRY/registry-selftest:1
podman tag "$REGISTRY_IMAGE" "$t" && podman push -q "$t" >/dev/null && echo "pushed $t"
for n in $k8s_nodes; do
  [[ " ${missed[*]} " == *" $n "* ]] && continue
  if on "$n" >/dev/null 2>&1 <<<"crictl pull $t && crictl rmi $t"; then echo "$n: pulled ok"
  else echo "$n: PULL FAILED (crictl pull $t)"; missed+=("$n"); fi
done
d=$(curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      "http://$REGISTRY/v2/registry-selftest/manifests/1" | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | tr -d '\r')
curl -s -o /dev/null -X DELETE "http://$REGISTRY/v2/registry-selftest/manifests/$d"
podman rmi "$t" >/dev/null 2>&1 || true
rm -rf "$REGISTRY_DATA/docker/registry/v2/repositories/registry-selftest"
echo
if [ ${#missed[@]} -gt 0 ]; then
  echo "NOT done on: $(printf '%s\n' "${missed[@]}" | sort -u | paste -sd' '). Rerun this script when they're back."
else
  echo "Done. Users: k8s-image build myapp:v1 . (new login shell for PATH)   Manifests: image: $REGISTRY/<name>:<tag>"
fi

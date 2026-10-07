#!/usr/bin/env bash
# Give LDAP users their Model Hub corner of k8s: namespace u-<user> (runs as them, Slurm-managed, GPU quota),
# read-only model volumes, and their own k8s login (~/.kube/aistack.config, client certificate, CN=<user>).
# Safe to rerun: existing objects are updated, a certificate with 30+ days left is kept.
# Run on master after 1-setup.sh:  sudo bash 2-sync-users.sh [user ...]     (no names = every LDAP user)
# ../1-ldap/add-user.sh runs it for each new person.
#
# Limits (GPUs at once, longest run) come from site.conf (USER_GPU_QUOTA, ENDPOINT_HOURS_MAX) unless the admin
# gave a person an exception; exceptions are kept on their namespace and survive reruns and changed defaults:
#   sudo bash 2-sync-users.sh bob --gpus 2            bob may hold 2 GPUs
#   sudo bash 2-sync-users.sh bob --max-hours 240     bob's endpoints may run 10 days
#   sudo bash 2-sync-users.sh bob --reset             bob back to the site.conf limits
#   sudo bash 2-sync-users.sh --show                  everyone's limits
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes users' home dirs, signs certificates)." >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
kubectl get validatingadmissionpolicy pod-runs-as-namespace-owner >/dev/null 2>&1 ||
  { echo "Run 1-setup.sh first (no pod UID policy yet: namespaces without it would be unsafe)." >&2; exit 1; }

if [ "${1:-}" = --show ]; then
  printf '%-16s %-5s %-10s\n' user gpus max-hours
  kubectl get ns -l aistack/user -o jsonpath='{range .items[*]}{.metadata.labels.aistack/user} {.metadata.labels.aistack/gpus} {.metadata.labels.aistack/max-hours} {.metadata.labels.aistack/custom-limits}{"\n"}{end}' |
    while read -r u g h c; do printf '%-16s %-5s %-10s %s\n' "$u" "${g:--}" "${h:--}" "$([ "$c" = true ] && echo '(exception)')"; done
  echo "defaults (site.conf): gpus $USER_GPU_QUOTA, max-hours $ENDPOINT_HOURS_MAX"
  exit 0
fi

set_gpus="" set_hours="" reset=0 users=()
while [ $# -gt 0 ]; do
  case $1 in
    --gpus)      set_gpus=${2:-}; shift 2 ;;
    --max-hours) set_hours=${2:-}; shift 2 ;;
    --reset)     reset=1; shift ;;
    -*)          echo "unknown option $1 (see the top of this script)" >&2; exit 1 ;;
    *)           users+=("$1"); shift ;;
  esac
done
[[ -z $set_gpus || $set_gpus =~ ^[0-9]+$ ]] || { echo "--gpus needs a whole number" >&2; exit 1; }
[[ -z $set_hours || $set_hours =~ ^[1-9][0-9]*$ ]] || { echo "--max-hours needs a whole number > 0" >&2; exit 1; }
if [ -n "$set_gpus$set_hours" ] || [ "$reset" = 1 ]; then
  [ ${#users[@]} -gt 0 ] || { echo "--gpus/--max-hours/--reset need user names (an exception is per person)." >&2; exit 1; }
fi

server=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
ca=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
deviceclasses=$(kubectl get deviceclass -o json)

[ ${#users[@]} -gt 0 ] || mapfile -t users < <(ldapsearch -x -LLL -H ldap://localhost -b "ou=People,$LDAP_BASE" \
                                                 '(objectClass=posixAccount)' uid | awk '/^uid: /{print $2}')
[ ${#users[@]} -gt 0 ] || { echo "No users in LDAP (ou=People,$LDAP_BASE)." >&2; exit 1; }

kubeconfig() {  # kubeconfig <user> <uid> <gid> <home>: a fresh client certificate signed by the cluster CA
  local u=$1 uid=$2 gid=$3 home=$4 tmp csr cert
  local out=$home/.kube/aistack.config
  if [ -f "$out" ] && kubectl config view --kubeconfig "$out" --raw -o jsonpath='{.users[0].user.client-certificate-data}' |
       base64 -d | openssl x509 -noout -checkend $((30 * 86400)) -subject 2>/dev/null | grep -q "CN *= *$u$"; then
    echo "        kubeconfig ok"; return
  fi
  tmp=$(mktemp -d); csr=mh-$u-$(date +%s)
  openssl req -new -newkey rsa:2048 -nodes -keyout "$tmp/key" -subj "/CN=$u" -out "$tmp/csr" 2>/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata: { name: $csr }
spec:
  request: $(base64 -w0 "$tmp/csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((365 * 86400))
  usages: [client auth]
EOF
  kubectl certificate approve "$csr" >/dev/null
  for _ in $(seq 20); do
    cert=$(kubectl get csr "$csr" -o jsonpath='{.status.certificate}'); [ -n "$cert" ] && break; sleep 1
  done
  kubectl delete csr "$csr" >/dev/null
  [ -n "$cert" ] || { echo "        certificate for $u not issued" >&2; rm -rf "$tmp"; return 1; }
  install -d -m 700 -o "$uid" -g "$gid" "$home/.kube"
  (umask 077; cat > "$out" <<EOF
apiVersion: v1
kind: Config
clusters: [{ name: $CLUSTER_ID, cluster: { server: $server, certificate-authority-data: $ca } }]
users: [{ name: $u, user: { client-certificate-data: $cert, client-key-data: $(base64 -w0 "$tmp/key") } }]
contexts: [{ name: aistack, context: { cluster: $CLUSTER_ID, user: $u, namespace: u-$u } }]
current-context: aistack
EOF
  )
  chown "$uid:$gid" "$out"
  # plain `kubectl` finds it too, unless the user already has a config of their own
  [ -e "$home/.kube/config" ] || { ln -s aistack.config "$home/.kube/config"; chown -h "$uid:$gid" "$home/.kube/config"; }
  rm -rf "$tmp"
  echo "        kubeconfig written: $out (1 year)"
}

for u in "${users[@]}"; do
  IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$u") || { echo "SKIP    $u (not resolvable)"; continue; }
  echo "user    $u ($uid:$gid) -> u-$u"
  install -d -m 700 -o "$uid" -g "$gid" "$home/models"      # the my-models volume; private like the home
  # limits: an existing exception stays unless changed or reset; everyone else follows site.conf
  read -r gpus hours custom < <(kubectl get ns "u-$u" --ignore-not-found \
    -o jsonpath='{.metadata.labels.aistack/gpus} {.metadata.labels.aistack/max-hours} {.metadata.labels.aistack/custom-limits}' ; echo)
  if [ "$reset" = 1 ] || [ "${custom:-}" != true ]; then gpus=$USER_GPU_QUOTA hours=$ENDPOINT_HOURS_MAX custom=false; fi
  [ -z "$set_gpus" ] || { gpus=$set_gpus; custom=true; }
  [ -z "$set_hours" ] || { hours=$set_hours; custom=true; }
  echo "        limits: $gpus GPU(s), max $hours h$([ "$custom" = true ] && echo ' (exception)')"
  export USER_NAME=$u USER_UID=$uid USER_GID=$gid USER_HOME=$home NFS_SERVER MODELS_ROOT \
         USER_GPUS=$gpus USER_MAX_HOURS=$hours USER_CUSTOM=$custom
  envsubst '$USER_NAME $USER_UID $USER_GID $USER_HOME $NFS_SERVER $MODELS_ROOT $USER_GPUS $USER_MAX_HOURS $USER_CUSTOM' \
    < "$HERE/onboarding/user-ns.yaml" | kubectl apply -f - | sed 's/^/        /'
  # the quota is the hard GPU limit; its annotation tells the Model Hub app the run-time limit (users can read
  # their quota but not change it, nor their namespace's labels)
  kubectl apply -f - <<EOF | sed 's/^/        /'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpus
  namespace: u-$u
  annotations: { model-hub/max-hours: "$hours" }
spec:
  hard:
$(python3 "$HERE/gpu-classes.py" --quota "$gpus" <<<"$deviceclasses")
EOF
  kubeconfig "$u" "$uid" "$gid" "$home"
done

echo
echo "Check one:  sudo -u <user> kubectl --kubeconfig ~<user>/.kube/aistack.config get pods      (expect: No resources found)"

#!/usr/bin/env bash
# Give LDAP users their Model Hub corner of k8s: namespace u-<user> (runs as them, Slurm-managed, GPU quota),
# read-only model volumes, and their own k8s login (~/.kube/aistack.config, client certificate, CN=<user>).
# Safe to rerun: existing objects are updated, a certificate with 30+ days left is kept.
# Run on master after 1-setup.sh:  sudo bash 2-sync-users.sh [user ...]     (no names = every LDAP user)
# ../1-ldap/add-user.sh runs it for each new person.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes users' home dirs, signs certificates)." >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
kubectl get validatingadmissionpolicy pod-runs-as-namespace-owner >/dev/null 2>&1 ||
  { echo "Run 1-setup.sh first (no pod UID policy yet: namespaces without it would be unsafe)." >&2; exit 1; }

server=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
ca=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
quota=$(kubectl get deviceclass -o json | python3 "$HERE/gpu-classes.py" --quota "$USER_GPU_QUOTA")

users=("$@")
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
  export USER_NAME=$u USER_UID=$uid USER_GID=$gid USER_HOME=$home NFS_SERVER MODELS_ROOT
  envsubst '$USER_NAME $USER_UID $USER_GID $USER_HOME $NFS_SERVER $MODELS_ROOT' < "$HERE/onboarding/user-ns.yaml" |
    kubectl apply -f - | sed 's/^/        /'
  kubectl apply -f - <<EOF | sed 's/^/        /'
apiVersion: v1
kind: ResourceQuota
metadata: { name: gpus, namespace: u-$u }
spec:
  hard:
$quota
EOF
  kubeconfig "$u" "$uid" "$gid" "$home"
done

echo
echo "Check one:  sudo -u <user> kubectl --kubeconfig ~<user>/.kube/aistack.config get pods      (expect: No resources found)"

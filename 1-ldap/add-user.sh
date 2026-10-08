#!/usr/bin/env bash
# Add a person to the cluster (instead of useradd on every node): next free UID, own group, password, home.
# Every node with 2-client.sh sees them at once, with the same UID. The same password works for
# SSH, Slurm, OOD and the MLflow UI. If MLflow is running, it also gets their MLflow job token; if Model Hub
# is set up, their k8s namespace and login.
# Run on master: sudo bash add-user.sh <username>     (asks for the password)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
U=${1:?usage: sudo bash add-user.sh <username>}
[[ "$U" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Bad username: $U" >&2; exit 1; }
getent passwd "$U" >/dev/null && { echo "$U already exists." >&2; exit 1; }
L=(-x -H ldap://localhost -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE")

echo "== 1. Next free UID (above every local and LDAP one)"
# ponytail: max+1, not safe if two admins add users at the same second; fine for one admin
used=$( { awk -F: '{print $3}' /etc/passwd /etc/group
          ldapsearch -x -LLL -H ldap://localhost -b "$LDAP_BASE" '(|(uidNumber=*)(gidNumber=*))' uidNumber gidNumber |
            awk '/^(uid|gid)Number:/{print $2}'; } | awk -v lo="$MIN_UID" -v hi="$MAX_UID" '$1>=lo && $1<=hi' | sort -n | tail -1)
ID=$(( ${used:-$((MIN_UID - 1))} + 1 ))
echo "$U -> uid/gid $ID"

echo "== 2. User + group entries"
ldapadd "${L[@]}" <<EOF
dn: cn=$U,ou=Groups,$LDAP_BASE
objectClass: top
objectClass: groupOfNames
objectClass: posixGroup
cn: $U
gidNumber: $ID

dn: uid=$U,ou=People,$LDAP_BASE
objectClass: top
objectClass: inetOrgPerson
objectClass: posixAccount
uid: $U
cn: $U
sn: $U
uidNumber: $ID
gidNumber: $ID
homeDirectory: /home/$U
loginShell: /bin/bash
EOF

echo "== 3. Password (typed, never on the command line)"
# 389 DS refuses password changes on a plain connection (error 13 "Confidentiality required"): ldaps
LDAPTLS_CACERT="$LDAP_CA" ldappasswd -x -H "$LDAP_URI" -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE" -S "uid=$U,ou=People,$LDAP_BASE"

echo "== 4. Home on the shared /home"
install -d -m 700 -o "$ID" -g "$ID" "/home/$U"
cp -rn /etc/skel/. "/home/$U/" && chown -R "$ID:$ID" "/home/$U"

echo "== 5. MLflow job token (skipped if MLflow isn't deployed yet)"
sss_cache -E 2>/dev/null || true
if curl -sf -o /dev/null --max-time 5 "$MLFLOW_URI/health"; then
  bash "$HERE/../3-mlflow/3-sync-tokens.sh"
else
  echo "MLflow not answering at $MLFLOW_URI, skipped. Later: sudo bash 3-mlflow/3-sync-tokens.sh"
fi

echo "== 6. Rootless podman ranges (/etc/subuid, /etc/subgid) on the login nodes"
# useradd writes these for local users only; LDAP users get none, and rootless podman fails without them.
# ponytail: next range comes from this node's files; login nodes stay identical as long as only this script writes them
start=$(awk -F: '{e=$2+$3; if (e>m) m=e} END {print (m>100000 ? m : 100000)}' /etc/subuid /etc/subgid)
add="for f in /etc/subuid /etc/subgid; do grep -q '^$U:' \$f || echo $U:$start:65536 >> \$f; done"
for n in $LOGIN_NODES; do
  if [ "$n" = "$(hostname -s)" ]; then bash -c "$add"
  elif ! ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$n" "$add"; then
    echo "NOT on $n (unreachable). Later, as root there: $add" >&2; continue
  fi
  echo "$n: $U:$start:65536"
done

echo "== 7. Model Hub: namespace u-$U, GPU quota, k8s login (skipped if 5-model-hub isn't set up yet)"
if KUBECONFIG=/etc/kubernetes/admin.conf kubectl get validatingadmissionpolicy pod-runs-as-namespace-owner >/dev/null 2>&1; then
  bash "$HERE/../5-model-hub/2-sync-users.sh" "$U"
else
  echo "Model Hub not set up, skipped. Later: sudo bash 5-model-hub/2-sync-users.sh $U"
fi

echo "== 8. Check"
getent passwd "$U" && id "$U"
echo
echo "Done. $U logs in everywhere (SSH, Slurm, OOD, MLflow UI) with that password."

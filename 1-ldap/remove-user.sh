#!/usr/bin/env bash
# Remove a person from the cluster (the reverse of add-user.sh). Always: stops everything they run (Slurm jobs, OOD
# session, processes on every node, Model Hub endpoints), deletes their API key, Model Hub namespace, MLflow login and
# token, Keycloak login, team memberships, and their LDAP user + own group. Their public models go private (the
# copies others could use are removed within a minute by 5-model-hub/public-models.py).
# Kept unless asked: the home folder (with ~/models) and their MLflow experiments, runs and models.
#   sudo bash remove-user.sh <username> [--delete-home] [--delete-mlflow] [--yes]
#     --delete-home     also delete /home/<username>
#     --delete-mlflow   also delete the MLflow experiments + registered models only they manage (files too)
#     --yes             don't ask to type the name (for the admin page)
# Their UID is never handed out again (LDAP_LAST_UID_FILE), so a kept home can't end up owned by someone new.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST (LDAP, MLflow data, Keycloak)." >&2; exit 1; }
U="" del_home=0 del_mlflow=0 yes=0
for a in "$@"; do
  case $a in
    --delete-home) del_home=1 ;; --delete-mlflow) del_mlflow=1 ;; --yes) yes=1 ;;
    -*) echo "unknown option $a (see the top of this script)" >&2; exit 1 ;;
    *) [ -z "$U" ] || { echo "one user at a time" >&2; exit 1; }; U=$a ;;
  esac
done
[[ $U =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "usage: sudo bash remove-user.sh <username> [--delete-home] [--delete-mlflow] [--yes]" >&2; exit 1; }
for k in $KEEP_LOCAL $OOD_ADMIN; do [ "$U" != "$k" ] || { echo "$U is a local admin account: never removed here." >&2; exit 1; }; done
DN="uid=$U,ou=People,$LDAP_BASE"
L=(-x -H ldap://localhost -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE")
read -r ID HOME_DIR < <(ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -b "$DN" -s base uidNumber homeDirectory 2>/dev/null |
  awk '/^uidNumber: /{n=$2} /^homeDirectory: /{h=$2} END{print n, h}')
[ -n "$ID" ] || { echo "No LDAP user '$U' (local accounts: userdel)." >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf SLURM_CONF   # sudo skips /etc/profile.d/slurm.sh: without it scancel finds no config
on() {  # on <node> <command>: as root, here or over ssh; an unreachable node is reported, not fatal
  if [ "$1" = "$(hostname -s)" ]; then bash -c "$2"
  else ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$1" "$2" || echo "        NOT done on $1 (unreachable?): $2" >&2; fi
}

echo "Remove $U (uid $ID, home $HOME_DIR)"
echo "  home folder:      $([ $del_home = 1 ] && echo DELETE || echo keep)"
echo "  MLflow work:      $([ $del_mlflow = 1 ] && echo DELETE || echo keep)"
if [ $yes = 0 ]; then
  read -rp "Type the username to go on: " ok
  [ "$ok" = "$U" ] || { echo "Nothing changed."; exit 1; }
fi

echo "== 1. Never hand out uid $ID again"
last=$(cat "$LDAP_LAST_UID_FILE" 2>/dev/null || echo 0)
[ "$ID" -le "$last" ] || (umask 077; echo "$ID" > "$LDAP_LAST_UID_FILE")
echo "last uid handed out: $(cat "$LDAP_LAST_UID_FILE")"

stop_all() {  # by UID, so it also works once the name is gone from LDAP
  "$SLURM_BIN/scancel" -u "$ID" && echo "Slurm jobs cancelled" || echo "scancel failed (Slurm down?)" >&2
  # the OOD session's nginx master runs as root (only its workers run as the user): stop it by its config file
  pkill -f "/puns/$U\.conf\$" && echo "OOD session stopped" || true
  for n in $(printf '%s\n' $LOGIN_NODES $COMPUTE_NODES | sort -u); do
    on "$n" "pkill -KILL -U $ID; true"
  done
}

echo "== 2. Stop what they run: Slurm jobs, OOD session, processes"
stop_all

echo "== 3. Model Hub: endpoints, API key, namespace u-$U (skipped if 5-model-hub isn't set up)"
if kubectl get validatingadmissionpolicy pod-runs-as-namespace-owner >/dev/null 2>&1; then
  # out of other people's share lists, so a future person with the same name doesn't inherit them
  kubectl get svc -A -l model-hub/runtime -o json | python3 -c '
import json, sys
for s in json.load(sys.stdin)["items"]:
    names = [n for n in s["metadata"].get("annotations", {}).get("model-hub/share-users", "").split(",") if n]
    if sys.argv[1] in names:
        print(s["metadata"]["namespace"], s["metadata"]["name"], ",".join(n for n in names if n != sys.argv[1]))
' "$U" | while read -r ns svc rest; do
    kubectl annotate -n "$ns" svc "$svc" --overwrite "model-hub/share-users=$rest" >/dev/null
    echo "unshared: $ns/$svc"
  done
  # the namespace holds their endpoints (pods: stopping them ends their Slurm jobs), API key, quota, logins
  kubectl delete ns "u-$U" --ignore-not-found --wait=true --timeout=5m
  kubectl delete pv -l "aistack/user=$U" --ignore-not-found      # Retain: only the objects, no files
else
  echo "Model Hub not set up, skipped."
fi

echo "== 4. MLflow: their models go private$([ $del_mlflow = 1 ] && echo ', their work is deleted'), login + token removed"
if curl -sf -o /dev/null --max-time 5 "$MLFLOW_URI/health"; then
  MLFLOW_URI=$MLFLOW_URI MLFLOW_DATA=$MLFLOW_DATA LDAP_BASE=$LDAP_BASE python3 - "$U" "$del_mlflow" <<'EOF'
import base64, json, os, shutil, subprocess, sys, urllib.error, urllib.parse, urllib.request
u, purge = sys.argv[1], sys.argv[2] == "1"
uri, data = os.environ["MLFLOW_URI"].rstrip("/"), os.environ["MLFLOW_DATA"]
auth = "Basic " + base64.b64encode(b"admin:" + open(os.path.join(data, "admin.pass"), "rb").read().strip()).decode()

def call(method, path, body=None, v="2.0", **params):
    url = f"{uri}/api/{v}/mlflow/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": auth, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        sys.exit(f"MLflow {method} {path}: HTTP {e.code} {e.read()[:300].decode(errors='replace')}")

mine = call("GET", "users/permissions/list", v="3.0", username=u)
if mine is None:
    print("not in MLflow (never logged in)"); sys.exit()
# what someone else manages too stays, whatever was asked (a shared experiment isn't only theirs)
ldap = subprocess.run(["ldapsearch", "-x", "-LLL", "-H", "ldap://localhost", "-b", f"ou=People,{os.environ['LDAP_BASE']}",
                       "(objectClass=posixAccount)", "uid"], capture_output=True, text=True, check=True).stdout
shared = set()
for o in (l[5:] for l in ldap.splitlines() if l.startswith("uid: ")):
    if o != u:
        for row in (call("GET", "users/permissions/list", v="3.0", username=o) or {}).get("permissions", []):
            if row["permission"] == "MANAGE":
                shared.add((row["resource_type"], row["resource_pattern"]))
own = [(r["resource_type"], r["resource_pattern"]) for r in mine["permissions"]
       if r["permission"] == "MANAGE" and (r["resource_type"], r["resource_pattern"]) not in shared]

art_root = os.path.realpath(os.path.join(data, "artifacts"))
for kind, name in own:
    if kind == "registered_model":
        if purge:
            call("DELETE", "registered-models/delete", {"name": name}); print(f"deleted model      {name}")
        else:   # nobody manages it now but the MLflow admin; the tag says whose it was
            call("POST", "registered-models/set-tag", {"name": name, "key": "public", "value": "false"})
            call("POST", "registered-models/set-tag", {"name": name, "key": "removed_owner", "value": u})
            print(f"kept model         {name} (private, tag removed_owner={u})")
    elif kind == "experiment" and purge and name != "0":
        exp = (call("GET", "experiments/get", experiment_id=name) or {}).get("experiment")
        if not exp:
            continue
        # MLflow only soft-deletes, and a deleted experiment keeps its name for good (set_experiment then refuses
        # it): rename first, so the name is free for the next person. Renaming a deleted one is refused.
        call("POST", "experiments/update", {"experiment_id": name, "new_name": f"{exp['name']}.removed-{u}-{name}"})
        call("POST", "experiments/delete", {"experiment_id": name})
        # ponytail: the soft-deleted rows stay in mlflow.db (hidden); `mlflow gc` in the pod if they ever matter
        # only the experiment's own folder: a user can point artifact_location at someone else's
        d = os.path.join(art_root, name)
        gone = exp.get("artifact_location", "").rstrip("/") == f"mlflow-artifacts:/{name}" and os.path.isdir(d)
        if gone:
            shutil.rmtree(d)
        print(f"deleted experiment {exp['name']}" + (f" + files {d}" if gone else " (files elsewhere: not touched)"))
call("DELETE", "users/delete", {"username": u})       # its grants go with it (MLflow 3.15), and the job token stops working
print(f"MLflow user {u} deleted")
EOF
else
  echo "MLflow not answering at $MLFLOW_URI: NOT cleaned. Later, by hand in the MLflow UI as admin: delete user $U." >&2
fi

echo "== 5. Keycloak: signed out everywhere, its copy of $U deleted (skipped if 6-keycloak isn't installed)"
if [ -f "$KEYCLOAK_DATA/admin.pass" ]; then
  KC_URL=http://127.0.0.1:$KEYCLOAK_PORT$KEYCLOAK_PATH KEYCLOAK_ADMIN=$KEYCLOAK_ADMIN KEYCLOAK_DATA=$KEYCLOAK_DATA \
    KEYCLOAK_REALM=$KEYCLOAK_REALM python3 "$HERE/../6-keycloak/kc.py" remove-user "$U"
else
  echo "Keycloak not installed, skipped."
fi

# LDAP last: until here a failed step can simply be rerun (the script needs the LDAP user to start)
echo "== 6. LDAP: out of every team, own group and user deleted"
ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -b "ou=Groups,$LDAP_BASE" "(member=$DN)" dn | sed -n 's/^dn: //p' |
  while read -r g; do
    printf 'dn: %s\nchangetype: modify\ndelete: member\nmember: %s\n' "$g" "$DN" | ldapmodify "${L[@]}" >/dev/null
    echo "left $g"
  done
ldapdelete "${L[@]}" "cn=$U,ou=Groups,$LDAP_BASE" 2>/dev/null && echo "group $U deleted" || true
ldapdelete "${L[@]}" "$DN" && echo "user $U deleted"

echo "== 7. Stop everything once more: an open browser tab or a queued job may have started something since step 2"
# nothing new can start now: OOD, Slurm and SSH no longer know the name
stop_all

echo "== 8. Every node forgets the cached user"
# their /etc/subuid + subgid ranges stay on purpose: add-user.sh never hands out a range twice that way
for n in $(printf '%s\n' "$MASTER_HOST" $LOGIN_NODES $COMPUTE_NODES | sort -u); do on "$n" "sss_cache -E 2>/dev/null; true"; done

echo "== 9. Home folder"
if [ $del_home = 1 ]; then
  if [ "$(realpath -m "$HOME_DIR")" = "/home/$U" ] && [ -d "/home/$U" ]; then
    rm -rf --one-file-system "/home/$U" && echo "deleted /home/$U"
  else
    echo "home is $HOME_DIR, not /home/$U: NOT deleted (check it by hand)" >&2
  fi
else
  echo "kept $HOME_DIR (owned by uid $ID, which nobody else will get). Delete later: sudo rm -rf $HOME_DIR"
fi

echo "== 10. Check"
getent passwd "$U" && echo "STILL KNOWN on this node: check SSSD (sss_cache -E)" >&2 || echo "$U is gone (getent passwd: nothing)"

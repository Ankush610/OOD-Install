#!/usr/bin/env bash
# Teams: LDAP groups of people, used to share Model Hub endpoints with a whole team (and seen by Keycloak).
#   sudo bash group.sh list [team]              teams and their members
#   sudo bash group.sh create <team>
#   sudo bash group.sh add <team> <user>...
#   sudo bash group.sh remove <team> <user>...
#   sudo bash group.sh delete <team>
# A team is a groupOfNames under ou=Groups (member = the person's DN). It is NOT a Linux group (no gidNumber), so it
# changes no file permissions. Everyone's personal group (made by add-user.sh, posixGroup) is left alone.
# After a change, the people concerned are re-synced into Model Hub (their namespace lists their teams; the
# gateway reads it, within a minute).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes LDAP as the Directory Manager)." >&2; exit 1; }
L=(-x -H ldap://localhost -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE")
NAME='^[a-z_][a-z0-9_.-]{0,31}$'
usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cmd=${1:-}; team=${2:-}; shift $(( $# > 2 ? 2 : $# ))
dn() { echo "cn=$1,ou=Groups,$LDAP_BASE"; }
is_team() {  # a groupOfNames that is NOT someone's personal posixGroup
  ldapsearch -x -LLL -H ldap://localhost -b "$(dn "$1")" -s base '(&(objectClass=groupOfNames)(!(objectClass=posixGroup)))' cn 2>/dev/null | grep -q '^cn:'
}
members() { ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -b "$(dn "$1")" -s base member 2>/dev/null |
              sed -n 's/^member: uid=\([^,]*\),.*/\1/p'; }
resync() {  # people whose team list changed -> Model Hub (skipped if it isn't set up)
  [ $# -gt 0 ] || return 0
  if [ -f "$HERE/../5-model-hub/2-sync-users.sh" ] &&
     KUBECONFIG=/etc/kubernetes/admin.conf kubectl get validatingadmissionpolicy pod-runs-as-namespace-owner >/dev/null 2>&1; then
    bash "$HERE/../5-model-hub/2-sync-users.sh" "$@" | grep -E '^user|limits|teams' || true
  fi
}
check_users() {
  for u in "$@"; do
    [[ $u =~ $NAME ]] && ldapsearch -x -LLL -H ldap://localhost -b "uid=$u,ou=People,$LDAP_BASE" -s base uid 2>/dev/null | grep -q '^uid:' ||
      { echo "No LDAP user '$u'." >&2; exit 1; }
  done
}

case $cmd in
  list)
    if [ -n "$team" ]; then is_team "$team" || { echo "No team '$team'." >&2; exit 1; }; members "$team"; exit 0; fi
    ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -b "ou=Groups,$LDAP_BASE" \
      '(&(objectClass=groupOfNames)(!(objectClass=posixGroup)))' cn | sed -n 's/^cn: //p' |
      while read -r t; do printf '%-20s %s\n' "$t" "$(members "$t" | paste -sd' ')"; done ;;
  create)
    [[ $team =~ $NAME ]] || usage
    getent passwd "$team" >/dev/null && { echo "'$team' is a user name: pick another team name." >&2; exit 1; }
    is_team "$team" && { echo "Team '$team' exists."; exit 0; }
    printf 'dn: %s\nobjectClass: top\nobjectClass: groupOfNames\ncn: %s\n' "$(dn "$team")" "$team" | ldapadd "${L[@]}" >/dev/null
    echo "created team $team" ;;
  add|remove)
    [ $# -gt 0 ] || usage
    is_team "$team" || { echo "No team '$team' (sudo bash group.sh create $team)." >&2; exit 1; }
    check_users "$@"
    have=$(members "$team"); change=()
    for u in "$@"; do
      if [ "$cmd" = add ] && ! grep -qx "$u" <<<"$have"; then change+=("$u"); fi
      if [ "$cmd" = remove ] && grep -qx "$u" <<<"$have"; then change+=("$u"); fi
    done
    [ ${#change[@]} -gt 0 ] || { echo "nothing to change"; exit 0; }
    op=$([ "$cmd" = add ] && echo add || echo delete)
    { printf 'dn: %s\nchangetype: modify\n%s: member\n' "$(dn "$team")" "$op"
      for u in "${change[@]}"; do printf 'member: uid=%s,ou=People,%s\n' "$u" "$LDAP_BASE"; done; } | ldapmodify "${L[@]}" >/dev/null
    echo "$cmd: ${change[*]} ($team)"
    resync "${change[@]}" ;;
  delete)
    is_team "$team" || { echo "No team '$team' (personal groups can't be deleted here)." >&2; exit 1; }
    mapfile -t was < <(members "$team")
    ldapdelete "${L[@]}" "$(dn "$team")"
    echo "deleted team $team"
    resync "${was[@]}" ;;
  *) usage ;;
esac

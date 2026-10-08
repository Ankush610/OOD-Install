#!/usr/bin/env bash
# Cluster users in a menu (whiptail): people, passwords, teams, checks, setup.
#   sudo bash menu.sh
# Each action runs this folder's scripts (add-user.sh, group.sh, 2-client.sh, ...), so it does exactly what they do
# by hand; their output shows in the terminal, then you're back in the menu. Passwords: nobody can SEE one (LDAP keeps
# only a hash); a new one works at once for SSH, Slurm, OOD and the MLflow UI (its login cache may take the old one for
# up to 5 min). Jobs use MLflow tokens, so they keep working. KEEP_LOCAL accounts (admin) aren't in LDAP: use passwd.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes LDAP as the Directory Manager)." >&2; exit 1; }
[ -t 0 ] && [ -t 1 ] || { echo "Needs a terminal." >&2; exit 1; }
command -v whiptail >/dev/null || { echo "Needs whiptail: dnf install newt" >&2; exit 1; }
# the LDAP server and its Directory Manager password live on master; other nodes are reached from here over ssh
[ "$(hostname -s)" = "$MASTER_HOST" ] || { echo "Run this on $MASTER_HOST (the LDAP server), not on $(hostname -s)." >&2; exit 1; }
ldapsearch -x -LLL -H ldap://localhost -b "$LDAP_BASE" -s base dn >/dev/null 2>&1 ||
  { echo "LDAP doesn't answer on $MASTER_HOST: systemctl status dirsrv@$LDAP_INSTANCE" >&2; exit 1; }

T="Cluster users · LDAP $LDAP_BASE"
export LDAPTLS_CACERT=$LDAP_CA   # 389 DS refuses password changes on a plain connection (error 13): use ldaps
L=(-x -H "$LDAP_URI" -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE")
dn() { echo "uid=$1,ou=People,$LDAP_BASE"; }
ask() { whiptail --title "$T" "$@" 3>&1 1>&2 2>&3; }   # whiptail answers on stderr: swap it to stdout
say() { whiptail --title "$T" --msgbox "$1" 14 76; }
show() { whiptail --title "$T" --scrolltext --msgbox "$1" 22 80; }
sure() { whiptail --title "$T" --defaultno --yesno "$1" 14 76; }
run() {  # a script in the plain terminal (it prints, may ask for a password), then back to the menu
  clear; echo "== $*"; echo
  if "$@"; then echo; echo "OK."; else echo; echo "FAILED (exit $?)."; fi
  read -rp "Press Enter to go back to the menu " _
}

# ---------- reading LDAP ----------
people() {  # "uid<TAB>uidNumber<TAB>home", one LDAP person per line
  ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' \
      uid uidNumber homeDirectory |
    awk '/^uid: /{u=$2} /^uidNumber: /{n=$2} /^homeDirectory: /{h=$2} /^$/{if(u)print u"\t"n"\t"h; u=n=h=""}
         END{if(u)print u"\t"n"\t"h}' | sort
}
teams() { bash "$HERE/group.sh" list; }   # "team   member member ..."

pick_user() {  # menu of people -> the chosen uid
  local m=() u n h
  while IFS=$'\t' read -r u n h; do m+=("$u" "uid $n · $h"); done < <(people)
  [ ${#m[@]} -gt 0 ] || { say "No LDAP users yet. Add one first."; return 1; }
  ask --menu "$1" 20 76 12 "${m[@]}"
}
pick_team() {
  local m=() t rest
  while read -r t rest; do m+=("$t" "${rest:-(no members)}"); done < <(teams)
  [ ${#m[@]} -gt 0 ] || { say "No teams yet. Create one first."; return 1; }
  ask --menu "$1" 20 76 12 "${m[@]}"
}

# ---------- people ----------
list_people() {
  local t=$(teams) u n h in
  show "$( { echo -e "USER\tUID\tHOME\tTEAMS"
             while IFS=$'\t' read -r u n h; do
               in=$(awk -v u="$u" '{for(i=2;i<=NF;i++) if($i==u) printf "%s ", $1}' <<<"$t")
               echo -e "$u\t$n\t$h\t${in:--}"
             done < <(people); } | column -t -s $'\t')"
}
add_person() {
  local u
  u=$(ask --inputbox "Username (lowercase letters, digits, - or _):" 9 60) || return 0
  [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { say "'$u' is not a valid username."; return 0; }
  sure "Add $u to the cluster?\n\nNext free UID, own group, home /home/$u, MLflow job token, Model Hub namespace.\nYou type the password in the terminal next." || return 0
  run bash "$HERE/add-user.sh" "$u"
}
set_pw() {
  local u p1 p2 out
  u=$(pick_user "Set a new password for:") || return 0
  p1=$(ask --passwordbox "New password for $u:" 8 60) || return 0
  [ -n "$p1" ] || { say "Empty password: nothing changed."; return 0; }
  p2=$(ask --passwordbox "Same password again:" 8 60) || return 0
  [ "$p1" = "$p2" ] || { say "The two passwords differ: nothing changed."; return 0; }
  if out=$(ldappasswd "${L[@]}" -T <(printf %s "$p1") "$(dn "$u")" 2>&1); then
    say "Password of $u changed. It works now for SSH, Slurm, OOD and MLflow."
  else
    say "Not changed:"$'\n'"$out"
  fi
}
test_pw() {
  local u p
  u=$(pick_user "Test the password of:") || return 0
  p=$(ask --passwordbox "Password to test for $u:" 8 60) || return 0
  # an empty password is an anonymous bind, which LDAP accepts: never call it right
  [ -n "$p" ] || { say "Empty password: that is never right."; return 0; }
  if ldapwhoami -x -H ldap://localhost -D "$(dn "$u")" -y <(printf %s "$p") >/dev/null 2>&1; then
    say "RIGHT: that is $u's password."
  else
    say "WRONG: that is not $u's password."
  fi
}
people_menu() {
  local c
  while c=$(ask --cancel-button Back --menu "People" 14 60 4 \
              list "List people (UID, home, teams)" add "Add a person" \
              password "Set a new password" test "Test a password"); do
    case $c in list) list_people ;; add) add_person ;; password) set_pw ;; test) test_pw ;; esac
  done
}

# ---------- teams (Model Hub sharing) ----------
new_team() {
  local t
  t=$(ask --inputbox "Team name (lowercase letters, digits, . - _):" 9 60) || return 0
  [[ $t =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || { say "'$t' is not a valid team name."; return 0; }
  run bash "$HERE/group.sh" create "$t"
}
team_members() {  # checklist of everyone, members ticked -> group.sh add / remove the difference
  local t have chosen u n h list=() add=() del=()
  t=$(pick_team "Change the members of:") || return 0
  have=$(bash "$HERE/group.sh" list "$t")
  while IFS=$'\t' read -r u n h; do list+=("$u" "" "$(grep -qx "$u" <<<"$have" && echo ON || echo OFF)"); done < <(people)
  chosen=$(ask --separate-output --checklist "Members of $t (space = tick / untick):" 20 60 12 "${list[@]}") || return 0
  for u in $chosen; do grep -qx "$u" <<<"$have" || add+=("$u"); done
  for u in $have; do grep -qx "$u" <<<"$chosen" || del+=("$u"); done
  [ ${#add[@]} -gt 0 ] || [ ${#del[@]} -gt 0 ] || { say "Nothing changed."; return 0; }
  clear
  [ ${#add[@]} -eq 0 ] || bash "$HERE/group.sh" add "$t" "${add[@]}" || true
  [ ${#del[@]} -eq 0 ] || bash "$HERE/group.sh" remove "$t" "${del[@]}" || true
  echo; read -rp "Press Enter to go back to the menu " _
}
del_team() {
  local t
  t=$(pick_team "Delete which team?") || return 0
  sure "Delete team $t?\n\nEndpoints shared with $t stop working for its members (within a minute).\nThe people themselves are not touched." || return 0
  run bash "$HERE/group.sh" delete "$t"
}
teams_menu() {
  local c
  while c=$(ask --cancel-button Back --menu "Teams (share Model Hub endpoints with a whole team)" 14 64 4 \
              list "List teams and members" create "Create a team" members "Add / remove members" delete "Delete a team"); do
    case $c in
      list) show "$(teams | sed 's/^$/(no teams yet)/')" ;;
      create) new_team ;; members) team_members ;; delete) del_team ;;
    esac
  done
}

# ---------- checks ----------
nodes() { echo "$MASTER_HOST" $COMPUTE_NODES | tr ' ' '\n' | awk 'NF && !s[$0]++'; }
on() {  # on <node> <command>: here, or as root over ssh (like add-user.sh)
  if [ "$1" = "$(hostname -s)" ]; then bash -c "$2"; else ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$1" "$2"; fi
}
local_copies() {  # "node<TAB>user<TAB>local home<TAB>LDAP home" for every local account named like an LDAP person
  local ldap n
  ldap=$(people)
  for n in $(nodes); do
    on "$n" "cat /etc/passwd" 2>/dev/null | LDAP_PEOPLE=$ldap awk -F: -v n="$n" -v keep=" $KEEP_LOCAL " '
      BEGIN { split(ENVIRON["LDAP_PEOPLE"], rows, "\n")
              for (i in rows) { split(rows[i], f, "\t"); if (f[1] != "") home[f[1]] = f[3] } }
      ($1 in home) && index(keep, " " $1 " ") == 0 { print n "\t" $1 "\t" $6 "\t" home[$1] }' ||
      echo -e "$n\t?\tunreachable (ssh root@$n)\t"
  done
}
check() {
  local out="" c rows sel=() n u lh h tick msg
  ldapsearch -x -LLL -H ldap://localhost -b "$LDAP_BASE" -s base dn >/dev/null 2>&1 && out+="OK    LDAP server answers\n" ||
    out+="FAIL  LDAP server doesn't answer (systemctl status dirsrv@$LDAP_INSTANCE)\n"
  u=$(people | head -1 | cut -f1)
  [ -z "$u" ] || { getent -s sss passwd "$u" >/dev/null && out+="OK    this node sees LDAP users (SSSD)\n" ||
                     out+="FAIL  this node doesn't see LDAP users: run Setup → this node\n"; }
  rows=$(local_copies)
  if [ -z "$rows" ]; then
    say "$(echo -e "${out}OK    no node has a local copy of an LDAP person")"; return 0
  fi
  # local entries win over LDAP (nsswitch: files sss): wrong home/shell on that node, and the old local password
  # keeps working there after a change in LDAP. Ticked = something differs; any can be removed.
  while IFS=$'\t' read -r n u lh h; do
    [ "$u" != "?" ] || { out+="WARN  $lh\n"; continue; }
    [ "$lh" = "$h" ] && tick=OFF msg="same home" || tick=ON msg="home $lh, LDAP says $h"
    sel+=("$n:$u" "$msg" "$tick")
  done <<<"$rows"
  [ ${#sel[@]} -gt 0 ] || { say "$(echo -e "$out")"; return 0; }
  c=$(ask --separate-output --checklist "$(echo -e "$out")\nLocal accounts that hide the LDAP person on that node.\nTicked ones are wrong. Remove the copy (userdel, NOT -r: the home stays):" 22 78 8 "${sel[@]}") || return 0
  [ -n "$c" ] || return 0
  sure "Remove these local copies?\n\n$c\n\nThe people keep working from LDAP, with their LDAP home and password." || return 0
  clear
  for x in $c; do
    n=${x%%:*} u=${x#*:}
    echo "== $n: userdel $u"
    # userdel also drops the user's /etc/subuid + subgid range (rootless podman needs it): put it back afterwards
    on "$n" "cp -a /etc/subuid /etc/subuid.pre-userdel; cp -a /etc/subgid /etc/subgid.pre-userdel
             userdel '$u' && for f in subuid subgid; do grep -q '^$u:' /etc/\$f || grep '^$u:' /etc/\$f.pre-userdel >> /etc/\$f || true; done
             sss_cache -E; getent passwd '$u'" || echo "FAILED on $n (a running process of $u? try again when idle)"
  done
  echo; read -rp "Press Enter to go back to the menu " _
}

# ---------- setup (once per cluster / node) ----------
client_on() {
  local m=() n
  for n in $(nodes); do m+=("$n" "$([ "$n" = "$(hostname -s)" ] && echo "this node" || echo "over ssh as root")"); done
  n=$(ask --menu "Make which node use LDAP (2-client.sh)?" 16 64 8 "${m[@]}") || return 0
  if [ "$n" = "$(hostname -s)" ]; then run bash "$HERE/2-client.sh"
  else run ssh -t -o ConnectTimeout=5 "root@$n" "bash $HERE/2-client.sh"; fi
}
import_local() {
  clear; bash "$HERE/import-local-users.sh" --dry-run || true
  echo; read -rp "That was a dry run. Press Enter to go on " _
  sure "Copy those local users into LDAP now?\n(Same UID, same password hash. Nothing local changes.)" || return 0
  run bash "$HERE/import-local-users.sh"
}
setup_menu() {
  local c
  while c=$(ask --cancel-button Back --menu "Setup (rarely needed; every step is safe to rerun)" 13 70 3 \
              server "LDAP server on $MASTER_HOST (1-server.sh)" client "A node uses LDAP (2-client.sh)" \
              import "Copy local users into LDAP (import-local-users.sh)"); do
    case $c in server) run bash "$HERE/1-server.sh" ;; client) client_on ;; import) import_local ;; esac
  done
}

while c=$(ask --cancel-button Quit --menu "What to do?" 14 64 4 \
            people "People and passwords" teams "Teams" check "Check (LDAP, this node, local copies)" setup "Setup"); do
  case $c in people) people_menu ;; teams) teams_menu ;; check) check ;; setup) setup_menu ;; esac
done
clear

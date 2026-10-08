#!/usr/bin/env bash
# LDAP passwords in a menu (whiptail): list users, set a new password, test a password.
#   sudo bash passwords.sh
# Nobody can SEE a password: LDAP keeps only a hash. "Test" says whether a typed password is the right one.
# A new password works at once for SSH, Slurm, OOD (Keycloak asks LDAP) and the MLflow UI (which may still take the
# old one for up to 5 min, its login cache). Jobs use MLflow tokens, so they keep working.
# Local accounts (KEEP_LOCAL, e.g. admin) are not in LDAP: use passwd for those.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes LDAP as the Directory Manager)." >&2; exit 1; }
[ -t 0 ] && [ -t 1 ] || { echo "Needs a terminal." >&2; exit 1; }
command -v whiptail >/dev/null || { echo "Needs whiptail: dnf install newt" >&2; exit 1; }

T="LDAP passwords ($LDAP_BASE)"
export LDAPTLS_CACERT=$LDAP_CA   # 389 DS refuses password changes on a plain connection (error 13): use ldaps
L=(-x -H "$LDAP_URI" -D "$LDAP_DM" -y "$LDAP_DM_PASS_FILE")
dn() { echo "uid=$1,ou=People,$LDAP_BASE"; }
ask() { whiptail --title "$T" "$@" 3>&1 1>&2 2>&3; }   # whiptail answers on stderr: swap it to stdout
say() { whiptail --title "$T" --msgbox "$1" 12 70; }

users() {  # "uid<TAB>name", one LDAP person per line
  ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost -b "ou=People,$LDAP_BASE" '(objectClass=posixAccount)' uid cn |
    awk '/^uid: /{u=$2} /^cn: /{sub(/^cn: /,""); c=$0} /^$/{if(u)print u"\t"c; u=c=""} END{if(u)print u"\t"c}' | sort
}

pick() {  # menu of users -> the chosen uid
  local m=() u c
  while IFS=$'\t' read -r u c; do m+=("$u" "${c:--}"); done < <(users)
  [ ${#m[@]} -gt 0 ] || { say "No LDAP users."; return 1; }
  ask --menu "$1" 20 70 12 "${m[@]}"
}

set_pw() {
  local u p1 p2 out
  u=$(pick "Set a new password for:") || return 0
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
  u=$(pick "Test the password of:") || return 0
  p=$(ask --passwordbox "Password to test for $u:" 8 60) || return 0
  # an empty password is an anonymous bind, which LDAP accepts: never call it right
  [ -n "$p" ] || { say "Empty password: that is never right."; return 0; }
  if ldapwhoami -x -H ldap://localhost -D "$(dn "$u")" -y <(printf %s "$p") >/dev/null 2>&1; then
    say "RIGHT: that is $u's password."
  else
    say "WRONG: that is not $u's password."
  fi
}

while c=$(ask --cancel-button Quit --menu "What to do?" 13 60 3 \
            list "List users" set "Set a new password" test "Test a password"); do
  case $c in
    list) whiptail --title "$T" --scrolltext --msgbox "$(users | column -t -s $'\t')" 20 70 ;;
    set)  set_pw ;;
    test) test_pw ;;
  esac
done
clear

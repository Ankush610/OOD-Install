# 1-ldap

One user list for the whole cluster: **389 Directory Server** on master, **SSSD** on every node. A user is added once, and every node knows them with the same UID. One password per person works for SSH, Slurm, OOD (`../2-ood`) and the MLflow UI (`../3-mlflow`).

```
            389 DS on master   ldaps://<MASTER_HOST>:636     <LDAP_BASE>
                               ├── ou=People   users
                               └── ou=Groups   groups
        ┌─────────────────┬──────────────────┬────────────────┐
     SSSD master      SSSD cn01          SSSD cn02 …      Apache (OOD), MLflow pod
     (ssh, sudo)      (Slurm jobs)       (Slurm jobs)     (check web passwords)
```

Ports 389/636 only, so no clash with OOD on 80/443. All settings come from `../site.conf`.

## Everyday: the menu

```bash
sudo bash menu.sh
```

One menu (whiptail) for everything below. Each action runs the script it names, so it does exactly the same; the script's output shows in the terminal, then you're back in the menu.

| Menu | What's in it |
|---|---|
| People and passwords | list people (UID, home, teams), add a person (`add-user.sh`), remove a person (`remove-user.sh`: asks whether to delete their home and their MLflow work), set a new password, test a password |
| Teams | list, create, add / remove members (a checklist: tick who's in), delete (`group.sh`) |
| Check | LDAP server answers; this node sees LDAP users; **local copies**: every node's `/etc/passwd` (master + `COMPUTE_NODES`, over `ssh root@`) against LDAP. A local account with an LDAP person's name wins on that node (`nsswitch: files sss`): a wrong home there breaks jobs (seen 2026-10-08: cn01 had `rakesh` with `/home/ankush`, so MLflow found no login in jobs), and the old local password keeps working after a change. Ticked = differs from LDAP; remove = `userdel` **without `-r`** (the home stays), `/etc/subuid`+`subgid` ranges put back |
| Setup | `1-server.sh`, `2-client.sh` on this node or another one (ssh), `import-local-users.sh` (dry run first) |

## Run by hand

```bash
sudo bash 1-server.sh                        # on master: 389 DS, the tree, access rules, CA -> LDAP_CA
sudo bash import-local-users.sh --dry-run    # optional, see below
sudo bash 2-client.sh                        # on master, then as root on every compute node
sudo bash add-user.sh <name>                 # on master: each new person
sudo bash remove-user.sh <name> [--delete-home] [--delete-mlflow]   # on master: someone leaves
sudo bash group.sh create nlp; sudo bash group.sh add nlp bob carol   # teams (Model Hub sharing); list / remove / delete
```

`2-client.sh` runs on the compute nodes straight from this folder, because it's on the shared `/home`. It checks for UID clashes before it changes anything, then switches the node to SSSD (`authselect`), and checks with `getent -s sss`, which asks LDAP only.

**`add-user.sh`** replaces `useradd`. It picks the next free UID (above every local and LDAP one), creates the user and their own group, asks for the password, and makes `/home/<name>`. It adds `/etc/subuid` + `/etc/subgid` ranges on `LOGIN_NODES` (rootless podman needs them; `useradd` only does this for local users). If MLflow is already running, it also runs `../3-mlflow/3-sync-tokens.sh` to give them a job token. With Keycloak (`../6-keycloak`), the password you type is **one-time**: their first web login asks for their own, which Keycloak writes to LDAP (so SSH etc. use it too). The menu's "Set a new password" does the same. Web only: an SSH-only user keeps it until `passwd`.

**`import-local-users.sh` (optional):** for a master that already has people as local users. It copies them into LDAP with the **same UID/GID** (their files stay theirs) and the **same password** (the `/etc/shadow` hash, stored as `{CRYPT}$6$...`). It skips `KEEP_LOCAL` and service accounts (`nologin`), and only adds to LDAP, never changes local files. Run it with `--dry-run` first.

**`remove-user.sh`** is the reverse. Always: their Slurm jobs, OOD session and processes on every node stop; their Model Hub namespace goes (endpoints, API key, quota), and their name leaves other people's share lists; their MLflow login + job token and their Keycloak login (all sessions) are deleted; they leave every team; their LDAP user and own group are deleted. Their public models go private. Kept unless asked: the home folder (`--delete-home`) and the MLflow experiments + registered models only they manage (`--delete-mlflow`; kept ones get the tag `removed_owner=<name>`, and only the MLflow admin manages them now). Their UID is written to `LDAP_LAST_UID_FILE` and `add-user.sh` never hands it out again, so a kept home can't end up owned by someone new; `add-user.sh` also refuses a name whose `/home/<name>` still exists. Their subuid/subgid ranges stay, for the same reason.

`KEEP_LOCAL` (`admin` by default) stays local on purpose: it's the way back in if LDAP breaks.

## Files

| File | What it does |
|---|---|
| `1-server.sh` | `dnf install 389-ds-base`, `dscreate` (self-signed TLS), `ou=People`/`ou=Groups`, access rules, CA -> `LDAP_CA` on the shared `/home` |
| `2-client.sh` | UID clash check, `sssd.conf` (rfc2307, ldaps, CA pinned, `root:root 0600`), `authselect select sssd with-mkhomedir` |
| `add-user.sh` | next free UID, user + own group, `ldappasswd -S`, home dir, subuid/subgid on login nodes, MLflow token |
| `remove-user.sh` | someone leaves: stops everything they run, deletes their logins, namespace, teams, LDAP entries; home and MLflow work only if asked; UID never reused |
| `set-password.sh` | new one-time password from stdin (forgotten password); used by `menu.sh` and the admin page |
| `group.sh` | teams: `groupOfNames` under `ou=Groups` without `posixGroup` (no gidNumber: not Linux groups, no file rights); create / add / remove / delete / list; re-syncs the people concerned into Model Hub (`aistack/teams` on their namespace) |
| `menu.sh` | the menu above (whiptail). Passwords: set (`ldappasswd -T`, as the Directory Manager), test (`ldapwhoami`); nobody can see one, LDAP keeps only the hash |
| `import-local-users.sh` | optional: local users -> LDAP with the same UID and password hash, then checks each UID |

Access rules: anyone may **read** users and groups except passwords (SSSD needs this), and each user may **change their own password**. Only the Directory Manager can add or delete. Its password is in `LDAP_DM_PASS_FILE` (`/root/.ldap-dm.pass`).

## Everyday commands

```bash
getent passwd <name>                       # Linux view (local or LDAP)
getent -s sss passwd <name>                # LDAP only, via SSSD
ldapsearch -x -H ldap://localhost -b ou=People,<LDAP_BASE> uid=<name>
sudo LDAPTLS_CACERT=<LDAP_CA> ldappasswd -x -H ldaps://<MASTER_HOST> -D "cn=Directory Manager" -y /root/.ldap-dm.pass -S uid=<name>,ou=People,<LDAP_BASE>   # ldaps: password changes are refused on plain ldap
ldapwhoami -x -H ldaps://<MASTER_HOST> -D uid=<name>,ou=People,<LDAP_BASE> -W     # test a password
sudo sss_cache -E                          # forget cached users after a change
```

`ldapwhoami`/`ldapsearch` need `-x` (simple login). Without it they try Kerberos and fail with `SASL/GSS-SPNEGO ... No credentials`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `1-server.sh`: `ldap_bind: Invalid credentials (49)` | `LDAP_DM_PASS_FILE` has a trailing newline, and `-y` sends it as part of the password | the script strips it now; rerun `1-server.sh` |
| `2-client.sh`: `sssd.service` fails, journal: `File ownership and permissions check failed` | `sssd.conf` isn't `root:root 0600` (where root's primary group isn't `root`, new files get another group) | the script sets it; by hand: `chown root:root /etc/sssd/sssd.conf; chmod 600 …; systemctl restart sssd` |
| `2-client.sh`: `CLASH: local user 'X' has UID N, which is 'Y' in LDAP` | a local account on that node (often a service like `node_exporter`) holds that UID, and local files are asked first | as root on that node: `systemctl stop X; groupmod -g <free id <1000> X; usermod -u <same> -g <same> -d /var/empty X; chown -R X:X <X's files: find / -xdev -uid N>; systemctl start X`, then rerun `2-client.sh` |
| `2-client.sh`: `SSSD cannot see LDAP users` | CA not trusted, or `MASTER_HOST` doesn't resolve on that node | `LDAPTLS_CACERT=<LDAP_CA> ldapsearch -x -H ldaps://<MASTER_HOST> -b <LDAP_BASE> -s base`; check `/etc/hosts`; `journalctl -u sssd` |
| Slurm job: `Couldn't determine user account information: user: unknown userid <uid>` | the compute node doesn't know the user: `2-client.sh` not run there | `sudo bash 2-client.sh` on that node; check with `srun -w <node> id <name>` |
| user sees their files owned by a bare number | their LDAP UID differs from the old local one | set `uidNumber` in LDAP to the old value, then `sss_cache -E` |
| `ldappasswd`: `Confidentiality required (13)`, `Operation requires a secure connection` | 389 DS only changes passwords over an encrypted connection; `ldap://localhost` is plain | use `-H ldaps://<MASTER_HOST>` with `LDAPTLS_CACERT=<LDAP_CA>` (`menu.sh`, `add-user.sh` do) |
| imported user can't log in | the account was locked locally (`!!`), so no password was copied | set one with `ldappasswd … -S` |
| undo on one node | | `authselect select local --force; systemctl stop sssd` |
| `remove-user.sh`: `No LDAP user '<name>'` on a rerun | the LDAP delete (step 6) already ran: only steps 7–8 were left | `sudo sss_cache -E` on each node; delete the home by hand if wanted |
| a removed person still opens the MLflow UI for a few minutes | MLflow caches a good LDAP login for 5 min (`ldap_auth.py`) | wait 5 min; their account has no rights left |
| `remove-user.sh` (before 2026-10-13 fix): `scancel: fatal: Could not establish a configuration source` | under `sudo`, `/etc/profile.d/slurm.sh` isn't read, so no `SLURM_CONF`; the user's jobs kept running | the script exports `SLURM_CONF` from `site.conf` now |
| a removed person's OOD session (`nginx: master process (<name>)`, owned by root) is still there | an open browser tab started a new one between step 2 and the LDAP delete | the script stops everything again after the LDAP delete (by UID and the session's config file), when nothing can restart |

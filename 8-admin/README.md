# 8-admin

The admin page (build-plan step 8) and its way to root: an OOD app only `OOD_ADMIN` sees (Interactive Apps -> Admin)
with four tabs, and the root helper every button goes through.

| Tab | Shows | Does |
|---|---|---|
| Running | everything in Slurm: VS Code / Jupyter sessions (each one), training jobs, Model Hub endpoints (linked to owner + endpoint); user, type, node + GPU, since, ends, waiting reason; counters; GPUs in use per node from all of them (refreshes every 5 s; filter by type or text) | Stop (always with a required message to the owner: why; they get it under the bell in OOD's top bar and in VS Code/Jupyter/Model Hub): a session or job = `scancel` (cancel-job); an endpoint = stop-endpoint (owner sees "stopped by admin", can redeploy) |
| Users | name, UID, teams, GPU limit, longest run ("custom" = not the site default) | Add (one-time password, Generate button), Password, Limits, Remove (two delete checkboxes, type the name) |
| Teams | each team and its members | New team, add/remove a member, delete a team |
| Log | `ADMIN_LOG`, newest first, incl. refused attempts | |

```
 LOGIN_HOST                                         MASTER_HOST
 admin page (OOD app, runs as OOD_ADMIN)  ──ssh──►  root, forced command    ──►  1-ldap/*.sh, 5-model-hub/2-sync-users.sh,
   key ADMIN_KEY (OOD_ADMIN only)        ADMIN_KEY  ADMIN_HELPER --ssh            kubectl (stop an endpoint, lists)
   each argument shlex-quoted                       fixed actions, every argument checked
                                                    ──► ADMIN_LOG (who, what, when, result)
 terminal on master: sudo ADMIN_HELPER ... (OOD_ADMIN only)
```

## Install

```bash
sudo bash 1-install.sh            # master: helper -> ADMIN_HELPER, sudo rule, log, the page's ssh key (made on LOGIN_HOST,
                                  # authorized in /root/.ssh/authorized_keys); checks admin may and an LDAP user may not
sudo bash 2-install-ood-app.sh    # LOGIN_HOST: the page -> /var/www/ood/apps/sys/aistack_admin, readable by OOD_ADMIN only
# then, logged in to OOD as OOD_ADMIN: Restart Web Server -> Interactive Apps -> Admin
```

## Use (as `OOD_ADMIN`, from the terminal too; full path: sudo's secure_path has no /usr/local/sbin)

```bash
sudo /usr/local/sbin/aistack-admin                                  # the list of actions
sudo /usr/local/sbin/aistack-admin endpoints                        # every endpoint: owner, state, node, GPU, since, until (JSON)
sudo /usr/local/sbin/aistack-admin users | python3 -m json.tool     # people, teams, limits
printf '%s\n' 'Their-1st-pass' | sudo /usr/local/sbin/aistack-admin add-user bob      # one-time password on stdin, never in argv
sudo /usr/local/sbin/aistack-admin remove-user bob --delete-home    # --delete-mlflow too if wanted
printf '%s\n' 'New-1-time' | sudo /usr/local/sbin/aistack-admin set-password bob
sudo /usr/local/sbin/aistack-admin team-create nlp; sudo /usr/local/sbin/aistack-admin team-add nlp bob carol; sudo /usr/local/sbin/aistack-admin team-delete nlp
sudo /usr/local/sbin/aistack-admin limits bob --gpus 2              # --max-hours 240 | --reset
sudo /usr/local/sbin/aistack-admin stop-endpoint bob my-llm 'Idle for 2 days.'   # frees the GPU; bob sees it "stopped" + the reason, can deploy it again
sudo /usr/local/sbin/aistack-admin jobs                             # everything in Slurm, what it is, whose, which GPUs
sudo /usr/local/sbin/aistack-admin cancel-job 1382 'Idle GPU for 6 hours: please use sbatch.'   # the owner reads the reason (endpoints: stop-endpoint)
sudo tail /var/log/aistack-admin.log                # what was done (refused attempts too)
```

Answers are one JSON line: `{"ok": …, "output": "<what the script printed>", "data": …}`; exit code 0 = ok.

## Why it's built this way

| What | Why |
|---|---|
| one helper, not a daemon; the page reaches it over ssh | the helper needs master (LDAP Directory Manager password, `admin.conf`, `ldap://localhost`), the page runs on `LOGIN_HOST`. Root's `authorized_keys` line is `restrict,from="LOGIN_IP",command="ADMIN_HELPER --ssh"`: no shell, pty or forwarding, only from the login node, only the helper. The key file is readable by `OOD_ADMIN` alone, so the key holder **is** the admin (the helper logs it as `OOD_ADMIN`); on master's terminal sudo says who asks (`SUDO_USER`). The login node gets no other way to root on master |
| the request: `shlex.join` on the page, `shlex.split(SSH_ORIGINAL_COMMAND)` in the helper | ssh sends one command line; quoting every argument and splitting it again (never a shell) gives back exactly the argv the page meant (`--test` checks `$(…)`, quotes, newlines) |
| fixed actions, regex-checked names, no shell | the page sends what a browser sends: nothing it says becomes a command |
| calls the existing scripts | the terminal and the page do exactly the same thing |
| passwords on stdin, removed from output before logging | never in a process list, the log, or the answer |
| one change at a time (`flock /run/aistack-admin.lock`) | `add-user.sh` picks max UID + 1; two at once could clash |
| "stop" deletes the pod, keeps the Service (annotated `model-hub/stopped-by` + `model-hub/stop-reason`) | ends the Slurm job and frees the GPU; the owner sees it stopped and can redeploy |
| the page: app folder `root:<admin's group> 750`, backend checks the user, `X-Requested-With` on changes | other users don't see it in OOD; if they reach it anyway: 403; a cross-site form can't send the header |
| `OOD_ADMIN` only | decided 2026-10-13; an `admins` team later needs `OOD-Install` root-owned first (see `1-install.sh`) |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sudo: a password is required` (terminal on master) | sudo rule missing, or another rule after it wins | rerun `1-install.sh` (its check fails if `OOD_ADMIN` can't run it) |
| the page: `the admin helper didn't answer: Permission denied (publickey)` / `Host key verification failed` | the key isn't in master's `/root/.ssh/authorized_keys`, `LOGIN_IP` isn't the address master sees, sshd refuses root (`PermitRootLogin no`), or master's host key changed | rerun `1-install.sh` on master (rewrites the line and `ADMIN_KEY.known_hosts`); `PermitRootLogin prohibit-password`; check `LOGIN_IP` against `who`/`/var/log/secure` on master |
| `<user> may not use the admin tool` | the caller isn't `OOD_ADMIN` | only that account; refused attempts are in `ADMIN_LOG` |
| `endpoints`/`users`: `kubectl ...` error | Model Hub not set up, or k8s down | `kubectl get nodes` as root |
| a change seems to hang | another change holds the lock (e.g. `remove-user` waits up to 5 min for a namespace) | wait; `sudo tail ADMIN_LOG` |
| `sudo: aistack-admin: command not found` | sudo's `secure_path` (EL9) has no `/usr/local/sbin` | use the full path `ADMIN_HELPER` |
| the Admin app isn't in the menu | not installed, or OOD caches the app list | `2-install-ood-app.sh`, then Restart Web Server (as admin) |
| the page says `the admin helper didn't answer` | helper missing on master, or the key / its `authorized_keys` line gone | `1-install.sh` on master |
| Admin is in no menu although installed | `manifest.yml` didn't parse (a `: ` in the unquoted description); OOD ignores it silently, so no category | quote the text; `2-install-ood-app.sh` now checks the manifest |
| not in Running: something a user started over SSH on master, outside Slurm | only Slurm jobs are listed | by hand: `ps -u <user>`; a "processes on master" view could come later |
| Stop endpoint: `error: name cannot be provided when a selector is specified` | old helper ran `kubectl get svc NAME -l ...` | fixed: `sudo bash 1-install.sh` |
| the user doesn't see "stopped by the admin" (session just vanishes) | VS Code/Jupyter list only `squeue` | the helper writes `ADMIN_NOTICES/<app>.<job>` (`admin <when>` + the reason; owned by the user, mode 600, stays until their bin button); rerun `4-vscode/3-install-ood-app.sh` + `7-jupyter/2-install-ood-app.sh` (site.json `notices`) |
| no bell in the user's top bar, or it stays empty | `setup-ood.sh` not rerun since (it installs the bell + app `aistack_notices`), or the user cleared it | rerun `2-ood/setup-ood.sh`, then Restart Web Server; `ls -l ADMIN_NOTICES` (the user's own files) |
| the bell's x / Clear all: `Could not clear it` | app `aistack_notices` missing, or its `site.json` path wrong | rerun `2-ood/setup-ood.sh` |
| `cancel-job` / `stop-endpoint` refused: `the reason: ...` | no message, over 1000 characters, or control characters | write why (the user reads it) |

# 8-admin

The admin page (build-plan step 8) and its way to root. **Now:** the root helper. **Next:** the page itself (an OOD
app for `OOD_ADMIN` only) that calls it.

```
 admin page (OOD app, runs as OOD_ADMIN)  ──sudo -n──►  ADMIN_HELPER (root)  ──►  1-ldap/*.sh, 5-model-hub/2-sync-users.sh,
                                                         fixed actions,            kubectl (stop an endpoint, lists)
                                                         every argument checked
                                                         ──► ADMIN_LOG (who, what, when, result)
```

## Install (on master)

```bash
sudo bash 1-install.sh      # helper -> ADMIN_HELPER, sudo rule for OOD_ADMIN, log; checks admin may and an LDAP user may not
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
sudo /usr/local/sbin/aistack-admin stop-endpoint bob my-llm         # frees the GPU; bob sees it "stopped" and can deploy it again
sudo tail /var/log/aistack-admin.log                # what was done (refused attempts too)
```

Answers are one JSON line: `{"ok": …, "output": "<what the script printed>", "data": …}`; exit code 0 = ok.

## Why it's built this way

| What | Why |
|---|---|
| `sudo` + one helper, not a daemon | the page runs as `OOD_ADMIN`; sudo already knows who is asking (`SUDO_USER`) and logs it; no socket or service to run |
| fixed actions, regex-checked names, no shell | the page sends what a browser sends: nothing it says becomes a command |
| calls the existing scripts | the terminal and the page do exactly the same thing |
| passwords on stdin, removed from output before logging | never in a process list, the log, or the answer |
| one change at a time (`flock /run/aistack-admin.lock`) | `add-user.sh` picks max UID + 1; two at once could clash |
| "stop" deletes the pod, keeps the Service (annotated `model-hub/stopped-by`) | ends the Slurm job and frees the GPU; the owner sees it stopped and can redeploy |
| `OOD_ADMIN` only | decided 2026-10-13; an `admins` team later needs `OOD-Install` root-owned first (see `1-install.sh`) |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sudo: a password is required` from the page | sudo rule missing, or another rule after it wins | rerun `1-install.sh` (its check fails if `OOD_ADMIN` can't run it) |
| `<user> may not use the admin tool` | the caller isn't `OOD_ADMIN` | only that account; refused attempts are in `ADMIN_LOG` |
| `endpoints`/`users`: `kubectl ...` error | Model Hub not set up, or k8s down | `kubectl get nodes` as root |
| a change seems to hang | another change holds the lock (e.g. `remove-user` waits up to 5 min for a namespace) | wait; `sudo tail ADMIN_LOG` |
| `sudo: aistack-admin: command not found` | sudo's `secure_path` (EL9) has no `/usr/local/sbin` | use the full path `ADMIN_HELPER` |

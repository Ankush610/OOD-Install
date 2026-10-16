# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Idempotent root bash scripts that set up, on a fresh Slurm + Kubernetes cluster (AlmaLinux 9): LDAP for users (389 DS on master + SSSD everywhere), Open OnDemand 4.2 logging in against it, and ONE shared MLflow server with LDAP login on k8s. The scripts run as root on the cluster's `master` node, or on the login node (`LOGIN_HOST`) for anything OOD/Apache, and can't be tested from a laptop.

This cluster: laptop → `network-node` (10.208.34.138) → `master` (192.168.40.102: LDAP, OOD, MLflow pod, Slurm controller, k8s control plane, registry `master:5000`; also the login node: `LOGIN_HOST=$MASTER_HOST`) + `cn01`/`cn02` (training). Access: `sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 -L 30500:192.168.40.102:30500 admin@master`, then `https://localhost`.

## Layout and run order

`site.conf` holds **every** site value; every script does `source "$HERE/../site.conf"`. Never hardcode an IP, hostname, base DN, port or path in a script. Add it to `site.conf`.

```
Runs on master unless marked [login] (= LOGIN_HOST; each script checks its host).
0-registry/setup-registry.sh registry:2 on master (deletes on, podman-restart), containerd hosts.toml + podman trust on every node, k8s-image
1-ldap/1-server.sh          master: 389 DS, tree, ACIs, CA -> LDAP_CA (shared /home)
1-ldap/import-local-users.sh  optional: local users -> LDAP, same UID + password hash
1-ldap/2-client.sh          every node: UID clash check, SSSD, authselect
1-ldap/add-user.sh          new person (replaces useradd), subuid/subgid on LOGIN_NODES, also runs 3-mlflow/3-sync-tokens.sh; never reuses a UID (LDAP_LAST_UID_FILE)
1-ldap/remove-user.sh       someone leaves: jobs/sessions/endpoints stopped, namespace, MLflow + Keycloak login, teams, LDAP entries; home + MLflow work only with flags
1-ldap/set-password.sh      one-time password from stdin (menu.sh, 8-admin); Keycloak must-change
1-ldap/group.sh             teams (groupOfNames, not Linux groups) for Model Hub sharing; re-syncs members via 5-model-hub/2-sync-users.sh
2-ood/setup-ood.sh          [login] OOD, AuthBasicProvider "ldap file" (ldaps to master), self-signed cert, Slurm cluster file
3-mlflow/1-build-image.sh   image/ -> MLFLOW_IMAGE (no root)
3-mlflow/2-deploy.sh        mlflow system user, data dir, basic_auth.ini, envsubst mlflow.yaml | kubectl apply, proxy secret -> LOGIN_HOST
3-mlflow/3-sync-tokens.sh   job token per LDAP user in ~/.mlflow/credentials
3-mlflow/4-install-ood-app.sh  [login] Passenger page + site.json -> /var/www/ood/apps/sys/mlflow_k8s
4-vscode/1-install-code-server.sh  release tarball -> CODE_SERVER_ROOT/<ver>, current symlink (shared /home)
4-vscode/2-slurm-viewer.sh  viewer partition on LOGIN_HOST, OverSubscribe=FORCE:n, slurm.conf to every node
4-vscode/3-install-ood-app.sh  [login] envsubst ood-app/vscode -> /var/www/ood/apps/sys/vscode (Batch Connect)
5-model-hub/1..8-*.sh         Model Hub: setup, users, images, tests, OOD app [login], gateway (v1 = git tag v1; v2 done; v3 is built here)
6-keycloak/1-install.sh     Keycloak + Postgres as podman quadlets on master (HTTP on MASTER_IP, firewalld: LOGIN_IP only; rest 127.0.0.1), OOD_CERT fetched from LOGIN_HOST, permanent admin
6-keycloak/2-realm.sh       realm CLUSTER_ID: LDAP users + groups, writable for passwords only (LDAP account cn=keycloak-passwords + access rule; ldaps); client ood (secret -> LOGIN_HOST) + OOD_ADMIN local user; kc.py = admin REST; Apache /auth proxy is in 2-ood
7-jupyter/1-install-jupyter.sh  standalone Python + venv + requirements.txt -> JUPYTER_ROOT/<lab>-py<py>, current symlink
7-jupyter/2-install-ood-app.sh  [login] 4-vscode's page + ood-app/jupyter -> /var/www/ood/apps/sys/jupyter (site.json "app": "jupyter")
8-admin/1-install.sh        root helper for the admin page: aistack-admin.py -> ADMIN_HELPER, sudo rule for OOD_ADMIN only, ADMIN_LOG, ssh key ADMIN_KEY on LOGIN_HOST -> root's authorized_keys (forced command)
8-admin/2-install-ood-app.sh  [login] admin page (OOD app aistack_admin, Model Hub's look) readable by OOD_ADMIN only; every button = one helper call
9-monitoring/1-install.sh   Prometheus on master (systemd, PROM_URL) + node_exporter on every node (node-setup.sh over ssh) with our textfile collectors: gpu-metrics.sh (nvidia-smi, GPU nodes) and slurm-metrics.py (scontrol/squeue, master); rules.yml = named queries apps read
9-monitoring/2-install-ood-app.sh  [login] OOD app cluster_status (Interactive Apps menu + home card in the Admin section of 2-ood/branding/_ai_tools.html.erb, OOD_ADMIN only like 8-admin, read-only): Model Hub's look, its backend asks PROM_URL
```

Local sanity checks (no tests or linters):
```bash
bash -n */*.sh
( cd 4-vscode/ood-app/vscode && ruby -ryaml -e 'YAML.load_file("form.yml")' )
python3 -c 'import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' 3-mlflow/image/ldap_auth.py 3-mlflow/ood-app/mlflow_k8s/passenger_wsgi.py
( set -a; source site.conf; envsubst < 3-mlflow/mlflow.yaml ) | kubectl apply --dry-run=server -f -
```

## Design decisions (don't undo without a reason)

- **Master and login node are split by `LOGIN_HOST`** (default `MASTER_HOST`). Code takes the same path either way: no "if same host" shortcut, so the one-machine cluster exercises the split. Master reaches the login node with root ssh (`on <node> <cmd>`: local when it's this host); **the login node never gets root on master**. What crosses: login-side code uses `LDAP_URI` (ldaps) + `LDAP_CA`, `KEYCLOAK_URL`, `MLFLOW_URI`; master pushes secrets to root-only files on `LOGIN_HOST` (`OOD_OIDC_SECRET` from `6-keycloak/2-realm.sh`, `MLFLOW_PROXY_SECRET` from `3-mlflow/2-deploy.sh`) and fetches `OOD_CERT` for Keycloak; public files go on the shared `/home` (`GATEWAY_CA`, `ADMIN_NOTICES`). The admin page calls the helper over ssh with `ADMIN_KEY`: root's `authorized_keys` line is `restrict,from="LOGIN_IP",command="ADMIN_HELPER --ssh"`, the page `shlex.join`s the request, the helper `shlex.split`s `SSH_ORIGINAL_COMMAND` (no shell) and takes the key holder as `OOD_ADMIN`. Master-only scripts keep `ldap://localhost`.

- **LDAP decides first everywhere.** OOD uses `AuthBasicProvider ldap file`: Apache stops at the first provider that knows the user, so `file` (htpasswd) only serves `OOD_ADMIN`, which is not in LDAP. `KEEP_LOCAL` accounts stay local as the way back in.
- **MLflow web UI login.** `OOD_AUTH=ldap`: opened **directly** on `MLFLOW_PORT` with the LDAP password (OOD's `/node` proxy doesn't pass the password on). `OOD_AUTH=keycloak`: opened **through** OOD's `/node` proxy (`MLFLOW_PREFIX` = `/node/<MASTER_IP>/<MLFLOW_PORT>`), which is already logged in and sets `X-Forwarded-User`. MLflow trusts that header **only together with** `X-MLflow-Proxy-Secret` (`MLFLOW_DATA/proxy.secret`), which Apache adds on MLflow's path alone. Never trust `X-Forwarded-User` without the secret: anyone reaching the port could fake it.
- **MLflow login** (`image/ldap_auth.py`): auth.db password (admin + job tokens) OR LDAP bind. It rejects empty passwords (an empty password is an anonymous bind, which LDAP accepts) and non-Linux usernames (DN injection). The first LDAP login creates the MLflow user. Good binds are cached 5 min in-process (`--workers 1`).
- **Jobs use tokens, not passwords:** `3-sync-tokens.sh` writes a random token; it survives password changes.
- **MLflow pod:** namespace `mlflow` (outside slurm-bridge's `managedNamespaces`, so the default scheduler places it with no Slurm time limit), pinned to `MASTER_HOST`, hostPath `MLFLOW_DATA` (SQLite on local disk, not NFS), `runAsUser: MLFLOW_UID` = local system account below `MIN_UID`, never in LDAP. `hostAliases` maps `MASTER_HOST` so `ldaps://` matches the certificate name.
- **`MLFLOW_PREFIX`** is passed as `MLFLOW_STATIC_PREFIX` (env, empty = none), not `--static-prefix`, so it can be empty. It's part of the tracking URI and the probe paths.
- **Artifacts go through the server** (`--artifacts-destination`), so permission checks apply to files, and `MLFLOW_DATA` stays mode 700.
- **VS Code** is a Batch Connect app (Slurm), not k8s: the session must run as the user with their home, which Slurm already does. One code-server install on `/home/apps`; extensions/settings live in each user's `~/.local/share/code-server`. "Editor only" sessions go to `viewer` on `LOGIN_HOST` with `OverSubscribe=FORCE:n` (cores shared, memory reserved), so editors never hold compute nodes. The viewer Slurm node is `NodeName=$VIEWER_NODE NodeHostname=$LOGIN_HOST` (default `viewer01`), never the hostname: slurm-bridge taints (NoExecute) every k8s node whose name matches a Slurm node, which evicted coredns & co. from master. The line comes from `slurmd -C` (RealMemory at 98%) plus `CoreSpecCount`/`MemSpecLimit`, which keep `VIEWER_RESERVED_*` out of Slurm for SSH users and master's services. `view.html.erb` posts the per-session password through `/rnode` (prefix stripped: code-server wants to sit at `/`). Templates hold `${SITE_VARS}` filled by `envsubst` with an explicit list, so `${port}`/`$HOME` survive. Job templates read form values as `context.<field>`; only `submit.yml.erb` gets bare names. GPU choices (`gpu1`..`gpuN`, one per count) are written into `form.yml` at install from `gpu-detect.sh` (sinfo), because OOD's per-option field hiding (`bc_dynamic_js`) is off by default; `submit.yml.erb` clamps n and requests untyped `--gres=gpu:n`.
- **Jupyter** works like VS Code (Slurm job as the user, `viewer` partition, GPU choices) and **shares its page**: `4-vscode/ood-app/vscode/passenger_wsgi.py`, texts picked by `site.json` `"app"`. Not one shared server (it runs user code, so it must run as the user) and not JupyterHub (a second login + server doing OOD's job). Own Python (python-build-standalone, `JUPYTER_PYTHON`): JupyterLab needs ≥ 3.10, nodes have 3.9; a venv on top so users' `pip install --user` can't reach the server. `base_url=/node/<ip>/<port>/` (not `/rnode`). Connect = `?token=` link: Jupyter's login POST needs `_xsrf` (403 without); never `disable_check_xsrf`. `allow_origin=https://OOD_SERVERNAME`. Kernels: `job.sh` writes one per `CONTAINERS_ROOT/training/*/*.sif` at session start (`apptainer exec --nv`; every training SIF must have ipykernel), so new images need no install step.
- **Monitoring** (`9-monitoring`): one Prometheus on master is the single metrics source for every app; apps query the named rules in `rules.yml`, not raw PromQL. Plain binaries under systemd, not k8s (like the registry and Keycloak). **It uses nothing it didn't install**: not the GPU operator's DCGM pods, not k8s, not Slurm's metrics plugin (no slurm.conf change). GPUs come from nvidia-smi and Slurm from scontrol/squeue `--json`, via node_exporter's textfile folder (written atomically; `*_collector_ok 0` instead of stale numbers). Only GPU types Slurm schedules count (drops display cards). Slurm series carry `node` = hostname (`honor_labels: true` on the `node` job keeps it over the target's) and `slurm_node`. It installs what's ours + curl/python3/tar; Slurm, the NVIDIA driver, firewalld, ssh and /home it only checks. No password on PROM_URL: OOD apps run as the user, so any secret they read every user can read; the firewall + read-only API are the protection. The Prometheus in k8s (`monitoring` ns) is KEDA's, not this one.
- `sssd.conf` must be `root:root 0600` (explicit `chown`: root's primary group isn't always `root`). `LDAP_DM_PASS_FILE` must have no trailing newline (`ldap* -y` sends it byte for byte).

## MLflow flags that must stay

- `--workers 1`: more workers run out of memory at 2 GB, and the login cache is per process.
- `--allowed-hosts "*"`: MLflow 3.x only answers localhost by default.
- Training containers ship `mlflow-skinny`, which can't open SQLite. Always give clients the HTTP tracking URI. `MLFLOW_VERSION` must be ≥ their version; db upgrades are one-way.

## Conventions

- Scripts use `set -euo pipefail`, source `site.conf`, print numbered `== N.` steps, and end with a check that says what to expect. Every script is safe to rerun.
- Secrets never go on a command line: `curl -K <(printf …)`, `ldappasswd -S`, `-y <file>`.
- `# ponytail:` comments mark deliberate shortcuts that have a known limit.
- Each folder's README keeps a Symptom | Cause | Fix table. When you hit a new failure mode, add a row.
- After changing an OOD app or config on the server: **Restart Web Server** in OOD (it caches config per user).

## Sibling repo

`../AI-Stack` holds the design docs (see its `CLAUDE.md`): `docs/cluster/` (architecture, `master:5000` registry, installed versions), `docs/model-hub/` (full Model Hub design; the current scope is `docs/model-hub/versions/version-2/`; its `build-plan.md` lists what goes in `5-model-hub/`; v1 is git tag `v1`), and test manifests in `k8s/examples/` (slurm-bridge, DRA GPUs).

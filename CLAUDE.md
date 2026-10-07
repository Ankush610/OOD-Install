# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Idempotent root bash scripts that set up, on a fresh Slurm + Kubernetes cluster (AlmaLinux 9): LDAP for users (389 DS on master + SSSD everywhere), Open OnDemand 4.2 logging in against it, and ONE shared MLflow server with LDAP login on k8s. The scripts run on the cluster's `master` node, mostly as root, and can't be tested from a laptop.

This cluster: laptop → `network-node` (10.208.34.138) → `master` (192.168.40.102: LDAP, OOD, MLflow pod, Slurm controller, k8s control plane, registry `master:5000`) + `cn01`/`cn02` (training). Access: `sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 -L 30500:192.168.40.102:30500 admin@master`, then `https://localhost`.

## Layout and run order

`site.conf` holds **every** site value; every script does `source "$HERE/../site.conf"`. Never hardcode an IP, hostname, base DN, port or path in a script. Add it to `site.conf`.

```
0-registry/setup-registry.sh registry:2 on master (deletes on, podman-restart), containerd hosts.toml + podman trust on every node, k8s-image
1-ldap/1-server.sh          master: 389 DS, tree, ACIs, CA -> LDAP_CA (shared /home)
1-ldap/import-local-users.sh  optional: local users -> LDAP, same UID + password hash
1-ldap/2-client.sh          every node: UID clash check, SSSD, authselect
1-ldap/add-user.sh          new person (replaces useradd), subuid/subgid on LOGIN_NODES, also runs 3-mlflow/3-sync-tokens.sh
1-ldap/group.sh             teams (groupOfNames, not Linux groups) for Model Hub sharing; re-syncs members via 5-model-hub/2-sync-users.sh
2-ood/setup-ood.sh          OOD, AuthBasicProvider "ldap file", self-signed cert, Slurm cluster file
3-mlflow/1-build-image.sh   image/ -> MLFLOW_IMAGE (no root)
3-mlflow/2-deploy.sh        mlflow system user, data dir, basic_auth.ini, envsubst mlflow.yaml | kubectl apply
3-mlflow/3-sync-tokens.sh   job token per LDAP user in ~/.mlflow/credentials
3-mlflow/4-install-ood-app.sh  Passenger page + site.json -> /var/www/ood/apps/sys/mlflow_k8s
4-vscode/1-install-code-server.sh  release tarball -> CODE_SERVER_ROOT/<ver>, current symlink (shared /home)
4-vscode/2-slurm-viewer.sh  viewer partition on master, OverSubscribe=FORCE:n, slurm.conf to every node
4-vscode/3-install-ood-app.sh  envsubst ood-app/vscode -> /var/www/ood/apps/sys/vscode (Batch Connect)
5-model-hub/1..7-*.sh         Model Hub: setup, users, images, tests, OOD app (v1 = git tag v1; v2 is built here)
6-keycloak/1-install.sh     Keycloak + Postgres as podman quadlets on master (127.0.0.1), image built + pushed, permanent admin
6-keycloak/2-realm.sh       realm CLUSTER_ID: LDAP users + groups read-only (kc.py = admin REST); Apache /auth proxy is in 2-ood
```

Local sanity checks (no tests or linters):
```bash
bash -n */*.sh
( cd 4-vscode/ood-app/vscode && ruby -ryaml -e 'YAML.load_file("form.yml")' )
python3 -c 'import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]' 3-mlflow/image/ldap_auth.py 3-mlflow/ood-app/mlflow_k8s/passenger_wsgi.py
( set -a; source site.conf; envsubst < 3-mlflow/mlflow.yaml ) | kubectl apply --dry-run=server -f -
```

## Design decisions (don't undo without a reason)

- **LDAP decides first everywhere.** OOD uses `AuthBasicProvider ldap file`: Apache stops at the first provider that knows the user, so `file` (htpasswd) only serves `OOD_ADMIN`, which is not in LDAP. `KEEP_LOCAL` accounts stay local as the way back in.
- **MLflow web UI login.** `OOD_AUTH=ldap`: opened **directly** on `MLFLOW_PORT` with the LDAP password (OOD's `/node` proxy doesn't pass the password on). `OOD_AUTH=keycloak`: opened **through** OOD's `/node` proxy (`MLFLOW_PREFIX` = `/node/<MASTER_IP>/<MLFLOW_PORT>`), which is already logged in and sets `X-Forwarded-User`. MLflow trusts that header **only together with** `X-MLflow-Proxy-Secret` (`MLFLOW_DATA/proxy.secret`), which Apache adds on MLflow's path alone. Never trust `X-Forwarded-User` without the secret: anyone reaching the port could fake it.
- **MLflow login** (`image/ldap_auth.py`): auth.db password (admin + job tokens) OR LDAP bind. It rejects empty passwords (an empty password is an anonymous bind, which LDAP accepts) and non-Linux usernames (DN injection). The first LDAP login creates the MLflow user. Good binds are cached 5 min in-process (`--workers 1`).
- **Jobs use tokens, not passwords:** `3-sync-tokens.sh` writes a random token; it survives password changes.
- **MLflow pod:** namespace `mlflow` (outside slurm-bridge's `managedNamespaces`, so the default scheduler places it with no Slurm time limit), pinned to `MASTER_HOST`, hostPath `MLFLOW_DATA` (SQLite on local disk, not NFS), `runAsUser: MLFLOW_UID` = local system account below `MIN_UID`, never in LDAP. `hostAliases` maps `MASTER_HOST` so `ldaps://` matches the certificate name.
- **`MLFLOW_PREFIX`** is passed as `MLFLOW_STATIC_PREFIX` (env, empty = none), not `--static-prefix`, so it can be empty. It's part of the tracking URI and the probe paths.
- **Artifacts go through the server** (`--artifacts-destination`), so permission checks apply to files, and `MLFLOW_DATA` stays mode 700.
- **VS Code** is a Batch Connect app (Slurm), not k8s: the session must run as the user with their home, which Slurm already does. One code-server install on `/home/apps`; extensions/settings live in each user's `~/.local/share/code-server`. "Editor only" sessions go to `viewer` on master with `OverSubscribe=FORCE:n` (cores shared, memory reserved), so editors never hold compute nodes. Master's Slurm node is `NodeName=$VIEWER_NODE NodeHostname=$MASTER_HOST` (default `viewer01`), never the hostname: slurm-bridge taints (NoExecute) every k8s node whose name matches a Slurm node, which evicted coredns & co. from master. The line comes from `slurmd -C` (RealMemory at 98%) plus `CoreSpecCount`/`MemSpecLimit`, which keep `VIEWER_RESERVED_*` out of Slurm for SSH users and master's services. `view.html.erb` posts the per-session password through `/rnode` (prefix stripped: code-server wants to sit at `/`). Templates hold `${SITE_VARS}` filled by `envsubst` with an explicit list, so `${port}`/`$HOME` survive. Job templates read form values as `context.<field>`; only `submit.yml.erb` gets bare names. GPU choices (`gpu1`..`gpuN`, one per count) are written into `form.yml` at install from `gpu-detect.sh` (sinfo), because OOD's per-option field hiding (`bc_dynamic_js`) is off by default; `submit.yml.erb` clamps n and requests untyped `--gres=gpu:n`.
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

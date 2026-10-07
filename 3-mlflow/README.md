# 3-mlflow

ONE shared MLflow server (tracking + model registry) for every user, running as an always-on k8s pod on master, not a Slurm job. Each user sees only their own experiments and models (`default_permission = NO_PERMISSIONS`). People log in with their **LDAP password**; jobs use a token. OOD gets a page, **Interactive Apps -> MLflow (shared)**.

See [WORKFLOW.md](WORKFLOW.md) for diagrams: the big picture, adding a user, a training run, the model registry, and who sees what.

## Run (on master, after ../1-ldap and ../2-ood)

```bash
bash      1-build-image.sh        # image/ -> MLFLOW_IMAGE, pushed to REGISTRY (no root)
sudo bash 2-deploy.sh             # mlflow account, data dir, auth config, k8s objects, checks
sudo bash 3-sync-tokens.sh        # every LDAP user: MLflow account + job token
sudo bash 4-install-ood-app.sh    # the OOD page, then Restart Web Server in OOD
```

| File | What it is |
|---|---|
| `image/` | `Containerfile`, pinned `requirements.txt`, `ldap_auth.py` (the login). `1-build-image.sh --from-venv <dir>` regenerates the pins from a venv |
| `mlflow.yaml` | **template**: `${...}` come from `../site.conf`. `2-deploy.sh` fills them in (`envsubst`) and applies |
| `2-deploy.sh` | creates the local system account `MLFLOW_USER` (`MLFLOW_UID`, below 1000, never in LDAP), which owns `MLFLOW_DATA` (mode 700) and runs the pod; writes `admin.pass` + `basic_auth.ini`; runs as root with `/etc/kubernetes/admin.conf` |
| `3-sync-tokens.sh` | random token per LDAP user in `~/.mlflow/credentials` (600); only replaces tokens that stopped working |
| `ood-app/mlflow_k8s/` | Passenger page (stdlib only). `4-install-ood-app.sh` writes `site.json` next to it from `site.conf` |

The pod: namespace `mlflow`, pinned to `MASTER_HOST` (data on its local disk, SQLite), NodePort `MLFLOW_PORT`, 1–2 CPU, 2Gi, `--workers 1`. It's outside slurm-bridge's managed namespace, so the default scheduler places it and there's no Slurm time limit. It tolerates the control-plane and slurm-bridge taints, so it can run on master.

## Login

`image/ldap_auth.py` is MLflow's `authorization_function`. A request gets in if:
- **the password matches `auth.db`**: the MLflow `admin` (`MLFLOW_DATA/admin.pass`) and the job tokens, **or**
- **an LDAP bind as that user works**: the person's normal SSH/OOD password. Their first LDAP login creates their MLflow user.

Empty passwords and usernames that aren't plain Linux names are refused, so there's no anonymous bind and no DN injection. Good LDAP logins are cached in the pod for 5 minutes, so a password change takes up to 5 minutes to reach MLflow. If LDAP is down, tokens and `admin` still work.

**Jobs** can't type a password, so `3-sync-tokens.sh` gives each user a random **token** in `~/.mlflow/credentials`. MLflow clients read it automatically. It survives password changes, and no real password is ever stored in a file.

## For users

```bash
export MLFLOW_TRACKING_URI=<MLFLOW_URI>      # shown, with Copy, on the OOD page
python train.py
```

**Web UI, with Keycloak (`OOD_AUTH=keycloak`):** **Open MLflow** opens it **through OOD** (`https://<OOD>/node/<MASTER_IP>/<MLFLOW_PORT>/`), already logged in: no second password. OOD's `/node` proxy sends the logged-in user as `X-Forwarded-User`; Apache adds `X-MLflow-Proxy-Secret` on that one path, and `image/ldap_auth.py` trusts the user **only** when the secret matches (`MLFLOW_DATA/proxy.secret`, made by `2-deploy.sh`, read by `../2-ood/setup-ood.sh`). Calling the port directly with a made-up `X-Forwarded-User` gets 401.

**Web UI, without Keycloak (`OOD_AUTH=ldap`):** **Open MLflow** goes **directly** to port `MLFLOW_PORT`, and MLflow asks for your cluster username and password (OOD's `/node` proxy doesn't pass the password on). From a laptop, the SSH tunnel needs `-L <MLFLOW_PORT>:<MASTER_IP>:<MLFLOW_PORT>`.

Jobs and scripts are the same either way: the token in `~/.mlflow/credentials` on `MLFLOW_URI`.

**Why `MLFLOW_PREFIX`:** MLflow serves under that URL path (`MLFLOW_STATIC_PREFIX`), and the tracking URI includes it. This cluster keeps `/node/<ip>/<port>` so the URI matches its earlier setup. On a new cluster, `""` gives a plain `http://<ip>:<port>`.

## Admin

- MLflow admin password: `MLFLOW_DATA/admin.pass` (log in to the UI as `admin` to manage users and permissions)
- logs: `sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n mlflow logs deploy/mlflow`
- empty everyone's trash: `kubectl -n mlflow exec deploy/mlflow -- mlflow gc --backend-store-uri sqlite:////data/mlflow.db --artifacts-destination /data/artifacts`
- backup: `MLFLOW_DATA` as one piece (`mlflow.db`, `auth.db`, `artifacts/`). Losing `mlflow.db` loses every run, version and alias
- upgrade: `MLFLOW_VERSION` in `site.conf` + `mlflow==` in `image/requirements.txt`, then `1-build-image.sh`, `2-deploy.sh`. Keep the server **at or above** the `mlflow-skinny` in the training containers. The db upgrades itself, one-way

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `1-build-image.sh`: `THESE PACKAGES DO NOT MATCH THE HASHES` | PyPI dropped the connection mid-download | rerun |
| Keycloak on, but **Open MLflow** still asks for a password | the OOD page was installed before the switch, or Apache has no MLflow secret yet | `sudo bash 2-deploy.sh`, `sudo bash ../2-ood/setup-ood.sh`, `sudo bash 4-install-ood-app.sh`, then Restart Web Server |
| through OOD: MLflow answers 401 | `proxy.secret` changed after `setup-ood.sh` ran (Apache sends the old one), or the pod runs the old image | rerun `../2-ood/setup-ood.sh`; check the pod's image is `MLFLOW_IMAGE` (`-sso`) |
| `2-deploy.sh`: `is not in the registry` | image not built/pushed, or another tag in `site.conf` | `bash 1-build-image.sh` |
| `2-deploy.sh`: `UID <n> already belongs to '<x>'` | `MLFLOW_UID` is taken on master | pick a free UID below `MIN_UID` in `site.conf` |
| `2-deploy.sh`: rollout timed out, event `failed calling webhook "pods.slinky.slurm.net" ... connection refused` | slurm-bridge's admission webhook is down, and it blocks new pods in every namespace except `kube-system`/`slurm` | its pods need a toleration for `slinky.slurm.net/managed-node`: `kubectl -n slurm patch deploy …` (lost on `helm upgrade`: put it in the chart values) |
| `2-deploy.sh`: `namespace mlflow ... is being terminated` | a deleted namespace hangs on a broken aggregated API (e.g. KEDA's `external.metrics.k8s.io`) | once it's empty: `kubectl get ns mlflow -o json \| jq ".spec.finalizers=[]" \| kubectl replace --raw /api/v1/namespaces/mlflow/finalize -f -` |
| MLflow UI refuses the SSH password | opened through OOD's `/node/…` (password stripped), user not in LDAP, LDAP unreachable from the pod, or a password changed in the last 5 min | use **Open MLflow** (direct port); `ldapwhoami -x -H ldap://localhost -D uid=<user>,ou=People,<LDAP_BASE> -W`; pod logs; wait 5 min |
| Open MLflow: page can't be reached | the laptop tunnel lacks the MLflow port | add `-L <MLFLOW_PORT>:<MASTER_IP>:<MLFLOW_PORT>` |
| job: `401` from MLflow | token in `~/.mlflow/credentials` missing or stale | `sudo bash 3-sync-tokens.sh` |
| job: `KeyError: 'sqlite'` | training containers ship `mlflow-skinny`, which can't open SQLite | always use the HTTP tracking URI |

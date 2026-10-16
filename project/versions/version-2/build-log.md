# Model Hub v2 — build log

Problems and fixes as we go, newest at the bottom. v1's log (everything learned so far): [../version-1/build-log.md](../version-1/build-log.md).

## 2026-10-06 — v2 planned

- v1 committed and tagged `v1` in `OOD-Install` and `AI-Stack`.
- Requirements decided with the admin (README "Decisions"); Rudra product context added; research in research.md.
- Next: senior answers (README "Questions for the senior"), then build-plan step 1.

## 2026-10-07 — Step 2a: Keycloak installed (`OOD-Install/6-keycloak/`), not yet used by OOD/MLflow

- **Where:** its own folder (not `5-model-hub/version2`): Keycloak is the login for OOD, MLflow and Model Hub alike.
- **How it runs:** Keycloak 26.8.0 + Postgres 17.11 as two podman **quadlets** (systemd) on master, both as system user
  `keycloak` (UID 949), both on **127.0.0.1 only**. Browsers reach it through OOD's Apache at `https://<OOD>/auth`
  (`2-ood/setup-ood.sh` now adds that proxy via `custom_vhost_directives`, and runs `apachectl configtest` before
  restarting). systemd, not k8s, so login keeps working when k8s has a problem.
- **Users:** realm `aistack`, LDAP user federation **read-only** (vendor rhds, anonymous search on `ldap://127.0.0.1`,
  uuid `nsuniqueid`), groups from `ou=Groups` (`groupOfNames`/`member`). No sign-up, no reset, brute-force protection,
  `VERIFY_PROFILE` off (LDAP users may have no e-mail and the profile can't be edited).
- **Found while testing (rootless podman, spare ports):**
  - master already uses **5432** (SonarQube's Postgres) and **9000** (SonarQube) → `KEYCLOAK_DB_PORT=5433`,
    `KEYCLOAK_MGMT_PORT=9180`; `1-install.sh` refuses ports owned by something else.
  - the Keycloak image runs as UID **1000 = `admin`** on this cluster → containers run as UID 949.
  - `start` (not optimized) rebuilds at runtime and can't as UID 949 → image pre-built (`image/Containerfile`,
    `kc.sh build`, `start --optimized`).
  - `KC_CACHE=local` is a **runtime** option in 26.8 (in the build it did nothing): without it Keycloak opened
    JGroups port 57800 on every interface.
- **Checked** (test instance with the real LDAP): `kc.py admin` twice (creates `kcadmin`, deletes the bootstrap admin;
  then "ok"); `kc.py realm` twice (created/updated; 8 of 8 LDAP users imported, linked to LDAP; 8 groups); wrong
  password / unknown user → `Invalid user credentials`; issuer `https://localhost/auth/realms/aistack`, backchannel on
  127.0.0.1; restart on the same DB keeps everything; quadlet dry-run generates both services; OOD portal renders
  the `/auth` block inside the 443 vhost.
- **Not checked:** the real install as root (systemd units, Apache proxy), a login with a real LDAP password.
- **Next:** admin runs `2-ood/setup-ood.sh`, `6-keycloak/1-install.sh`, `2-realm.sh` and logs in at
  `/auth/realms/aistack/account`. Then step 2b: OOD logs in through Keycloak.
- **Installed on master (admin, 2026-10-07):** `setup-ood.sh` (configtest OK, `/auth` 503 before Keycloak),
  `1-install.sh` (images mirrored/built, units active, ports 5433/8180/9180 on 127.0.0.1 only, `/auth` ok through
  Apache), `2-realm.sh` (8 of 8 users, 8 groups). **Login test PASS:** ankush with the LDAP password got a Keycloak
  token from `https://localhost/auth/realms/aistack`. OOD and MLflow still ask for their own passwords: expected until 2b/2c.

## 2026-10-07 — Step 2b: OOD logs in through Keycloak (written + tested without root; admin switches it on)

- `site.conf` **`OOD_AUTH=ldap|keycloak`** (default still `ldap`): `2-ood/setup-ood.sh` writes either the old
  Basic-auth LDAP login or OIDC (`mod_auth_openidc`, now installed with OOD). Switching back = one word + rerun.
- keycloak mode: `kc.py client ood https://<OOD>` (confidential, auth-code + PKCE only, redirect `<OOD>/oidc`,
  post-logout `<OOD>/*`; secret → `/etc/ood/oidc-client.secret`), crypto passphrase in `/etc/ood/oidc-crypto.passphrase`,
  `ood_portal.yml` mode 0600. Apache reads Keycloak's metadata on `127.0.0.1`; `preferred_username` = LDAP uid = the
  Linux user. Logout: `/oidc?logout=https://<OOD>/`.
- `OOD_ADMIN` (local `admin`, not in LDAP) becomes a **local Keycloak user** (`kc.py local-user`, password asked once)
  instead of htpasswd: still the way in when LDAP is down.
- **Checked** (throwaway Keycloak with the real LDAP, no root): `kc.py client` twice (created/updated, secret file 0600);
  `local-user` (too-short password refused; created; second run "exists"; the script's exists-check with pipefail);
  a full browser-style login against client `ood` (login page → redirect to `https://localhost/oidc?code=…` →
  code + secret + PKCE → id_token `iss=https://localhost/auth/realms/aistack`, `aud=ood`, `preferred_username=admin`);
  wrong redirect_uri → 400; wrong secret → refused; password grant for `ood` → refused. Both `OOD_AUTH` modes render a
  valid `ood_portal.yml` and pass OOD's generator (OIDC block, `Redirect /logout`).
- Found: Keycloak 26 client secrets are 86 characters; `lastName "(local)"` is rejected by Keycloak's name validation.
- A test extraction accidentally ran the rest of `setup-ood.sh` as `admin` (no root): every write failed, nothing changed
  (httpd start time and OOD files unchanged, checked).
- **Not checked:** Apache + mod_auth_openidc for real (needs root), logout redirect, an LDAP user's browser login.
- **Switched on (admin, 2026-10-07):** `OOD_AUTH=keycloak`, `setup-ood.sh` (asked once for `admin`'s new local
  Keycloak password). **Browser login PASS:** `https://localhost` → Keycloak page → LDAP user → OOD dashboard.
  MLflow still asks for its own password (step 2c).

## 2026-10-07 — Step 2c: MLflow web UI through OOD's login (written + tested without root)

- **No new proxy needed:** `MLFLOW_PREFIX` was already `/node/<MASTER_IP>/<MLFLOW_PORT>`, so OOD's own `/node` proxy
  reaches MLflow. With Keycloak that path is logged in, and OOD's Lua handler sets `X-Forwarded-User` (overwriting any
  value the browser sends).
- **Trust only Apache:** `image/ldap_auth.py` accepts `X-Forwarded-User` only with `X-MLflow-Proxy-Secret` = the
  secret in `MLFLOW_DATA/proxy.secret` (constant-time compare, Linux-name check, first use creates the MLflow user).
  `2-deploy.sh` makes the secret; `setup-ood.sh` (keycloak mode) adds it in a `<Location "$MLFLOW_PREFIX">` that
  Apache merges with OOD's `/node` `<LocationMatch>`, so only MLflow's path gets it. Tokens, LDAP password and the
  admin password on the port work as before. Image tag `…-ldap` → `…-sso` (a changed image never moves a tag).
- The two "Open MLflow" buttons (MLflow page, Model Hub) link through OOD when `OOD_AUTH=keycloak`, else as before.
- **Checked:** private Apache (non-root, port 18080) with **OOD's real `node_proxy.lua`** + an echo backend: MLflow's
  path gets user + secret; a faked `X-Forwarded-User: admin` + guessed secret are overwritten; another `/node` app
  gets **no** secret; not logged in → 401. Test MLflow 3.15.1 (current image + new `ldap_auth.py`, `NO_PERMISSIONS`):
  right secret → 200; wrong / missing secret, bad name, no user → 401; admin password → 200; ankush's experiment
  → ankush 200, rakesh **403**; UI page through the header → 200. Both button modes render (ldap = old link).
- **Note:** the local `admin` Keycloak user maps to MLflow's `admin` (MLflow superuser) through OOD. Same person
  (the cluster admin), but worth knowing.
- **Not checked:** the real chain (Keycloak + Apache + the new image) as root.
- Admin run: build (`3.15.1-sso`), deploy, setup-ood, MLflow page OK; `7-install-ood-app.sh` failed: `NameError: true` (I wrote the JSON literal `true` inside the Python heredoc) → fixed to `"$OOD_AUTH" == "keycloak"`, block rerun with real values → `sso: True`.
- **MLflow SSO PASS (admin, 2026-10-07):** after `7-install-ood-app.sh` + Restart Web Server, OOD login with Keycloak → **Open MLflow** opens with no second password. **Step 2 (one login) done:** OOD + MLflow + Model Hub behind Keycloak; jobs keep their tokens.

## 2026-10-07 — Step 3: per-user limits (GPUs, run time), 2-GPU models, queue position (written + tested without root)

- **Config:** `site.conf` `USER_GPU_QUOTA=1`, `ENDPOINT_HOURS_DEFAULT=24`, `ENDPOINT_HOURS_MAX=96` (replaces
  `ENDPOINT_HOURS`). One person: `2-sync-users.sh bob --gpus 2 | --max-hours 240 | --reset`, `--show` = table. Stored as
  namespace labels `aistack/gpus`, `aistack/max-hours`, `aistack/custom-limits` (users can't change their namespace);
  exceptions survive reruns and changed defaults. GPU limit = the ResourceQuota (per user now); max hours also as a
  quota annotation so the app can read it (users can read, not write, their quota).
- **Cluster rule** `pod-has-time-limit` (in `onboarding/uid-policy.yaml`, applied by `1-setup.sh`), user namespaces,
  CREATE only: needs `slurmjob…/timelimit` (whole minutes > 0) ≤ `max-hours`×60, and `exclusive: "false"`.
  **Closes a real hole:** a pod without the annotation got the partition's limit (365 days) and, without
  `exclusive: false`, the whole node. CREATE only: Slurm takes the limit at creation, and checking updates could
  block slurm-bridge's cleanup of older pods.
- **2 GPUs:** `render.py` `gpus` 0..8, vLLM `--tensor-parallel-size N` when N > 1; the deploy form offers 1..limit
  GPUs for LLMs. **Not testable here** (1 A30 per node); needs the H100 nodes.
- **Queue:** a waiting endpoint shows "waiting for a free GPU (number N in the queue)" (squeue, partition, priority
  order; `PrivateData=none` here, so every job is visible).
- **Checked:** policy in a temporary namespace + test binding (deleted after): 1 day / 4 days ok; 5 days, no limit,
  `1-00:00:00`, 0, exclusive missing/true, namespace without max-hours → refused with clear messages; a 240 h exception
  allows 5 days. `2-sync-users.sh` per-user block against the API server (dry run): default, `--gpus 2`, kept on rerun,
  `--max-hours` on top, `--reset`, changed default; `--show` on the real namespaces; `render.py --test`; backend with
  stubs (limits from quota; 3 GPUs / 241 h / 2 GPUs or 97 h for a default user → 400 with a hint; queue message);
  `3-test-tenancy.sh` pods now carry a 10-min limit, plus 4 new policy checks.
- **Not checked:** the real `1-setup.sh` + `2-sync-users.sh` run as root, the UI in a browser, a real 2-GPU pod.
- **Admin run PASS (2026-10-07):** `1-setup.sh`, `2-sync-users.sh` (`--show`: everyone 1 GPU / 96 h), `3-test-tenancy.sh` incl. the time-limit checks, `7-install-ood-app.sh`; the deploy form shows the limits and refuses over the max. **Step 3 done.**

## 2026-10-07 — Step 4: gateway + personal API keys (written + tested without root)

- **Choice:** nginx + a small key checker of ours (`5-model-hub/gateway/auth.py`, stdlib), not LiteLLM: LiteLLM speaks
  only OpenAI-style LLM calls; we need ML/DL `/invocations` too and per-endpoint owner/sharing rules.
- **Shape:** one pod in ns `model-hub` on master (nginx 1.30.5 unprivileged + python 3.12.15, both mirrored, uid 101,
  read-only root), Service LoadBalancer `GATEWAY_IP:443` (MetalLB, `.205` here), certificate from a self-signed
  Rudra CA (cert-manager) unless `GATEWAY_TLS_SECRET`. URL `https://<gw>/<owner>/<endpoint>/<path>`; nginx
  `auth_request` → auth.py → 200 / 401 / 403. Streaming passes through (buffering off), 100 MB bodies, 600 s timeouts.
- **Keys:** `mh~<user>~<48 hex>`, made in Model Hub (new **API key** page; shown once); only the SHA-256 is stored, as
  Secret `model-hub-key` in the user's own namespace. Gateway reads it via a ClusterRole bound per user namespace
  (`user-ns.yaml`). For vLLM the gateway adds the endpoint's own key; callers never see it.
- **UI:** API tab now leads with "From anywhere" (gateway URL, header, CA download, curl + Python/OpenAI examples);
  ssh-tunnel instructions removed; the direct ClusterIP section stays for in-cluster use.
- **Two holes found while testing, fixed:**
  1. **Path traversal:** auth checked `$request_uri` but nginx routes on the normalized path, so
     `/ankush/churn/../../test/theirs/x` reached test's model with ankush's key. Now auth checks `/$owner/$ep$rest`
     (what nginx routes to); raw `..`, `%2e%2e` and `//` variants all → 403.
  2. **ExternalName/selector tricks:** users can create Services in their namespace; one pointing elsewhere would be
     followed. auth.py now accepts only Services shaped like render.py's (ClusterIP, selector `app: <name>`).
- **Checked:** auth.py unit tests (15 cases); the real nginx image + auth.py against a mock k8s API and an echo model:
  owner ML/LLM 200 (vLLM key injected, caller key not forwarded), no/wrong key 401, other's/unknown 403, bad address
  404, query strings kept, 20 MB body, **streaming arrives token by token** (1 s apart), JSON access log; both
  containers as uid 101 with read-only root; all manifests accepted by the API server (dry run); UI screenshots
  (API key page, API tab, deploy form) against a mock backend.
- **Not checked:** the real deploy (MetalLB IP, cert-manager certificate, cluster DNS to a real endpoint, RBAC),
  a call from a laptop.
- **CA download failed in the browser** ("check internet connection"): `gateway-ca.crt` was in `public/`, served as `application/x-x509-ca-cert`, which Chrome tries to install instead of saving. Now the file sits next to the app and `GET api/gateway-ca` sends it as `application/octet-stream` + `Content-Disposition: attachment` (checked via WSGI: 200 + headers; 404 with a message when there is no file). Admin: rerun `7-install-ood-app.sh`.
- **Step 4 PASS (admin, 2026-10-07):** `8-gateway.sh` (IP `.205`, cert ok), key made in Model Hub, call with the key works **on the cluster** and **from the laptop** (test cluster: through `ssh -J … -L 8443:192.168.40.205:443` + `curl --connect-to 192.168.40.205:443:localhost:8443`, because `192.168.40.x` is private behind the jump host; on a customer rack the gateway IP is on their network). **Step 4 done.**

## 2026-10-07 — Step 5: sharing (people, teams, everyone) (written + tested without root)

- **Teams:** LDAP had only personal groups (posixGroup, no members), so `1-ldap/group.sh` (create / add / remove /
  delete / list): a team = `groupOfNames` without `posixGroup` (not a Linux group, no file rights). Each person's teams
  are copied by `2-sync-users.sh` to annotation `aistack/teams` on their namespace (users can't edit it); `group.sh`
  re-syncs the people it changed. So the gateway needs no LDAP client and no new image.
- **Rules on the endpoint:** Service annotations `model-hub/share-users`, `model-hub/share-teams`, `model-hub/share-all`
  (go away with the endpoint; only the owner can change them). Model Hub: **Share** button (only me / chosen people
  and teams / everyone), team picker from LDAP, the URL to send, badge in the list; unknown users/teams refused.
- **Gateway:** `auth.py` allows owner, listed users, members of listed teams (caller's namespace annotation), or
  everyone; callers use their own key; vLLM key added as before. New ClusterRole `model-hub-gateway-teams` (get
  namespaces, cluster-wide: names/labels/annotations only).
- **Checked:** auth.py 21 cases (by name, by team / not in team, everyone, `alicex` ≠ `alice`, owner's vLLM key for a
  shared call, not shared → 403); backend `set_share` (people + team saved, own name dropped, unknown user / team / bad
  name refused, the exact `kubectl annotate`); `teams()` against the real LDAP (none yet); group.sh read paths
  (personal group is not a team); namespace with `aistack/teams` accepted (server dry run); UI screenshots (dialog,
  badges).
- **Not checked:** group.sh writes (need root), the real gateway with a shared call between two users.
- **Left for later:** a "Shared with me" list in Model Hub (users can't list other namespaces; needs either a
  gateway-side listing authenticated by the user's cluster certificate, or an index). For now the owner sends the URL
  from the Share dialog.
- **"Shared with me" added (2026-10-07):** users can't list other namespaces, so the gateway answers. Model Hub calls
  `https://<GATEWAY_IP>:8444/shared` with the user's **cluster client certificate** (`~/.kube/aistack.config`, CN = user,
  signed by the cluster CA, written to a private temp dir for the call). nginx's second listener (8444, mTLS, cluster
  CA from ConfigMap `kube-root-ca.crt`, `ssl_verify_client on`) passes the CN to auth.py, which lists user namespaces,
  their endpoint Services and `endpoints` (running or not) and returns what that user may call (not their own).
  Separate port so browsers on 443 never get a certificate prompt. RBAC: + `list` services (per user namespace),
  `get` endpoints, `list` namespaces. UI: a section under My endpoints (owner, state, URL copy, "How to call" with
  the user's own key). **Checked:** auth.py tests (alice 3, carol 2, bob 0 = never own); real nginx with test CA:
  alice's cert → her list, admin-style cert (`O=…,CN=kubernetes-admin`) → `[]`, no cert / same name from another CA
  → 400, other paths on 8444 → 404, `/shared` on 443 → 404, 443 needs no cert; the backend's real
  `shared_with_me()` with a kubeconfig like `2-sync-users.sh` writes → nginx → auth.py → mock k8s → list; screenshot.

## 2026-10-07 — Model Hub UI redesign (plain words, cleaner layout)

- **Why:** the screens showed internal terms (`namespace u-rakesh`, `models:/churn/3`, Slurm, pods) and every element
  had the same weight, so it didn't look like a finished product. A shared-endpoint user (rakesh) also couldn't see
  where `gateway-ca.crt` comes from: the "How to call" popup used `--cacert` but had no download link.
- **What changed** (`5-model-hub/ood-app/model_hub/`: `public/app.js`, `public/style.css`, `index.html`; still
  Bootstrap 5.3, no new libraries, backend untouched):
  - **Words:** plain status (Ready / Starting / Waiting for GPU / Failed / Stopped), "Stops in 20h 29m", "Updated 2
    days ago", model shown as `churn · v3`; tabs **Try it / Use the API / Logs**; "Run" instead of "Predict";
    "Create key / Replace key". Waiting/failed/stopped endpoints get a one-line banner (e.g. "You're number 2 in line.
    It starts by itself") and **Deploy again** when stopped.
  - **Layout:** readable nav with a clear current page + user avatar; model page = fact tiles + Deploy in a sticky
    panel on the right, extras under "Technical details"; endpoint rows fully clickable with a soft status pill and
    one meta line; API tab = 3 numbered steps (your key → download certificate → curl/Python), in-cluster address
    under "Advanced"; API key page shows status and the same steps.
  - **Shared endpoints:** "How to use" opens the same 3 steps, with the certificate download button (one file for
    every user, whoever owns the endpoint).
- **Checked:** mock backend + headless Firefox screenshots of every page (light, dark, 390 px phone width);
  `node --check`. **Installed on master (admin, 2026-10-07)** with `7-install-ood-app.sh`: looks right in the real
  browser. Old UI backup deleted on request.

## 2026-10-07 — Sharing showed up late for the other user

- **Why:** after Share, the other user waited up to ~90 s: the gateway cached every k8s lookup (share annotations,
  keys, the "Shared with me" listing) for 60 s, and the Model Hub page fetched "Shared with me" at most every 30 s.
  Also a bug: coming back to My endpoints within 30 s left the "Shared with me" spinner until the 30 s passed.
- **What changed:** gateway cache 60 → 5 s (`5-model-hub/gateway/auth.py` default, `gateway/gateway.yaml` env);
  also makes a revoked key / removed share stop working within 5 s. `public/app.js`: "Shared with me" loads at once
  when the page is drawn, then every 10 s.
- **Checked:** `auth.py --test` ok, `node --check` ok. Not yet on the cluster.
- **Admin:** rerun `8-gateway.sh` (new env → gateway pod restarts) and `7-install-ood-app.sh`.
- **Step 5 PASS (admin, 2026-10-07, in the UI):** ankush shared endpoints with a person, a team and everyone;
  rakesh and test each saw exactly what was shared with them under "Shared with me". **Step 5 done.**
  (Calls with rakesh's / test's own key to a shared endpoint: worth one curl when convenient.)

## 2026-10-07 — Step 6: v1 leftovers removed

- **Why:** the gateway (step 4) and sharing (step 5) replace v1's ways in; the old ones contradicted "the gateway is
  the only way in" and "model files: private or public, set by the owner" (step 6b).
- **What changed:**
  - `model-register`: `--public` removed (it registered as the MLflow admin from root). Always runs as the user,
    root refused; admins register base models as themselves. `1-setup.sh`: hint updated, unused `@MLFLOW_DATA@` dropped.
  - Model Hub API tab: "Advanced: call it directly from inside the cluster" removed (ClusterIP URL, the endpoint's own
    vLLM key with Show/Copy, direct curl). Backend route `GET api/endpoints/<n>/key` removed, so no endpoint key
    reaches the browser any more. The playground still calls server-side (backend adds the key).
  - `5-model-hub/README.md`, `3-mlflow/3-sync-tokens.sh` comment updated.
- **Kept on purpose:** the READ-grant loop in `3-sync-tokens.sh` (tag `public=true`): step 6b reuses it. Existing
  public base models (registered with the old `--public`) keep working.
- **Checked:** `node --check app.js`, `py_compile passenger_wsgi.py`, `bash -n` on the scripts, `model-register --help`;
  no removed variable still used in the API tab. Not yet: screenshot / real browser.
- **Admin:** rerun `1-setup.sh` (installs the new `model-register`) and `7-install-ood-app.sh`.
- **Still to do for step 6:** the end-to-end test (train → register → deploy → share → colleague calls from laptop)
  for one ML, one DL, one LLM model.

## 2026-10-07 — MLflow (shared) page: same look as Model Hub

- **Why:** the MLflow OOD page used its own plain style and a "Dashboard" button; it should look like Model Hub and
  link to it.
- **What changed:** `3-mlflow/ood-app/mlflow_k8s/passenger_wsgi.py` only. It loads Model Hub's Bootstrap, icons and
  `style.css` from `/pun/sys/model_hub/` (no copies), with the same navbar, user avatar and dark-mode toggle (shares the
  `mh-theme` setting). Status shown as OK/Problem pills, tracking URI as numbered steps with Copy. Buttons: **Model Hub**
  + **Open MLflow**; Dashboard button removed. Needs Model Hub installed (otherwise the page shows unstyled).
- **Checked:** mock server + headless Firefox screenshots (desktop, 390 px phone width).
- **Installed on master (admin, 2026-10-07)** with `3-mlflow/4-install-ood-app.sh`: works in the real browser.

## 2026-10-08 — Step 6 end-to-end test: DL passed

- **DL PASS (admin, 2026-10-08):** train → register → deploy → share → colleague calls from laptop, all from the browser.
- **Still to do:** LLM full run (vLLM runtime, `/v1/chat/completions` + streaming, files from `~/models`); ML quick
  check only (deploy + one call; sharing/gateway are the same code as DL).
- **Admin reminder:** `/home/apps/bin/model-register` on master was still the old one (with `--public`): rerun `1-setup.sh`.

## 2026-10-08 — Check: private ML/DL files can't be read by other users (PASS)

- **Why:** before 6b, check that MLflow really checks permissions on file downloads, not just on the model entry
  (older MLflow didn't check the artifact proxy). ML/DL files live in `MLFLOW_DATA/artifacts` (mode 700, `mlflow`),
  so the server is the only way in.
- **Checked (admin, as rakesh, on ankush's private `test-model-DL` v1):** download by `models:/test-model-DL/1`,
  download by the exact path `mlflow-artifacts:/1/models/m-…/artifacts`, list `mlflow-artifacts:/` and
  `mlflow-artifacts:/1/models`: all **403 Permission denied**. Owner (ankush) can read it. **PASS.**
- Note: MLflow says 403 for a model that doesn't exist too (looks like a permission error).

## 2026-10-08 — Step 6b: public models (written + self-tests; not yet on the cluster)

- **Why:** owners make a model private or public (everyone), replacing v1's admin-only `--public`. Reviewed first;
  fixes are in build-plan 6b ("Safety"). New finding while reading MLflow 3.15's auth code: a file download is checked
  against the **experiment** the files are in, not the model. So READ on someone's model is not enough to deploy or
  download it → public models get a **copy** of their files (ML/DL too, not only LLMs).
- **What changed:**
  - new `5-model-hub/public-models.py` (root, systemd timer every minute, installed by `1-setup.sh` step 7): copies
    (ML/DL → experiment `model-hub-public`; LLM → `MODELS_ROOT/public/<owner>/<model>/v<N>`, read as the owner),
    version tags `public_copy` / `public_status`, model tag `owner`, READ grants for everyone (after the copy),
    revokes + deletes copies when private. Owner's own `path` tag is never touched.
  - `3-mlflow/3-sync-tokens.sh`: the old READ-grant loop removed (the timer does it, and also revokes).
  - `passenger_wsgi.py`: someone else's public model uses the public copy (LLM folder / ML-DL `download_uri`); clear
    message while it's still copying or failed; `POST api/models/<name>/public` (owner only: MANAGE, checked with
    MLflow's `users/current/permissions`); model card has `public`, `owner`, `mine`, `can_manage`, `public_status`.
  - `render.py`: init container downloads `download_uri` when given (endpoint still listed as `models:/<name>/<v>`);
    tests for that and for no `--trust-remote-code`.
  - `app.js`: "Public" badge (+ "by <owner>") in the list and on the model page; owner card "Who can use this model"
    with Make public / Make private + copy status (refreshes itself while copying); confirm dialogs say what happens
    (all versions, copy size, downloaded files stay, running endpoints keep running); others see a warning on ML/DL
    ("runs <owner>'s code") and a Download line. Delete-endpoint dialog now uses the same confirm helper.
  - READMEs updated.
- **Checked:** `public-models.py --test`, `render.py --test`, `py_compile`, `node --check`, `bash -n`; UI with a mock
  backend + headless Firefox. Not yet: the timer against the real MLflow (needs root).
- **Admin:** `sudo bash 5-model-hub/1-setup.sh` (installs model-register + the timer; shows the timer's first run),
  then `sudo bash 5-model-hub/7-install-ood-app.sh` and Restart Web Server.
- **Installed on master (admin, 2026-10-08):** `1-setup.sh` (timer enabled, first runs exit 0, every LDAP user with an
  MLflow account got READ on `model-hub-public`; `MODELS_ROOT/public` made) and `7-install-ood-app.sh`.
  `1-setup.sh` printed "model-register still has an unfilled @VAR@": false alarm (the check matched bash's `${args[@]}`);
  check now looks for `@NAME@` only. Next: the 6b test in the browser.
- **Fix (before the test):** an LLM registered from `MODELS_ROOT` (e.g. a base model) was skipped by
  `public-models.py` without tags, so others would wait on "still being copied" forever. It now tags it
  `public_copy` = its own folder, `public_status=ready` (no copy needed). Admin: rerun `1-setup.sh`.

## 2026-10-08 — Model page: Download button (to my computer / to my cluster home)

- **Why:** users had to type an `mlflow artifacts download` command (and the right MLflow version: master's own
  `/usr/local/bin/mlflow` is 3.1.4, the server 3.15.1). Now one button.
- **What changed** (`ood-app/model_hub/`: `passenger_wsgi.py`, `public/app.js`; no new libraries): a Download card
  under Deploy, for every model the user can see (not the owner's own chat model: it's in their home already).
  - **To my computer (.zip):** ML/DL; the backend lists the files with MLflow's artifact API and streams a zip
    (stdlib `zipfile`, nothing kept on the server). Chat models: not offered (too big; use the home copy + OOD Files).
  - **To my cluster home:** any model, into `~/model-downloads/<model>/v<N>`. Runs in the background (a detached
    `passenger_wsgi.py --fetch`), so a big LLM doesn't time out; the card shows Downloading… / In your home folder /
    the error, and refreshes itself.
  - Everything runs as the user with their own MLflow login, so it can't fetch more than they may read.
- **Checked:** against a fake MLflow server: zip has the right files and bytes; home copy completes, `.pid` removed;
  a failing file shows "Download failed: …" and a retry starts again. `py_compile`, `node --check`, screenshots.
- **Admin:** `7-install-ood-app.sh`, then Restart Web Server.
- **Fix:** rakesh didn't see the Download card after the install: his browser kept the old `app.js` (OOD's nginx
  serves `public/` with no cache rule, so browsers cache it heuristically). `index.html` (never cached) now loads
  `app.js?v=<file time>` and `style.css?v=…`, so every install reaches users at once. Workaround: Ctrl+Shift+R.

## 2026-10-08 — Progress bars: sharing a public model, downloading to the cluster home

- **Why:** a big LLM takes minutes; "Sharing the files…" / "Downloading…" said nothing about how far along.
- **What changed:** real bytes, no fake bar.
  - `public-models.py`: while copying, every 5 s (`TICK`) it measures the half-done copy and sets the version tag
    `public_status = copying <done>/<total>`; `copy()` moved to the top level so the self-test runs a real copy (as
    the current user, `runuser` stripped); tar's errors go to temp files (pipes could fill up and hang).
    Bug found by that test, fixed before it shipped: a local `du` hid the `du()` function → first progress update crashed.
  - `passenger_wsgi.py`: Make public sets every version to `public_status=waiting`, so an old "ready" from an earlier
    public period doesn't show before the new copy. Download: `fetch` writes `<dir>.total` first (sum of MLflow's file
    sizes, or the folder size); the state call returns `done` = size of `<dir>.part`. Shared `du()` helper.
  - `app.js`: `progressBar()` ("Sharing the files · 37% · 1.5 GB of 4.0 GB", "Downloading · 43% · …"), striped bar until
    the total is known; "Waiting to start (within a minute)" before the timer picks it up; owner card refreshes every 5 s.
- **Checked:** `public-models.py --test` (real copy + progress + failure), download against a fake slow MLflow (done
  only grows, total fixed, helper files removed), `node --check`, `py_compile`, screenshots of both bars.
- **Admin:** `1-setup.sh` (new timer script) + `7-install-ood-app.sh`, Restart Web Server.

## 2026-10-08 — Step 6b test (admin, in the browser): DL model PASS

- **DL PASS:** ankush made `test-model-DL` public → rakesh saw it ("Public · by ankush"), downloaded it **to his
  computer (.zip)** and **to his cluster home**; download buttons and progress bars work. ankush made it private →
  rakesh's downloads failed at once; the model left his list after ~1 minute + a page reload.
- **Why the delay is normal:** "private" is a tag (instant); the timer (every minute) revokes READ and deletes the
  copy. Others' open pages don't refresh themselves. For the DL model, downloads stop at once (Model Hub then points
  at the owner's own files, which MLflow refuses); for an LLM in `MODELS_ROOT/base` nothing stops at once, because
  that folder is readable by everyone on disk.
- **Known limit:** an LLM registered from `MODELS_ROOT/base` is hidden in Model Hub when private, but its files stay
  readable on disk by every user. Really private LLMs belong in the owner's `~/models`.
- **Still to do:** the LLM (`qwen3.5-0.8b-ankush`) and ML runs of the same test. Option (not built): Make private also
  revokes READ at once, from the owner's own login (MANAGE allows it); the timer would only delete the copy.

## 2026-10-08 — Models list: All / Public / Private filter

- `app.js` only: a dropdown next to the search (below it on a phone): All models | Public | Private (only you).
  Works together with the search and the model count. Checked: `node --check`, screenshots (desktop, 390 px).
- **Admin:** `7-install-ood-app.sh`, Restart Web Server.

## 2026-10-08 — rakesh's training job: MLflow 401 after a password change

- **Why:** `~rakesh/.mlflow/credentials` held his old LDAP **password** (hand-written or from an early script), not the
  random job token. MLflow accepts LDAP passwords too, so `3-sync-tokens.sh` saw it "working" and left it alone.
  `1-ldap/passwords.sh` changed the password → the file stopped working → `mlflow.set_experiment` got 401 in the job.
  (A real token survives password changes; that's the design.)
- **What changed:** `3-mlflow/3-sync-tokens.sh` keeps a file's value only if it is our token (48 hex chars) and works;
  anything else is replaced by a new token. Also stops LDAP passwords sitting in plain files.
- **Admin:** `sudo bash 3-mlflow/3-sync-tokens.sh` (replaces every such file; `token` in the output = replaced).
- **Real cause (found 2026-10-08):** not the token. **cn01 has a local `/etc/passwd` line `rakesh:…:1010:1010::/home/ankush`**
  (made by hand some time ago). `nsswitch` is `files sss`, so on cn01 the local line wins over LDAP
  (`/home/rakesh`, correct). Apptainer mounts the passwd home, so inside the job `~` was `/home/ankush` → no
  `~/.mlflow/credentials` (and rakesh can't read ankush's 700 home) → MLflow sent no login → 401. Master is right
  (its local line says `/home/rakesh`). Checked: same inode for `/home/rakesh` on both, NFS fine, admin's homes mount
  fine in Apptainer on cn01. cn02 not checked (srun there didn't start).
- **Fix (admin, root on cn01):** `userdel rakesh` (NO `-r`: it would delete his real home on NFS), `sss_cache -E`,
  `getent passwd rakesh` → `/home/rakesh`. Local copies of LDAP users (ankush on cn01, ankush/rakesh on master)
  should go too: they hide LDAP (wrong data, and a local password still works after `passwords.sh`).
  `import-local-users.sh` only adds to LDAP, by design; KEEP_LOCAL is `admin`.

## 2026-10-08 — `1-ldap/menu.sh`: one menu for users, passwords, teams, checks, setup

- **Why:** the LDAP tasks were six scripts with arguments to remember; and the rakesh 401 above came from a local
  account hiding LDAP on cn01, which nothing checked.
- **What changed** (`OOD-Install/1-ldap/`): new `menu.sh` (whiptail, like the old password menu). People: list
  (UID, home, teams), add (`add-user.sh`), set / test a password. Teams: list, create, members as a checklist, delete
  (`group.sh`). **Check:** LDAP answers, this node sees LDAP, and every node's `/etc/passwd` vs LDAP (over `ssh root@`):
  local copies of LDAP people listed, the ones with a different home ticked; remove = `userdel` without `-r`, subuid /
  subgid ranges put back. Setup: `1-server.sh`, `2-client.sh` (this node or over ssh), `import-local-users.sh`
  (dry run first). `passwords.sh` removed (its code is in the menu). README updated.
- **Checked** (no root here): `bash -n`; people list and team columns against the real LDAP; local-copy check on
  master's real `/etc/passwd` and a simulated cn01 (`rakesh … /home/ankush` flagged, unreachable node reported).
  Not yet: the screens themselves, as root.
- **Fix:** run on cn01, the menu showed an empty people list and `Can't contact LDAP server (-1)` (the LDAP server and
  the Directory Manager password are on master only). It now stops at once: "Run this on master …", and if LDAP
  doesn't answer on master it says so (`systemctl status dirsrv@…`). Other nodes are handled from master over ssh.

## 2026-10-08 — MLflow page: experiment naming (`<user>/<name>`) and "If something goes wrong"

- **Why:** rakesh's job then got `403 Permission denied` on `mlflow.set_experiment("mnist-ddp")`: experiment names
  are global and the first user owns one, but nobody can see others' experiments, so nothing told him. The fix that
  worked: his own name (`mnist-ddp-$USER`). Usernames are unique, `/` can't be in one → `<user>/<name>` never clashes.
- **What changed:** `3-mlflow/ood-app/mlflow_k8s/passenger_wsgi.py`: step 2 "Name your experiment": why in one sentence,
  a name box with `<user>/` in front, live copy-ready lines (`mlflow.set_experiment("<user>/<name>")` and
  `export MLFLOW_EXPERIMENT_NAME="<user>/<name>"`); new card "If something goes wrong" (403, 401, connection) in plain
  words. Copy buttons share one handler. `WORKFLOW.md` §5 explains the rule. Model Hub `style.css`: code blocks keep
  room for the Copy button on phones (it covered the text).
- **Checked:** page served locally (fake site.json, Model Hub's CSS), rendered script passes `node --check`;
  screenshots light, dark, 390 px. Bug caught on the way: a lost backslash broke the page's script; quoting now
  uses `JSON.stringify`.
- **Admin:** `sudo bash 3-mlflow/4-install-ood-app.sh` + `5-model-hub/7-install-ood-app.sh` (CSS), Restart Web Server.
- **Not done (offered):** the shared training templates in `/home/apps/Containers-CDAC/1-test-scripts/` still use
  `--experiment=mnist-ddp`.
- **Trimmed (user feedback, same day):** too much for a customer. Name box removed: step 2 is one sentence + two
  static examples (`<user>/my-experiment`, Python and `export`). "If something goes wrong" = only 401 / 403 / 404 /
  connection: what it means and the likely cause. No admin commands or backend names anywhere on the page (status rows
  now say "Contact your administrator"; checked: no `kubectl`, `sync-tokens`, `3-mlflow` in the HTML).

## 2026-10-08 — Fix: Models filter did nothing; chat models listed as "Model"

- **Filter:** the dropdown had `id="who"`, already used by the navbar's user avatar; `$('#who')` found the avatar, so
  the filter never filtered. Renamed to `#show`; no other id in `index.html` is reused by `app.js`. My earlier
  screenshot only showed "All models": now checked with the filter set (Private → only own private models, Public →
  only public ones).
- **Chat models:** the list looked for `path` on the **model**'s tags, but `model-register` puts it on each **version**
  (the mock had it on the model, so it hid the bug). Backend `list_models` now sets `llm` from the latest versions' tags
  (MLflow includes them); `app.js` uses it for the icon and "Chat model".
- **Admin:** `7-install-ood-app.sh`, Restart Web Server.
- **Installed on master (admin, 2026-10-08):** MLflow page (`3-mlflow/4-install-ood-app.sh`) and the Model Hub filter
  + chat-model fix (`7-install-ood-app.sh`): both work in the real browser.

## 2026-10-09 — MLflow page: chat-model notice + one "Questions" FAQ; Model Hub help points to it

- **Why:** an LLM only works in Model Hub if it is a full HF folder (LoRA merged) under `~/models/`, registered with
  `model-register` (the version's `path` tag). Nothing told users; `mlflow.transformers.log_model` looks like it works
  and doesn't. Guidance was also spreading over several cards, so it now lives in one FAQ.
- **What changed:** `3-mlflow/ood-app/mlflow_k8s/passenger_wsgi.py`: yellow notice under "Use it in your jobs"
  ("Training a chat model? … Show me how" → `#faq-llm`). "If something goes wrong" card replaced by a **Questions**
  accordion (Model Hub's Bootstrap bundle, same look as its help page): where to keep files (a `/home/<user>/` tree:
  `projects/`, `models/<name>/v1`, `model-downloads/`; only `models/` is a rule), why `<user>/` experiment names,
  how to get ML/DL into Model Hub, how to get a chat model in (save/merge → `model-register` → Deploy, with the
  `log_model` warning), chat model missing checklist, 401/403/404/connection (old text). `#faq-…` links open the answer.
  `5-model-hub/.../app.js` help page: chat-model step gets a warning + "Step by step" link to
  `/pun/sys/mlflow_k8s/#faq-llm`; ML example uses `"<user>/my-project"`; containers list adds pytorch-llm.
- **Checked:** page served locally with a fake site.json; inline scripts `node --check`; `app.js` `node --check`;
  no admin words in the HTML; screenshots desktop light, phone (390 px) dark, with answers open. Fixed on the way:
  the folder tree wrapped on phones (now scrolls). Not checked visually: Model Hub's help page (template-only change).
- **Admin:** `sudo bash 3-mlflow/4-install-ood-app.sh` + `sudo bash 5-model-hub/7-install-ood-app.sh`, Restart Web Server.

## 2026-10-09 — LLM training container (pytorch-llm) + an LLM test for the MLflow → Model Hub path

- **Why:** no container could train LLMs (pytorch-nlp has no trl/peft/bitsandbytes/DeepSpeed), and there was no
  test that takes an LLM from training through MLflow into Model Hub.
- **Container:** `/home/apps/Containers-CDAC/torch-llm/pytorch-llm-2.10-cuda-12.9/pytorch-llm-2.10.0-cuda12.9.sif`
  (5.6 GB): torch 2.10 cu129, transformers 5.19, TRL 1.14, PEFT 0.21, bitsandbytes 0.50, DeepSpeed 0.19.7, flash-attn
  2.8.1, mlflow-skinny 3.15.1, TensorBoard. Tracking needs no server (`file://` or the cluster MLflow). Reasons in its
  `.notes.txt`. `%test` passed at build and with `--nv` on cn01 (A30). First build died: transformers 5 dropped
  `TrainingArguments(logging_dir=)`.
- **Test:** `1-test-scripts/torch-llm/pytorch-llm-2.10-cuda-12.9/` (`download-data.py`, `train.py`, `run.sh`,
  `run-manual.sh`). Qwen2.5-0.5B-Instruct + Capybara, LoRA SFT, logs params/loss/perplexity/samples/adapter to MLflow,
  merges into a full HF folder, and with `--register-model=NAME` registers it **from Python** with the same tags as
  `model-register` (`path`, `format=hf`) but linked to the training run. `run.sh` uses `MLFLOW_URI` from site.conf and
  saves to `~/models/llm-sft-test/v<jobid>`. Checked: CPU dry run with a file store (run, artifacts, version + tags,
  merged folder answers prompts). Not yet: the GPU run as an LDAP user, deploy in Model Hub.
- **Found:**
  - `admin` has no MLflow job login (`3-sync-tokens.sh` covers LDAP users only): as admin, use `run-manual.sh`.
  - ankush job 1310 died in 1 s with no logs: submitted from the admin-owned test dir, so Slurm couldn't write
    `./logs`. Users must copy the test dir into their home. Job 1311: the copy's `source ../../apptainer.sh` path
    broke (absolute path needed in a copy). `sacct` is off here: use `scontrol show job <id>`.
- **Open:** the FAQ says "always use `model-register`"; registering from Python works too (above). Offered to add
  it as a second option.

## 2026-10-09 — Jupyter in OOD (7-jupyter), same as VS Code

- **Why:** users train in notebooks; there was no Jupyter, only VS Code. Researched how AI platforms do it (Run:ai
  workspaces, DGX Cloud dev pods, OOD clusters): notebook/IDE + batch jobs everywhere; a "fine-tune button" only on
  clouds and only for known models. Decided: Jupyter as a **Slurm job per user, like VS Code**. Not one shared server
  like MLflow (Jupyter runs user code, so it must run as the user); not JupyterHub (it also starts one Jupyter per
  user, and adds a second login + server that OOD already covers).
- **What changed (OOD-Install):** new `7-jupyter/` (`1-install-jupyter.sh`, `2-install-ood-app.sh`, pinned
  `requirements.txt` = JupyterLab 4.6.4 + ipykernel, `ood-app/jupyter/{job.sh,manifest.yml}`, README).
  `4-vscode/ood-app/vscode/passenger_wsgi.py` is now **one page for both** (`site.json` `"app"` picks title, icon,
  texts, Connect method); `4-vscode/3-install-ood-app.sh` writes `"app": "vscode"`. `site.conf`: `JUPYTER_*` block (at
  the end: it uses `ML_TRAIN_SIF`/`TORCH_TRAIN_SIF`). `CLAUDE.md`: layout + design line.
- **Found on the way:**
  - JupyterLab 4.6 needs Python ≥ 3.10; compute nodes have only 3.9 (master also has 3.12). So: python-build-standalone
    3.12.15 on shared `/home` + a venv (so `pip install --user` from a Python 3.12 container kernel can't break the server).
  - Jupyter's login POST needs `_xsrf` → 403 from OOD's page. OSC turns XSRF off; we use the `?token=` link instead.
  - Master has 16 quantum kernels in `/usr/local/share/jupyter/kernels` (conda envs in `/home/apps/miniconda`); Jupyter
    lists them in sessions on master only. Left as is.
  - pip from PyPI timed out once here: the installer uses `--retries 10 --timeout 60`.
- **Checked (as admin, install in a test root under ~admin, real Slurm):** installer end to end (Python download,
  venv, 3 container kernels, `jupyter lab --version` on cn01; cn02 is down). Page API → `sbatch` → session on `viewer`
  and a GPU session on cn01. Token link logs in + sets cookie; wrong token → login page; no cookie → login page.
  Kernels over websocket: venv kernel runs as the user with no `SLURM_*`; `ml-classic-cpu` container works;
  `pytorch-mlflow` container on cn01 sees the A30 and runs a matmul. Other Origin → 404. Stop → `scancel`, info file
  removed; unknown job refused. Idle (60 s test): idle kernel culled, server stopped itself, Slurm job ended.
  Screenshots desktop + 390 px. VS Code page HTML unchanged against git HEAD (only whitespace in one paragraph).
  **Not tested:** through OOD's real `/node` proxy in a browser (no OOD login for admin here).
- **Admin:** `sudo bash 7-jupyter/1-install-jupyter.sh`, `sudo bash 7-jupyter/2-install-ood-app.sh`, and
  `sudo bash 4-vscode/3-install-ood-app.sh` (the shared page needs `"app"` in VS Code's `site.json`), then Restart Web Server.

## 2026-10-09 — /home/apps/containers (new layout) + Jupyter finds training images by itself

- **Why:** the user moved `/home/apps/Containers-CDAC` to a backup (`/home/admin/Documents/Containers-CDAC`, git repo,
  untouched) and wanted one standard container folder for the AI Factory that Jupyter picks up as it grows.
- **What changed:**
  - `/home/apps/containers/` (66 GB, copied from the backup without `uv-cache/` ~90 GB, job logs, run output):
    `README.md` (rules + every image, status, min. driver; merges old DOCS/status/Containers.md), `apptainer.sh` (the one
    place its path lives; Apptainer itself stays in `/home/apps/apptainer`), `training/<family>/` (pytorch,
    pytorch-mlflow, pytorch-llm, pytorch-nlp, pytorch-vision, tensorflow, ml-classic; recipes only: tensorflow-nlp,
    tensorflow-vision, rapids), `serving/` (vllm, sglang, llamacpp, mlflow = old standalone server), `test-scripts/`
    (same names; `SIF=` paths + `source ../../../apptainer.sh` fixed, incl. old `/home/cnidan/...` paths).
  - `site.conf`: `CONTAINERS_ROOT`; `ML_TRAIN_SIF`/`TORCH_TRAIN_SIF` point into it; `JUPYTER_KERNEL_SIFS` removed.
  - `7-jupyter/ood-app/jupyter/job.sh`: one kernel per `training/*/*.sif` at session start (per-session folder on
    `JUPYTER_PATH`, deleted at the end): a SIF copied in shows in the next session. `1-install-jupyter.sh` no longer
    writes kernels and removes the ones it wrote before. `2-install-ood-app.sh` fills `CONTAINERS_ROOT`, `APPTAINER`.
  - Docs: 7-jupyter README, OOD-Install + AI-Stack `CLAUDE.md`.
- **Checked:** all 11 SIFs same size as the backup; all 7 training SIFs have ipykernel (rule holds); every test
  script's `SIF=` exists (except below); `bash -n`. Real session as admin with the installed Jupyter: 7 container
  kernels, all on the new paths (they win over the stale same-named ones still in `/home/apps/jupyter` until
  `1-install-jupyter.sh` reruns); sklearn and TensorFlow kernels ran code; Stop removed the kernels folder.
  `model-register` rendered from the new site.conf differs from the installed one only in the SIF path.
- **Found:** first test session died at once: `job.sh` unsets `SLURM_*` before the kernel loop used `SLURM_JOB_ID`
  (fixed: folder name from the info file path). `test-scripts/serving/llamacpp/run.sh` names
  `llamacpp-b10254-cuda13.3.sif`, which exists nowhere (also not in the backup); left for the user.
- **Broken until the admin reruns:** `model-register` (runs in the old ml-classic path). **Admin:**
  `sudo bash 5-model-hub/1-setup.sh`, `sudo bash 7-jupyter/1-install-jupyter.sh`, `sudo bash 7-jupyter/2-install-ood-app.sh`,
  Restart Web Server. `4-images.sh` needs no rerun (same SIF contents, same pins).

## 2026-10-09 — every training image carries mlflow-skinny; pytorch-mlflow is now "pytorch"

- **Why:** user decision: only keep training SIFs that can track to MLflow out of the box.
- **Checked first:** `mlflow-skinny` per training SIF: yes in ml-classic, pytorch-mlflow, pytorch-llm (3.15.1); none in
  pytorch, pytorch-nlp, pytorch-vision, tensorflow, nor in the unbuilt tensorflow-nlp/-vision, rapids recipes.
- **What changed (`/home/apps/containers`):** old plain `training/pytorch` deleted; `pytorch-mlflow` renamed to
  `training/pytorch/pytorch-2.10.0-cuda12.9.*` (def label/help reworded, notes say so; SIF unchanged); its test dir
  now `test-scripts/training/pytorch`. SIFs of pytorch-nlp, pytorch-vision, tensorflow deleted (backup keeps them);
  their `.def`s get the pytorch-mlflow pattern: `mlflow-skinny==3.15.1` as the last package step (before the freeze),
  version assert, `MLFLOW_ALLOW_FILE_STORE=true`, `%test` import line, TRACKING help section. README rule 2 now
  requires ipykernel + mlflow-skinny. OOD-Install: `site.conf` `TORCH_TRAIN_SIF` → `training/pytorch/...`; Model Hub
  help text (`app.js`) names "pytorch" instead of "pytorch-mlflow".
- **Checked:** dry-run `uv pip install mlflow-skinny==3.15.1` inside each old SIF before deleting: only adds 21–26
  packages, changes none (the builds should resolve). `bash -n` on `%post`/`%environment`/`%test` of the 4 defs;
  `node --check app.js`.
- **Open:** user builds pytorch-nlp, pytorch-vision, tensorflow. tensorflow-nlp/-vision and rapids recipes still lack
  MLflow (README marks them). Jupyter: notebooks saved with the "pytorch-mlflow-…" kernel ask to pick a kernel once.
  **Admin:** `sudo bash 5-model-hub/7-install-ood-app.sh` (help text), on top of the earlier 1-setup + Jupyter reruns.
- **Follow-up (same day):** the 4 unbuilt training recipes (tensorflow-nlp, tensorflow-vision, rapids cuda12.4 +
  cuda13.0) got the same mlflow-skinny block; all already had ipykernel. No SIF to dry-run in, so checked by hand:
  of mlflow-skinny 3.15.1's requirements, only protobuf is pinned (7.35.1 in the TF recipes; it and
  opentelemetry-proto take <8, same as the tensorflow image that dry-ran fine). Every `training/*/*.def` now has
  mlflow-skinny; `bash -n` on their shell sections passes. README rows updated.

## 2026-10-09 — admin reruns after the containers move; two small fixes

- **Ran (admin):** `5-model-hub/1-setup.sh` → `/home/apps/bin/model-register` now runs in
  `/home/apps/containers/training/ml-classic/ml-classic-cpu.sif` (checked). `7-jupyter/1-install-jupyter.sh` → the
  old container kernels with dead paths are gone (only `python3` + master's quantum kernels left).
  `7-jupyter/2-install-ood-app.sh` → app installed (job.sh checked: new paths, kernel loop), but the script then
  failed its own last check.
- **Fixed:** that check grepped for any `${JUPYTER_...}` and hit `${JUPYTER_PATH:+...}`, a runtime variable, not an
  unfilled site value. Now it looks only for the five values envsubst fills. Verified: the installed job.sh passes,
  the raw template still fails (6 hits).
- **Fixed:** `/home/apps/containers/test-scripts/serving/llamacpp/run.sh` + `HOW-TO.txt` named
  `llamacpp-b10254-cuda13.3.sif` (exists nowhere) → `serving/llamacpp/llamacpp-v0.3.0-cuda12.9.sif` (has
  `llama-server`). Still open: its `--partition=gpu` / `--gres=gpu:2` are the old cluster's (here: `standard`, 1 GPU).
- **Admin, still to run:** `sudo bash 7-jupyter/2-install-ood-app.sh` (clean finish),
  `sudo bash 5-model-hub/7-install-ood-app.sh` (help text "pytorch"), Restart Web Server.

## 2026-10-09 — image builds: EPEL pinned to the official server

- **Found:** `pytorch-vision` build died in `%post`: `Failed to download metadata for repo 'epel' ... all mirrors
  were already tried` (404 on `d8ee…-primary.xml.xz`). EPEL's metalink handed out mirrors mid-sync; the official
  server was already on newer metadata (`e7da…`), so the requested file existed nowhere consistent.
- **Fixed:** all 14 `.def`s in `/home/apps/containers` (training + serving): right after `dnf install epel-release`,
  `dnf config-manager --save --setopt=epel.metalink= --setopt=epel.baseurl=https://dl.fedoraproject.org/pub/epel/9/Everything/$basearch/`.
  Built SIFs unchanged (only matters on rebuild).
- **Checked:** throwaway almalinux:9 build with that line: EPEL metadata loads, an EPEL package (ffmpeg-free)
  downloads, build completes. `bash -n` on every `%post`.

## 2026-10-09 — Model Hub: Download box out of the sticky column; own chat models say where their files are

- **Reported:** Download shows for some models (old test models) but not for others, e.g. ankush's `test-model-DL`.
- **Cause:** the Download card sat under Deploy in the right column, which is `position: sticky`. On a laptop
  (768 px screen) that column is ~910 px tall (830 + 80 px offset), so Download stayed below the screen edge while the
  left column scrolled, until the very end of the page. Models with little info (old test models) have a short left
  column, so nothing stuck and Download was visible. Reproduced with the installed page + a fake backend shaped like
  `test-model-DL` (DL, owner, run + metrics + library check). Separately, the owner's own chat model had no Download
  card at all by design (its files are its `~/models` folder), which looked like a bug.
- **Fixed (`5-model-hub/ood-app/model_hub/public`):** `app.js`: Download card moved to the left column (after "Who can
  use this model"), shown for every model; own chat model: "Nothing to download: files are already on the cluster, in
  `~/models/...`" + copy button + "use OOD's Files app or scp". `style.css`: Deploy is sticky only when the screen is
  ≥ 992 px wide and ≥ 800 px tall.
- **Checked:** `node --check`; screenshots with the fake backend: DL at 1366×768 and full height (Download with .zip +
  cluster home), own chat model (path + copy).
- **Admin:** `sudo bash 5-model-hub/7-install-ood-app.sh`, Restart Web Server.

## 2026-10-09 — Keycloak login page: AI-Factory name + background

- **Why:** the login page showed the old name (AI-Stack, from `CLUSTER_TITLE`) on Keycloak's default dark background.
- **Changed (`OOD-Install/6-keycloak`):** new login theme `theme/ai-factory/login` (parent `keycloak.v2`, our
  background `resources/img/bg.jpg`, dark heading because the background is light, dark mode off). `1-install.sh`
  copies it to `KEYCLOAK_DATA/themes`, mounts that read-only at `/opt/keycloak/themes`, restarts Keycloak when it
  changed. `kc.py realm` sets `loginTheme=ai-factory` and `displayName`/`displayNameHtml` = new `KEYCLOAK_TITLE`
  ("AI-Factory") in `site.conf`. `CLUSTER_TITLE` untouched (it also names OOD's cluster and the gateway CA).
- **Checked:** `bash -n`, `kc.py` parses; throwaway `start-dev` Keycloak 26.8.0 with the theme mounted, screenshot of
  the login page (background + "AI-FACTORY" heading readable).
- **Admin:** `sudo bash 6-keycloak/1-install.sh` then `sudo bash 6-keycloak/2-realm.sh`.

## 2026-10-09 — OOD look: AI-Factory name, navy top bar, no OOD branding

- **Why:** match the Keycloak login page; users should see AI-Factory, not Open OnDemand.
- **Changed (`OOD-Install`):** `site.conf`: `KEYCLOAK_TITLE` renamed `PORTAL_TITLE` (one name for OOD + Keycloak),
  new `PORTAL_COLOR="#05295d"`. `2-ood/setup-ood.sh` step 8 writes `/etc/ood/config/ondemand.d/ai-factory.yml`
  (`dashboard_title`, dark navbar, `brand_bg_color`, `disable_dashboard_welcome_message`, `custom_css_files`) and copies
  `2-ood/branding/ai-factory.css` + the Keycloak theme's `bg.jpg` to `/var/www/ood/public/ai-factory/`. The CSS hides
  the footer ("Powered by Open OnDemand", GitHub, version) and puts the background on the home page only (CSS `:has()`
  on the navbar title link, which OOD marks `aria-current="page"` only there). ldap-mode `AuthName` = `PORTAL_TITLE`.
- **Left:** favicon (OOD's icon), `<meta generator>`, the rare browser-too-old / logout texts.
- **Checked:** `bash -n`; mock page with OOD 4.2.4's own `application.css` + our CSS: home has background, other pages white, footer hidden.
- **Admin:** `sudo bash 2-ood/setup-ood.sh`, then Restart Web Server. `sudo bash 6-keycloak/2-realm.sh` once more (it now reads `PORTAL_TITLE`).

## 2026-10-09 — OOD top bar: only Files, Clusters, Interactive Apps (no Desktop)

- **Why:** users don't need Jobs, My Interactive Sessions, All Apps, or OOD's Desktop app.
- **Changed:** `2-ood/setup-ood.sh` step 8 adds `nav_bar` to `ondemand.d/ai-factory.yml`: `files`, `clusters`, and an
  "Interactive Apps" menu = every app with `category: Interactive Apps, subcategory: Servers`. Desktop is
  `subcategory: Desktops`, so it drops out; a new app with subcategory Servers shows up with no config change.
  Nothing deleted: Desktop and the sessions page still exist by URL (launching Jupyter/VS Code still lands on the
  sessions page).
- **Checked:** OOD 4.2.4's own `NavBar.items` (`bin/rails runner` with `/opt/ood/ondemand/enable`) on this config:
  Files: Home Directory | Clusters: Module Browser, AI-Stack Shell Access, System Status |
  Interactive Apps: Model Hub, VS Code, MLflow (shared), Jupyter.
- **Admin:** `sudo bash 2-ood/setup-ood.sh`, then Restart Web Server.

## 2026-10-09 — OOD footer: "© 2026 C-DAC India — Government of India"

- **Changed:** `2-ood/branding/ai-factory.css`: OOD's footer content stays hidden; the footer itself now shows our
  line (CSS `::after`), centred, and sits at the bottom of the window on short pages (body = flex column,
  footer `margin-top: auto`). The text lives in the CSS file; change the year there. OOD's code is not patched.
- **Checked:** mock with OOD 4.2.4's `application.css` and its real footer markup: home page (background) and a
  normal page, footer centred at the bottom on both.
- **Admin:** `sudo bash 2-ood/setup-ood.sh`, then Restart Web Server (hard-reload if the old CSS is cached).

## 2026-10-12 — OOD: C-DAC logo in the top bar + tab icon

- **Why:** the top bar showed the "AI-Factory" text and the tab showed OOD's icon; both now show C-DAC.
- **Changed (`OOD-Install`):** new `2-ood/branding/cdac-logo.svg` and `favicon.ico` (64/48/… px, built from the logo).
  `2-ood/setup-ood.sh` step 8 copies both to `/var/www/ood/public/ai-factory/` and `ai-factory.yml` gets
  `dashboard_header_img_logo: /public/ai-factory/cdac-logo.svg` (logo instead of the title; `dashboard_title` stays
  the tab title + alt text) and `public_url: /public/ai-factory` (the dashboard takes `favicon.ico` and
  `custom_css_files` from there, so OOD's own `/var/www/ood/public/favicon.ico` is untouched; `custom_css_files` is
  now `["ai-factory.css"]`). `ai-factory.css`: logo 40px high, made white (`brightness(0) invert(1)`) on the navy bar.
  `2-ood/README.md` updated. Fixes the "favicon" item left open on 2026-10-09.
- **Checked:** `bash -n 2-ood/setup-ood.sh`.
- **Admin:** `sudo bash 2-ood/setup-ood.sh`, then Restart Web Server (hard-reload for the new icon/CSS).

## 2026-10-12 — App pages get OOD's top bar (VS Code, Jupyter, MLflow, Model Hub)

- **Why:** our own app pages had a plain white bar; going from the dashboard into an app looked like another site.
- **Changed (`OOD-Install`):** new `2-ood/branding/app-bar.css`: `PORTAL_COLOR` bar, white C-DAC logo (links back to
  the dashboard), light text and links, in light and dark mode. `2-ood/setup-ood.sh` step 8 writes it to
  `/public/ai-factory/app-bar.css` with `:root { --portal-color: PORTAL_COLOR }` in front. Model Hub
  (`index.html`), MLflow and VS Code/Jupyter (`passenger_wsgi.py`) load it after `style.css`, add the logo, and
  mark the bar `app-bar` + `data-bs-theme="dark"`. Like OOD's bar: full width (`container-fluid`; page content
  stays centred) and the user shown as a person icon + "Logged in as <user>" (`.logged-in`, light grey) instead of
  the letter avatar (`.avatar` removed from Model Hub's `style.css` and `app.js`). `2-ood/README.md` updated.
- **Checked:** `bash -n`/`py_compile`/`node --check`; headless Firefox mock of Model Hub's real `index.html` +
  CSS at 1600px: logo and links at the left edge, "Logged in as rakesh" and theme button at the right edge.
- **Admin:** `sudo bash 2-ood/setup-ood.sh`; `3-mlflow/4-install-ood-app.sh`, `4-vscode/3-install-ood-app.sh`,
  `5-model-hub/7-install-ood-app.sh`; Restart Web Server; hard-reload each page.

## 2026-10-13 — Step 8a: remove a user (`1-ldap/remove-user.sh`), UIDs never reused

- **Why:** step 8 now also covers user management from the admin page (decisions in build-plan step 8). The page
  will call the same scripts, so the terminal versions come first.
- **New `OOD-Install/1-ldap/remove-user.sh <name> [--delete-home] [--delete-mlflow] [--yes]`** (also in `menu.sh` →
  People → Remove a person). Always: `scancel -u`, OOD session stopped (`nginx_stage nginx --signal=stop`),
  `pkill -KILL -U <uid>` on login + compute nodes; name taken out of other people's `model-hub/share-users`
  (else a future person with the same name would inherit those shares); `kubectl delete ns u-<name>` (endpoints,
  API key, quota, RoleBindings) and their two PVs (Retain: objects only); MLflow: models only they manage go
  `public=false` + tag `removed_owner=<name>`, then `users/delete` (MLflow 3.15 drops the user's grants with it, and
  the job token in their home stops working); Keycloak `kc.py remove-user` (new: logout all sessions, delete its
  copy); out of every team, own group + LDAP user deleted (**LDAP last**, so a failed step can be rerun);
  `sss_cache -E` on every node. Flags: `--delete-home` (only if the home is exactly `/home/<name>`),
  `--delete-mlflow` (experiments + registered models **only they** manage: soft-delete via the API, then the
  experiment's own folder `MLFLOW_DATA/artifacts/<id>`).
- **Found while writing it:**
  - `add-user.sh` took max(UID)+1: removing the newest person and keeping their home would give the next person
    the same UID, so the old files. Now `LDAP_LAST_UID_FILE` (new in `site.conf`, `/root/.ldap-last-uid`) holds the
    highest UID ever handed out; both scripts write it. Step 9 must back it up with LDAP.
  - `add-user.sh` on a name whose `/home/<name>` was kept would `chown -R` the old home to the new person. It now
    refuses while `/home/<name>` exists.
  - A user can create an experiment whose `artifact_location` points at another experiment's folder; deleting "the
    experiment's files" by that location would delete someone else's. Only `artifacts/<own id>` is removed, and only
    when the location is exactly `mlflow-artifacts:/<id>`.
  - subuid/subgid ranges are left in place on purpose: `add-user.sh` starts after the highest range, so none is
    ever handed out twice.
- **Left (known limits):** soft-deleted MLflow rows stay in `mlflow.db` (hidden; `mlflow gc` if they matter).
  MLflow's 5-min login cache can keep a removed person's UI session alive for up to 5 min (no rights left).
  A k8s client certificate can't be revoked; it is useless once the namespace and RoleBinding are gone.
- **Checked (no root on this account):** `bash -n`, `kc.py` parses; the MLflow part against a fake MLflow server:
  keep mode only tags; purge mode deletes the sole-owned model + experiments, leaves the model and experiment
  carol also manages, and leaves the files of an experiment pointing at another folder; share-list filter on sample
  Services (`bob,carol` → `carol`, `bob` → empty, `bobby` untouched).
- **Not yet tested live.** Admin: create a throwaway user, give them an endpoint, a share, a team and an MLflow model,
  then `sudo bash 1-ldap/remove-user.sh <name> --delete-home --delete-mlflow`; expect every step to print what it
  removed and `getent passwd <name>` to be empty on master and cn01.
- **Live test 1 (admin, menu → Add a person):** `add-user.sh` stopped silently at step 1. On a first run
  `LDAP_LAST_UID_FILE` doesn't exist; its `cat` failed inside the UID pipeline, and `pipefail` + `set -e` ended the
  script without a message. Fixed: `cat … || true`. Also `menu.sh` printed "FAILED (exit 0)": `$?` was read after
  an `echo`; it now keeps the script's real exit code.
- **Test kit:** `~/Desktop/ankush/testing/remove-user/` (outside both repos): `user-setup.sh` (as the test user:
  Slurm job, process, MLflow experiment + public model, API key, CPU endpoint shared with another user, gateway call),
  `check.sh` (root: `prepare` = team + a share by the other user; then PRESENT/gone per item), README with the steps.
  `check.sh` dry-run as non-root on rakesh: LDAP rows right, root-only rows "gone" as expected.
- **Live test 2 (rmtest, `--delete-home --delete-mlflow`):** LDAP, teams, namespace + PVs, share list, MLflow
  (experiment + files, model, user), Keycloak, home: all removed. Three holes:
  - `scancel` failed: `sudo` doesn't read `/etc/profile.d/slurm.sh`, so no `SLURM_CONF` (Slurm here is in
    `/usr/local`, its built-in path has no config). The queued `rmtest-sleep` job started on cn01 *after* the removal,
    as UID 1011. Fix: export `SLURM_CONF` from `site.conf`.
  - The OOD session was back (started 10:39:56, after step 2): the open browser tab respawned it while the name was
    still in LDAP. Its nginx master runs as **root**, so `pkill -U <uid>` never hits it. Fix: `stop_all` (scancel by
    UID, `pkill -f /puns/<name>.conf$`, `pkill -U <uid>` on every node) runs in step 2 and again in step 7, after the
    LDAP + Keycloak delete, when OOD, Slurm and SSH can't start anything for the name.
  - `check.sh` said "gone" for jobs and processes because it looked them up by the (deleted) name, and for cn02
    because ssh failed. Now by UID (saved by the "before" run), `SLURM_CONF` set, unreachable nodes say UNREACHABLE.
  - The public copy (`artifacts/5/rmtest/…`) was still there right after: expected, `public-models.py` removes it
    within a minute. cn02 was down (no route): its `pkill` / `sss_cache` were reported as not done.
- **Live test 3 (fixed script, rmtest again → UID 1012, so the UID fix works):** every line `gone` after removal,
  incl. the Slurm job (`scancel` by UID, cancelled in step 2 and checked again in step 7) and the processes on cn01;
  cn02 down, shown as UNREACHABLE. **But `user-setup.sh` stopped at its step 2 with no message**, so this run had no
  endpoint, API key, model or OOD session to remove (those were covered in test 2, except the endpoint pod and the
  second session stop).
  - Cause: MLflow only soft-deletes experiments, and a deleted experiment **keeps its name**: run 2 deleted
    `rmtest-exp`, so the new rmtest's `set_experiment("rmtest-exp")` failed ("Cannot set a deleted experiment").
    On a real cluster: a new person could never reuse a removed person's experiment names. Fix in `remove-user.sh`:
    rename to `<name>.removed-<user>-<id>` first (MLflow refuses to rename a deleted one), then delete.
  - `user-setup.sh`: the failing `$(…)` under `set -e` ended the script silently; now it prints FAILED + the error.
  - Checked: fake MLflow server, purge mode: `experiments/update` (rename) before `experiments/delete`.
- **Live test 4:** `user-setup.sh` now said why: `experiments/get-by-name … 403 Permission denied`. MLflow experiment
  names are **global**: the earlier `rmtest-exp` (owned by a removed user) still exists, and the new rmtest may not
  read it, so `set_experiment` fails. Same thing a real user hits when someone else already has that name. The test
  now uses `rmtest-exp-<uid>`; `remove-user.sh` renames before deleting (above), so it doesn't leave names behind.
- **Live test 5:** the endpoint's Slurm job (1375) sat pending: the test's own `sbatch --wrap 'sleep 7200'` asked no
  memory, and `DefMemPerNode=UNLIMITED` gave it all 185 GB of cn01 (cn02 down), so nothing else fit. Test now asks
  `-c 1 --mem=64M`. **Cluster finding (not fixed here):** any user's `sbatch` without `--mem` takes a whole node's
  memory and blocks Model Hub endpoints. A `DefMemPerCPU` in slurm.conf would stop that: a question for the admin.
- **Live test 6, setup:** `user-setup.sh` as rmtest (UID 1013) passed end to end: experiment `rmtest-exp-1013`,
  `rmtest-model` v1 public, API key, CPU endpoint `rmtest-ep` on cn01 shared with rakesh, gateway call with the key →
  `{"predictions": [0, 1]}`.
- **Live test 6, removal: PASS.** Before: PRESENT on every line (Slurm job 1376, processes on master + cn01 incl. the
  endpoint's mlflow/uvicorn, OOD session with the browser tab open, pod `rmtest-ep`, API key, PVs, MLflow user +
  public model + `rmtest-exp-1013`, public copy, Keycloak user, home). `remove-user.sh rmtest --delete-home
  --delete-mlflow`, then after 60 s: **gone on every line**; cn02 UNREACHABLE (down); rakesh untouched; last UID 1013.
  Step 7 printed "OOD session stopped" again: the open tab had respawned the session after step 2, and the second pass
  caught it, as designed. Not covered: removal from another person's share list (rakesh had no endpoint; the filter is
  unit-tested only) and the keep mode (no flags).

## 2026-10-13 — Step 8b: one-time passwords; Keycloak writes passwords (only) to LDAP

- **Why:** the admin types a new user's password; the user must choose their own (decided, build-plan step 8).
- **Changed (`OOD-Install`):**
  - `6-keycloak/2-realm.sh` step 0: LDAP account `cn=keycloak-passwords,<base>` (password `KEYCLOAK_DATA/ldap.pass`)
    and an access rule on `ou=People`: write `userPassword`, nothing else. The check tries to change `description`
    as that account and fails the script if LDAP allows it. Keycloak now talks **ldaps://MASTER_HOST:636** (389 DS
    refuses password changes on plain ldap).
  - `6-keycloak/1-install.sh`: `LDAP_CA` mounted into the container + `KC_TRUSTSTORE_PATHS` (runtime option in 26.8,
    checked with `kc.sh start --help-all`). The unit changes, so a rerun restarts Keycloak.
  - `kc.py realm`: LDAP provider `WRITABLE`, simple bind as that account, `useTruststoreSpi=always`; every attribute
    mapper forced `read.only` (with a writable provider Keycloak would push name/e-mail edits to LDAP); required
    action `UPDATE_PASSWORD` enabled. New `kc.py must-change|logout|remove-user`.
  - `1-ldap/add-user.sh` step 8 and `menu.sh` "Set a new password": `kc.py must-change` → one-time password.
  - `1-ldap/remove-user.sh`: **found while designing it:** with a writable provider, deleting a user in Keycloak also
    deletes them in LDAP, which the account may not do → the old step 5 (delete in Keycloak) would fail and stop the
    script. Now: `kc.py logout` in step 5, `kc.py remove-user` right after the LDAP delete (Keycloak then drops only
    its copy: "can't be deleted from LDAP as it doesn't exist here", seen in the 26.8 jar).
- **Limit (agreed):** web only. An SSH-only user keeps the one-time password until `passwd`.
- **Test kit** `~/Desktop/ankush/testing/keycloak-passwords/run.sh` (rootless pod: 389 DS 2.4.6 + our
  `keycloak:26.8.0-rudra` in `start-dev`; the real `2-realm.sh` + `kc.py` inside, test `site.conf`):
  - **Near miss:** rootless podman wrote `<host IP> ldaptest` into the pod's `/etc/hosts`, so `ldaps://ldaptest` went to
    **master's real LDAP**. Nothing was written: the test CA rejected master's certificate, and base DN + Directory
    Manager password were the test's (checked afterwards: no `keycloak-passwords`, no `alice`, no new access rule on
    the real LDAP). Fix: `--add-host ldaptest:127.0.0.1` on the pod, and `run.sh` stops unless `ldaptest` is 127.0.0.1.
  - Result, fresh realm: 12/12. `UPGRADE=1` (realm first made read-only by the last commit's scripts, like master
    today, then the new ones): 13/13. Checked: account + rule created, other attributes refused, rerun changes
    nothing, first login with the one-time password → "update password" → new password in LDAP (ldaps bind OK),
    one-time password rejected, second login without questions; `remove-user` refuses while the user is in LDAP;
    logout; `remove-user` after the LDAP delete.
- **Not yet live.** Admin, on master: `sudo bash 6-keycloak/1-install.sh` (restarts Keycloak: logins pause ~30 s),
  `sudo bash 6-keycloak/2-realm.sh`, then add a test user and log in once in the browser.
- **Live (master): PASS.** `1-install.sh` (unit changed → restart, ready), `2-realm.sh`: account created, access
  rule added, binds over ldaps, realm updated (read-only → writable, 8 users, 10 groups), `description` change refused.
  `add-user.sh pwtest` (UID 1014) → "must choose a new password"; first browser login asked for a new one and it
  worked. `remove-user.sh pwtest --delete-home --delete-mlflow`: step 5 "signed out everywhere", LDAP delete, then
  "deleted from Keycloak"; all clean (cn02 down, reported).

## 2026-10-13 — Step 8c: a sign-out in Keycloak ends the OOD login too (back-channel logout)

- **Why:** after `remove-user.sh` (or "sign out other devices"), an open OOD tab kept working: OOD's Apache
  (`mod_auth_openidc`) keeps its own login for up to 8 h, independent of Keycloak's session.
- **Changed (`OOD-Install`):** `kc.py client`: `backchannel.logout.url = https://OOD_SERVERNAME/oidc?logout=backchannel`
  (+ `session.required`), so Keycloak tells Apache whenever a session ends. Keycloak must trust OOD's certificate for
  that call: new `OOD_CERT` in `site.conf` (used by `2-ood/setup-ood.sh` too), mounted into Keycloak's truststore
  folder; `KC_TRUSTSTORE_PATHS` is now the folder (LDAP CA + OOD cert). `1-install.sh` checks the cert exists.
  Model Hub `app.js`: API calls send `X-Requested-With` (mod_auth_openidc then answers 401 instead of a login page)
  and a 401 or a redirect to Keycloak reloads the page → the browser lands on the login.
- **Test kit** `testing/backchannel-logout/run.sh`: Apache with **master's own** `mod_auth_openidc.so` 2.4.10
  (AlmaLinux repos only have 2.4.16 now; all its libraries resolve in an AlmaLinux 9 image) + our Keycloak image, CN-only
  self-signed certificate like master's (Java accepted it: no SAN needed). **6/6:** control (no back-channel URL =
  today): Keycloak logout, Apache still serves bob → the problem reproduced; with it: alice's next page → 302 to the
  Keycloak login, XHR → 401.
- **Limit:** a page that makes no request can't be told; it changes at the next click. Model Hub's endpoint pages
  poll every 5 s; other OOD pages change on the next click.
- **Not yet live.** Admin: `sudo bash 6-keycloak/1-install.sh` (restart), `sudo bash 2-ood/setup-ood.sh` (updates the
  client), `sudo bash 5-model-hub/7-install-ood-app.sh`, Restart Web Server.
- **Live (master): PASS.** After `1-install.sh`, `setup-ood.sh`, `7-install-ood-app.sh` + Restart Web Server: the admin
  had every interactive app open as a test user, removed the user, and every tab went to the Keycloak login.

## 2026-10-13 — Step 8d: the admin page's root helper (`OOD-Install/8-admin/`)

- **What:** `aistack-admin.py`, installed root-owned as `ADMIN_HELPER` (`/usr/local/sbin/aistack-admin`) by
  `8-admin/1-install.sh`, plus `/etc/sudoers.d/aistack-admin`: `OOD_ADMIN ALL=(root) NOPASSWD: ADMIN_HELPER` (checked
  with `visudo -c`). The page (next) runs as `OOD_ADMIN` and calls `sudo -n aistack-admin <action>`.
- **Actions:** reads `users` (LDAP + teams + limits), `teams`, `endpoints` (all namespaces: owner, state, node, GPU as
  `<node>/<device>` from the pod's ResourceClaim, since, until, stopped-by); changes `add-user`, `remove-user`
  (`--delete-home`, `--delete-mlflow`), `set-password`, `team-create|delete|add|remove`, `limits` (`--gpus 0..8`,
  `--max-hours 1..8760`, `--reset`), `stop-endpoint USER NAME` (deletes the pod only: Slurm job ends, GPU free; the
  Service stays, annotated `model-hub/stopped-by=admin <time>`, so the owner sees "stopped" and can redeploy).
- **Safety:** caller = `SUDO_USER` must be `OOD_ADMIN` (or root in a terminal); fixed actions; every name checked
  against the same patterns as the scripts; no shell; `admin`/`KEEP_LOCAL` can't be removed; passwords only on stdin
  and replaced by `********` in any output before it's logged or returned; one change at a time (`flock`); every change
  **and every refused attempt** in `ADMIN_LOG` (root 600, JSON lines: time, by, action, args, ok, last 300 chars).
- **Script changes:** `add-user.sh --password-stdin`; new `1-ldap/set-password.sh` (one-time password from stdin +
  Keycloak must-change), now also used by `menu.sh` (8+ characters enforced there too).
- **Known limit (ponytail):** the helper runs the scripts in `OOD-Install`, which its owner can edit. Fine while only
  `OOD_ADMIN` (full sudo anyway) may use it; an `admins` team needs `OOD-Install` root-owned first (step 9).
- **Checked:** `aistack-admin.py --test`: 9 good requests planned, 15 bad refused (`Bob`, `bob;rm -rf /`, `-rf`, removing
  admin, `--yes` from outside, duplicated flags, `../x`, GPUs 99/-1, unknown option, unknown action, …), endpoint
  rows from sample svc/pod/ResourceClaim JSON (running with GPU `cn01/gpu-0`, stopped, loading after a redeploy hides
  an old stopped-by). As **root in an AlmaLinux 9 container** with stub scripts: arguments and stdin reach the right
  script, `bob` refused, `admin` not removable, log `-rw-------`, refused attempts logged, password not in the log.
  `teams` read against the real LDAP: `nlp: rakesh, test`, `rmtest-team: []` (leftover from the tests).
- **Not yet live.** Admin: `sudo bash 8-admin/1-install.sh`.
- **Live 1:** `1-install.sh` OK (admin runs it without a password; narmada refused). The short name failed:
  `sudo: aistack-admin: command not found`: EL9 sudo `secure_path` has no `/usr/local/sbin`. Use the full path
  (README fixed; the page will use `ADMIN_HELPER`).
- **Live 2 (as admin, full path): PASS.** `users` (LDAP + teams + limits), `endpoints` (ankush's `llm-sft-test-v1`:
  stopped, no GPU), `team-delete rmtest-team`, `add-user helpertest` (password on stdin, UID 1016, one-time),
  `team-create helpers`, `team-add`, `limits --gpus 2` (shown as exception), `users` shows teams + 2 GPUs,
  `remove-user --delete-home`, `team-delete helpers`; every change in the log with `by: admin`.
  Not tried live: `stop-endpoint` (nothing was running), `set-password`.
  Fix: a script's stderr came after all its stdout (cn02 warnings after step 10): one stream now (`stderr=STDOUT`).

## 2026-10-13 — Step 8e: the admin page (`OOD-Install/8-admin/ood-app/aistack_admin`)

- **What:** OOD Passenger app "Admin" (Interactive Apps), Model Hub's look (same top bar, its `style.css` + Bootstrap
  copied in at install). Tabs: **Endpoints** (counters, GPUs in use per node with user/endpoint/since, table with
  node + GPU, since, stops, Stop button; refresh 5 s; filter), **Users** (UID, teams, limits, Add with one-time password
  + Generate, Password, Limits, Remove with the two delete checkboxes + type-the-name), **Teams** (cards, add/remove
  members, new/delete), **Log** (ADMIN_LOG newest first, refused attempts in red).
- **How:** the backend runs as the logged-in user and does nothing itself: every read/change = `sudo -n ADMIN_HELPER
  <action>`, passwords on stdin. Helper got a `log` read action (ADMIN_LOG is root-only).
- **Locks (three):** the app folder is `root:<admin's group> 750` (OOD lists only apps the user can read); the
  backend answers 403 to anyone but `OOD_ADMIN`; the helper checks `SUDO_USER` again. Changes need `X-Requested-With`
  (a cross-site form can't set it). One dialog for every form; anything destructive asks first; the result shows
  what the script printed.
- **Checked here** (wsgiref server + a fake helper that returns sample data and records calls; headless Firefox):
  every route calls the helper with the right action/args, password only on stdin; no header → 403; another user →
  403 (page too). Screenshots of all four tabs, the Add / Remove / Limits / Stop dialogs, a stop's "Done" with the
  output, the username check, phone width (cards stack, table scrolls). Fixed on the way: team member "×" was invisible.
  Test-harness lessons (not app bugs): wsgiref is single-threaded (use a threading server), headless Firefox doesn't
  run CSS transitions in `--screenshot` (modals stay transparent, button colours stay old): `transition: none` in the test.
- **Not yet live.** Admin: `sudo bash 8-admin/1-install.sh` (helper has `log` now), `sudo bash 8-admin/2-install-ood-app.sh`,
  Restart Web Server as admin.
- **Live 1:** installed, readable by admin only, but not in the Interactive Apps menu. OOD's own code (`bin/rails
  runner`, `SysRouter.apps` as admin) showed `sys/aistack_admin` accessible with an **empty category**: the
  manifest's description had `this): who` — a `: ` in a plain YAML scalar is a syntax error, and OOD drops a manifest it
  can't parse without any message. Fixed: description quoted; `2-install-ood-app.sh` now parses the manifest and
  checks the category.

## 2026-10-13 — Step 8f: "Running" tab: every Slurm job, stoppable (sessions, training jobs, endpoints)

- **Why:** the admin wants to stop anything a user runs, e.g. several VS Code / Jupyter sessions, a training job, an
  endpoint; the tab only had endpoints.
- **How:** everything runs through Slurm, so one `squeue -a --json` lists it all (Slurm 25.11: `gres_detail` gives the
  GPU index per node, e.g. `gpu:a30:1(IDX:0)`; `command` tells the OOD app: `/var/www/ood/apps/sys/<app>/job.sh`).
  Endpoint jobs are submitted by user `slurm` in `BRIDGE_PARTITION`: linked back to owner + endpoint through the pod's
  annotation `slurmjob.slinky.slurm.net/job-name`. Helper: `jobs` (read; multi-node node lists expanded with
  `scontrol show hostnames`; works without Model Hub) and `cancel-job JOBID` (digits only; must exist; refuses an
  endpoint job → stop-endpoint keeps it redeployable; `scancel`; logged). Helper sets `SLURM_CONF` itself (sudo
  drops the environment, and Slurm in `/usr/local` has no built-in config path). Page: Endpoints tab → **Running**
  (type badge, waiting reason, filter by type/text, GPU card from all jobs, Stop with type-specific wording).
- **Not covered:** programs started over SSH on master outside Slurm (not jobs). Stopped endpoints are no longer listed
  in the admin page (nothing runs); the owner still sees them in Model Hub.
- **Checked:** self-test 12 good / 18 bad (job ids `1382;id`, `-1`, two ids refused); `jobs_from` on sample JSON (session +
  GPU, endpoint linked to bob/llm, 2-node job `cn01/gpu-0..1` + `cn02/gpu-3`, pending VS Code with reason). **Real Slurm
  on master** (as admin, read only): ankush's Jupyter job 1382 → session/Jupyter, `cn01/gpu-0`, since 07:29:53Z, ends
  +4 h. As root in an AlmaLinux container with fake squeue/scancel: cancels a session (scancel got `SLURM_CONF`),
  refuses an endpoint job, a finished job and `13;id`, all logged. Page screenshots: Running with 6 kinds of rows, the
  session and job stop dialogs.
- **Not yet live.** Admin: `sudo bash 8-admin/1-install.sh` then `sudo bash 8-admin/2-install-ood-app.sh`, Restart Web Server.

## 2026-10-13 — Step 8g: admin stops work for endpoints and show up for the user

- **Live (8f):** stopping VS Code and Jupyter sessions from Running worked, on CPU and on GPU. Stopping a GPU vLLM endpoint
  (`qwen3-5-0-8b-ankush-v1`) failed: `error: name cannot be provided when a selector is specified`. The helper checked
  "is this a Model Hub endpoint" with `kubectl get svc NAME -l model-hub/runtime`, which kubectl refuses, so it stopped
  before anything happened (CPU endpoints too). Also: the user's page kept saying the session was running until a
  reload, and then the session was just gone, with no "stopped by the admin" anywhere.
- **Fix, endpoint stop:** read the Service as JSON and check the label in Python.
- **Model Hub:** it never read the `model-hub/stopped-by` annotation the helper writes. Now a stopped endpoint with it
  says "Stopped by the admin on <time>" (list + endpoint page). Deploy removes the annotation, so a later timeout isn't
  blamed on the admin. It stays listed until the owner deletes it (bin button, as before).
- **VS Code / Jupyter:** the page lists only `squeue`, so a cancelled session vanished. `cancel-job` now writes
  `ADMIN_NOTICES/<jobname>.<jobid>` (`site.conf`, default `/var/lib/aistack-admin/stopped`), "admin <time>".
  The folder is sticky 1777 (like /tmp) and the file is owned by the job's user, so only that user can delete it.
  The page shows a "Stopped by the admin on <time>" card with a bin button (`api/dismiss`) until they remove it. No
  expiry. The page shows only files named for its own app and owned by the user (anyone can drop files there). The
  helper writes with `O_EXCL|O_NOFOLLOW` after unlinking, so a planted symlink can't redirect root's write. The job
  name is user-chosen, so anything but `[a-z_]` becomes `job`. Pages with a running session now reload every 30 s
  (not while a form field has focus), so an admin stop shows without a manual reload. site.json gets `notices` (both
  installers).
- **Checked here:** helper self-test; Python 3.9 parse; `node --check`; the page with a fake notices folder: card shown,
  no expiry, bin removes it, Jupyter's notice not on the VS Code page, another user's file ignored, bad id refused.
  **Not checked:** the helper's notice write (needs root + Slurm).
- **Not yet live.** `sudo bash 8-admin/1-install.sh`, `5-model-hub/7-install-ood-app.sh`, `4-vscode/3-install-ood-app.sh`,
  `7-jupyter/2-install-ood-app.sh`, then Restart Web Server (admin + users).

## 2026-10-13 — OOD home page: our tools as cards (dashboard widget)

- **Why:** with the welcome message off, the home page was only the background.
- **What:** a custom OOD widget `ai_tools` (`OOD-Install/2-ood/branding/_ai_tools.html.erb`), the only thing in
  `dashboard_layout`. Sections, one below the other: **Develop** (Jupyter, VS Code, Shell), **Track & Deploy** (MLflow,
  Model Hub), **Data & Cluster** (Files), **Admin** (AI Stack Admin). Each card: icon, name, subtitle, one line on what the
  tool does (as a chat bubble), "Open". Same look as Model Hub (Bootstrap card, `kind-icon`, `eyebrow`, playground
  bubble), styles at the end of `branding/ai-factory.css`. Tools hidden from the top bar (Desktop, Active Jobs, System
  Status, Module Browser) aren't on the home page either.
- **How:** cards come from OOD's own `SysRouter.apps` + `links.first`, so the link is the top bar's (Shell → the login
  host, Files → home) and a card shows only when the user may open the app: Admin only for `OOD_ADMIN` (the app folder is
  `root:admin 750`). `OOD_ADMIN` gets no MLflow / Model Hub cards (not in LDAP, both log in through LDAP);
  `setup-ood.sh` fills `${OOD_ADMIN}` with `envsubst` at install. A widget error shows as OOD's error box in its place,
  the rest of the page stays up.
- **Checked here:** static mockup + headless Firefox screenshots for the design. Widget rendered with OOD's own code as
  admin (`source /opt/ood/ondemand/enable; bin/rails runner 'ApplicationController.render(partial: "widgets/ai_tools")'`,
  `OOD_APP_CONFIG_ROOT` pointing at a test folder; the system `bundler` 2.2 can't read OOD's Gemfile): 4 sections, 7
  cards, right links; with `OOD_ADMIN=admin` Track & Deploy is gone, with another name it's back. `bash -n setup-ood.sh`.
- **Not checked:** the live page; a non-admin user's view (needs another login).
- **Not yet live.** `sudo bash 2-ood/setup-ood.sh` (or just step 8's widget, CSS and `dashboard_layout` by hand), Restart
  Web Server.
- **Left as is:** MLflow / Model Hub stay in admin's **Interactive Apps** menu (nav_bar config is the same for everyone);
  hiding them there = deny admin on those app folders in their installers.

## 2026-10-13 — Home page card icons; portal renamed AI-HPC-Cluster

- **Icons (admin's own edit, committed with this):** the home page cards use the apps' own Bootstrap Icons (as in each
  app's top bar), white on one colour per tool (`icon-<colour>` classes in `ai-factory.css`, not inline style: OOD's
  CSP can block style attributes). `setup-ood.sh` copies Model Hub's `bootstrap-icons` to `/public/ai-factory/` and
  loads it through `custom_css_files`. The Admin card is "Admin Panel", dashed green.
- **Name:** `PORTAL_TITLE="AI-HPC-Cluster"` (was AI-Factory). One value: the Keycloak realm's display name (login page
  heading, `6-keycloak/2-realm.sh`, safe to rerun) and OOD's tab title (`2-ood/setup-ood.sh`). Internal names (theme
  `ai-factory`, `ai-factory.css`) stay.
- **Not yet live (when written):** `sudo bash 6-keycloak/2-realm.sh`; OOD keeps the old title until `setup-ood.sh` reruns.

## 2026-10-13 — Step 8h: the admin says why; users get it under a bell in OOD's top bar

- **Why:** an admin stop (8g) told the user *that* it was stopped, not *why*.
- **Admin:** `cancel-job JOBID REASON` and `stop-endpoint USER NAME REASON`; the reason is required (1..1000 characters,
  newlines allowed, no control characters) and logged in `ADMIN_LOG` with the request. The page's Stop dialog (session,
  job, endpoint) has a required "Message to <user>: why is it stopped?" box.
- **Where it goes:** `notify()` writes `ADMIN_NOTICES/<key>` = `admin <when>` + the reason, owned by the user, now mode
  **600** (was 644: anyone could read another user's notice). Jobs: `<jobname>.<jobid>` as before. Endpoints:
  `endpoint.<user>.<name>` (endpoint names repeat across users) plus annotation `model-hub/stop-reason` next to
  `stopped-by`; a redeploy removes both. A user with no Linux account on master: Model Hub still shows it, no file.
- **User side:**
  - **Bell in OOD's top bar**, left of Help (`2-ood/branding/_notifications.html.erb`): count badge, dropdown with the
    messages, newest first, each with an × and a Clear all button, no expiry. OOD 4.2 has no setting for a custom
    top-bar item (`nav_bar`/`help_bar` take only OOD's own templates and links). OOD looks in its config views folder
    first, so the bell is installed there as `layouts/nav/_develop_dropdown.html.erb`: the Develop slot sits right
    before Help and is empty here (no app development). If Develop is ever needed: override `_help_dropdown` instead.
  - **Clearing** = app `aistack_notices` (`2-ood/notices/`, in no menu): runs as the user, `POST api/dismiss {names}`
    removes only the user's own files, names checked against what 8-admin writes, `X-Requested-With` required. Not
    OOD's Files/transfers API: its `rm` runs as a background job that shows in the user's transfer list.
  - VS Code / Jupyter: a stopped card gets an envelope that opens the message (native `<dialog>`; that page has no
    Bootstrap JS). Model Hub: the envelope on the endpoint list row and on the "stopped" banner.
  - First version was an envelope above the home page cards (last 14 days, no clear: a widget can't take a POST);
    replaced by the bell on the admin's request.
- **Live:** the bell showed real messages (Jupyter 1396 "the session time exceeded", endpoint
  `qwen3-5-0-8b-ankush-v1` "gpu on maitainance"). × answered **HTTP 404**: OOD makes a new sys app's nginx config
  (`/var/lib/ondemand-nginx/config/apps/sys/<app>.conf`, shared) only through the "Initialize App" page on a first
  browser visit, which a background POST never reaches. **Fix:** `setup-ood.sh` stages it
  (`nginx_stage app --sub-request=/sys/aistack_notices --skip-nginx`) and reloads running PUNs (`nginx_list`,
  `nginx --signal=reload`). Quick fix by hand: open `/pun/sys/aistack_notices/` once, press Initialize.
- **Checked here:** helper self-test (12 good, 24 bad requests, incl. missing/blank/too long/escape-code reasons);
  `notify()` for real in a scratch dir (600, replace, unknown user leaves no file); the bell rendered through OOD's own
  Rails (`bin/rails runner ... render(inline:)`): items, empty state, a message with HTML comes out escaped; dismiss app
  with fake requests (removes, already-gone is fine, `../` refused, no header 403, GET 404); VS Code card + Model Hub
  `node --check`. **Not checked:** another user's file refused (needs root to create one; the uid check and the sticky
  dir both stop it); the fixed × in the browser.
- **Not yet live (the 404 fix):** `sudo bash 2-ood/setup-ood.sh`, Restart Web Server.
- **Left:** two root-owned files `1388`, `1389` in `ADMIN_NOTICES` from before the `<app>.<id>` names; nothing lists
  them; `sudo rm` them.

## 2026-10-13 — Model Hub playground: JSON for chat models

- **Why:** the playground's inputs are a guess (Image from the tensor shape, Form from the columns, Chat for vLLM); the
  guess won't always fit. ML endpoints already had a JSON box beside the guess; chat models had only the chat box.
- **What:** vLLM endpoints get a Chat | JSON switch. JSON = the request body (pre-filled `{model, messages,
  max_tokens}`), sent as typed to `/v1/chat/completions` (the backend passes the body through), raw answer shown. All
  JSON boxes share `runJson()`/`send()`.
- **Limits:** chat models' JSON always goes to `/v1/chat/completions` (`/v1/completions`, `/v1/embeddings` would need
  a backend route). While an endpoint starts the page re-renders every 5 s and resets the box (as the ML one did).
- **Checked:** `node --check`. **Not checked:** in the browser.
- **Not yet live (when written):** `sudo bash 5-model-hub/7-install-ood-app.sh`.

## 2026-10-13 — Steps 6 + 6b: LLM and ML PASS; v2 closed

- **Step 6 PASS (admin, 2026-10-13):** the LLM and ML runs of the end-to-end test (DL passed 2026-10-08). **Step 6 done.**
- **Step 6b PASS (admin, 2026-10-13):** the LLM and ML runs of the public-model test (DL passed 2026-10-08). **Step 6b done.**
- **v2 closed** (README "Status"). Done: steps 2, 3, 4, 5, 6, 6b, 8 (admin page, users, stops, messages). Moved to
  [v3](../version-3/README.md): step 1 (network lock), step 7 (NVMe cache), step 9 (packaging), usage logs kept on
  disk (step 8), the "Not yet live" reruns above, and the senior questions.

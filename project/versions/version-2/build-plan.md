# Model Hub v2 — build plan (one step at a time)

**Closed 2026-10-13.** Steps 1, 7, 9 and step 8's usage logs continue in [v3](../version-3/build-plan.md).

Each step is built, tested on the dummy cluster, logged in [build-log.md](build-log.md) and committed before the
next one starts. Code goes in `OOD-Install/` (numbered folders, `site.conf`). Decisions: [README.md](README.md).

Order = base first: a step only depends on the steps above it.

| # | Step | Depends on |
|---|---|---|
| 1 | Network lock | — |
| 2 | One login (Keycloak) | — |
| 3 | Scheduling rules (GPU limit, run time, 2-GPU models) | — |
| 4 | Gateway: keys + owner-only access | 1 |
| 5 | Sharing: people, groups, everyone | 4 |
| 6 | Model Hub app on the gateway + share dialog + "My key" | 2, 4, 5 |
| 6b | Public models (model files: private or everyone) | 6 |
| 7 | Model cache on GPU-node NVMe | 3 |
| 8 | Admin page + usage logs | 4, 6 |
| 9 | Rudra packaging: versions, offline bundle, upgrade, backup | all |

---

## 1. Network lock

**Goal:** a model endpoint can only be reached through the gateway. Today (flannel) any pod or node can call any endpoint.

- **Test first:** install Calico (pinned) on a copy of the dummy cluster setup, or replace flannel during a planned
  break: all existing pods (MLflow, GPU operator, slurm-bridge, KEDA, …) come back; a GPU test pod still gets its A30.
- **Build:** network plugin install script; in every `u-<user>` namespace a policy "only the gateway's namespace may
  connect to endpoints"; the same for `mlflow` where it makes sense.
- **Done when:** from a pod in `u-bob` and from master, `curl` to alice's endpoint **fails**; from the gateway's
  namespace it **works**; `6-test-endpoints.sh` still passes through the gateway path.
- **Cluster-side:** replaces the CNI. Senior approval needed (README question 1).

## 2. One login (Keycloak)

**Goal:** log in once; OOD, MLflow and Model Hub all know who you are. LDAP stays the user list.

- **Test first:** Keycloak (pinned, own Postgres or embedded DB) with **LDAP user federation, read-only**; a test
  user logs in with their LDAP password. Then: OOD with OIDC (`mod_auth_openidc`, supported by OOD); MLflow UI
  behind OIDC while **job tokens keep working** (needs research: MLflow OIDC plugin or a proxy in front).
- **Build:** `OOD-Install/6-keycloak/` (install, realm, LDAP federation, clients for OOD/MLflow/gateway);
  OOD and MLflow switched to it; old login kept as fallback until done.
- **Done when:** one login in the browser opens OOD, MLflow and Model Hub without a second password; a new LDAP
  user (`add-user.sh`) can log in everywhere with no extra step; `mlflow` from a job still works with its token.

## 3. Scheduling rules

**Goal:** the agreed limits, enforced by the cluster (not only by the UI).

- **GPU limit:** `USER_GPU_QUOTA=1` default; admin raises one person to 2 (`2-sync-users.sh <user> --gpus 2`,
  stored per user). The ResourceQuota stays the hard limit.
- **Run time:** default 1 day, max 4 days (`ENDPOINT_HOURS_DEFAULT=24`, `ENDPOINT_HOURS_MAX=96`); longer only
  when the admin sets a per-user override. Enforced in the backend **and** checked in the pod admission policy
  (so `kubectl` can't skip it).
- **2-GPU models:** vLLM with tensor parallel 2 on one node (NVLink). **Test first:** a 2-GPU pod through
  slurm-bridge gets both GPUs on the same node, and Slurm records 2 GPUs.
- **Waiting:** a queued model shows "waiting for a GPU (position N)" in Model Hub.
- **Done when:** a 3rd GPU request is refused by the quota; a 5-day run is refused; a 2-GPU vLLM model answers.

## 4. Gateway: keys + owner-only access

**Goal:** one HTTPS address on the customer network; every call needs a personal key; at first only the owner may call.

- **Test first (pick the tool):** compare on the dummy cluster
  (a) **LiteLLM** proxy (keys, limits, usage built in, but made for OpenAI-style LLM calls), and
  (b) **Envoy or nginx + a small auth service of ours** (works for any HTTP model: `/invocations` and `/v1/...`).
  Must handle: ML/DL `/invocations`, vLLM `/v1/chat/completions` with **streaming**, per-endpoint rules, ~100 users.
- **Build:** gateway in its own namespace (`model-hub`), runs as non-root, pinned image; address from **MetalLB**
  (installed) on port 443; certificate from **cert-manager** (installed): a self-signed Rudra CA by default, the
  customer's certificate if they give one. Keys: one per person, stored **hashed**, created/revoked from Model Hub.
  URL: `https://<gateway>/<owner>/<endpoint>/...`. vLLM's own key becomes internal (the gateway adds it).
- **Done when:** from a laptop on the network, owner + key → 200; no key / wrong key / another user's key → 401/403;
  LLM streaming works; ML `/invocations` works; endpoints are still unreachable directly (step 1).

## 5. Sharing

**Goal:** the owner picks who may call each endpoint: only me / people / LDAP groups / everyone.

- Rules live **on the endpoint** (annotations on its Service in `u-<owner>`), so they go away with it and the
  owner can only change their own. The gateway reads them; groups come from LDAP (cached a few minutes).
- **Done when:** alice shares with `bob` → bob 200, carol 403; shares with group `nlp` → members 200;
  "everyone" → any user 200; removing a share takes effect within ~5 s (gateway cache).

## 6. Model Hub app on the gateway

**Goal:** the app uses the new pieces; users never see ClusterIPs or tunnels.

- Login through Keycloak (step 2); **"My key"** page (create, show once, revoke); **share dialog** on each endpoint;
  "Shared with me" list; playground and API tab call the **gateway address** with the user's key
  (curl / Python examples work from a laptop as-is).
- Remove v1's `model-register --public`, the MLflow READ grants in `3-sync-tokens.sh`, the per-endpoint vLLM key
  display and the ssh-tunnel instructions.
- **Done when:** a user does train → register → deploy → share with a colleague → colleague calls it from their
  laptop, for one ML, one DL and one LLM model, all from the browser.

## 6b. Public models

**Goal:** the owner makes a **model** (all its versions' files) private or public. Public = every user can see it,
deploy their own copy, download it. No chosen people or teams (decided 2026-10-07): for that, users copy the files
themselves, outside Model Hub. Replaces v1's admin-only `model-register --public`.

- Model Hub: **Make public / Make private** on the model page (owner only, = MANAGE in MLflow); badge
  "Public · by <owner>" in the list. It only sets the MLflow tag `public=true|false`.
- A root timer (every minute, `5-model-hub/public-models.py`) does the privileged part:
  - **Copies** every version's files where everyone may read them, then tags the version `public_copy` (where) +
    `public_status` (copying | ready | error: ...). The owner's own `path` tag / source are **never changed**, so
    going private can't break the owner's model.
    - **ML / DL:** into MLflow experiment `model-hub-public` (READ for every user). Needed because MLflow checks a
      file download by the **experiment** it's in: READ on the model alone doesn't let others download it, and READ
      on the owner's experiment would show all their runs (found 2026-10-08).
    - **LLM:** into `MODELS_ROOT/public/<owner>/<model>/v<N>` (owned by `modelhub`, read-only for others).
  - **READ** on the model for every user, given only after the copy is there; **revoked** when private.
  - **Deletes** copies of models that are private, deleted, or whose version is gone.
- Others deploy / download from the public copy; the owner keeps using their own files.
- **Safety** (review 2026-10-08):
  - owner = the LDAP user(s) with MANAGE on the model;
  - LLM folder must belong to an owner and is read **as that owner** (`runuser`): nobody can publish files they
    couldn't read themselves (another user's folder, system files, a symlink to them);
  - ML/DL files must be in an experiment an owner manages (a version's source could point at someone else's);
  - free-space check before each copy (size + 2 GB, and 5 % of the disk left);
  - any MLflow error stops the run before anything is deleted; systemd never runs two at once (big copies);
  - vLLM never gets `--trust-remote-code`; the model page warns that a public ML/DL model runs its owner's code.
- Base models (Qwen, ...): the admin registers them normally and makes them public, same button (files under
  `MODELS_ROOT` are already readable by every endpoint: no copy).
- **Known limits** (said in the UI): files someone already downloaded stay with them; others' running endpoints keep
  running until they stop (a restart after "private" fails); someone can re-share their endpoint of it.
- **Before real users:** step 1 (network lock), so a public model's code can't reach other endpoints.
- **Done when:** alice makes an ML, a DL and an LLM model public → bob sees, deploys and downloads each; alice makes
  them private → within ~1 minute bob no longer can (his running endpoint from it keeps running until it stops).

## 7. Model cache on the GPU node

**Goal:** big models start fast. NFS stays the source; the GPU node keeps a copy on its NVMe.

- **Test first:** how long a 16 GB and a ~140 GB model take to load from NFS vs local NVMe on a GPU node.
- **Build:** a cache on each GPU node managed by the platform (not by users: user pods can't use hostPath under
  PSA `restricted`); a model is copied on first use, checked by size + hash, oldest removed when the disk fills.
  Pods mount the cache read-only.
- **Done when:** the second start of the same model loads from NVMe; a changed model version is copied again.

## 8. Admin page + usage logs

**Goal:** the customer's admin sees what runs and who uses it, without `kubectl`.

- Admin page (Model Hub, admins only): all endpoints, owner, GPU, node, start/end time, state, logs; stop an endpoint;
  set a user's GPU limit / run-time override.
- The gateway logs every call (who, which endpoint, when, status, LLM tokens). Kept on disk, rotated. Reports later.
- **Users from the page** (decided 2026-10-13):
  - **Who:** only the local `OOD_ADMIN` account (a Keycloak local user, works when LDAP is down). No `admins` team yet.
  - **How:** the page runs as the logged-in person, not root. A small root helper accepts a fixed set of actions
    (add, remove, set one-time password, teams, GPU limit / run time), validates every argument and refuses anyone
    but `OOD_ADMIN`. It calls the existing scripts (`1-ldap/add-user.sh`, `group.sh`, `5-model-hub/2-sync-users.sh`),
    no second copy of the logic.
  - **Add:** the admin types a one-time password; the user must set a new one at first login. Keycloak's LDAP
    provider goes from read-only to **writable for passwords only**, via a new LDAP account that may change
    `userPassword` and nothing else (not the Directory Manager). The new password works for SSH, Slurm, OOD, MLflow.
  - **Remove** (new `1-ldap/remove-user.sh`): always stops their endpoints and deletes their API key, `u-<user>`
    namespace, team memberships and public-model copies, then the LDAP entries. Two checkboxes, both off by
    default: delete the home folder, delete their MLflow runs and models.
  - **UIDs are never reused:** the last UID handed out is stored, so a kept home folder can't end up owned by the
    next new user (today `add-user.sh` takes max+1).
- **Done when:** the admin can answer "who is using GPU 3 on node 2 and since when" from the page, and can add a
  user (who then sets their own password at first login) and remove one, from the page only.

## 9. Rudra packaging

**Goal:** the same install on every rack, upgrades without losing data.

- One versions file (charts, images, packages), an offline bundle (images pushed into the rack's registry),
  a top-level install order, an upgrade script, backup + restore of: LDAP, Keycloak DB, MLflow DB + artifacts,
  gateway keys, `site.conf`.
- **Done when:** a fresh install from the bundle works with no internet; upgrade from the previous release keeps
  users, models, keys and running endpoints' records.

---

## Before step 1

- Answers to the senior questions in [README.md](README.md) (at least 1 and 3).
- cn02 is often down on the dummy cluster: 2-GPU and sharing tests need both nodes, or at least cn01 healthy.

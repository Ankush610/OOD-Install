# Model Hub — version 2 (production, for Rudra)

v1 (tag `v1` in both repos) proved the core on the dummy cluster: a user deploys their own ML, DL or LLM model
from OOD, and it runs as a Slurm job on a GPU. v2 makes it a **product**: secure, shareable, one login, reachable
from laptops, and installable on every **Rudra** rack.

Requirements below were decided with the admin on 2026-10-06. Research behind them: [research.md](research.md).
Steps, one at a time: [build-plan.md](build-plan.md). Problems and fixes as we go: [build-log.md](build-log.md).

## Status: closed 2026-10-13

| Step | |
|---|---|
| 2 one login · 3 scheduling rules · 4 gateway + keys · 5 sharing · 6 app on the gateway · 6b public models | **done**, tested live (ML, DL, LLM) |
| 8 admin page (users, teams, limits, Running, stops with a message) | **done**; usage logs only in the gateway pod's output |
| 1 network lock · 7 NVMe cache · 9 Rudra packaging · usage logs on disk | **moved to [v3](../version-3/README.md)** |

**Not safe for real users yet:** without step 1 any pod can still reach an endpoint directly, past the gateway.

## What Rudra is

A single-rack AI system we **sell**. It runs at the customer's site, for the customer's users.

| | |
|---|---|
| Nodes | 3 CPU nodes + 2 GPU nodes (4–8 GPUs each, NVLink, local NVMe) |
| Users | researchers and institutes (sometimes small orgs), up to ~100, all with a Rudra login (LDAP) |
| Network | behind the customer's firewall; usually has internet, **must also work without it** |
| Looked after by | the customer's IT admin, plus our team remotely |
| Software | **the same on every Rudra** (no per-customer feature picking) |

## Product rules (apply to every part)

1. **Installs from our scripts** (`OOD-Install`, values in `site.conf`), the same way on every rack. Rerunning is safe.
2. **Works offline.** Images come from the rack's own registry; nothing downloads at runtime.
3. **The customer's admin can run it** without us: add users, see what runs where, read logs, fix common problems.
4. **Upgradable.** A new Rudra release updates a running rack without losing users, models or keys.
5. **Every version is pinned** (charts, images, packages). No `latest`.

## What users do

The main job is **"I trained a model, now put it online"** (not chat-first).

```
 train (Slurm, SIF) ──► register in MLflow ──► deploy from Model Hub ──► call it
                         (every model)          (runs as a Slurm job     (from the cluster or a laptop,
                                                 on 1–2 GPUs)             with a personal API key)
                                                       │
                                                       └── share: only me / people / groups / everyone
```

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Model types | LLM, deep learning, classic ML | all three are used |
| Catalog | **every model goes through MLflow** first (`log_model`, or `model-register` for HF folders) | one list of all models, with who made them and how |
| Who can call a model | **owner decides per endpoint**: only me / named people / LDAP groups / everyone. No admin approval | owners know who needs it |
| Where calls come from | inside the cluster **and** laptops on the customer network | both are needed |
| How calls get in | **one gateway**: HTTPS, a key on every request, checks the owner's sharing rules. **The only way in** | one place for security, keys and usage |
| Keys | **one API key per person**, works for every model they may call | like an OpenAI key; can be revoked per person |
| Login | **Keycloak on top of LDAP**: log in once for OOD, MLflow, Model Hub. LDAP stays the user list (SSH, Slurm, files) | one login, nothing duplicated |
| GPUs | **1 per person** by default, the admin can raise one person to 2. Models up to ~70B (2 GPUs over NVLink) | fair share on a 8–16 GPU rack |
| GPUs busy | the model **waits in line**. Training jobs are never stopped. No GPUs reserved for serving | training is the rack's main job |
| Run time | **1 day** default, **4 days** max; longer only by admin approval | GPUs come back to training |
| Model files | stay on NFS; copied to the GPU node's NVMe on first use, so later starts are fast | a 70B model is ~140 GB |
| Downtime | an hour is acceptable (research tool) → **one** gateway, no HA pairs | keeps it simple |
| Usage reports | planned now (the gateway logs who called what), built later | the customer's admin will ask "who uses my GPUs?" |

## The picture

```
 Customer network (laptops)                  Inside Rudra (notebooks, jobs, VS Code)
            │                                              │
            └──────────────────────┬───────────────────────┘
                                   ▼
             Keycloak (login once; checks passwords in Rudra's LDAP)
                                   │
          ┌────────────────────────┼──────────────────────────┐
          ▼                        ▼                          ▼
   OOD + Model Hub app          MLflow                 Gateway (HTTPS, port 443)
   deploy · share · my key ·    every model            key → person → may they call
   admin page                   starts here            this endpoint? → forward
                                                                │
                              network lock: nothing else        │
                              can reach the models  ────────────┤
                                                                ▼
                         User endpoints: pod in u-<owner>, runs as the owner's UID,
                         Slurm job via slurm-bridge (1–2 GPUs, 1–4 days)
                         weights: NFS → NVMe cache on the GPU node
```

## What we keep from v1 (proven, see version-1/build-log.md)

| Kept | Notes |
|---|---|
| Namespace per user `u-<user>`, UID policy, PSA `restricted`, GPU `ResourceQuota` | the security base for NFS; quota becomes per-person (1 or 2) |
| slurm-bridge scheduling: **bare pods**, `slurmjob.*` annotations, `exclusive: false`, `DynamicResources` patch | all hard-won; time limit now 1 day / 4 days |
| Serving images `mlflow-serve-ml`, `mlflow-serve-torch` (pinned to the training SIFs, pt2 device fix), vLLM | add 2-GPU vLLM (tensor parallel) |
| `render.py` (pod + service objects), OOD app pages (models, model card, deploy, endpoints, playground, help) | the playground and API tab move to the gateway |
| `model-register` for HF folders | `--public` is **dropped**: any owner can make a model public (below); the MLflow READ grant sync stays, driven by the `public` tag |
| Registry `master:5000`, `site.conf`, idempotent numbered scripts | product rule 1 |

## What changes from v1

| v1 | v2 |
|---|---|
| Flannel: any pod can reach any endpoint | network lock (Calico or Cilium): only the gateway reaches endpoints |
| Separate logins (OOD, MLflow, each with LDAP) | Keycloak single sign-on |
| Endpoints reachable only inside the cluster (ClusterIP, ssh tunnel) | gateway on the customer network, HTTPS |
| A vLLM key per endpoint; ML/DL endpoints have no key | one personal key for everything, checked by the gateway |
| Private only (sharing via MLflow grants, confusing) | owner shares per endpoint: people / groups / everyone |
| Public models only by admin (`--public`) | owner sets a **model** private or public (everyone); no per-person/team model sharing (users copy files themselves, outside Model Hub) |
| 1 GPU, 24 h, for everyone | 1 GPU (admin: 2), 1 day default / 4 days max |
| Weights read over NFS on every start | NVMe cache on the GPU node |

## Not in v2 (later)

- Shared always-on models run by the platform (e.g. one Qwen for everyone): no GPUs are reserved, so not now.
- Autoscaling and scale-to-zero, models larger than 2 GPUs or across nodes (KServe / llm-d).
- Sharing a **model** with chosen people or teams: models are only private or public (decided 2026-10-07). Teams who
  want a copy download it and share it themselves, outside Model Hub.
- Usage reports and budgets (the data is collected from step 4 of the build plan; reports come later).
- Connecting to the customer's own Active Directory / SSO (Rudra brings its own LDAP + Keycloak).

## Risks (and what we do about them)

| Risk | Plan |
|---|---|
| **slurm-bridge is young** (1.2.x; we hit two GPU bugs; its docs don't list the NVIDIA DRA driver) | pin the version; every install runs a GPU test; keep the `DynamicResources` check in setup; watch upstream 1.3 |
| Changing the network plugin on a running cluster is disruptive | do it first, on the dummy cluster, before any user depends on it; a fresh Rudra installs it from day one |
| A model waits a long time when training fills the GPUs | show the queue position in Model Hub; the admin can use a Slurm reservation if a customer wants serving guaranteed |
| The gateway is a single door | an hour of downtime is OK; running endpoints keep running; restart is automatic (k8s) |
| Keycloak touches every login | test OOD + MLflow login with Keycloak on the dummy cluster before switching; keep the old login as a fallback until it's proven |

## Questions for the senior

1. **Network plugin:** OK to replace flannel with Calico (or Cilium) on Rudra? This is what makes the gateway the only way in.
2. **GPU node storage:** NVMe size on the GPU nodes? Is there anything faster than NFS for shared files?
3. **Gateway address:** what name/IP will customers use (e.g. `models.<customer-domain>`)? Do we ship a self-signed
   certificate, or does the customer give us one?
4. **Remote support:** how does our team reach a customer's rack (VPN, customer opens access when needed)?
5. **Releases:** how do we version and ship Rudra updates (git tag + offline bundle of images)?

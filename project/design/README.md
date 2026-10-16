# Model Hub — full design (all versions)

Goal: one web UI where a user picks any registered model (classic ML, DL, LLM), deploys it to a GPU/CPU
endpoint with a few clicks, tries it in a playground, and calls it from scripts with a token.
Same pattern as the "AI factory" platforms (NVIDIA NIM / OpenShift AI / Databricks / SageMaker):
**standard package formats → a fixed runtime catalog → one or two API protocols → one generic UI.**

Other parts of the design: [user-flow.md](user-flow.md) (the full path, all versions) ·
[serving.md](serving.md) (catalog, runtimes, pods, UI backend, gateway) · [tenancy.md](tenancy.md)
(namespace per user, UID policy, quota, onboarding) · [publishing.md](publishing.md) (sharing models, v2).
**What we are building now:** [versions/version-3/](../versions/version-3/README.md).

Builds on: [container registry](https://ankush610.github.io/AI-Factory-Docs/how-it-works/06-containers-and-registry/) (`master:5000`), this repo
(LDAP, OOD, shared MLflow; **the Model Hub code goes in `OOD-Install/5-model-hub/`**),
[vLLM notes](../vllm-notes.md), [cluster architecture](https://ankush610.github.io/AI-Factory-Docs/how-it-works/01-cluster-architecture/).

## TL;DR decisions

| # | Decision | Why |
|---|---|---|
| 1 | **MLflow = catalog.** The live server is OOD-Install's (LDAP login, per-user permissions, tokens in `~/.mlflow/credentials`) | Already running; permissions come for free |
| 2 | **Weights come from both places:** small models are downloaded from MLflow with the deployer's token; big weights are mounted from `/home/apps/models` (path stored as an MLflow tag) | 15 GB+ LLMs through a 2 Gi MLflow pod is too slow |
| 3 | **Inference = k8s pods via Slinky slurm-bridge**, one namespace per user `u-<user>`, UID pinned by policy | RBAC per user; NFS safety ([tenancy.md](tenancy.md)) |
| 4 | **UI = OOD Passenger app**, backend runs **as the logged-in user** | No second login, no root/impersonation ([docker-slinky](../rejected/docker-slinky.md)) |
| 5 | **k8s access = per-user client cert** in `~/.kube/config` (0600), made at onboarding | Real RBAC; same as the user running kubectl |
| 6 | **Onboarding hooks into `1-ldap/add-user.sh`** (like `3-sync-tokens.sh`), plus a sync script for existing users | One command per new person |
| 7 | **GPU quota: 1 per user** (`ResourceQuota`). GPU types (A30, H100, ...) read from `sinfo` **at install**; the matching DRA DeviceClass is made at install too ([tenancy.md](tenancy.md)) | Few GPUs; no hardcoded card type |
| 8 | **Endpoint lifetime 24 h**, renewable from the UI ("Extend") | GPUs come back automatically |
| 9 | **Callers: owner + people they share with.** Enforced in one place: the gateway | Sharing is per endpoint, not per namespace |
| 10 | **API access: per-user token** through an always-on **gateway** (NodePort, like MLflow) | Scripts, Slurm jobs, notebooks |
| 11 | **Day-one runtimes: vLLM, llama.cpp, mlflow-serve (sklearn/xgboost/torch), Triton** + users' own images | Covers LLM, GGUF, classic ML/DL, ONNX/TensorRT |
| 12 | **Public tier** (`models-public` ns): **admin-only** deploys; everyone calls with their token; weights copied to node-local disk | Popular models run once, not once per user |
| 13 | **Chat = the playground's chat**, no Open WebUI yet | One UI |

Decisions 8 (Extend), 9, 10 (gateway, sharing), 11 (llama.cpp, Triton, custom) and 12 (public tier) are **v2+**;
see [versions/version-1](../versions/version-1/README.md) for what v1 keeps.

## Directory layout (everything on the shared `/home/apps`, NFS)

```
/home/apps/
├── mlflow-shared/                 mlflow:mlflow 0700   EXISTING (MLFLOW_DATA). Only the MLflow pod touches it.
│                                                       Never mounted into inference pods.
├── registry/                      root 0755            registry:2 storage behind master:5000
├── models/                        modelhub 0755        weights, see [publishing.md](publishing.md)
│   ├── base/<org>/<model>/<rev>/                       admin-mirrored upstream weights
│   ├── published/<user>/<name>/<vN>/                   MODEL.yaml + weights, dirs 0555 / files 0444
│   ├── .tmp/                                           publish staging (0700)
│   └── PUBLISH.log
├── model-hub/                     root:apps 0755       the product; READ-ONLY at runtime (no state here)
│   ├── ood-app/model_hub/                              installed to /var/www/ood/apps/sys/model_hub
│   │   ├── manifest.yml
│   │   ├── passenger_wsgi.py                           backend, runs AS the user ([serving.md](serving.md))
│   │   ├── site.json                                   written at install: MLflow URI, gateway URL, GPU list from sinfo
│   │   └── public/                                     the registry-ui (index.html, app.js, style.css)
│   ├── runtimes.yaml                                   format → image in master:5000 → protocol → args
│   ├── templates/                                      k8s YAML with ${VARS}; the backend fills them
│   │   ├── serve-vllm.yaml
│   │   ├── serve-llamacpp.yaml
│   │   ├── serve-mlflow.yaml
│   │   ├── serve-triton.yaml
│   │   └── serve-custom.yaml                           user's own master:5000/<user>/<image>
│   ├── gateway/                                        token-checking reverse proxy (image source + manifest)
│   │   ├── Containerfile  app.py
│   │   └── gateway.yaml                                ns model-hub: Deployment + NodePort Service + RBAC
│   ├── onboarding/
│   │   ├── uid-policy.yaml                             cluster-wide, once ([tenancy.md](tenancy.md))
│   │   └── user-ns.yaml                                per user: ns, RoleBinding, quota, PVs/PVCs
│   └── images/                                         Containerfiles for the serving runtimes we build
│       ├── mlflow-serve-sklearn/  mlflow-serve-xgboost/  mlflow-serve-torch/
│       └── README.md                                   which training SIF each one is paired with
├── bin/                           k8s-image, model-publish            (existing plan)
├── libexec/                       model-receive, mlflow-register      (existing plan)
└── containers/                    training SIFs (Slurm side)          (existing plan)
```

Per user (made by onboarding, all 0600/0700, in the user's own home):
```
~/.mlflow/credentials      EXISTING  MLflow job token (3-sync-tokens.sh)
~/.kube/config             NEW       client cert, CN=<user>, only has rights in u-<user>
~/.model-hub/token         NEW       API token for the gateway (v2; its hash lives in k8s, see serving.md "Gateway")
```

**No runtime state on NFS.** Endpoints are k8s objects, UI specs are MLflow tags, run history is in the
browser. So nothing in `/home/apps/model-hub` is written after install: no SQLite, no locks, no permission tangles.

Where the UI's data comes from:

| UI piece | Source of truth |
|---|---|
| Model list, versions, input/output schema | MLflow registry + model signature (user's token → they see only what they may) |
| Weights location | MLflow tag `path` → `/home/apps/models/...` or `~/models/...`; no tag → MLflow artifact |
| Saved UI spec (widget overrides) | MLflow model tag `ui_spec` (owner edits) |
| My endpoints | `kubectl get deploy,svc -n u-<user> -l model-hub/model` |
| Shared-with-me + public endpoints | gateway `GET /api/endpoints` (user can't list other namespaces) |
| Logs, status | `kubectl logs` / pod status in `u-<user>`; Slurm job via slurm-bridge |
| GPU choices | `site.json`, from `sinfo` at install |

## Components

```
 browser ──443 tunnel──► OOD (master) ──► Passenger app model_hub  (runs AS alice)
                                             │  ~/.mlflow/credentials ──► MLflow :30500   (models, schemas, tags)
                                             │  ~/.kube/config ─────────► k8s API          (deploy / delete / logs in u-alice)
                                             │  ~/.model-hub/token ─────► gateway :30600   (playground calls)
                                             ▼
 scripts / Slurm jobs ── token ─────────► gateway (ns model-hub, NodePort 30600)
                                             │  checks token → caller; checks owner / shared-with / public
                                             ▼
                               Service in u-<owner> or models-public ──► serving pod (slurm-bridge → Slurm job on a GPU node)
                                                                          image: master:5000/<runtime>
                                                                          weights: PVC /models, /my-models, or MLflow download
```

Details of each box: [serving.md](serving.md). v1 has no gateway: the app and scripts call the Service directly.

## What won't work / avoid

| Idea | Why not |
|---|---|
| Publish = symlink into `/home/apps/models` | others can't traverse alice's 0700 home; alice can still change the files |
| `chmod` user homes to share | breaks the privacy model for everything else in the home |
| All users in the one `slurm-bridge` namespace | anyone can delete anyone's deployment; no per-user UID pinning |
| Mounting `/home` into pods without the UID policy | NFS trusts the claimed UID: `runAsUser: <bob>` reads bob's home |
| Weights baked into images | a 15 GB image per model version fills the registry; runtime and weights version separately |
| 100 GB LLMs pushed through MLflow artifact upload | slow HTTP proxy + a second copy on disk; store a path tag instead |
| `mlflow models serve` with the default env manager in pods | tries to pip install and pods are offline; `--env-manager local` in a matching image |
| Training SIF and serving image with different sklearn/xgboost | pickles break or silently misbehave; build in pinned pairs |
| Pickles / `torch.save` of whole objects as a published format | loading runs arbitrary code and anyone can publish; prefer safetensors / GGUF / MLflow flavors, warn on others' pickles |
| Mutable `latest/` directories or `:latest` tags | a running endpoint changes under your feet; immutable versions + aliases |
| iframing every tool into one custom page | X-Frame-Options, separate logins, sub-path issues; use links |
| Standalone JupyterHub / home-grown dashboard | can only run as one fixed UID or as root impersonating users; OOD already spawns as the real user |

## Future scope (not day one)

| Feature | What it adds | Needs |
|---|---|---|
| TEI runtime | embeddings / rerankers for RAG | mirror `text-embeddings-inference` image |
| HF transformers server | non-LLM HF models (vision, audio, NER) without MLflow packaging | KServe `huggingfaceserver` image, v2 protocol |
| `pywrap` custom runtime | user writes `load()` / `predict()`, platform wraps it | base image + builder (like Cog / BentoML) |
| Autoscaling on queue | vLLM replicas on `num_requests_waiting` ([vllm-notes](../vllm-notes.md)) | Prometheus + KEDA |
| Scale to zero | idle endpoints give back GPUs, cold start on first call | KEDA HTTP add-on or Knative |
| MIG slices | several users per A30/H100 | GPU operator MIG config + DRA `mig.nvidia.com` |
| Real network isolation | pods can't bypass the gateway | Calico/Cilium instead of flannel + NetworkPolicy |
| Open WebUI | ChatGPT-style UI on public endpoints | one Deployment pointed at the gateway |
| Single sign-on | one login for OOD, MLflow, gateway | Keycloak + OIDC on top of LDAP |
| Metrics dashboards | req/s, latency, GPU use per endpoint | Prometheus + Grafana, DCGM exporter |
| Batch inference | run a model over a dataset as a job, not an endpoint | Slurm/k8s Job template in the same wizard |
| Canary / A-B | two versions behind one name, traffic split | gateway weighted routing |
| Optimized engines (NIM-style) | TensorRT-LLM / quantized builds per GPU type | build pipeline per GPU arch |

## Known limits / risks

1. **MLflow's SQLite location.** `mlflow.db` + `auth.db` live in `/home/apps/mlflow-shared` (hostPath on master).
   Dummy cluster: that's master's local ext4 (master is the NFS server), so it's fine. Production: if master
   mounts `/home` over NFS, SQLite is safe only with exactly one writer (`Recreate` + `--workers 1`, both set);
   move the DBs to master's local disk or PostgreSQL then. Model Hub only uses the MLflow API either way.
2. **flannel doesn't enforce NetworkPolicy.** Any pod can call any endpoint's ClusterIP directly and skip the
   gateway's checks. Acceptable for trusted users; fix with Calico/Cilium (future scope).
3. **slurm-bridge `managedNamespaces` per user** = a Helm upgrade per onboarding ([tenancy.md](tenancy.md) "Onboarding" step 5).
4. **1 GPU per user with few GPUs**: a queue forms in Slurm. The UI must show "Pending: waiting for a GPU" from
   the pod/Slurm state, not a spinner forever.
5. **Extend restarts the pod.** Big LLMs take minutes to reload.
6. **Loading pickles runs code.** `mlflow-serve` on someone else's shared sklearn model trusts that person
   (see "What won't work"). The UI shows a warning when deploying a model you don't own.
7. **GPU quota with DRA.** GPUs reach pods through the NVIDIA DRA driver; `nvidia.com/gpu` is an extended
   resource mapped by a DeviceClass (`a30` today). A quota on `requests.nvidia.com/gpu` counts pods that ask
   that way, but a user could create a ResourceClaim for the class directly and skip it. So the quota must also cap
   `<class>.deviceclass.resource.k8s.io/devices` for every GPU class. **Verify on k8s 1.36 in P1** (a second
   GPU pod and a direct ResourceClaim in `u-alice` must both be rejected).
8. **NFS load from big weights**: see [serving.md](serving.md) "NFS and big weights".

## Phases

```
v1 ─────────────────────────────────────────────────────────────────────────────────────────────
P0  Prereqs: KEDA/Prometheus/MetalLB tolerations (namespace deletes stop hanging)
P1  Base: modelhub account + /home/apps/models (base/); mirror 1–2 base models
    Onboarding: user-ns.yaml + UID policy + client cert, hooked into add-user.sh; sync for existing users;
                slurm-bridge managedNamespaces
    Catalog: model-register; admin registers the base models
    Runtimes: mirror vllm-openai; build mlflow-serve-sklearn + mlflow-serve-torch paired with the training SIFs
              (non-root checked); serve templates for the three
    Done when: alice deploys an LLM, an sklearn and a torch model with kubectl in u-alice;
               bob's pod with alice's UID is rejected; a 2nd GPU pod / direct ResourceClaim is rejected
P2  OOD app v1: registry-ui wired to MLflow + kubectl; models, deploy, my endpoints, logs, delete, playground
    Done when: a user goes train → register → deploy → chat/predict entirely from OOD (versions/version-1/user-flow.md)
v2+ ────────────────────────────────────────────────────────────────────────────────────────────
P3  Gateway (token + owner/shared/public check, NodePort 30600) + share dialog + Extend
P4  Publishing (model-publish/model-receive, published/ tree), public tier, llama.cpp/Triton, future scope
```

Version plans: [version-1](../versions/version-1/README.md) = P0–P2. A `version-2/` folder starts with P3.

## New `site.conf` values (for `OOD-Install/5-model-hub/`)

```
MODELHUB_ROOT=/home/apps/model-hub
MODELHUB_NS=model-hub
GATEWAY_PORT=30600                      # NodePort on MASTER_IP
GATEWAY_IMAGE=$REGISTRY/model-hub-gateway:<ver>
ENDPOINT_TIMELIMIT_MIN=1440             # 24 h, Extend restarts it
USER_GPU_QUOTA=1
BRIDGE_PARTITION=slurm-bridge           # slurmjob.slinky.slurm.net/partition
REGISTRY_DATA=/home/apps/registry
MODELS_ROOT=/home/apps/models
MODELHUB_USER=modelhub                  # service account that owns MODELS_ROOT, like mlflow
MODELHUB_UID=951                        # below MIN_UID
NFS_SERVER=$MASTER_IP                   # for the per-user PVs (dummy: master exports /home)
NFS_EXPORT=/home
MAX_USER_GB=500                         # per-user publish cap
```

## Open questions

1. Roughly how many users, and how big is production `/home`? This sets `MAX_USER_GB` and GPU quotas.
2. Production: is login01 a separate machine? OOD-Install puts OOD + `viewer` on `MASTER_HOST` today; if split,
   those move to login01 and `LOGIN_NODES` / sudoers for `model-receive` go there.
3. Production storage: NFS from a storage server, or a parallel FS? Changes `NFS_SERVER`/PV type and risk 1.

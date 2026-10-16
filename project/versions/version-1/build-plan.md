# Model Hub v1 — build plan

Code goes in `OOD-Install/5-model-hub/`, sourcing `OOD-Install/site.conf` like the other numbered folders.
Scripts are safe to rerun. Design details are linked, not repeated.

## P0 — prerequisites (cluster fixes)

- Give **KEDA, Prometheus, MetalLB** pods tolerations / a master nodeSelector (Helm values), like slurm-bridge.
  Until KEDA runs, `v1beta1.external.metrics.k8s.io` is `MissingEndpoints` and **namespace deletes hang**,
  which breaks deleting test `u-<user>` namespaces.
- **Done when:** `kubectl get apiservice v1beta1.external.metrics.k8s.io` is `True`; deleting an empty namespace finishes.

## P1 — base: storage, tenancy, catalog, runtimes

| File (in `OOD-Install/5-model-hub/`) | Does | Design |
|---|---|---|
| `1-setup.sh` (root, once + after every slurm-bridge `helm upgrade`) | `modelhub` account (UID 951), `/home/apps/models/base/`; applies `onboarding/uid-policy.yaml`; makes the GPU DeviceClass per type from `sinfo`; enables `DynamicResources` in slurm-bridge's `scheduler-config` (Helm resets it; see build-log 2026-10-06); installs `model-register` to `/home/apps/bin` (done 2026-10-06) | [tenancy.md](../../design/tenancy.md), [publishing.md](../../design/publishing.md) "Layout rules" |
| `onboarding/uid-policy.yaml` | pod must run as the namespace owner's UID/GID | [tenancy.md](../../design/tenancy.md) |
| `onboarding/user-ns.yaml` | per user: ns `u-<user>`, RoleBinding, GPU quota, `models-ro` + `my-models` PV/PVC | [tenancy.md](../../design/tenancy.md) |
| `2-sync-users.sh` (root) | for every LDAP user (or one): apply `user-ns.yaml`, client cert → `~/.kube/config`, add ns to slurm-bridge `managedNamespaces` (keep `slurm-bridge`!) | [tenancy.md](../../design/tenancy.md) "Onboarding" |
| hook in `1-ldap/add-user.sh` | runs `2-sync-users.sh <user>` if the cluster answers, like the MLflow token step | |
| `bin/model-register` | user-side: register `~/models/x/vN` in MLflow with a `path` tag | [serving.md](../../design/serving.md) "How models get into the catalog" |
| `images/mlflow-serve-ml/Containerfile`, `images/mlflow-serve-torch/Containerfile` | serving images, versions pinned to the training SIFs | [runtimes.md](runtimes.md) |
| `3-images.sh` (no root) | build + push the two images, mirror `vllm-openai:<pinned>` | [container registry](https://ankush610.github.io/AI-Factory-Docs/how-it-works/06-containers-and-registry/) |
| `templates/serve-vllm.yaml`, `templates/serve-mlflow.yaml` (became `render.py`) | Pod + Service with slurm-bridge annotations | [serving.md](../../design/serving.md) "Serving template" |

Admin, once: download 1–2 base models into `/home/apps/models/base/` and `model-register` them.

**Checks first (cheap, decide the design):**
- A second GPU pod **and** a direct ResourceClaim in `u-alice` are both rejected by the quota (DRA).
- Does slurm-bridge accept a namespace label selector instead of a list? If yes, no Helm upgrade per user.

**Done when:**
- alice deploys an LLM, an sklearn and a torch model **with kubectl** in `u-alice`, and calls each from master;
- bob's pod with alice's UID is rejected;
- a second GPU in `u-alice` is rejected.

## P2 — the OOD app

| File | Does |
|---|---|
| `ood-app/model_hub/manifest.yml`, `passenger_wsgi.py` | backend, runs **as the user**: MLflow (their token), `kubectl` (their kubeconfig), fills the templates |
| `ood-app/model_hub/public/` | UI from the registry-ui mockup (not kept), reworked (see below) |
| `4-install-ood-app.sh` (root) | copies the app to `/var/www/ood/apps/sys/model_hub`, writes `site.json` (MLflow URI, GPU types from `sinfo`) |

Backend API (v1 subset of [serving.md](../../design/serving.md) "UI backend"): `GET /api/models`, `POST /api/deploy`,
`GET /api/endpoints` (own namespace only), `GET /api/endpoints/<n>/logs`, `DELETE /api/endpoints/<n>`,
`POST /api/predict/<n>` (calls the Service directly).

UI rework from the prototype:
- drop the KServe YAML, replicas / autoscaling / scale-to-zero, the free-form Register form, fake `data.js`;
- deploy wizard: version · runtime (auto from format) · CPU or GPU type · 24 h · YAML preview;
- endpoints: **Mine** only, status (waiting for GPU / loading / ready), countdown, logs, delete, URL + curl/python
  example (+ API key for LLMs);
- playground: chat (OpenAI) or a form from the MLflow signature (`/invocations`);
- "how to get your model here" page.

**Done when:** a user goes train → register → deploy → chat/predict entirely from OOD
([user-flow.md](user-flow.md)), for one ML, one DL and one LLM model.

## New `site.conf` values for v1

```
MODELS_ROOT=/home/apps/models
MODELHUB_ROOT=/home/apps/model-hub
MODELHUB_USER=modelhub                  # service account, like mlflow
MODELHUB_UID=951                        # below MIN_UID
ENDPOINT_TIMELIMIT_MIN=1440             # 24 h
USER_GPU_QUOTA=1
BRIDGE_PARTITION=slurm-bridge
NFS_SERVER=$MASTER_IP                   # for the per-user PVs (dummy: master exports /home)
NFS_EXPORT=/home
```
Gateway and publish values (`GATEWAY_*`, `MAX_USER_GB`) wait for v2.

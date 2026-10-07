# 5-model-hub/version2

Deploy registered MLflow models (ML, DL, LLM) as endpoints from OOD. Design and scope:
`../../../AI-Stack/docs/model-hub/` (v1: `versions/version-1/`). Built part by part; this README grows with it.

## Run (on master, after ../../3-mlflow)

```bash
sudo bash 1-setup.sh          # once (+ after every slurm-bridge helm upgrade): modelhub account + MODELS_ROOT, pod UID policy,
                              # GPU DeviceClass(es), DynamicResources in slurm-bridge's scheduler, model-register -> /home/apps/bin
sudo bash 2-sync-users.sh     # every LDAP user (or: 2-sync-users.sh <user> ...); add-user.sh runs it for new people
sudo bash 3-test-tenancy.sh <userA> <userB>   # proves the rules, acting as userA; cleans up after itself
bash 4-images.sh              # no root: build + push the serving images, mirror vLLM; tags -> images/built.env
bash 5-test-serving.sh        # no root: models trained in the ML SIF load + answer in mlflow-serve-ml (local podman)
sudo bash 6-test-endpoints.sh <user> [ml] [llm] [torch] [--keep]   # real endpoints in u-<user>, acting as the user
sudo bash 7-install-ood-app.sh                # the OOD app (Interactive Apps -> Model Hub), then Restart Web Server
```

**Once, by hand (the admin, not scripted):** slurm-bridge manages namespaces by label instead of a fixed list, so
adding a user needs no `helm upgrade`:
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl label ns slurm-bridge aistack/slurm-bridge=true --overwrite      # keep the existing namespace managed
helm upgrade slurm-bridge oci://ghcr.io/slinkyproject/charts/slurm-bridge --version <deployed version> -n slurm \
  --reuse-values --set-json 'admission.managedNamespaceSelector={"matchLabels":{"aistack/slurm-bridge":"true"}}'
kubectl -n slurm rollout restart deploy/slurm-bridge-admission deploy/slurm-bridge-controllers deploy/slurm-bridge-scheduler
sudo bash 1-setup.sh          # REQUIRED after ANY helm upgrade of slurm-bridge: puts DynamicResources back (GPUs)
```

**Every `helm upgrade` of slurm-bridge resets its scheduler profile** (ConfigMap `scheduler-config`, hard-coded in the
chart, no value for it) to `multiPoint: disabled: '*'` with no `DynamicResources`. Pods still get a Slurm job and the
A30 is reserved in Slurm, but the pod's DRA ResourceClaim is never allocated, so no GPU inside the pod. This happened on
2026-09-30 (revision 4 above). `1-setup.sh` step 5 patches it back and restarts only the scheduler.

## Per user

| What | Where | Why |
|---|---|---|
| namespace `u-<user>` | labels `aistack/uid`, `aistack/gid`, `aistack/slurm-bridge=true`, PSA `restricted` | pods run as the user (policy), become Slurm jobs, can't use hostPath/root |
| RoleBinding `edit` | `u-<user>` only | deploy, logs, delete in their own namespace; nothing elsewhere; can't relabel it |
| ResourceQuota `gpus` | `USER_GPU_QUOTA` for `nvidia.com/gpu` and each typed GPU class, 0 for the operator's catch-all classes | a direct ResourceClaim can't get around the limit |
| PVCs `models-ro`, `my-models` | `MODELS_ROOT` and `~/models`, read-only, over NFS from `NFS_SERVER` | the only storage a pod can mount |
| `~/.kube/aistack.config` | 0600, client certificate CN=`<user>`, 1 year, default namespace `u-<user>`; `~/.kube/config` links to it if the user had none | the OOD app and `kubectl` act as the user; rerun renews when < 30 days are left |

## Files

| File | What it does |
|---|---|
| `1-setup.sh` | `MODELHUB_USER` (`MODELHUB_UID`, below `MIN_UID`) owns `MODELS_ROOT/base`; applies `onboarding/uid-policy.yaml`; makes one DeviceClass per Slurm GPU type in `BRIDGE_PARTITION`; enables `DynamicResources` in `BRIDGE_NS`'s `scheduler-config` (restarts `slurm-bridge-scheduler` only if it changed) |
| `model-register` | `model-register DIR NAME [--public]`: a Hugging Face folder (`config.json` + `*.safetensors`) under `~/models/` or `MODELS_ROOT/` → MLflow run with only `MODEL.yaml` + a version tagged `path=DIR`, `format=hf` (MLflow rejects local paths as a source). Weights stay put. LoRA / non-`hf` refused (v1 serves full HF models). `--public` (sudo): registers as the MLflow admin + tag `public=true`; `3-mlflow/3-sync-tokens.sh` then grants every user READ. Installed by `1-setup.sh` (`@VARS@` filled) |
| `onboarding/uid-policy.yaml` | ValidatingAdmissionPolicy: in namespaces labelled `aistack/uid`, pods must run as that uid/gid, no `supplementalGroups`/`fsGroup` |
| `onboarding/user-ns.yaml` | per-user namespace, RoleBinding, PV/PVC pairs (`${VARS}` filled by `2-sync-users.sh`) |
| `2-sync-users.sh` | per LDAP user: `~/models`, `user-ns.yaml`, GPU quota (from `gpu-classes.py --quota`), kubeconfig via the k8s CSR API (`kube-apiserver-client` signer, approved, CSR deleted) |
| `3-test-tenancy.sh` | as userA: RBAC (own ns yes, other ns / relabel / PVs no), UID policy (own uid yes; other uid, root, no securityContext no), a pause pod runs via slurm-bridge, second GPU and direct ResourceClaims rejected |
| `4-images.sh` | builds `images/mlflow-serve-ml` and `images/mlflow-serve-torch` with the training SIF's `/opt/base-constraints.txt` as pip constraints (tag `<mlflow>-<sha8 of it>`), mirrors `vllm-openai:$VLLM_VERSION`, writes `images/built.env` |
| `images/*/Containerfile` | python 3.12 (as the SIFs) + full `mlflow` + the SIF's ML libs at the SIF's versions; `USER 65534`, `HOME=/tmp`, `ENTRYPOINT mlflow models serve --env-manager local` on :8080 |
| `5-test-serving.sh` | trains sklearn (skops + cloudpickle with a pickled `pd.Series`), XGBoost, LightGBM, CatBoost in `ML_TRAIN_SIF`, serves each with `mlflow-serve-ml` as a random UID, calls `/invocations` |
| `6-test-endpoints.sh` | as the user: `mlflow-creds` Secret from `~/.mlflow/credentials`; ml = train + register in MLflow + deploy on CPU; llm = `LLM_PATH` under `MODELS_ROOT` on 1 GPU, 401 without the key, chat with it; torch = train + register + deploy on 1 GPU, checks `torch.cuda` in the pod; calls each at its ClusterIP from master, deletes it unless `--keep` |
| `7-install-ood-app.sh` | copies `ood-app/model_hub` + `render.py` to `/var/www/ood/apps/sys/model_hub`, writes `site.json` (MLflow URI, `images/built.env`, each image's library pins from `images/*/constraints.txt`, `MASTER_HOST` + `SSH_JUMP` for the tunnel command, GPU types from `sinfo`, partition, hours, `MODELS_ROOT`) |
| `ood-app/model_hub/passenger_wsgi.py` | backend, **runs as the logged-in user**: MLflow with `~/.mlflow/credentials`, `kubectl` with `~/.kube/aistack.config` in `u-<user>`; `/api/models`, `/api/models/<n>/<v>` (model card: `MLmodel` flavor/signature/size, the run's metrics/params/experiment/user, `requirements.txt` vs the serving image's pins; LLMs: size, architecture, context, params from safetensors headers, LoRA base), `/api/deploy` (+ `preview`), `/api/endpoints` (state + reason), `logs`, `key`, `predict` (server-side call to the ClusterIP), `DELETE` |
| `ood-app/model_hub/index.html` + `public/` | the page, **Bootstrap 5.3.8 + Bootstrap Icons 1.13.1 vendored in `public/vendor/`** (no CDN; works without internet in the browser). `index.html` is outside `public/` on purpose (see Troubleshooting). Pages: Models, model detail + Deploy (CPU/GPU, hours, preview modal), My endpoints (state badge, reason, time left, delete modal), endpoint Playground (chat for LLMs, form from the signature or JSON for ML/DL), API (**Accessing on cluster**: ClusterIP URL, hidden vLLM key + `/v1` base URL, request/response format from the signature, health path, one curl, `input.json` download for big tensors; **On your local machine**: one `ssh [-J SSH_JUMP] -L 8080:<ClusterIP>:8080 <user>@MASTER_HOST`), Logs, Help; dark mode |
| `render.py` | one endpoint → Secret (vLLM API key) + **bare Pod** + Service in `u-<user>`: runs as the user, slurm-bridge annotations on the pod itself (partition, time limit, job name, `exclusive: "false"`), probes. Not a Deployment: slurm-bridge ignores pod-template annotations and a Deployment would restart an expired endpoint forever (see Troubleshooting). mlflow: initContainer downloads `models:/<name>/<v>` with the user's token; vllm: model from the read-only PVCs, optional LoRA. `python3 render.py --test` |
| `gpu-classes.py` | Slurm type (`gpu:a30:1`) → the one DRA product name that matches (`NVIDIA A30`, not the `RTX A400` display card) → DeviceClass YAML. One type: the class maps `nvidia.com/gpu`. `--quota N`: the ResourceQuota lines. Self-test: `python3 gpu-classes.py --test` |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| step 4: `No GPU class made` | no GPU node up (no ResourceSlices), or Slurm's type name isn't in the DRA product name | start a GPU node and rerun; for odd names create the DeviceClass by hand from `gpu-classes.py`'s output format |
| GPU pod Running with a Slurm job (A30 allocated in `scontrol show job`) but no `/dev/nvidia*`, `nvidia-smi` missing, vLLM `Failed to infer device type`, empty `status.extendedResourceClaimStatus` | a `helm upgrade` of slurm-bridge reset `scheduler-config`: no `DynamicResources` plugin, so the DRA ResourceClaim is never allocated | `sudo bash 1-setup.sh` (step 5), then redeploy the pod |
| `6-test-endpoints.sh`: `Cannot set a deleted experiment 'mh-test-<user>'` | the experiment was deleted in the MLflow UI (soft delete: it sits in the trash, name still taken) | fixed: `register()` restores it first; by hand: restore it in the MLflow UI |
| torch endpoint exits: `exported by torch.export API ... weights / buffers on 'cpu' device, it can't be loaded on 'cuda'` | MLflow 3.x logs torch as pt2 by default, and MLflow only loads a pt2 model on the device it was exported on | fixed in the image: `images/mlflow-serve-torch/sitecustomize.py` moves it to the serving device (`move_to_device_pass`); rebuild with `4-images.sh` |
| a user can't see an admin base model in Model Hub | MLflow's `default_permission = NO_PERMISSIONS`: each user needs a READ grant | `sudo bash ../../3-mlflow/3-sync-tokens.sh` (grants READ on every `public=true` model; add-user.sh runs it for new people) |
| `2-sync-users.sh`: `Run 1-setup.sh first` | no UID policy yet; a user namespace without it would let pods claim any UID | run `1-setup.sh` |
| test pod stays `Pending`, no Slurm job | namespace not labelled `aistack/slurm-bridge=true`, or slurm-bridge still on its list config | `kubectl -n slurm get cm slurm-bridge-config -o yaml` must show `managedNamespaceSelector` |
| user's `kubectl`: `Unauthorized` | certificate expired or cluster CA changed | rerun `2-sync-users.sh <user>` |
| deploy fails: `denied request: ... pod-runs-as-namespace-owner` | the pod's uid/gid isn't the namespace owner's | render with the user's own `uid`/`gid` |
| endpoint runs past its hours; `scontrol show job` says `TimeLimit=365-00:00:00`, `JobName=(null)`, all 48 CPUs | slurm-bridge reads `slurmjob.*` annotations from the pod's **top owner**; under a Deployment that's the Deployment, so pod-template annotations are ignored (and an ended job's pod would be recreated) | endpoints are bare Pods (`render.py`); never wrap one in a Deployment/ReplicaSet |
| deploy: `<name> is still running` | pods can't be changed in place; re-applying would move the UI's expiry but not Slurm's | delete the endpoint first, or use another name |
| Model Hub page shows plain unstyled HTML | `index.html` was in `public/`: for `/pun/sys/model_hub` (no slash) OOD's nginx (`alias <app>/public$1`) serves it itself, and relative CSS/JS paths resolve to `/pun/sys/` | keep `index.html` in the app root; the app serves it with `<base href=…/model_hub/>` |
| `UID 951 already belongs to ...` | `MODELHUB_UID` taken locally | pick another free UID below `MIN_UID` in `site.conf` |

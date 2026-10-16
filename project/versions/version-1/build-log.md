# Model Hub v1 — build log

What happened while building v1, in order: problems found, fixes, what is still open. Newest at the bottom.
Plan: [build-plan.md](build-plan.md).

## 2026-09-30 — P0: master tainted, cluster DNS down

**Found:** master carried `slinky.slurm.net/managed-node=slurm-bridge-scheduler:NoExecute` again. Every pod on
master without that toleration was evicted and stayed Pending (`3 node(s) had untolerated taint(s)`):

| Namespace | Stuck |
|---|---|
| kube-system | **coredns** (both replicas) → cluster DNS down for ~2 days |
| cert-manager | cert-manager, cainjector, webhook |
| gpu-operator | gpu-operator, node-feature-discovery gc + master |
| keda | operator, metrics-apiserver, admission-webhooks → `v1beta1.external.metrics.k8s.io` `MissingEndpoints` → namespace deletes hang |
| monitoring | prometheus-server |
| metallb-system | controller; speaker DaemonSet had 0 desired |
| headlamp-dashboard-sanket | headlamp |

Still running: MLflow and the slurm-bridge pods (they already tolerate it), DaemonSets on cn01.

**Cause:** `OOD-Install/4-vscode/2-slurm-viewer.sh` made master a Slurm node (`viewer` partition). slurm-bridge's
node-controller taints **every k8s node that is also a Slurm node**, not only nodes in its own partition, and
re-adds the taint if removed (log: `"Add taint to node" ... "master"` at 09:32). The chart (1.2.x) has no option
to exclude a node.

**Options considered:**
- A. Toleration on every pod that must run on master. Done first, then replaced by B.
- B. Rename master's Slurm node (`NodeName=viewer01 NodeHostname=master`) so slurm-bridge doesn't match it.
  **Tested and adopted** (see below).
- C. Drop the `viewer` partition. Loses VS Code editor-only sessions.

**Done:**
- coredns patched with the toleration (`kubectl patch`), both replicas Running (master + cn01). DNS back.
- `OOD-Install/4-vscode/4-k8s-tolerations.sh`: adds the toleration to all the workloads above, safe to rerun.
  Documented in `4-vscode/README.md` (run step 4 + troubleshooting row + Helm values snippet).

**Open:**
- ~~Run `4-k8s-tolerations.sh`~~ **Done 2026-09-30** by the admin: all 13 workloads patched, no Pending pods,
  `v1beta1.external.metrics.k8s.io` = `True`. **P0 done.**
- `helm upgrade` / `kubeadm upgrade` of these components resets the patch: rerun the script, or add the
  toleration to their Helm values.
- Every Model Hub pod meant for master (gateway in v2) needs the toleration too. Serving pods already have it
  (they run through slurm-bridge).
- ~~Production: decide A vs B~~ → B.

## 2026-09-30 — B tested: rename master's Slurm node → works

Admin ran: `slurm.conf` → `NodeName=viewer01 NodeHostname=master NodeAddr=master ...`, `PartitionName=viewer
Nodes=viewer01`; copied to cn01; restarted slurmctld + slurmd; removed the taint from master; waited 2 min.

| Check | Result |
|---|---|
| `sinfo -N -p viewer` | `viewer01 idle` |
| `srun -p viewer hostname` | `master` |
| master's taints after 2 min | only `control-plane` |
| controller log `Add taint to node ... master` (3 min) | 0 |

**Conclusion:** slurm-bridge matches k8s nodes to Slurm nodes **by name**. With a different `NodeName` master is
never tainted, so no toleration patches are needed.

**Changed in OOD-Install:** `site.conf` `VIEWER_NODE=viewer01`; `4-vscode/2-slurm-viewer.sh` writes
`NodeName=$VIEWER_NODE NodeHostname=$MASTER_HOST`, replaces an old `NodeName=master` line, and removes a leftover
taint; `4-k8s-tolerations.sh` deleted (never needed on a fresh install); README + troubleshooting updated.
The tolerations already patched on this cluster are harmless and stay. `mlflow.yaml` keeps its toleration too.

## 2026-09-30 — P1 part 2: one-time setup (`OOD-Install/5-model-hub/1-setup.sh`)

**Written:** `1-setup.sh`, `onboarding/uid-policy.yaml`, `gpu-classes.py`, `README.md`; `site.conf` gets
`MODELS_ROOT MODELHUB_USER MODELHUB_UID BRIDGE_PARTITION USER_GPU_QUOTA ENDPOINT_HOURS`.

**Found:**
- DRA lists **two** NVIDIA devices per node: `NVIDIA A30` and `NVIDIA RTX A400` (display card). Slurm only
  schedules the A30. So a GPU class must select the exact product name, or pods could get the A400.
  `gpu-classes.py` maps the Slurm type to the one matching product name (word match: `a40` ≠ `A400`).
- First draft of the UID policy put `containers`, `initContainers`, `ephemeralContainers` in one CEL list;
  they are different types, which only shows up as a type-check warning after creation. Split into three checks.

**Checked (no root, nothing changed):** `kubectl apply --dry-run=server` accepts the policy; the generated `a30`
class is identical to the hand-made one (`unchanged`, empty `kubectl diff`); `gpu-classes.py --test` passes
(A30, H100 name, A40-vs-A400, several types → no `nvidia.com/gpu` mapping).

**Ran** (admin, 2026-09-30): `modelhub` 951 owns `/home/apps/models{,/base}` 0755; policy + binding created,
`status.typeChecking` empty (no CEL warnings); `a30` class unchanged, maps `nvidia.com/gpu`.
**Open:** the UID policy is proven only once tested with pods in a `u-<user>` namespace (part 3).

## 2026-09-30 — slurm-bridge: namespaces by label (admin, by hand)

The permission check blocks Claude from scripting a `helm upgrade` of slurm-bridge, so the admin ran it:
`kubectl label ns slurm-bridge aistack/slurm-bridge=true`, then `helm upgrade slurm-bridge
oci://ghcr.io/slinkyproject/charts/slurm-bridge --version 1.2.2 -n slurm --reuse-values --set-json
'admission.managedNamespaceSelector={"matchLabels":{"aistack/slurm-bridge":"true"}}'` (revision 4) and a rollout
restart of the 3 slurm-bridge deployments.

**Result:** `config.yaml` has `managedNamespaceSelector: aistack/slurm-bridge: "true"` (no list); 3 pods Running;
master still untainted. Onboarding a user = labelling `u-<user>`; no helm upgrade per user.
Rollback if needed: `helm rollback slurm-bridge -n slurm`.

## 2026-09-30 — P1 part 3: per-user setup (`2-sync-users.sh`, `3-test-tenancy.sh`)

**Written:** `onboarding/user-ns.yaml` (namespace with `aistack/uid|gid|slurm-bridge` labels + PSA restricted,
RoleBinding `edit`, PV/PVC `models-ro` + `my-models`), `2-sync-users.sh` (+ GPU quota, client-cert kubeconfig
`~/.kube/aistack.config` via the CSR API), `3-test-tenancy.sh`, `gpu-classes.py --quota`, hook in
`1-ldap/add-user.sh` (step 7), README. `site.conf`: `NFS_SERVER`.

**Decisions:**
- **GPU quota covers both ways to get a GPU:** `requests.nvidia.com/gpu` = N, the typed class (`a30`) = N, and the
  operator's catch-all NVIDIA classes (`gpu.nvidia.com`, `mig.nvidia.com`, `vfio.gpu.nvidia.com`) = 0, so a direct
  ResourceClaim can't take a second GPU (or the A400). Whether a pod asking `nvidia.com/gpu` is *also* counted
  against `a30.deviceclass…/devices` is what the test finds out.
- kubeconfig goes to `~/.kube/aistack.config` (fixed path for the OOD app); `~/.kube/config` becomes a link to it
  only if the user has none, so nobody's own config is overwritten.
- No NetworkPolicy: flannel doesn't enforce it (see README "Known limits" 2).
- Test pods use `pause:3.10.1`, containerd's sandbox image, present on every node: no registry, works offline.

**Checked (no root):** syntax; the rendered namespace + both PVs pass `--dry-run=server` for `ankush`; the test's
pod/claim YAML passes client validation; `--quota 1` on the live classes gives the 5 lines above.

**Ran** (admin, 2026-09-30): `2-sync-users.sh ankush test` created both namespaces, PV/PVCs, quotas, kubeconfigs.
`3-test-tenancy.sh ankush test`: **16 passed, 0 failed** (RBAC ×5, UID policy ×4, pause pod Running on cn01 as
Slurm job 1240, second GPU pod + direct claims on all 4 NVIDIA classes rejected).

- The `a30` claim was rejected while the first GPU pod existed, so a pod asking `nvidia.com/gpu` **is** counted
  against `a30.deviceclass…/devices` too: one user can't hold 2 GPUs by mixing the two ways. Open question closed.
- Slurm shows the bridge job's user as **`slurm`**, not `ankush`: the pod runs as UID 1009, but Slurm accounting
  and fairshare charge the bridge's account. Per-user GPU limits therefore come from the k8s quota, not Slurm.
  Revisit if per-user Slurm accounting of endpoints matters.

**P1 tenancy done.** Next: serving images + templates (`mlflow-serve-ml`, `mlflow-serve-torch`, `vllm-openai`).

## 2026-09-30 — P1 part 4: serving images + endpoint renderer

**vLLM version:** "latest" = newest release **v0.30.0** (2026-09-22; registry's old `:latest` was v0.28.0).
Default image = **CUDA 13.0.2**; nodes run driver **580.142** (CUDA 13.0), so it fits. The `-cu129` variant (13 GB)
isn't needed. `site.conf` `VLLM_VERSION=v0.30.0`, mirrored as `master:5000/vllm-openai:v0.30.0` (never `latest`).

**MLflow serving images pinned to the training SIFs automatically:** each SIF has its full `pip freeze` in
`/opt/base-constraints.txt` (ml-classic: 160 packages, pytorch-mlflow: 234; both Python 3.12.14). `4-images.sh`
copies it in as pip constraints, so numpy/pandas/sklearn/torch… are the SIF's exact versions (pickles load), and
tags the image `<mlflow>-<sha8 of the freeze>`: a rebuilt SIF gives a new tag, never a moved one. The SIFs only have
`mlflow-skinny` (log, can't serve); the images add full `mlflow` of the same version.

**Renderer instead of envsubst templates:** `render.py` (Secret + Deployment + Service). LoRA and GPU/CPU are
conditional, which envsubst can't express cleanly; the OOD backend (Python) will import it. Self-test passes;
both runtimes pass `--dry-run=server` in `u-ankush` (PSA restricted + UID policy).

**Found:** a Deployment with the wrong uid is *accepted* (the policy checks pods): it sits at 0 pods with a
`FailedCreate` event. The UI must show pod-creation errors, not just "Pending".

### Image build problems + option A (pandas 3) proven

1. **Silent fallback to an ancient mlflow.** With the SIF freeze as constraints and `mlflow` unpinned, pip couldn't
   fit mlflow 3.15.1 and quietly installed a years-old mlflow (import failed on `google.protobuf.service`).
   Fix: `mlflow==${MLFLOW_VERSION}` (the SIF's skinny version) so pip fails loudly.
2. **The full freeze is too strict:** the SIF pins its Jupyter stack, e.g. `cryptography==50.0.1`; mlflow needs `<50`.
   Fix: pin only model-relevant packages (`images/<name>/pin.txt`, 11 for ML, 6 for torch).
3. **pandas:** full mlflow 3.15.1 declares `pandas<3`; both SIFs train with pandas 3.0.5 (skinny doesn't care).
   Options: A force 3.0.5 / B pandas 2 in serving / C rebuild SIFs. **Chose A**: pandas is left out of the resolve,
   then `pip install --no-deps pandas==3.0.5`; `verify-pins.py` fails the build on any drift.
   Build: all 11 pins `ok` (numpy 2.4.6, pandas 3.0.5, sklearn 1.9.0, xgboost-cpu 3.3.0, lightgbm 4.7.0, catboost
   1.2.10, …), mlflow 3.15.1, image 1.3 GB.
   **Proof** (`5-model-hub/5-test-serving.sh`): trained in `ml-classic-cpu.sif`, served by the image as uid 4242:
   sklearn Pipeline carrying a pickled `pd.Series` → PASS, XGBoost → PASS, LightGBM → PASS, CatBoost → PASS.
4. **MLflow 3.15 saves sklearn (and LightGBM's sklearn API) with `skops` by default; the SIF has no `skops`.**
   `mlflow.sklearn.log_model(model, ...)` with defaults fails in the SIF with `No module named 'skops'`.
   Works today: `serialization_format="cloudpickle"`. Open: add `skops` to the SIF (+ serving image), or document
   cloudpickle for users. skops is also the safer format (no code runs on load; README risk 6).
   **Decided (2026-09-30): add skops.** `ml-classic-cpu.def` (in `/home/apps/Containers-CDAC/ml-classic/`) gets
   `skops==0.16.0` next to `mlflow-skinny`, a `%test` step that saves + loads a model in the default format, a
   `%help` note, and a notes entry. skops adds one package (`prettytable` 3.18.0; its `wcwidth` is already there).
   Snippet pre-checked on the old SIF with skops in a temp PYTHONPATH: `model.skops` written, loaded, same
   predictions. Serving: `mlflow-serve-ml` installs `skops` and pins it from the SIF's freeze (`pin.txt`).
   `5-test-serving.sh` now serves sklearn + LightGBM in skops format too (plus the cloudpickle/pandas case).
   **Open:** admin rebuilds the SIF; then `4-images.sh` and `5-test-serving.sh`.

### 2026-09-30 — rebuilt SIF with skops; images

- Admin rebuilt `ml-classic-cpu.sif` (17:34): `skops==0.16.0`, `prettytable==3.18.0`; pandas 3.0.5, sklearn 1.9.0 unchanged.
- `4-images.sh`: **`master:5000/mlflow-serve-ml:3.15.1-9141c12c` pushed**, all 12 pins `ok` (skops included).
- `5-test-serving.sh` on the pushed image: **5/5 PASS** — sklearn (skops, default), sklearn (cloudpickle + pickled
  `pd.Series`), XGBoost, LightGBM (skops, default), CatBoost.
- `mlflow-serve-torch` first build failed inside pip: `BrokenPipeError` while downloading the torch wheel from
  download.pytorch.org (flaky link, same as earlier PyPI/Open VSX trouble). Fix: `RUN --mount=type=cache` for pip's
  cache (finished downloads survive a failed build), `--retries 10 --timeout 120`, and `4-images.sh` retries a build
  up to 3×. Rerun: try 1 failed again, **try 2 succeeded** from the cache.
- **All three in the registry** (`images/built.env`):
  - `master:5000/mlflow-serve-ml:3.15.1-9141c12c` — 12 pins ok, 5/5 serving test
  - `master:5000/mlflow-serve-torch:3.15.1-346a6fb0` — 6 pins ok (torch 2.10.0+cu129, torchvision 0.25.0+cu129,
    numpy 2.1.3, pandas 3.0.5, triton 3.6.0, cloudpickle 3.1.2)
  - `master:5000/vllm-openai:v0.30.0`
- The old `vllm-openai:latest` (v0.28.0) is still in the registry; nothing uses it.
- Open: the torch image isn't serving-tested yet (needs a GPU pod: part 5, in-cluster deploys).

## 2026-10-01 — Registry cleanup + P1 part 5: real endpoints (`6-test-endpoints.sh`)

**Registry cleanup:** `registry:2` had deletes off (405). Admin deleted the 0-replica bench Deployment
`slurm-bridge/vllm-qwen3-5-4b` (still pointed at `vllm-openai:latest`) and restarted the registry with
`REGISTRY_STORAGE_DELETE_ENABLED=true` (now in `docs/cluster/container-registry.md`). Deleted by digest after checking
none shares a digest with a kept tag: `mlflow-server:3.15.1`, `qwen-llama:0.5b`, `qwen-llama:0.5b-cuda`,
`vllm-openai:latest`. Kept: `mlflow-serve-ml`, `mlflow-serve-torch`, `mlflow-server:3.15.1-ldap`, `vllm-openai:v0.30.0`.
Disk is freed only by `registry garbage-collect --delete-untagged` (admin).

**Written:** `6-test-endpoints.sh <user> [ml] [llm] [torch]`: acts as the user end to end (their MLflow token →
`mlflow-creds` Secret, their kubeconfig), calls endpoints at the ClusterIP from master, deletes them after.

**Found (users will hit these too; for the user guide / OOD help page):**
- **MLflow 3.15 saves PyTorch as `pt2` (torch.export) by default and requires `input_example`**; without it
  `mlflow.pytorch.log_model` fails. With it, the torch image serves the pt2 model (checked locally on CPU:
  `{"predictions": [[3.19e-22], [1.0]]}`).
- sklearn defaults to `skops` (see above): fine now that the SIF has it.
- `mlflow models serve` ignores SIGTERM for 10 s+, so endpoint pods take the full grace period (30 s) to stop.

**LLM weights:** `Qwen3.5-0.8B` (1.7 GB, `Qwen3_5ForConditionalGeneration`) exists at
`/home/admin/Documents/AI-Stack/model/`; to be copied to `MODELS_ROOT/base/qwen/Qwen3.5-0.8B` as `modelhub`.

### 2026-10-01 — `6-test-endpoints.sh ankush`: 3 passed, 2 failed — GPU pods get no GPU

- **ml: PASS end to end.** Trained in `ml-classic-cpu.sif` as ankush with their token, registered
  `mh-test-sklearn` v1, deployed on CPU in `u-ankush` (initContainer downloaded it with the `mlflow-creds` Secret),
  `/invocations` → `{"predictions": [0, 1, 1]}`.
- **llm: FAIL** — vLLM `RuntimeError: Failed to infer device type`. **torch: FAIL** — `mlflow models serve` exited 1
  (log cut off above the real error; may be a second problem, see below).
- **Diagnosis** (pod `mh-gpu-diag` in `slurm-bridge`, `nvidia.com/gpu: 1`, as uid 1009): no `/dev/nvidia*`,
  no `nvidia-smi`, `torch.cuda` False, empty `extendedResourceClaimStatus`. The pod was scheduled and got a Slurm job,
  but **no GPU was allocated or attached**. Not a non-root problem.
- **Cause:** slurm-bridge's scheduler profile disables every default plugin (`multiPoint: disabled: '*'`), incl.
  `DynamicResources`; its own plugin handles DRA. **slurm-bridge 1.2.2 (latest release) supports only the CPU DRA
  driver and the DRA *example* GPU driver — not the NVIDIA DRA driver.** NVIDIA DRA support is in `main`
  (**1.3.0-rc1, unreleased**): pods must request `deviceclass.resource.kubernetes.io/gpu.nvidia.com`;
  `nvidia.com/gpu` means the NVIDIA *device plugin*; `extendedResourceName` aliases (our `a30` class) are ignored.
- So `nvidia.com/gpu` + slurm-bridge has never attached a GPU on this cluster since the GPU operator moved to DRA.
  The 3-test-tenancy GPU checks only proved admission + quota, not that a GPU arrives. All `k8s/examples/*gpu*`
  manifests are affected the same way.
- `6-test-endpoints.sh` now prints the first error lines of a failed pod, and `TORCH_GPUS=0` runs the torch test on CPU.
- **Open — decision needed:** how GPU endpoints get a GPU (slurm-bridge 1.3.0-rc1 / device plugin / bypass slurm-bridge).

### 2026-10-01 — CORRECTION after reading slurm-bridge source (v1.2.2 tag vs main)

The claim above ("1.2.2 supports only the example GPU driver; NVIDIA DRA only in 1.3.0-rc1") was **wrong**: it came
from the v1.2.2 README, which is out of date. Source + changelog (codeload tarballs of tag v1.2.2 and main):
- `CHANGELOG-1.1.md`: "Add in NVIDIA GPU handling for the NVIDIA GPU driver" → **1.1, 1.2.x support NVIDIA DRA**.
- How 1.2.2 does it (`internal/nodeinfo/nodeinfo.go` GetDeviceRequests, `scheduler/plugins/slurmbridge/dra.go`):
  for each GRES Slurm allocated to the job, `deviceClassName := gres.Type`; a claim is made only if a DeviceClass
  with that **exact name** exists **and** the name is `gpu.nvidia.com` or `gpu.example.com` (`isSupportedDRADriver`).
  The claim selects `device.attributes['gpu.nvidia.com'].name in ['gpu-<Slurm GRES index>']`, so the pod gets the
  very GPU Slurm picked. The pod must request `deviceclass.resource.kubernetes.io/gpu.nvidia.com: N`.
  `nvidia.com/gpu` is treated as the device plugin (`slurmjobir.go`), never DRA.
- **Why we got no GPU:** our Slurm GRES type is `a30` (not `gpu.nvidia.com`) and pods asked `nvidia.com/gpu`.
- **main / 1.3.0-rc1 (unreleased):** `sharedConfig.deviceProfiles`; a profile's `name` becomes the Slurm GRES type and
  its `selector` must exactly match a DeviceClass's single CEL selector. So a custom profile `name: a30` with our `a30`
  class's selector would let Slurm keep `gpu:a30`. `extendedResourceName` aliases still not resolved.
- Open: confirm Slurm GRES index == NVIDIA `gpu-<minor>` name on the nodes (A30 = gpu-0, A400 = gpu-1 per DRA).

## ⚠ PARKED (2026-10-01): GPU endpoints — torch + vLLM tests still FAILING

> **CLOSED 2026-10-06:** llm (vLLM) and torch (DL) both pass on the A30; see "v1 closed" at the end.
> **2026-10-06: root cause found and fixed, see the last entry ("GPU pods got no GPU: Helm reset").** The
> "Why no GPU" below (GRES type must be `gpu.nvidia.com`) was **not** the cause: `nvidia.com/gpu` + the `a30` class
> works once `DynamicResources` is enabled in slurm-bridge's scheduler. llm/torch tests still need a rerun.

Moved on to the GUI (P2); come back here before v1 is called done.

| Test (`6-test-endpoints.sh ankush`) | Status | Reason |
|---|---|---|
| ml (sklearn, CPU) | PASS | — |
| llm (vLLM, Qwen3.5-0.8B, 1 A30) | **FAIL** | pod gets no GPU → vLLM `Failed to infer device type` |
| torch (mlflow-serve-torch, 1 A30) | **FAIL** | same GPU cause likely; also check on CPU: `sudo TORCH_GPUS=0 bash 6-test-endpoints.sh ankush torch` (the pod log was cut off above the real error) |

**Why no GPU:** slurm-bridge 1.2.2 attaches a GPU via DRA only when the Slurm GRES **type** is literally
`gpu.nvidia.com` and the pod requests `deviceclass.resource.kubernetes.io/gpu.nvidia.com`. Ours: Slurm type `a30`,
pods request `nvidia.com/gpu` (device-plugin path) → no claim, no `/dev/nvidia*`. Details: correction section above.

**To pick when back:**
1. Stay on 1.2.2: Slurm GPU type `a30` → `gpu.nvidia.com` (slurm.conf + gres.conf); batch `--gres=gpu:a30:1` breaks,
   `--gres=gpu:1` keeps working.
2. slurm-bridge 1.3.0-rc1 (pre-release) with a device profile `name: a30` → Slurm keeps `gpu:a30`.

**Then change:** `render.py` (request `deviceclass.resource.kubernetes.io/<class>` instead of `nvidia.com/gpu`, gres
annotation type), GPU quota in `2-sync-users.sh`/`gpu-classes.py --quota` (`gpu.nvidia.com` class is 0 today → would
block it), `3-test-tenancy.sh` GPU checks (also assert the pod *sees* a GPU, not just admission), rerun
`6-test-endpoints.sh ankush llm torch`. First confirm Slurm GRES index = NVIDIA `gpu-<minor>` on cn01 (gres.conf).

## 2026-10-01 — P2: the OOD app (GUI)

**Written** (`OOD-Install/5-model-hub/`): `ood-app/model_hub/{manifest.yml, passenger_wsgi.py, public/}`,
`7-install-ood-app.sh` (writes `site.json`). The prototype's look (`style.css`) is kept; `app.js` is new and has no
fake data, KServe YAML, autoscaling or register form.
- Backend runs **as the logged-in user** (Passenger): MLflow REST with their token, `kubectl` with their kubeconfig,
  `render.py` for the objects. Model kind comes from MLflow: a `path` tag → LLM/vLLM; else the `MLmodel` file's
  flavors (pytorch → DL/torch image, else ML/CPU) and signature (→ playground form). Endpoint state + reason from pod
  status and events (`queued` = waiting for Slurm, `failed` incl. `FailedCreate` from the UID policy).
- Endpoints are called server-side at the ClusterIP; only the user's own vLLM key is shown, on request.

**Checked:** `node --check`; backend routes via a WSGI harness (no creds → clear "ask the admin" errors, bad names
400, unknown routes 404, `u-ankush` listing with admin's kubeconfig); every page rendered in headless Firefox
against a mock backend with real-format data (models, model + deploy form, endpoints, ML playground form from the
signature, LLM chat while queued, help). Found + fixed: the endpoint page had no spinner while loading.

**Not yet tested:** real MLflow/k8s calls as a user through OOD → install with `7-install-ood-app.sh`, log in as
ankush. LLM/torch deploys will still fail on the parked GPU issue; ML works.
- **First real load (admin, 2026-10-01): page unstyled, nothing loaded.** OOD opened `/pun/sys/model_hub` (no
  trailing slash), so relative `style.css`, `app.js`, `api/...` went to `/pun/sys/...`. The mock test used `/` and
  missed it. Fix: the backend 301-redirects an empty PATH_INFO to `SCRIPT_NAME + "/"` (checked: `''` → 301
  `/pun/sys/model_hub/`, `/` and `/app.js` → 200).
- Redirect alone didn't fix it (admin reinstalled: still unstyled), probably because OOD hands the app PATH_INFO `/`
  even for the slash-less URL. Fix that doesn't depend on the URL: the backend injects
  `<base href="<SCRIPT_NAME>/">` into `index.html` (checked: `/` and `/endpoints` → `<base href="/pun/sys/model_hub/">`).
- `<base>` injection didn't help either. **Real cause** (OOD's own template,
  `/opt/ood/nginx_stage/templates/app.conf.erb`): `location ~ ^/pun/sys/<app>(/.*|$) { alias <app>/public$1; ... }`.
  For the slash-less URL `$1` is empty, the alias is the `public/` directory, and **nginx serves `public/index.html`
  itself** as the directory index — the Passenger app never sees the request, so neither the redirect nor `<base>`
  ran. (OOD and Passenger docs say nothing explicit about this; read from the template.)
  **Fix:** `index.html` moved out of `public/` to the app root; the app serves it (any non-file path) with
  `<base href="<SCRIPT_NAME>/">`; `style.css`/`app.js` stay in `public/` for nginx. Rule for OOD Passenger apps:
  **never put index.html in public/.**

## 2026-10-01 — UI redesigned on Bootstrap 5.3 (admin's request)

- **Bootstrap 5.3.8** + **Bootstrap Icons 1.13.1** vendored into `public/vendor/` (724 KB; from jsdelivr, no CDN at run
  time). `style.css` is now ~20 lines (chat bubbles, code blocks, card hover); everything else is Bootstrap classes.
- Components: navbar with user badge + dark-mode toggle (`data-bs-theme`, remembered per browser), cards for models,
  list-group for endpoints with state badges (ready/queued/loading/failed/stopped → success/warning/info/danger/secondary),
  breadcrumbs, form validation on the endpoint name, modals for delete confirm and YAML preview, nav-tabs on an
  endpoint, chat with typing indicator + temperature slider, toasts, accordion help incl. "register an existing run".
- Same backend API; `app.js` rewritten. Checked: `node --check`; all pages + dark mode screenshotted in headless
  Firefox against the mock backend. Fixed: signature "Shape" showed `""` for plain columns.

### 2026-10-01 — torch endpoint on CPU crashed (CrashLoopBackOff) — FIXED

- ankush deployed a PyTorch model on CPU from the UI → `serve` crash loop. Log: torch inductor (MLflow 3 loads `pt2`
  models via torch.export) calls `getpass.getuser()` → `pwd.getpwuid(1009)` → **`KeyError: uid not found: 1009`**:
  the pod runs as the user's UID, which has no `/etc/passwd` entry in the image.
- Local tests passed because **podman adds a passwd entry for `--user` UIDs; Kubernetes doesn't.**
- Fix (`render.py`, all endpoint pods): env `USER`/`LOGNAME` = the user (getuser() reads these first) and
  `TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor`. Self-test asserts it.
- Proof (`podman run --passwd=false --user 1009`): without the env → same KeyError; with it →
  `{"predictions": [[0.378]]}`. `5-test-serving.sh` now runs with `--passwd=false` too.
- This was very likely also the torch failure in `6-test-endpoints.sh` (log was cut off there). vLLM may hit the same.
- After reinstalling, the redeploy still crashed identically: the new Deployment (created after the install) had no
  `USER`/`LOGNAME`. ankush's Passenger process still had the **old `render.py` in memory**. Passenger restarts a
  Python app on `tmp/restart.txt`, not on a touched `passenger_wsgi.py`. `7-install-ood-app.sh` now touches
  `$APP/tmp/restart.txt`. Rule: **after reinstalling an OOD Passenger app, restart.txt or Restart Web Server**.

### 2026-10-01 — torch on CPU works; playground gets image input

- After Restart Web Server + redeploy, ankush's PyTorch endpoint **runs** (`ankush-model-v1`, pod with
  `USER`/`LOGNAME`, 1/1 Ready on cn01). The getpwuid fix is confirmed in the cluster.
- ankush's model: input `[-1, 1, 28, 28]` float32 (MNIST-style), output `[-1, 10]`. The playground only offered
  JSON for tensors, and its example was **wrong** (used only the last dim: 28 zeros).
- Added (`public/app.js`): `imageLayout()` reads the tensor signature (`[N]` square-flattened, `[H,W]`, `[C,H,W]`,
  `[H,W,C]`, C = 1 or 3) → **Image** input mode: upload (fit on black) or draw on a pad; the browser resizes to H×W,
  grey or RGB, lays out CHW/HWC/flat, scales 0–1 / 0–255 / ImageNet mean-std, optional invert; shows what the
  model gets. **Output**: class-score rows → predicted class + top-5 bars (softmax when they look like logits), raw
  JSON under a toggle. JSON example now zeros in the full shape.
- Checked: layout/example/softmax logic in node (8 shapes incl. non-image ones → null); the exact request format
  sent to ankush's **live** endpoint (a drawn vertical stroke) → class **1** at 99%; UI screenshot with the mock.

### 2026-10-01 — Playground scope decided: JSON + auto helpers; "build your own UI" via Gradio

- **Decision (admin):** no per-input widget picker / `ui_spec` in v1 (it amounts to rebuilding Gradio). The playground
  keeps JSON always + the auto helpers already built (form for named-column signatures, image upload/draw for
  image-shaped tensors, chat for LLMs, class-score bars). Anything else → the user's own Gradio app. Widget picker +
  `ui_spec` stay a v2 idea if several users ask for the same missing input type.
- **API tab → "Your own UI":** `gradioApp()` writes a ready `app.py` for that endpoint: image models → `gr.Image` +
  `gr.Label` top-5 (resize/grey/layout from the signature, softmax), LLMs → `gr.ChatInterface` via the OpenAI client
  (`MH_KEY` env), table models → `gr.Dataframe` with the signature's columns, else a JSON box. Run on master with
  python3.12 (Gradio 6.29 needs ≥3.10; system python3 is 3.9), tunnel port 7860. **Help** gets the same steps.
- **Checked** with Gradio 6.29.0 in a python3.12 venv: all 4 generated apps build and serve (HTTP 200); the image app
  through PIL → ankush's live endpoint → class 1 (97%). The LLM app's chat call is untested (no vLLM: parked GPU issue).

### 2026-10-01 — No ssh tunnels for users: own UIs go through OOD's `/rnode` proxy

- Admin: in production the user is on a laptop with only OOD in the browser; `ssh -L` is just how we reach this test
  cluster. So the Gradio steps ("add -L 7860") were wrong.
- OOD here: `rnode_uri: /rnode`, `host_regex` default `[^/]+` (any host), prefix stripped before proxying,
  `ProxyPreserveHost On` (so apps see OOD's host), behind OOD's login. **Any logged-in OOD user can reach any
  `/rnode/<host>/<port>`** → a user's app needs its own password.
- Generated `app.py` now: runs on the cluster (OOD VS Code terminal or ssh on the login node), picks a free port,
  `root_path=/rnode/<host>/<port>`, `auth=(USER, random password)`, prints `https://<OOD>/rnode/<host>/<port>/` + the
  password. Help updated: no install on the laptop, no tunnel.
- **Checked** (Gradio 6.29, all 4 variants): with the headers Apache sends, Gradio's root =
  `https://localhost/rnode/master/<port>`; assets are relative; API without login → 401, with the password → 200;
  the image app, logged in, upload + predict through Gradio's API → ankush's live endpoint → "1". Not yet clicked
  through real OOD (needs a user login).
- Other `-L` places: `OOD-Install/README.md` now says production users open OOD directly and the tunnel is for this
  test cluster; the MLflow page no longer tells users to add `-L`.
- **Open (production):** the MLflow web UI (NodePort `MASTER_IP:30500`) is the one thing not behind OOD; OOD's `/node`
  proxy strips `Authorization`, which MLflow's login needs. Users' network must reach it, or MLflow needs another
  login path (e.g. a cookie/session in front of it).
- **Open (production):** the user's Gradio app calls the endpoint's ClusterIP, which works where the app runs on a k8s
  node (master here). A separate login node that is not a k8s node can't reach ClusterIPs → the v2 gateway.

## 2026-10-01 — Endpoints ran past their hours → endpoints are now bare Pods

**Found:** ankush deployed a DL model for **1 h**; after 1 h 20 min it was still running. `scontrol show job 1254`:
`TimeLimit=365-00:00:00`, `JobName=(null)`, `AllocTRES cpu=48` (asked 2). The pod carried
`slurmjob.slinky.slurm.net/timelimit: "60"`, but Slurm never got it.

**Cause** (slurm-bridge v1.2.2 source, `internal/utils/slurmjobir/`):
- `TranslateToSlurmJobIR` → `applySlurmAnnotations` parses the annotations of the pod's **root owner**
  (`getRootOwnerMetadata`: pod → ReplicaSet → Deployment; Deployment isn't a known workload type, so the top owner
  wins). Our slurmjob.* annotations sat on the pod **template**, so timelimit, job-name and gres were all ignored;
  partition fell back to the config default (`slurm-bridge`), so nothing looked wrong.
- `exclusive` defaults to **true** (`sharedFromExclusiveAnnotation`): every endpoint, even a 2-CPU one, took the
  whole node (and its A30 away from batch jobs).
- When a job ends, slurm-bridge **deletes the pod** (`controller/pod/pod_sync.go`). Under a Deployment the
  ReplicaSet makes a new pod = a new job: even with a working time limit, the endpoint would never stop.
- `3-test-tenancy.sh` used a bare pod, so it never showed this. `k8s/examples/{qwen-bridge-gpu,vllm-bench}.yaml`
  (Deployments with template annotations) have the same bug.

**Fix:** an endpoint = **bare Pod** + Service (+ key Secret). A bare pod is its own root owner, and nothing recreates it.
- `render.py`: Pod with the slurmjob.* annotations on its own metadata + `exclusive: "false"`; `model-hub/model` and
  `model-hub/expires` also on the Service, which outlives the pod. **gres annotation dropped**: it never reached
  Slurm before (GPU jobs got `gres/gpu=1` from the `nvidia.com/gpu` limit), and `gres:gpu:a30:1` is not the format
  slurm-bridge itself writes (`gres/gpu:<type>=N`); the parked GPU fix decides this.
- `passenger_wsgi.py`: endpoints listed from Services; no pod = **stopped** ("deploy again"); deploy refuses (409)
  while a pod of that name exists (pods are immutable, and re-applying would move only the UI's expiry);
  delete = `pod,svc,secret`; logs from the pod.
- `6-test-endpoints.sh`: `kubectl wait --for=condition=Ready pod/…` instead of `rollout status`; logs/exec on the pod.
- Docs: `serving.md` (Serving pods, Expired/Delete/Extend), `5-model-hub/README.md` (render.py row + 2 troubleshooting
  rows), build-plan row.

**Checked:** `render.py --test` ok. On the cluster, `ankush-model` v1 rendered as a Pod with the Slurm limit set to
2 min: job 1255 `mh-ankush-mh-expiry-test`, `TIME_LIMIT 2:00`, **2 CPUs** (not 48), pod Ready. At 2 min Slurm ended
it, slurm-bridge deleted the pod, **60 s later still no pod and no job**; the Service stayed. Backend (new code,
live namespace): endpoint `ready` → after expiry `stopped`; redeploy over the running pod → 409. Test endpoint deleted.

**Open:** reinstall the app (`sudo bash 7-install-ood-app.sh`, then Restart Web Server). Fix or delete the two
Deployment examples in `k8s/examples/` if they're used again.

### 2026-10-01 — API tab made generic (admin's request)

- The API tab no longer ships framework code (Python snippet, generated Gradio `app.py`). It now lists what **any**
  client needs (Flask, FastAPI, Streamlit, Gradio, notebook, job): protocol, base + full URL (copy), method, headers,
  vLLM key (hidden, copy) + model name, request body format, inputs/outputs from the signature, response format,
  health path; plus **one curl**. For big tensors (images) the curl pipes `python3 -c` zeros in the right shape
  instead of pasting 784+ numbers (checked: `[-1,1,28,28]` → shape `(1, 1, 28, 28)`).
- Help step 4 is framework-neutral: run your app on the cluster, open it via `/rnode/<host>/<port>/` with its base path
  set to that, and give it a password (every OOD user can reach `/rnode`). `gradioApp()` removed.
- Checked: `node --check`; screenshots of an ML (tensor) and an LLM endpoint's API tab against a mock backend.

### 2026-10-01 — Model page: a card for picking a version (admin's request)

The model page repeated the API tab (full input/output tables). It now shows what helps choose a version:
- **Does**: one line (`float32 tensor [-1,1,28,28] → float32 tensor [-1,10]`, or `N columns: …`); full format stays in the API tab.
- **Results**: the run's metrics as tiles (fallback: MLflow 3 logged-model metrics); **Training settings**: run params, collapsed.
- **Provenance**: registered when / by whom, experiment / run name, run duration, **Open in MLflow** (run page).
- **Size**: `model_size_bytes` from `MLmodel`. LLMs: size on disk, architecture, dtype, context length (`config.json`,
  incl. `text_config`), parameter count summed from the safetensors **headers** only (Qwen3.5-0.8B: 873 M, 1.6 GB, 0.00 s),
  LoRA base + rank (`adapter_config.json`).
- **Libraries**: the model's `requirements.txt` vs the serving image's pins (`site.json` `image_libs`, written by
  `7-install-ood-app.sh` from `images/*/constraints.txt` + mlflow from the tag). Local labels (`+cu129`) ignored,
  `xgboost-cpu`≡`xgboost`, `mlflow-skinny`≡`mlflow`. Mismatch → warning badge `torchvision 0.26.0 → 0.25.0`.
- **Already running**: my endpoints serving this version, linked. vLLM endpoints now also carry `models:/<name>/<v>`
  in `model-hub/model` so they match too.
- Backend: `model_card()` (only for `GET /api/models/<n>/<v>`; deploy still calls the lighter `model_version()`);
  every extra is best effort (missing run/requirements = a gap, not an error). The endpoint page caches the card per
  model URI instead of refetching it on every 5 s refresh.
- Checked: `lib_check` on torch + ml pins (match, mismatch, aliases), `llm_card` on the real Qwen folder; screenshots
  (light + dark, DL with a drift, LLM) against a mock backend. **Not checked against live MLflow** (no MLflow login
  from the admin shell): field names are MLflow's documented REST ones (`runs/get`, `experiments/get`, `logged-models`).

### 2026-10-01 — API tab: endpoints unreachable from a laptop → show the OOD address too

**Found:** ankush ran the API tab's curl on his laptop: `/ping` and `/invocations` on `10.107.43.198:8080` just hung.
From master the same calls answered (200, 10 predictions). A ClusterIP only exists inside the cluster; the tab said
so in one easy-to-miss sentence. The `python3 -c … | curl -d @-` example for image tensors was also confusing.

**Fix (no new server code):** the app's existing `POST /api/endpoints/<n>/predict` is already a per-user proxy:
OOD's Apache asks for the cluster login (Basic auth, `AuthBasicProvider ldap file`: 401 without it), the backend runs
as that user, can only see their namespace, and adds the vLLM key itself. So the API tab now shows two addresses:
- **From your computer:** `https://<OOD>/pun/sys/model_hub/api/endpoints/<n>/predict`, `curl -u <user>` (or
  `requests.post(..., auth=(user, password))`), `-k` on the self-signed dummy cert; no LLM key needed.
- **From inside the cluster:** the ClusterIP URL (+ `/v1` base URL and key for OpenAI clients, health path).
- Request/response format once, for both. Big example bodies: `-d @input.json` + a **Download input.json** button.
- Help step 4: an app can now run on your computer (OOD address) or on the cluster (direct address).

**Limits:** through OOD there is no streaming (the backend returns the whole answer) and OpenAI client libraries
don't fit (they send `Authorization: Bearer`, OOD needs Basic): use the direct address on the cluster for those.
Each call does a few `kubectl get`s first (~1 s). The v2 gateway (token, streaming) replaces this.
**Not tested end to end** from a laptop (needs a user's password): screenshots against a mock only.
- Follow-up: the laptop curl failed with `SSL certificate ... self-signed (60)`; the `-k` hint was a footnote.
  `7-install-ood-app.sh` now checks OOD's certificate (from `ood_portal.yml`: issuer = subject → self-signed) and
  writes `tls_self_signed` to `site.json`; the example curl then includes `-k` itself. Production with a real
  certificate gets no `-k`.

### 2026-10-01 — API tab: on cluster + ssh tunnel (OOD route dropped from the page)

Decided with ankush: the OOD `predict` route + cluster password isn't the standard way (breaks under SSO, the password
becomes an API key, ~1 s overhead), and production access will be the P3 gateway (`https://models.<site>`, Bearer
token, port 443). Until the site has DNS/network for it, users reach endpoints from their machine with an ssh tunnel.
- API tab = **Accessing on cluster** (URL, LLM key/base URL/model name, method, body, inputs/outputs, response,
  health, one curl) + **On your local machine** (one `ssh -L 8080:<ClusterIP>:8080 <user>@<MASTER_HOST>`, with
  `-J <user>@<SSH_JUMP>` when set; then `http://localhost:8080`).
- New `site.conf` `SSH_JUMP` (this cluster: `10.208.34.138`; `""` in production); `site.json` `ssh: {login, jump}`.
- Removed: the self-signed-cert detection + `-k` (only the OOD route needed it). The backend `predict` route stays
  (the playground uses it).
- Checked: screenshots (ML + LLM) against a mock backend.

## 2026-10-06 — GPU pods got no GPU: our `helm upgrade` dropped `DynamicResources` from slurm-bridge's scheduler

**Found by the senior admin:** Slurm reserved the A30 fine, but Kubernetes DRA never completed the claim/injection path:
`DynamicResources` was missing from slurm-bridge's scheduler profile. They patched the ConfigMap back (2026-10-01 13:06 UTC,
`kubectl patch`) and restarted only `slurm-bridge-scheduler`. Then the pod's DRA ResourceClaim was created + allocated
and the NVIDIA DRA driver put the A30 in the container. Checked 2026-10-06: pod `qwen-bridge-gpu` (ns `slurm-bridge`,
`nvidia.com/gpu: 1`) has `/dev/nvidia0`, `nvidia-smi` shows the A30, and claim `…-extended-resources-…` is `allocated,reserved`.

**Why it broke (our side):** ConfigMap `slurm/scheduler-config` is Helm-managed, and the chart template
(`templates/scheduler/configmap.yaml`, 1.2.2) **hard-codes** the plugin list: `multiPoint: disabled: '*'`, no
`DynamicResources`, and no value to change it. Someone had hand-patched `DynamicResources` in before. Our
`helm upgrade --reuse-values` on 2026-09-30 (**revision 4**, the `managedNamespaceSelector` change, see above)
re-rendered the ConfigMap from the chart (managedFields: `helm` 2026-09-30 10:40 UTC) and **wiped the patch**. From then on
GPU pods got no GPU. This is what the 2026-10-01 `6-test-endpoints.sh` llm/torch failures were. The diagnosis in
the PARKED section (GRES type `a30` vs `gpu.nvidia.com`) was wrong. Nothing in our scripts touched RBAC for
ResourceClaims (the hand-made `slurm-bridge-dra-binding-updater` Role/ClusterRole from 2026-09-14 was never changed).

**Fix (automation; cluster-side changes):**
- `OOD-Install/site.conf`: new `BRIDGE_NS=slurm` (the slurm-bridge release namespace).
- `OOD-Install/5-model-hub/1-setup.sh` new step 5: if `scheduler-config` has no `DynamicResources`, add
  `multiPoint: enabled: [DynamicResources]` (keeps `disabled: '*'`), `kubectl replace`, restart **only**
  `slurm-bridge-scheduler`; already there → no change, no restart. Step 6 (check) prints the `multiPoint` block.
  Fails loudly if the chart ever drops `multiPoint:`.
- `OOD-Install/5-model-hub/README.md`: run order + the helm block say **rerun `1-setup.sh` after every slurm-bridge
  `helm upgrade`**; new troubleshooting row (Slurm job + A30 allocated, but no `/dev/nvidia*` in the pod).

**Checked (no change made to the cluster; it is already patched):** `bash -n`; the step's transform on the chart's
unpatched config gives **exactly** the senior's live config (diff empty); `kubectl replace --dry-run=server` accepted;
input without `multiPoint:` → clear error, exit 1. The live run of step 5 should print `already enabled`.

**Open:** rerun `sudo bash 6-test-endpoints.sh ankush llm torch` (GPU in `u-ankush`, under the ResourceQuota
`a30.deviceclass…/devices: 1`). If it passes, close the PARKED section. Upstream: a chart value for extra plugins would
remove the need for this patch.

### 2026-10-06 — GPU test rerun: llm PASS on the A30; torch blocked by a deleted MLflow experiment

`sudo bash 6-test-endpoints.sh ankush llm torch` (after the DynamicResources fix, in `u-ankush` under the GPU quota):
- **llm: PASS.** vLLM (Qwen3.5-0.8B) on 1 A30 on cn01; no key → 401; chat answered. First GPU endpoint working in a user
  namespace, so the GPU quota (`a30.deviceclass…/devices: 1`) + UID policy + PSA `restricted` allow a DRA GPU pod.
- **torch: FAIL before deploy** — `Cannot set a deleted experiment 'mh-test-ankush'`: it had been deleted in the MLflow UI,
  and MLflow only soft-deletes (the name stays taken until it's purged). Not a GPU problem.
- **Fix** (`OOD-Install/5-model-hub/6-test-endpoints.sh`, test script only, no cluster change): `register()` now
  runs a shared preamble that restores `mh-test-<user>` if it's deleted, then `set_experiment`; both ml and torch use it.
  Checked: `bash -n`, the preamble parses. **Open:** rerun `sudo bash 6-test-endpoints.sh ankush torch`; if it passes,
  close the PARKED section.

### 2026-10-06 — torch on GPU: pt2 model exported on CPU won't load on cuda → fixed in the serving image

**Found:** `6-test-endpoints.sh ankush torch` (experiment restored) → the endpoint pod got its A30, then `mlflow models serve`
exited: `The saved model is exported by torch.export API, the original model contains weights / buffers on 'cpu' device,
it can't be loaded on 'cuda' device`. This is the error the 2026-10-01 log had cut off.

**Cause:** MLflow 3.15 logs torch models as **pt2** (`torch.export`) by default. `mlflow.pytorch._load_model` can't move
a pt2 model and refuses any device other than the export device; serving picks `cuda` when a GPU is visible. Users
will hit it both ways: train/log on CPU → deploy on GPU fails; train on GPU (`net.to('cuda')`) → deploy on CPU fails.

**Fix (image only, no cluster change):**
- `OOD-Install/5-model-hub/images/mlflow-serve-torch/sitecustomize.py` (new, copied into site-packages by the
  Containerfile): wraps `torch.export.load` so the program is moved with `torch.export.passes.move_to_device_pass` to
  the device MLflow will serve on (same rule: `MLFLOW_DEFAULT_PREDICTION_DEVICE`, else cuda if available, else cpu).
  Pickle-format models never reach this path.
- `4-images.sh`: the image tag hash now covers **every file** in `images/<name>/` (was `constraints.txt` only, so an
  image change kept the old tag and the build was skipped). Both serving images get new tags once (ml rebuilds too).

**Checked** in the current torch image (torch 2.10.0+cu129, mlflow 3.15.1) with the file mounted in; no GPU on master, so
`meta` stood in for the other device: export on CPU → load for `meta` fails without the patch (same error), **loads with it**
(params on meta); CPU load + predict unchanged; `mlflow --version` still starts. A real CPU→cuda load is not tested yet.

**Open (admin runs):** `bash 4-images.sh` (new tags → `images/built.env`), `sudo bash 6-test-endpoints.sh ankush torch`,
then `sudo bash 7-install-ood-app.sh` + Restart Web Server so the OOD app deploys the new tags. If torch passes, close
the PARKED section.

- Rerun (new images built): torch trained + registered v2, then deploy failed: `The Pod "mh-torch" is invalid: ... pod
  updates may not change fields`. A `mh-torch` pod from an earlier run (probably stopped before its cleanup) was still
  there, and `kubectl apply` tried to change it in place. `6-test-endpoints.sh` `deploy()` now deletes any leftover
  `app=<name>` pod/svc/secret first (test script only, no cluster change).

## 2026-10-06 — `model-register` written (base LLMs + users' own HF folders into MLflow)

The help page already told users to run `model-register ~/models/my-llm/v1 my-llm`, but it didn't exist.
**Status before:** DL torch on GPU now passes end to end in OOD (admin, 2026-10-06), so the torch pt2 fix works on a real A30.

**Written** (`OOD-Install/5-model-hub/model-register`, installed to `/home/apps/bin` by `1-setup.sh` step 6, `@VARS@`
filled like `0-registry`'s `k8s-image`), per [serving.md](../../design/serving.md) "How models get into the catalog":
- `model-register DIR NAME [--public]`. DIR must be under `~/models/` or `MODELS_ROOT/` (what an endpoint can mount) and
  hold `config.json` + `*.safetensors`. LoRA adapters (`adapter_config.json`) and `MODEL.yaml` `format` ≠ `hf` are refused
  with a hint (v1's vLLM pod serves full HF models only). `MODEL.yaml` is **optional** (design said required): defaults
  `format: hf`, `task: text-generation`; its `license`/`description`/`base_model` are used when present.
- Runs in `ML_TRAIN_SIF` (mlflow 3.15.1) with the user's token. Experiment `model-register-<user>` (experiment names
  are global in MLflow; a deleted one is restored). Logs only `MODEL.yaml`; version source = that artifact
  (MLflow 3.15 rejects a local path as `source` when no run is attached: `_validate_source_run`); tags `path`,
  `format`, `base_model`. The OOD app keys LLMs off the `path` tag (unchanged).
- `--public` (sudo): registers as the MLflow **admin** (`MLFLOW_DATA/admin.pass`, passed by env, never argv) and tags
  the registered model `public=true`.
- **Cluster-side (MLflow) change:** `OOD-Install/3-mlflow/3-sync-tokens.sh` now ends with "Public models": for every
  registered model tagged `public=true`, grant each LDAP user READ via MLflow 3.15's
  `POST /api/3.0/mlflow/users/permissions/grant` (`resource_type: registered_model`). Duplicate → `RESOURCE_ALREADY_EXISTS`
  = counted as "already had it". `add-user.sh` already runs it, so new users get the base models too.

**Checked** against throwaway local MLflow 3.15.1 servers (podman, the torch image's full mlflow):
- usage / not under ~/models or MODELS_ROOT / no config.json+safetensors / LoRA / `format: gguf` / `--public` without
  sudo → each a clear error, exit ≠ 0; a good folder → v1, again → v2.
- version: source `mlflow-artifacts:/…/MODEL.yaml`, run attached, tags `{path, format: hf}`, description from
  MODEL.yaml; run artifacts = `MODEL.yaml` only; `tags.public = 'true'` search returns only the tagged model.
- grant block (exact lines from `3-sync-tokens.sh`) against a basic-auth server: 1st run `1 granted`, rerun
  `1 already had it`, user without an MLflow account listed as FAILED.
- **Not checked:** the real server (no MLflow login from this shell), running as root with `--public`, and a
  user's access with `NO_PERMISSIONS` (the test server's default was READ).

**Admin, next:**
```bash
sudo bash 1-setup.sh                         # installs /home/apps/bin/model-register (other steps: no change)
sudo /home/apps/bin/model-register --public /home/apps/models/base/qwen/Qwen3.5-0.8B qwen3.5-0.8b
sudo bash ../3-mlflow/3-sync-tokens.sh       # every user: READ on qwen3.5-0.8b
```
Then as a user: Model Hub lists `qwen3.5-0.8b` → deploy on GPU → chat (the LLM end-to-end check in OOD).

- `sudo model-register …` → `command not found`: sudo uses its own `secure_path`, which doesn't include `/home/apps/bin`.
  Help text, `1-setup.sh` and this log now say `sudo /home/apps/bin/model-register --public …`.

## 2026-10-06 — v1 closed (committed and tagged `v1` in both repos)

**Works (tested on the dummy cluster):**
- Per-user namespace, UID policy, GPU quota (1 A30), per-user kubeconfig, slurm-bridge time limits (bare pods).
- Serving: classic ML (`mlflow-serve-ml`, CPU), DL (`mlflow-serve-torch`, A30, pt2 device fix), LLM (vLLM, A30):
  `6-test-endpoints.sh ankush ml llm torch` all PASS; DL deployed and called end to end from the OOD app (admin).
- OOD app: models, model card, deploy, endpoints (status, logs, expiry), playground (form, image, chat), API tab, help.
- `model-register` (HF folder → MLflow by path), `1-setup.sh` re-adds `DynamicResources` after slurm-bridge upgrades.

**Not finished in v1, moved to v2:**
- Sharing (public/private, promote): v1's way (MLflow grants via `model-register --public` + `3-sync-tokens.sh`)
  works but is per-service and confusing; v2 replaces it with a gateway that enforces the owner's sharing rules.
- Access from laptops (only ClusterIP + ssh tunnel), one login (separate LDAP checks per service), network isolation
  (flannel: any pod reaches any endpoint), usage reports.
- LLM registered with `model-register --public` and deployed from OOD: registration ran, user visibility not confirmed.

**Next:** `../version-2/` (production design for Rudra, the single-rack product).


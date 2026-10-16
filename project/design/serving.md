# Model Hub — serving (catalog, runtimes, pods, UI backend, gateway)

Part of the [Model Hub design](README.md). Security around these pods: [tenancy.md](tenancy.md).

## How models get into the catalog

Model Hub lists **registered** models from MLflow, using the user's token (so each user sees only what MLflow
allows). Nothing is picked up from the filesystem on its own.

| Model | How the user registers it | Where the weights are | How the pod gets them |
|---|---|---|---|
| Classic ML, DL | `mlflow.<flavor>.log_model(..., registered_model_name="x")`, or MLflow UI → run → *Register model* | MLflow artifacts (`/home/apps/mlflow-shared`) | initContainer `mlflow artifacts download -u models:/x/<v>` with the deployer's token |
| LLM, big DL (GBs) | `model-register ~/models/x/v1 x` | `~/models/x/v1` (or `/home/apps/models/base/...` for admin models) | `my-models` / `models-ro` PVC, read-only mount |

`/home/apps/bin/model-register DIR NAME` (user side, runs as the user with `~/.mlflow/credentials`):
1. Checks `DIR` is under `~/models/` and has a `MODEL.yaml` with `format` (`hf` / `hf-lora`), `task`, `license`.
2. Starts an MLflow run, logs `MODEL.yaml` as its only artifact (a few KB, never the weights).
3. Registers a version of `NAME` from that run, with tags `path=<DIR>`, `format`, `base_model`.

MLflow 3 rejects arbitrary local paths as a version `source`, which is why the version points at the run's
tiny artifact and the real location is a tag. The backend only mounts paths under the deployer's own
`~/models` or under `/home/apps/models`. The UID policy means a pod can't read anyone else's home anyway.

Admin models: the admin runs `model-register` once per `base/` model (as a public-read MLflow model), so
"just deploy Qwen" works without training.

## UI backend (`passenger_wsgi.py`, runs as the user)
- `GET  /api/models`         → MLflow `registered-models/search` + versions + signature + tags
- `POST /api/deploy`         → pick runtime (auto from `format`, user can override) → fill `templates/serve-*.yaml`
                              → `kubectl apply -n u-<user>` with the user's kubeconfig
- `GET  /api/endpoints`      → own namespace (kubectl) + gateway's shared/public list
- `POST /api/endpoints/<n>/extend | share | delete`
- `POST /api/predict/<n>`    → forwards to the gateway with the user's token (the same path scripts use,
                              so sharing is enforced in one place)
- Because it runs as the user, it can only ever do what the user could do with kubectl and MLflow.
- OOD's `/node` proxy strips `Authorization`; that doesn't matter here: the app is under `/pun/sys/`, and
  it talks to the gateway server-side.

## Gateway (ns `model-hub`, the only new always-on service)
- Small reverse proxy (FastAPI/httpx or nginx+lua; keep it tiny). NodePort `30600` on `MASTER_IP`.
- **Token check:** per user, a k8s Secret in `model-hub` holds `sha256(token)` (label `model-hub/user=<user>`).
  The plain token only exists in `~/.model-hub/token`.
- **Who may call:** caller == namespace owner (`aistack/uid` label → user), or caller is in the endpoint Service's
  annotation `model-hub/shared-with: bob,carol`, or the endpoint is in `models-public`.
- **Routes:** `/<endpoint-owner>/<endpoint>/...` → `http://<endpoint>.u-<owner>.svc:8080/...`, streaming passed through
  (SSE for LLMs). `/public/<endpoint>/...` → `models-public`.
- **RBAC:** ServiceAccount can `get/list` pods, services, namespaces cluster-wide and read Secrets in
  `model-hub`. Nothing else, no write rights.
- Runs as a non-root UID, restricted PSA, pinned to master like MLflow (no Slurm time limit).

## Serving pods (per endpoint = a bare Pod + Service in `u-<user>`)
- **A bare Pod, not a Deployment** (slurm-bridge 1.2.2): slurm-bridge reads the `slurmjob.*` annotations from the
  pod's *top owner* (for a Deployment, the Deployment's own metadata, so pod-template annotations are ignored), and
  when the Slurm job ends it deletes the pod, which a Deployment would recreate as a new job, forever. The Service
  outlives the pod, so an expired endpoint is still listed. Found the hard way: version-1 build-log, 2026-10-01.
- `schedulerName: slurm-bridge-scheduler`, toleration `slinky.slurm.net/managed-node`, annotations
  `slurmjob.slinky.slurm.net/partition`, `.../timelimit: "1440"`, `.../exclusive: "false"` (default is the whole
  node). GPU: the `nvidia.com/gpu` limit (slurm-bridge derives `gres/gpu=1`); a typed `.../gres` is untested.
- `runAsUser/runAsGroup` = the user's UID/GID (the UID policy rejects anything else), `runAsNonRoot`, restricted PSA.
- Volumes: `models-ro` PVC → `/models` (public weights), `my-models` PVC → `/my-models` (user's `~/models`),
  `emptyDir` `/tmp`, memory `emptyDir` `/dev/shm` for vLLM/torch.
- MLflow-artifact models: an initContainer runs `mlflow artifacts download -u models:/<name>/<v>` into an
  emptyDir, using a Secret `mlflow-creds` made from the deployer's `~/.mlflow/credentials`.
  "Shared with me" MLflow models work the same way: the deployer has READ, so their token can download.
- Labels: `model-hub/model`, `model-hub/version`, `model-hub/runtime`. Annotations: `model-hub/shared-with`,
  `model-hub/expires` (for the UI countdown).
- `HF_HUB_OFFLINE=1`, `HOME=/tmp`, probes on the runtime's health path.
- Replicas: 1 by default. The GPU quota (1 per user) caps it anyway.

## Runtime catalog (`runtimes.yaml`)

| Format (`MODEL.yaml` / MLflow flavor) | Runtime image (`master:5000/...`) | Protocol the UI speaks | Default hardware |
|---|---|---|---|
| `hf`, `hf-lora` (LLM) | `vllm-openai:<pinned>` (`--enable-lora` for adapters) | OpenAI `/v1/chat/completions` | 1 GPU |
| `gguf` | `llama-cpp-server:<pinned>` (cuda variant for GPU) | OpenAI `/v1/chat/completions` | CPU (GPU optional) |
| `mlflow` (sklearn / xgboost / pytorch / keras...) | `mlflow-serve-<framework>:<ver>` (`mlflow models serve --env-manager local`) | MLflow `/invocations` | CPU (torch: GPU optional) |
| `onnx`, `torchscript`, `tensorrt` | `tritonserver:<pinned>` | KServe v2 `/v2/models/<m>/infer` | 1 GPU |
| custom image | `master:5000/<user>/<image>:<tag>` | must be OpenAI or v2 (user declares which) | user picks |

- Three protocols, not one: the UI and gateway have one small adapter each for OpenAI, `/invocations` and v2.
  The playground builds its form from the MLflow signature, or falls back to raw JSON.
- The auto-picked runtime can be overridden in the wizard (with a warning if the format doesn't match),
  the same "auto guess + manual override" rule the playground uses for widgets.
- Keep the version-drift rule ([publishing.md](publishing.md)): each `mlflow-serve-<fw>` image is built in a pinned
  pair with its training SIF.
- Images are mirrored or built on master (it has internet) with `k8s-image mirror|build`. Pin tags; never use `:latest`.

## Flows

### Deploy (user, in the UI)
Registry → model → **Deploy** → wizard: version · runtime (auto, overridable) · hardware (GPU type from sinfo,
CPU/RAM) · lifetime (24 h) · share with (optional) → live YAML preview → Deploy
→ backend `kubectl apply` → slurm-bridge makes a Slurm job → pod pulls `master:5000/...` → loads weights
→ readiness passes → **Endpoints** page shows URL, curl example, logs, countdown.

### Call it
- **Playground:** form from the signature (or raw JSON / chat), sent through the backend → gateway → Service.
- **Script / Slurm job / notebook:**
  ```bash
  curl http://192.168.40.102:30600/alice/qwen-chat/v1/chat/completions \
       -H "Authorization: Bearer $(cat ~/.model-hub/token)" -d '{...}'
  ```
  OpenAI-protocol endpoints work with the `openai` Python client by setting `base_url`.

### Share, extend, stop
- **Share:** the owner edits the `model-hub/shared-with` annotation from the UI; the gateway reads it on every request.
- **Extend:** a new 24 h = a new Slurm job, so the UI deletes the pod and creates it again (reloads weights)
  and updates `model-hub/expires`. The UI says "about N minutes of downtime" for big models.
- **Expired:** Slurm ends the job and slurm-bridge deletes the pod. The Service stays, showing "stopped, deploy again".
- **Delete:** removes the Pod + Service (+ key Secret).

### Public tier (admin)
Admin deploys a popular model into `models-public` (same templates, no `my-models`, no time limit, not under any
user quota). An initContainer copies the weights to node-local `emptyDir` first, so NFS is read once per pod.
The UI lists it under **Public endpoints**; any user calls it with their own token.

## Serving template (what `templates/serve-vllm.yaml` fills in)
Early sketch, kept for the fields. **v1's real one is `OOD-Install/5-model-hub/render.py`: a bare Pod** with these
annotations on its own metadata (see "Serving pods" for why not a Deployment).
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: x-v1, namespace: u-alice, labels: { model-hub/model: x, model-hub/version: v1, model-hub/runtime: vllm } }
spec:
  replicas: 1
  selector: { matchLabels: { app: x-v1 } }
  template:
    metadata:
      labels: { app: x-v1 }
      annotations:
        slurmjob.slinky.slurm.net/partition: slurm-bridge
        slurmjob.slinky.slurm.net/gres: "gres:gpu:${GPU_TYPE}:1"      # type from sinfo
        slurmjob.slinky.slurm.net/timelimit: "1440"
    spec:
      schedulerName: slurm-bridge-scheduler
      tolerations:
      - { key: slinky.slurm.net/managed-node, operator: Equal, value: slurm-bridge-scheduler, effect: NoExecute }
      securityContext:                                   # restricted PSA + the UID policy
        runAsUser: 1001
        runAsGroup: 1001
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: serve
        image: master:5000/vllm-openai:v0.x.y            # runtime only, no weights
        args: ["--model", "/my-models/x/v1", "--port", "8080"]
        # public model:  "--model", "/models/published/bob/y/v2"
        # LoRA:          "--model", "/models/base/qwen/Qwen2.5-7B-Instruct/a09a354", "--enable-lora",
        #                "--lora-modules", "x=/my-models/x/v1"
        env:
        - { name: HOME, value: /tmp }
        - { name: HF_HUB_OFFLINE, value: "1" }
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: [ALL] }
        ports: [{ containerPort: 8080 }]
        resources:
          limits: { nvidia.com/gpu: "1", cpu: "4", memory: 32Gi }
        volumeMounts:
        - { name: models,    mountPath: /models,    readOnly: true }
        - { name: my-models, mountPath: /my-models, readOnly: true }
        - { name: tmp,       mountPath: /tmp }
        - { name: shm,       mountPath: /dev/shm }
      volumes:
      - { name: models,    persistentVolumeClaim: { claimName: models-ro, readOnly: true } }
      - { name: my-models, persistentVolumeClaim: { claimName: my-models, readOnly: true } }
      - { name: tmp,       emptyDir: {} }
      - { name: shm,       emptyDir: { medium: Memory, sizeLimit: 4Gi } }
```
Serving images must run as an **arbitrary non-root UID**: no writes outside `/tmp`, nothing that expects root.
Check every podman-built serving image for this.

## NFS and big weights

A 7B model is 15 GB, a 70B one 140 GB, read at every pod start.
- PV / GPU-node mount options: `nconnect=8`, large `rsize`/`wsize`.
- Long-running shared endpoints: an initContainer copies weights to a node-local `emptyDir`, so NFS is read once per pod.
- safetensors is memory-mapped: loading straight from NFS works, it's just network-bound. Measure before optimizing.

## UI changes from the prototype (registry-ui mockup, not kept)
- Deploy wizard: plain **Pod + Service with slurm-bridge annotations** instead of a KServe InferenceService.
  No autoscaling or scale-to-zero; a fixed replica count plus the 24 h lifetime and Extend.
- Runtime list = the four above + custom image. GPU list from `site.json`. 1-GPU cap shown in the wizard.
- Endpoints page gets three groups: **Mine**, **Shared with me**, **Public**. Plus a share dialog and a countdown/Extend button.
- "API" tab shows the gateway URL + `~/.model-hub/token` usage (never the token itself in the page).
- Register page: no free-form "register" form. Models come from the MLflow registry (`log_model(registered_model_name=)`,
  the MLflow UI, or `model-register` for LLMs). The page becomes a "how to get your model here" guide + links.
- v1 subset: models list, deploy wizard (no share field), **Mine** endpoints only, countdown, logs, delete,
  playground (chat for OpenAI endpoints, schema form for `/invocations`). The rest arrives with v2.

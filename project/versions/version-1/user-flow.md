# Version 1 — user flow: from training to inference

How a user goes from raw data to a model they can call, for the three kinds of models:
**classic ML** (sklearn, XGBoost, LightGBM), **deep learning** (PyTorch), and **LLMs** (fine-tuning),
with what v1 ships. Scope: [README.md](README.md) · runtimes: [runtimes.md](runtimes.md) ·
full flow incl. v2 (sharing, gateway): [../../user-flow.md](../../design/user-flow.md).

**Model Hub lists models from the MLflow Model Registry, automatically.** A model shows up in Model Hub as
soon as it is *registered* in MLflow; a run that only logged metrics does not. You register only the run you
want to keep: one argument in the training script, one command, or one click in the MLflow UI.
You see only models MLflow lets you see (your own in v1).

## Same for all three: getting started

```
You ──► OOD login (cluster username + password)
          │
          ▼
       Dashboard
          ├──► Files app: upload your data ──► ~/data/
          └──► VS Code app (in the browser): write train.py + job.sh
                 │
                 ▼
          sbatch job.sh  (VS Code terminal or OOD Jobs app) ──► one of the 3 flows below
```

## 1. Classic ML (sklearn, XGBoost, LightGBM): CPU all the way

```
 ═══ TRAIN (Slurm, CPU node) ════════════════════════════════════════════
   sbatch -p <cpu partition>  job.sh
          │
          ▼
   apptainer exec ml-classic-cpu.sif python train.py      (sklearn 1.9.0, xgboost 3.3.0, lightgbm 4.7.0)
          │
          ├──► params / accuracy / F1 ──► MLflow
          │
          └──► mlflow.sklearn.log_model(model, "model", signature=..., input_example=...)
                  stored in MLflow: MLmodel + model.pkl + requirements.txt + input schema
 ═══ PICK + REGISTER ════════════════════════════════════════════════════
   MLflow UI: compare runs ──► best run ──► [Register model] as "churn"  ──► churn v1
   (or register straight from the script: log_model(..., registered_model_name="churn"))
 ═══ DEPLOY (Model Hub) ═════════════════════════════════════════════════
   Model Hub (reads MLflow) ──► churn v1 ──► [Deploy]   (hardware: CPU, no GPU)
          │
          ▼
   pod in u-<you>, image master:5000/mlflow-serve-ml:<pinned>
   downloads churn v1 from MLflow with your token
   runs: mlflow models serve --env-manager local ──► Ready in seconds
 ═══ USE ════════════════════════════════════════════════════════════════
   Playground: a form built from the input schema (age, plan, usage …) ──► prediction
   Scripts:    POST <url>/invocations  {"dataframe_records": [...]}
```

- The serving image must have **the same sklearn / xgboost / lightgbm versions** as the training `.sif`
  (`ml-classic-cpu.sif` ↔ `mlflow-serve-ml`). Otherwise the pickle may fail to load, or load wrong.
- No GPU used, so it doesn't count against your 1-GPU quota.

## 2. Deep learning (PyTorch: vision, audio, tabular nets): GPU to train, GPU or CPU to serve

```
 ═══ TRAIN (Slurm, GPU node) ════════════════════════════════════════════
   sbatch -p <gpu partition> --gres=gpu:1  job.sh      (multi-GPU: torchrun / DDP)
          │
          ▼
   apptainer exec --nv pytorch-mlflow-2.10.0-cuda12.9.sif python train.py
          │
          ├──► loss / val accuracy per epoch ──► MLflow
          ├──► checkpoints every N epochs ──► ~/models/resnet-cls/checkpoints/
          │
          └──► best epoch: mlflow.pytorch.log_model(model, "model", signature=...)
 ═══ PICK + REGISTER ════════════════════════════════════════════════════
   MLflow UI: loss curves ──► best run ──► [Register model] as "resnet-cls"  ──► resnet-cls v1
   (or in the script: log_model(..., registered_model_name="resnet-cls"))
 ═══ DEPLOY (Model Hub) ═════════════════════════════════════════════════
   Model Hub (reads MLflow) ──► resnet-cls v1 ──► [Deploy]   (hardware: 1 GPU, or CPU for small models)
          │
          ▼
   pod in u-<you>, image master:5000/mlflow-serve-torch:2.10-cu129
   Slurm job ──► waits for a GPU (if asked) ──► downloads v1 from MLflow ──► Ready
 ═══ USE ════════════════════════════════════════════════════════════════
   Playground: upload an image / fill a form ──► predicted class + scores
   Scripts:    POST <url>/invocations  (tensor or dataframe JSON)
```

- Same version rule: `pytorch-mlflow-2.10.0` SIF trains, `mlflow-serve-torch:2.10-cu129` serves.
- Keras/TensorFlow models: not in v1 (needs a third serving image).
- Very large DL models (several GB): save to `~/models` and register the path, like an LLM below.
- Later option: export to ONNX/TorchScript and serve with Triton for speed. Not needed to start.

## 3. LLM (fine-tune an open model with LoRA): GPU all the way

```
 ═══ START FROM A BASE MODEL ════════════════════════════════════════════
   admin has mirrored it: /home/apps/models/base/qwen/Qwen2.5-7B-Instruct/<rev>/
   (or you download one yourself into ~/models/ from master, which has internet)
 ═══ TRAIN (Slurm, GPU node) ════════════════════════════════════════════
   sbatch -p <gpu partition> --gres=gpu:2  job.sh
          │
          ▼
   apptainer exec --nv pytorch-nlp-2.10.0-cuda12.9.sif python finetune_lora.py
          │    reads base weights (read-only) + ~/data/qa.jsonl
          │
          ├──► train/eval loss ──► MLflow
          │
          └──► peft_model.save_pretrained("~/models/qwen-legal/v1")
                  writes only the adapter (~50–500 MB), not a 15 GB copy
                  + MODEL.yaml:  format: hf-lora,  base_model: base/qwen/...
 ═══ PICK + REGISTER ════════════════════════════════════════════════════
   MLflow UI: eval loss / your test scores ──► pick the best adapter
          │
          ▼
   model-register ~/models/qwen-legal/v1 qwen-legal     (one command, on master)
   weights stay in ~/models (too big for MLflow); MLflow gets an entry
   with tag path=~/models/qwen-legal/v1  ──► qwen-legal v1
 ═══ DEPLOY (Model Hub) ═════════════════════════════════════════════════
   Model Hub (reads MLflow) ──► qwen-legal v1 ──► [Deploy]   (hardware: 1 GPU, type from sinfo)
          │
          ▼
   pod in u-<you>, image master:5000/vllm-openai:<pinned>
   mounts ~/models (read-only) at the registered path
   loads base model + your adapter (--enable-lora)
   Slurm job ──► waits for a GPU ──► loads weights (minutes) ──► Ready
 ═══ USE ════════════════════════════════════════════════════════════════
   Playground: chat in the browser
   Scripts:    OpenAI-compatible API
               client = OpenAI(base_url="<url>/v1", api_key="<key from Model Hub>")
               client.chat.completions.create(model="qwen-legal", messages=[...])
```

- A full fine-tune (not LoRA) works the same way: save with `model.save_pretrained(...)`, `format: hf`.
- Just want to use a base model without training? The admin registers every `base/` model once, so it's
  already in the list: skip to DEPLOY.
- GGUF (quantized, llama.cpp) is a later option for running small LLMs on CPU.

## The three side by side

| | Classic ML | Deep learning | LLM |
|---|---|---|---|
| Train on | CPU node | GPU node | GPU node(s) |
| Training container | `ml-classic-cpu.sif` | `pytorch-mlflow-2.10` SIF | `pytorch-nlp-2.10` SIF |
| Saved as | `mlflow.sklearn.log_model` (in MLflow) | `mlflow.pytorch.log_model` (in MLflow) | adapter / HF folder + `MODEL.yaml` in `~/models` |
| Registered by | MLflow UI click or `registered_model_name=` | same | `model-register DIR NAME` (path tag) |
| Pod gets weights | downloads from MLflow | downloads from MLflow | mounts `~/models` read-only |
| Serving image | `mlflow-serve-ml` | `mlflow-serve-torch` | `vllm-openai` |
| Serve on | CPU | GPU or CPU | GPU |
| API | `/invocations` | `/invocations` | OpenAI `/v1/chat/completions` |
| Playground | form from input schema | form / file upload | chat |
| Startup | seconds | seconds–a minute | minutes |

**What connects training and inference:** the MLflow Model Registry. Model Hub only lists registered models.
For ML/DL the model itself lives in MLflow; for LLMs MLflow holds a pointer (`path` tag) to `~/models/...`.
Either way the registered version links back to the run that produced it.

**Training vs inference, in every flow:**

| | Training | Inference |
|---|---|---|
| Runs as | a Slurm batch job | a k8s pod that is also a Slurm job (slurm-bridge) |
| Container | Apptainer `.sif` from `/home/apps/containers` | OCI image from `master:5000` |
| Ends | when the script finishes | when you delete it, or after 24 h |

## What the admin does once per user

`sudo bash OOD-Install/1-ldap/add-user.sh <name>` gives the user:
- a login that works for SSH, Slurm, OOD and MLflow (LDAP);
- an MLflow token in `~/.mlflow/credentials`;
- rootless podman ranges on the login node(s);
- (Model Hub) their namespace `u-<name>`, 1-GPU quota and k8s login in `~/.kube/config`.

The user never sets anything up themselves.

## Limits in v1

- **Private only:** you see and deploy only your own models (plus the admin's `base/` models).
  Sharing with others needs the publish step, planned for v2.
- **1 GPU per user, 24 h per endpoint.** Redeploy to run longer.
- **Calling endpoints:** from master (it's a k8s node), at the URL Model Hub shows. LLM endpoints need an
  API key (shown in Model Hub); ML/DL endpoints have no key in v1, so any cluster user could call them.
  Per-user tokens and sharing come with the gateway in v2.
- **Serving images come in pinned pairs with training `.sif`s.** A model trained in a `.sif` with no
  matching serving image can't be deployed until the admin builds that pair.

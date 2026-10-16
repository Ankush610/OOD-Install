# Model Hub — version 3

v2 (closed 2026-10-13, see its [README](../version-2/README.md#status-closed-2026-10-13)) made Model Hub a product:
one login, gateway + personal keys, sharing, public models, admin page. v3 does two things:

1. **Finish what v2 left**, so the rack is safe and installable for real users.
2. **Deploy any model with the right settings by itself**: Model Hub reads the model's own files, picks the
   runtime, image and hardware, and the user only corrects what's wrong.

Scope: **vLLM (LLMs) and MLflow serving (ML / DL)**. Rudra, the product rules and v2's decisions still apply
([v2 README](../version-2/README.md)). Steps: [build-plan.md](build-plan.md). Problems and fixes: [build-log.md](build-log.md).
Code goes in `OOD-Install/5-model-hub/` (and the folders named per step).

## Where we start (checked 2026-10-13)

| | Today | Gap |
|---|---|---|
| ML serving | image `mlflow-serve-ml`, pinned to `ml-classic` SIF: sklearn, XGBoost, LightGBM, CatBoost | — |
| DL serving | image `mlflow-serve-torch`, pinned to `pytorch` SIF: `torch` + `torchvision` only | models from `pytorch-vision` (timm, ultralytics, smp), `pytorch-nlp` (transformers), `tensorflow`, ONNX, pyfunc with extra packages all fail |
| Image choice | flavor `pytorch` → torch image, **anything else → ML image** | a transformers / Keras / ONNX model lands on an image without its library |
| LLM facts | tags `path`, `format`, `base_model` | size, context, task, inputs unknown |
| Deploy form | one GPU dropdown; CPU / RAM fixed in `render.py` (4 / 32 Gi with GPU, 2 / 4 Gi without) | no way to give a model more RAM; a too-big LLM fails inside vLLM |

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Serving images | **one per training SIF, made from the SIF itself** (`apptainer build --sandbox` → `podman import`), looped over `training/*/*.sif` in `4-images.sh` | serving has exactly the packages training had; a new training image gets a serving image with no new recipe (like Jupyter's kernels) |
| MLflow in the SIFs | **`mlflow-skinny` as they are**: it already runs `mlflow models serve` (FastAPI + uvicorn); no `.def` change, no SIF rebuild | tested 2026-10-15 on all 8 SIFs (build log); the planned switch to full `mlflow` wasn't needed |
| Image catalog | at build, each image's `pip freeze` (and vLLM's supported architectures) saved next to its tag | "which image fits?" is a lookup, not a guess |
| Model inspector | **one function, `inspect(model) → deploy plan`**, reads the model's files; no questions to the user | users often don't know the answers; the files do |
| When it runs | on the model page (cached in MLflow tags, redone when images change) and again in the backend on deploy | old models work without re-registering; page defaults and backend checks can't disagree |
| Registration | `model-register` only records the path (escape hatch: `--task`) | the inspector does the rest |
| Hardware | **presets** in `site.conf` (name, CPUs, RAM, GPUs), not separate boxes | how SageMaker, HF Endpoints, Run:ai, OpenShift AI do it; caps every endpoint's size without a CPU / RAM quota |
| Too big / unsupported | the form says why before deploying, Deploy disabled ("needs `timm`, no image has it"; "needs ~40 GB, an A30 has 24 GB: use a 4-bit AWQ/GPTQ version") | today it fails at load, in a log only experts read |
| Overrides | Advanced, only from allowed lists (registry images, presets); backend checks them | users can fix a wrong guess, can't pick arbitrary images (offline, pinned) |
| Naming | "Chat model" → **LLM** | LLMs aren't only chat |
| Image / audio input LLMs | same vLLM runtime, upload in try-it when the plan says so | vLLM takes them on `/v1/chat/completions` |
| Embedding models | same vLLM runtime in embedding mode, `/v1/embeddings` | no new server |
| Image / audio generation | MLflow **pyfunc** on a torch serving image | `/invocations` already goes through the gateway |
| Video | not in v3 | too heavy for one A30 |

## What the inspector reads

| Model | Files | Decides |
|---|---|---|
| ML / DL (MLflow) | `MLmodel` (flavors, `model_size_bytes`), `requirements.txt` | the image whose package list has every requirement (version differences shown as a warning); CPU (ML) or GPU (DL); preset from the size |
| LLM (HF folder) | `config.json` (architecture, `max_position_embeddings`, `vision_config` / `audio_config`, `quantization_config`, `torch_dtype`, `auto_map`), `tokenizer_config.json` (`chat_template`), `*.safetensors` (size), `adapter_config.json`, sentence-transformers files | task (chat / completion / embed), inputs (text / image / audio), size, context, fits on the GPU or not, vLLM supports the architecture or not, needs custom code (→ refused: vLLM never gets `--trust-remote-code`) |

Not sure (e.g. a base model without a chat template) → the plan says so and the form asks for that one value.
The model page shows the plan in one line, e.g. *LLM · chat · text + image · 8B · bf16 · 16 GB → vLLM, 1 × A30, context 8k*.

## Deploy parameters

| Shown | Parameter | Applies to | Default |
|---|---|---|---|
| always | Endpoint name | all | `<model>-v<N>` |
| always | Hardware preset | all | inspector (kind + size); only presets the model can use, within the user's GPU limit |
| always | Run time (hours) | all | 24, max 96 (per user) |
| Advanced | Runtime / image | all | inspector's pick; registry list only |
| Advanced | Task | LLM | from the files; shown only when the inspector isn't sure |
| Advanced | Context length | LLM | the model's, capped to what fits (`--max-model-len`) |
| never | CPU, RAM, GPU type + count | | the preset |
| never | Tensor parallel | LLM | GPU count > 1 |
| never | Quantization, dtype | LLM | the model files (vLLM reads them) |
| never | Image / audio input | LLM | the inspector's `inputs` |
| never | `/dev/shm` 8 GB, GPU memory share 90 % | LLM | fixed / vLLM default |
| never | Partition, Slurm time limit, UID | all | `site.conf` + the user (as today) |

## Not in v3 (later)

- Models over one node (KServe / llm-d), autoscaling, scale-to-zero (same as v2).
- Usage reports and budgets: v3 keeps the logs on disk; reports read them later.
- Video models; other LLM runtimes (llama.cpp, Triton).

## Open questions (carried from v2)

The five [senior questions](../version-2/README.md#questions-for-the-senior) are still open. Question 1
(network plugin) blocks step A.

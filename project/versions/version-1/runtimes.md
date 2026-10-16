# Model Hub v1 — what we serve and with what

Two inference tools, three serving images. The full runtime catalog (incl. later ones) is in
[../../serving.md](../../design/serving.md) "Runtime catalog".

| | **ML** | **DL** | **LLM** |
|---|---|---|---|
| Model types | Tabular classification / regression: **scikit-learn, XGBoost, LightGBM** | **PyTorch** (`nn.Module`, incl. torchvision): image classification, custom nets | **HF text-generation** (Qwen, Llama, Mistral…) in safetensors, **full weights or LoRA adapter** |
| Saved / registered as | `mlflow.<flavor>.log_model` → registered in MLflow | `mlflow.pytorch.log_model` → registered in MLflow | folder in `~/models` + `MODEL.yaml`, registered with `model-register` (path tag) |
| Inference tool | **MLflow serving** (`mlflow models serve --env-manager local`) | **MLflow serving** | **vLLM** (`--enable-lora` for adapters) |
| Serving image (`master:5000/…`) | `mlflow-serve-ml:<pinned>` (CPU) | `mlflow-serve-torch:2.10-cu129` (GPU or CPU) | `vllm-openai:<pinned>` (GPU) |
| API | `/invocations` | `/invocations` | OpenAI `/v1/chat/completions` |
| Playground | form from the model signature | form / JSON | chat |
| Pod gets weights | initContainer downloads from MLflow (deployer's token) | same | read-only mount of `~/models` or `/home/apps/models` |

## Two kinds of containers, two jobs

| | Apptainer SIF | Podman OCI image |
|---|---|---|
| Purpose | **training** (and other batch jobs) | **serving** (endpoints) |
| Runs through | Slurm `sbatch` | k8s pod via slurm-bridge |
| Lives in | `/home/apps/Containers-CDAC/...` (target: `/home/apps/containers`) | `master:5000` |

The only link between them is **library versions**, and only for pickled models (ML, DL):

| Training SIF | Serving image must pin the same |
|---|---|
| `ml-classic/ml-classic-cpu.sif` | scikit-learn 1.9.0, xgboost 3.3.0 (CPU), lightgbm 4.7.0 |
| `torch/pytorch-mlflow-2.10-cuda-12.9` | torch 2.10.0 + cu129 |

LLMs (safetensors) have no such link: pin `vllm-openai` to any tested version, never `:latest`
(the registry has only `:latest` today, so re-mirror with a real tag).

## Serving images: what to build

- **`mlflow-serve-ml`**: python + **full** `mlflow==3.15.1` (the SIFs have `mlflow-skinny`, which can log but
  can't serve) + the three pinned libs above. CPU only.
- **`mlflow-serve-torch`**: CUDA 12.9 runtime + `torch==2.10.0+cu129` + full `mlflow==3.15.1`.
- **`vllm-openai`**: mirror of the upstream image, pinned tag (`k8s-image mirror`).
- All three: run as an **arbitrary non-root UID** (`HOME=/tmp`, no writes elsewhere), offline (`HF_HUB_OFFLINE=1`).

## Not in v1

| Left out | Why | When |
|---|---|---|
| TensorFlow / Keras | needs a third serving image (the SIF exists) | when users ask |
| llama.cpp / GGUF, SGLang | vLLM covers LLMs; a second LLM engine doubles the upkeep | CPU-only LLMs, or if vLLM falls short |
| Embeddings, vision-language, HF pipelines (BERT, NER) | each needs its own playground UI | v2 (TEI / vLLM can serve some cheaply) |
| Triton / ONNX / TensorRT | speed-up for heavy DL traffic; MLflow serving (one process, no batching) is fine for tests and light use | when a DL endpoint gets real load |

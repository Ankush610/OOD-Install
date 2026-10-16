# Model Hub v3 — build plan (one step at a time)

Each step is built, tested on the dummy cluster, logged in [build-log.md](build-log.md) and committed before the
next one starts. Decisions: [README.md](README.md). Steps A–D come from v2 ([v2 build plan](../version-2/build-plan.md));
the details written there still hold.

| # | Step | Depends on |
|---|---|---|
| 0 | v2 leftovers live (reruns, two untried helper actions) | — |
| A | Network lock (v2 step 1) | senior answer 1 |
| 1 | Serving images from the training SIFs + image catalog — **built 2026-10-15**, GPU-node check left | — |
| 2 | Model inspector (`inspect() → deploy plan`) | 1 |
| 3 | Deploy form: presets, Advanced, "can't run" check | 2 |
| 4 | "LLM" naming, image / audio input in try-it | 2 |
| 5 | Embedding models | 2 |
| 6 | Image / audio generation (pyfunc) | 1, 3 |
| B | Usage logs kept on disk (v2 step 8) | — |
| C | Model cache on GPU-node NVMe (v2 step 7) | — |
| D | Rudra packaging (v2 step 9) | all |

---

## 0. v2 leftovers live

- Reruns the v2 log lists as "Not yet live": `8-admin/1-install.sh`, `8-admin/2-install-ood-app.sh`,
  `2-ood/setup-ood.sh` (home cards, bell 404 fix, portal title), `6-keycloak/2-realm.sh` (portal name),
  `5-model-hub/7-install-ood-app.sh` (chat JSON), `4-vscode/3-install-ood-app.sh`; Restart Web Server.
- Try live: helper `stop-endpoint` and `set-password` (from the admin page); a non-admin's home page.
- `sudo rm` the two old files `1388`, `1389` in `ADMIN_NOTICES`.
- **Done when:** each item above is checked in the browser and logged.

## A. Network lock

As v2 step 1. **Before real users**, and before anyone deploys someone else's public model.

## 1. Serving images from the training SIFs

- ~~Test first: full `mlflow` in the `.def`s~~ not needed: `mlflow-skinny` serves (2026-10-15, build log).
- **Build:**
  - `4-images.sh`: for every `CONTAINERS_ROOT/training/*/*.sif`: `apptainer build --sandbox` → `tar | podman import`
    with `ENV` from the def's `%environment` (`PATH=/opt/venv/bin:…`, `VIRTUAL_ENV`, `LC_ALL`), `USER 65534`,
    `ENTRYPOINT mlflow models serve --env-manager local …`, plus `sitecustomize.py` (pt2 device fix) for torch
    images. Tag = `serve-<sif name>:<sha256 of the SIF + sitecustomize + the recipe, 8 chars>` (never moves).
    `STOPSIGNAL SIGINT` (mlflow as PID 1 ignores SIGTERM).
  - image catalog: each image's `pip list`, its SIF name and GPU yes/no in `images/catalog.json` (done); left: for vLLM, its
    supported architectures (`ModelRegistry.get_supported_archs()`), CLI flags we rely on, version.
  - retire `images/mlflow-serve-ml`, `images/mlflow-serve-torch` once the new images pass `6-test-endpoints.sh`.
- **Done when:** a timm model (pytorch-vision), a transformers model (pytorch-nlp) and a Keras model (tensorflow)
  each serve from their family's image; ML and plain torch still pass (**all done on CPU, 2026-10-15**); left:
  images pull on a GPU node (time the first pull, log it) and serve on GPU there; vLLM part of the catalog.

## 2. Model inspector

- One Python module in `5-model-hub/` (used by the OOD app backend; `--test` with sample files), `inspect(model)`
  returns a plan: `kind`, `runtime`, `image`, `preset`, `task`, `inputs`, `context`, `size`, `warnings`,
  `cant_run` (reason) and `unsure` (fields the user must pick).
- **ML / DL:** `MLmodel` + `requirements.txt` → first catalog image that has every package (version differences →
  warning); none → `cant_run: needs <pkg>, no image has it`. GPU for DL images, CPU for ML.
- **LLM:** `config.json`, `tokenizer_config.json`, `*.safetensors`, `adapter_config.json`, sentence-transformers
  files → task, inputs, size, quantization, context; architecture not in vLLM's list or `auto_map` present →
  `cant_run` with the reason.
- Cached as MLflow version tags (`plan_*`, with the catalog's hash); redone when the catalog changes. The backend
  runs it again on deploy (never trusts the page).
- `model-register`: only records the path; `--task` as the escape hatch.
- Model page: the plan in one line, plus warnings / `cant_run`.
- **Done when:** `--test` covers each rule; on the cluster the Qwen test model, a vision LLM, an embedding model,
  an unsupported architecture, and the ML / DL models from step 1 each get the right plan.

## 3. Deploy form

- `site.conf`: `ENDPOINT_PRESETS` (name, CPUs, RAM, GPUs), e.g. CPU small 2/4G, CPU large 8/32G, GPU 8/32G/1,
  GPU large 16/90G/1. Card memory from the DRA ResourceSlices at install (`gpu-classes.py`).
- Form = the [deploy parameters](README.md#deploy-parameters): name, preset, hours; Advanced: runtime / image,
  task (only when unsure), context length (LLM, capped so weights + KV cache fit; `--max-model-len`, see
  [vllm-notes](../../vllm-notes.md)). Defaults from the plan; `cant_run` → message, Deploy disabled.
- Backend: preset, image and task must be from the allowed lists; `render.py` gets `cpu` / `memory` / image /
  `max_model_len` from them (it already takes `cpu` / `memory`).
- **Done when:** each model kind opens with the expected defaults; a too-big LLM is stopped in the form; an LLM
  whose default context doesn't fit starts with the capped value; a hand-made POST with an unknown preset or image
  is refused.

## 4. LLM naming, image / audio input

- UI: "Chat model" → "LLM" everywhere (list, filter, help, MLflow page notice).
- Try-it: when the plan's `inputs` has `image` / `audio`, an upload button; the file goes as an `image_url` /
  `input_audio` content part (base64) to `/v1/chat/completions`. API tab shows the same request.
- **Done when:** a small vision LLM (e.g. Qwen2-VL-2B) answers about an uploaded picture, in try-it and through the
  gateway from a laptop.

## 5. Embedding models

- `task=embed` → `render.py` starts vLLM in embedding mode; try-it and the API tab use `/v1/embeddings` (needs a
  backend route; today only `/v1/chat/completions` passes through).
- **Done when:** an embedding model returns vectors in try-it and from a laptop.

## 6. Image / audio generation

- Users log a `diffusers` or TTS model as an MLflow **pyfunc** (example in the help page and the training templates);
  the libraries go into a training SIF, so step 1 makes its serving image.
- Try-it shows a returned base64 image / audio file.
- **Done when:** a small Stable Diffusion pyfunc and a small TTS pyfunc deploy and answer from try-it and a laptop.

## B. Usage logs on disk

- The gateway's call log (one line per call: who, endpoint, when, status, LLM tokens) kept on disk on master,
  rotated, readable by the admin only. Reports later.
- **Done when:** a day's calls are on disk after the gateway pod restarts.

## C. Model cache on the GPU node

As v2 step 7.

## D. Rudra packaging

As v2 step 9, plus backing up `LDAP_LAST_UID_FILE` with LDAP, `ENDPOINT_PRESETS` and `images/catalog.json`.

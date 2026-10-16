# Model Hub — publishing (v2: sharing models with everyone)

Part of the [Model Hub design](README.md). v1 only uses `base/` (admin-mirrored models, registered with
`model-register`) and the version-drift rule from this doc. The `published/` tree and `model-publish` are v2.

Users train → test privately → **publish** → everyone can deploy it. Anyone can publish (no approval), so the
guardrails are automatic: required license, size cap, audit log, immutable versions.

## Layout rules
```
/home/apps/models/                          modelhub:modelhub 0755   only `modelhub` writes
├── base/<org>/<model>/<revision>/          admin-curated upstream weights (HF mirror) + MODEL.yaml
├── published/<user>/<name>/<vN>/           MODEL.yaml + SHA256SUMS + weights; dirs 0555, files 0444
├── .tmp/                                   modelhub-only staging for atomic publish (0700)
└── PUBLISH.log                             who published what, when
/home/<user>/models/<name>/{checkpoints,v1}/   private: mutable scratch + publish candidates
```
- Versions are `v1, v2, …`, **never overwritten**. Need a fix → publish `v2`.
- "Which one is current" = an MLflow **alias** (`@prod`), not a `latest/` dir.
- LoRA fine-tunes: publish the **adapter only**, `base_model:` points into `base/` (7B full copy ~15 GB, adapter 50–500 MB).
- `modelhub` is a service account like `mlflow`: UID below `MIN_UID` (e.g. 951), same number on every node.
  Create `/home/apps/models` on the machine where root isn't squashed (dummy: master, `no_root_squash`).

## Getting base models in (master has internet; compute nodes don't)
```bash
sudo -u modelhub HF_TOKEN=... hf download Qwen/Qwen2.5-7B-Instruct --revision a09a354 \
  --local-dir /home/apps/models/base/qwen/Qwen2.5-7B-Instruct/a09a354
```
- `--local-dir` gives plain files, not the HF cache's symlink layout. Pin `--revision`; `main` moves.
- Gated models need a token from an account that accepted the license.
- Users can download into `~/models` themselves and publish as `<user>/<model>` (`format: hf`).
- Jobs and pods set `HF_HUB_OFFLINE=1` and always load models **by path**.

## MODEL.yaml (one per version)
```yaml
name: qwen7b-legal-lora
format: hf-lora                               # hf | hf-lora | gguf | mlflow         (required)
task: text-generation                         # (required)
license: apache-2.0                           # must be compatible with base model's (required)
base_model: base/qwen/Qwen2.5-7B-Instruct/a09a354
mlflow_run_id: 3f2a9c...                      # lineage: the run on the shared MLflow server
description: Legal QA fine-tune
serve:
  image: master:5000/vllm-openai:v0.x.y
  gpus: 1
# owner: / version: are stamped by publish; anything the user writes there is replaced
```
The MLflow registry can be **rebuilt** by walking every `MODEL.yaml`, so losing MLflow's DB loses no weights.

| `format` | what's in the dir | produced by (Slurm/Apptainer side) |
|---|---|---|
| `hf` | `config.json`, `*.safetensors`, tokenizer | `model.save_pretrained(dir)` |
| `hf-lora` | `adapter_config.json`, `adapter_model.safetensors` | `peft_model.save_pretrained(dir)` |
| `gguf` | one `.gguf` file | llama.cpp convert/quantize |
| `mlflow` | `MLmodel`, `requirements.txt`, model files | `mlflow.<flavor>.save_model(m, dir)` |

## Version-drift trap (Apptainer trains, podman serves)
safetensors/GGUF don't care which torch wrote them. **Pickled classic ML does**: an sklearn model trained in
`sklearn-1.5.sif` may fail, or load wrong, under sklearn 1.6.
- Pods are offline, so `mlflow models serve` needs `--env-manager local`, and the image must already match the model's `requirements.txt`.
- Build SIFs and serving images in **pairs with the same pinned versions** (`torch-2.5.sif` ↔ `mlflow-serve-torch:2.5`).
- Strongest option for the `mlflow-serve-*` family: podman-build once, push, then `apptainer build x.sif docker://master:5000/…`.

## Publish mechanism (`model-publish` → `model-receive`)
alice's home is 0700 and `/home/apps` isn't user-writable, so: read as alice, write as `modelhub`, pipe between them.
```
  alice:  tar -C ~/models/x/v1 -cf - .  ── stdin ──►  sudo -u modelhub /home/apps/libexec/model-receive x v1
```
sudoers on the login node(s): `ALL ALL=(modelhub) NOPASSWD: /home/apps/libexec/model-receive`

`/home/apps/bin/model-publish` (user side):
```bash
#!/bin/bash
set -euo pipefail
src=${1:?usage: model-publish DIR NAME VERSION} name=${2:?} ver=${3:?}
[[ -f $src/MODEL.yaml ]] || { echo "missing $src/MODEL.yaml" >&2; exit 1; }
read -rp "Published models are visible to ALL users and can't be edited or overwritten. Publish $name $ver? [y/N] " ok
[[ $ok == [yY] ]] || exit 1
tar -C "$src" -cf - . | sudo -u modelhub /home/apps/libexec/model-receive "$name" "$ver"
```

`/home/apps/libexec/model-receive` (root-owned 0755, runs as modelhub). **The trust boundary: validate everything.**
```bash
#!/bin/bash
set -euo pipefail
MAX_USER_GB=500                                    # per-user publish cap: tune to NFS size / user count
root=/home/apps/models
user=$SUDO_USER name=$1 ver=$2
re='^[a-z0-9][a-z0-9._-]{0,63}$'
[[ $user =~ $re && $name =~ $re && $ver =~ ^v[0-9]+$ ]] || { echo "bad name/version" >&2; exit 1; }
dest=$root/published/$user/$name/$ver
[[ ! -e $dest ]] || { echo "$dest exists — versions are immutable, bump the version" >&2; exit 1; }

tmp=$(mktemp -d "$root/.tmp/pub.XXXXXX")
trap 'rm -rf "$tmp"' EXIT                          # cleans up on any failure; no-op after the mv
tar -C "$tmp" --no-same-owner --no-same-permissions -xf -
[[ -z $(find "$tmp" ! -type f ! -type d) ]] || { echo "only regular files allowed (no symlinks/devices)" >&2; exit 1; }
card=$tmp/MODEL.yaml
grep -Eq '^format: *(hf|hf-lora|gguf|mlflow) *$' "$card" && grep -q '^license: *[^ ]' "$card" \
  && grep -q '^task: *[^ ]' "$card" \
  || { echo "MODEL.yaml needs format (hf|hf-lora|gguf|mlflow), license, task" >&2; exit 1; }

mkdir -p "$(dirname "$dest")"
used=$(du -s --block-size=1G "$tmp" "$root/published/$user" | awk '{s+=$1} END {print s}')
(( used <= MAX_USER_GB )) || { echo "over ${MAX_USER_GB}G publish cap for $user (${used}G)" >&2; exit 1; }

sed -i -e '/^owner:/d; /^version:/d' -e '$a\' "$card"      # drop user-supplied values, ensure trailing newline
printf 'owner: %s\nversion: %s\n' "$user" "$ver" >> "$card"
(cd "$tmp" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS)
mv "$tmp" "$dest"                                  # same filesystem → atomic rename, no half-published dirs
chmod -R a=rX "$dest"
echo "$(date -Is) $user $name $ver total=${used}G" >> "$root/PUBLISH.log"
/home/apps/libexec/mlflow-register "$dest"
echo "published: $dest"
```
- Tested earlier (as a draft): good publish passes; duplicate version, bad name, symlink, missing license rejected; no `.tmp` leftovers.
- Ceiling: the size cap is checked **after** extracting into `.tmp`; add an NFS/filesystem quota if that ever bites.
- **`mlflow-register`**: the training run is already on the shared MLflow server (users log there with their token),
  so it only creates version `<user>.<name>` linked to `mlflow_run_id`, with tags `path`, `format`, `owner`.
  MLflow 3 may reject a local path as a version `source`; if so, register from the run and keep the path in the tag.
- **Unpublish** (admin only): tag `deprecated` in MLflow, move to `$root/.trash/`, delete after N days (a running
  endpoint may still use it). `PUBLISH.log` says who to talk to.

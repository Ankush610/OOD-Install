#!/usr/bin/env bash
# Build + push the serving images to $REGISTRY, and mirror vLLM. No root needed (rootless podman).
#   mlflow-serve-ml    <- ML_TRAIN_SIF     each image pins the packages in images/<name>/pin.txt to the versions in
#   mlflow-serve-torch <- TORCH_TRAIN_SIF  the SIF's pip freeze; tag <mlflow>-<8 chars of the sha256 of images/<name>/*>,
#                                          so a changed SIF or image gives a new tag, never a moved one
#   vllm-openai:$VLLM_VERSION
#   serve-<sif name>   <- every CONTAINERS_ROOT/training/*/*.sif (v3), made from the SIF itself, see sif_image
# Writes the tags to images/built.env (read by the deploy templates / OOD app) and images/catalog.json (v3: each
# serve- image's SIF, GPU yes/no and package list). Safe to rerun: existing tags are skipped.
# Run on master (has internet):  bash 4-images.sh            everything
#                                bash 4-images.sh <sif>...   only those SIFs' serve- images (no built.env/catalog)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"

exists() { curl -sf "http://$REGISTRY/v2/${1%:*}/tags/list" | grep -q "\"${1##*:}\""; }

# The serving image has exactly the packages training had: sandbox of the SIF -> podman import, with the SIF's
# %environment as ENV. mlflow-skinny (in every SIF) already serves: `mlflow models serve` runs FastAPI + uvicorn.
# Images with torch get sitecustomize.py (pt2 device fix). Tag = 8 chars of the sha256 of the SIF + that file +
# this function, so a rebuilt SIF or a changed recipe never moves a tag. Sets IMG.
# STOPSIGNAL SIGINT: mlflow is PID 1 with no SIGTERM handler, so SIGTERM waited out the grace period, then SIGKILL.
SITECUSTOM=$HERE/images/mlflow-serve-torch/sitecustomize.py
TMPD=""; trap '[ -z "$TMPD" ] || { chmod -R u+w "$TMPD"; rm -rf "$TMPD"; }' EXIT
sif_image() {
  local sif=$1 name tag names site torch kv v env=()
  name=serve-$(basename "$sif" .sif)
  tag=$(cat "$sif" "$SITECUSTOM" <(declare -f sif_image) | sha256sum | cut -c1-8)
  IMG=$REGISTRY/$name:$tag
  echo "== $name  (from $sif)"
  if exists "$name:$tag"; then echo "already in $REGISTRY: $name:$tag"; return; fi
  # the variables the def exports, with the values they have inside the SIF (PATH=/opt/venv/bin:..., VIRTUAL_ENV, ...)
  names=$("$APPTAINER" inspect -e "$sif" | sed -n 's/^ *export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort -u | paste -sd'|')
  while IFS= read -r kv; do
    v=${kv#*=}
    # apptainer's own /.singularity.d/libs and empty entries (= the current directory) don't belong in an image
    [ "${kv%%=*}" != LD_LIBRARY_PATH ] || v=$(tr : '\n' <<<"$v" | { grep -v -e '^$' -e '^/.singularity.d' || true; } | paste -sd:)
    env+=(--change "ENV ${kv%%=*}=\"${v//\"/\\\"}\"")
  done < <("$APPTAINER" exec --cleanenv "$sif" env | grep -E "^($names)=")
  read -r site torch < <("$APPTAINER" exec --cleanenv "$sif" python3 -c \
    'import site, importlib.util as u; print(site.getsitepackages()[0], u.find_spec("torch") is not None)')
  TMPD=$(mktemp -d "${TMPDIR:-/var/tmp}/serve.XXXXXX")
  "$APPTAINER" build --sandbox "$TMPD/root" "$sif" >/dev/null
  if [ "$torch" = True ]; then
    [ ! -e "$TMPD/root$site/sitecustomize.py" ] || { echo "$sif already has $site/sitecustomize.py" >&2; exit 1; }
    cp "$SITECUSTOM" "$TMPD/root$site/"
  fi
  chmod -R u+rX "$TMPD/root"   # mode-000 files (/etc/shadow) are ours in the sandbox but tar can't read them
  tar -C "$TMPD/root" --numeric-owner --owner=0 --group=0 -cf - . |
    podman import "${env[@]}" --change 'ENV HOME=/tmp' --change 'ENV MLFLOW_HOME=/tmp' \
      --change 'ENV PYTHONDONTWRITEBYTECODE=1' --change 'USER 65534' --change 'WORKDIR /tmp' --change 'STOPSIGNAL SIGINT' \
      --change 'ENTRYPOINT ["mlflow", "models", "serve", "--env-manager", "local", "--host", "0.0.0.0", "--port", "8080"]' \
      - "$IMG"
  chmod -R u+w "$TMPD"; rm -rf "$TMPD"; TMPD=""
  podman push "$IMG"
}

if [ $# -gt 0 ]; then
  for sif; do sif_image "$sif"; echo "$IMG"; done
  exit 0
fi
out=$HERE/images/built.env; : > "$out.new"

for pair in "mlflow-serve-ml:$ML_TRAIN_SIF" "mlflow-serve-torch:$TORCH_TRAIN_SIF"; do
  name=${pair%%:*} sif=${pair#*:} dir=$HERE/images/$name
  echo "== $name  (from $(basename "$sif"))"
  freeze=$("$APPTAINER" exec "$sif" cat /opt/base-constraints.txt)
  mlflow=$(sed -n 's/^mlflow-skinny==//p' <<<"$freeze")
  [ -n "$mlflow" ] || { echo "$sif has no mlflow-skinny pin: can't pair it." >&2; exit 1; }
  # only the model-relevant packages: the SIF also pins things full mlflow can't use (e.g. cryptography)
  grep -iE "^($(paste -sd'|' "$dir/pin.txt"))==" <<<"$freeze" > "$dir/constraints.txt"
  sed 's/^/   pin /' "$dir/constraints.txt"
  # every file in the folder (pins + Containerfile + extras), so a change to the image itself gives a new tag too
  img=$name:$mlflow-$(cat "$dir"/* | sha256sum | cut -c1-8)
  if exists "$img"; then echo "already in $REGISTRY: $img"
  else
    # a flaky link can drop a multi-GB wheel mid-download; the pip cache mount keeps what already arrived
    for try in 1 2 3; do
      podman build --build-arg MLFLOW_VERSION="$mlflow" -t "$REGISTRY/$img" "$dir" && break
      [ "$try" = 3 ] && { echo "build of $img failed 3 times" >&2; exit 1; }
      echo "build failed (try $try/3), retrying with the downloads kept..."
    done
    podman push "$REGISTRY/$img"
  fi
  key=${name//-/_}; echo "${key^^}=$REGISTRY/$img" >> "$out.new"      # MLFLOW_SERVE_ML=master:5000/...
done

echo "== vllm-openai:$VLLM_VERSION"
img=vllm-openai:$VLLM_VERSION
if exists "$img"; then echo "already in $REGISTRY: $img"
else
  podman pull "docker.io/vllm/$img"
  podman tag "docker.io/vllm/$img" "$REGISTRY/$img"
  podman push "$REGISTRY/$img"
fi
echo "VLLM_OPENAI=$REGISTRY/$img" >> "$out.new"

cat=$HERE/images/catalog.json; echo "{}" > "$cat.new"
for sif in "$CONTAINERS_ROOT"/training/*/*.sif; do
  sif_image "$sif"
  "$APPTAINER" exec --cleanenv "$sif" python3 -m pip list --format=json 2>/dev/null |
    python3 -c 'import json, sys
cat, img, sif = sys.argv[1:]
c = json.load(open(cat))
c[img] = {"sif": sif, "gpu": "cuda" in sif, "packages": {p["name"].lower(): p["version"] for p in json.load(sys.stdin)}}
json.dump(c, open(cat, "w"), indent=1, sort_keys=True)' "$cat.new" "$IMG" "$sif"
done
mv "$cat.new" "$cat"

mv "$out.new" "$out"
echo; cat "$out"

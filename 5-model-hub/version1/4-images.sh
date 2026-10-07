#!/usr/bin/env bash
# Build + push the serving images to $REGISTRY, and mirror vLLM. No root needed (rootless podman).
#   mlflow-serve-ml    <- ML_TRAIN_SIF     each image pins the packages in images/<name>/pin.txt to the versions in
#   mlflow-serve-torch <- TORCH_TRAIN_SIF  the SIF's pip freeze; tag <mlflow>-<8 chars of the sha256 of images/<name>/*>,
#                                          so a changed SIF or image gives a new tag, never a moved one
#   vllm-openai:$VLLM_VERSION
# Writes the tags to images/built.env (read by the deploy templates / OOD app). Safe to rerun: existing tags are skipped.
# Run on master (has internet):  bash 4-images.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../../site.conf"
out=$HERE/images/built.env; : > "$out.new"

exists() { curl -sf "http://$REGISTRY/v2/${1%:*}/tags/list" | grep -q "\"${1##*:}\""; }

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

mv "$out.new" "$out"
echo; cat "$out"

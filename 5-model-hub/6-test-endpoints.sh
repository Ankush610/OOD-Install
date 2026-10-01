#!/usr/bin/env bash
# Real endpoints in the cluster, acting AS a user (their MLflow token, their kubeconfig, their namespace):
#   ml     train sklearn in ML_TRAIN_SIF -> register in MLflow -> deploy mlflow-serve-ml on CPU -> /invocations
#   llm    a base model from MODELS_ROOT/base -> deploy vllm-openai on 1 GPU -> /v1/chat/completions with the API key
#   torch  train a tiny torch net in TORCH_TRAIN_SIF -> register -> deploy mlflow-serve-torch on 1 GPU -> /invocations
# Endpoints are called from master at their ClusterIP (v1: no gateway). Each is deleted after its test unless --keep.
# GPU tests run one after the other (USER_GPU_QUOTA=1).
# Run on master:  sudo bash 6-test-endpoints.sh <user> [ml] [llm] [torch] [--keep]     (default: all three)
#   llm needs:   LLM_PATH, a folder under MODELS_ROOT (default MODELS_ROOT/base/qwen/Qwen3.5-0.8B)
#   TORCH_GPUS=0 runs the torch endpoint on CPU (default 1)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"; source "$HERE/images/built.env"
export PATH="$SLURM_BIN:$PATH" SLURM_CONF
[ "$(id -u)" = 0 ] || { echo "Run with sudo (acts as the user)." >&2; exit 1; }
U=${1:?usage: sudo bash 6-test-endpoints.sh <user> [ml] [llm] [torch] [--keep]}; shift
keep=0; tests=()
for a in "$@"; do [ "$a" = --keep ] && keep=1 || tests+=("$a"); done
[ ${#tests[@]} -gt 0 ] || tests=(ml llm torch)
LLM_PATH=${LLM_PATH:-$MODELS_ROOT/base/qwen/Qwen3.5-0.8B}

IFS=: read -r _ _ uid gid _ home _ < <(getent passwd "$U") || { echo "No user $U" >&2; exit 1; }
KC=$home/.kube/aistack.config; NS=u-$U
[ -f "$KC" ] || { echo "No $KC: run 2-sync-users.sh $U first." >&2; exit 1; }
creds=$home/.mlflow/credentials
[ -f "$creds" ] || { echo "No $creds: run ../3-mlflow/3-sync-tokens.sh first." >&2; exit 1; }
kU() { kubectl --kubeconfig "$KC" -n "$NS" "$@"; }                    # every k8s call is the user's own
asU() { sudo -u "$U" env HOME="$home" MLFLOW_TRACKING_URI="$MLFLOW_URI" "$@"; }
gpu_type=$(sinfo -h -p "$BRIDGE_PARTITION" -o %G | sed -n 's/.*gpu:\([^:(,]*\):[0-9].*/\1/p' | head -1)
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; [ -n "${2-}" ] && echo "$2" | tail -15 | sed 's/^/      /'; fail=$((fail+1)); }

echo "== $U ($uid:$gid) in $NS, GPU type '$gpu_type', MLflow $MLFLOW_URI"
# the pod's MLflow login: a Secret made from the user's own token file (files, so it never shows up in ps)
t=$(mktemp -d); chmod 700 "$t"
sed -n 's/^mlflow_tracking_username *= *//p' "$creds" | tr -d '\n' > "$t/username"
sed -n 's/^mlflow_tracking_password *= *//p' "$creds" | tr -d '\n' > "$t/password"
kU create secret generic mlflow-creds --from-file="$t/username" --from-file="$t/password" \
  --dry-run=client -o yaml | kU apply -f - >/dev/null && echo "secret mlflow-creds ok"
rm -rf "$t"

deploy() {  # deploy <runtime> <name> key=value...  -> waits until Ready (or fails), prints the ClusterIP
  local rt=$1 name=$2; shift 2
  python3 "$HERE/render.py" "$rt" name="$name" user="$U" uid="$uid" gid="$gid" partition="$BRIDGE_PARTITION" \
    hours=1 "$@" | kU apply -f - >/dev/null || return 1
  # Ready = the model is loaded (startup probe passed); big models take minutes, plus the wait for a GPU
  if ! kU wait --for=condition=Ready pod/"$name" --timeout=900s >/dev/null 2>&1; then
    kU get pods -l app="$name" -o wide >&2
    # the first error lines matter (a traceback's end only says "exit code 1"), then the last few lines
    kU logs "$name" --all-containers --tail=300 2>&1 | grep -iE -m 12 'error|exception|denied|not found|no such' >&2
    kU logs "$name" --all-containers --tail=8 >&2 2>&1
    kU get events --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp 2>/dev/null | tail -5 >&2
    return 1
  fi
  kU get svc "$name" -o jsonpath='{.spec.clusterIP}'
}
cleanup() { [ "$keep" = 1 ] && { echo "      kept: $1 (delete: kubectl -n $NS delete pod,svc,secret -l app=$1)"; return; }
            kU delete pod,svc,secret -l app="$1" --wait=true >/dev/null 2>&1; echo "      deleted $1"; }

register() {  # register <sif> <name> <python code that sets `model` and `X`, and logs it>  -> prints the version
  asU "$APPTAINER" exec --pwd /tmp "$1" python - "$2" "$U" <<<"$3" 2>&1 | grep -v -i warning | tail -1
}

for test in "${tests[@]}"; do
case $test in
ml)
  echo "-- ml: sklearn in $(basename "$ML_TRAIN_SIF") -> MLflow -> mlflow-serve-ml (CPU)"
  v=$(register "$ML_TRAIN_SIF" mh-test-sklearn '
import sys, mlflow, numpy as np, pandas as pd
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from mlflow.models import infer_signature
name, user = sys.argv[1], sys.argv[2]
mlflow.set_experiment(f"mh-test-{user}")
rng = np.random.default_rng(0)
X = pd.DataFrame({"age": rng.integers(18, 80, 200).astype(float), "usage": rng.random(200) * 100})
y = (X["age"] + X["usage"] > 90).astype(int)
with mlflow.start_run():
    info = mlflow.sklearn.log_model(make_pipeline(StandardScaler(), LogisticRegression()).fit(X, y), name="model",
                                    signature=infer_signature(X, y), registered_model_name=name)
print(info.registered_model_version)')
  [[ $v =~ ^[0-9]+$ ]] || { bad "ml: train + register" "$v"; continue; }
  ok "ml: trained in the SIF, registered mh-test-sklearn v$v"
  if ip=$(deploy mlflow mh-sklearn image="$MLFLOW_SERVE_ML" model_uri="models:/mh-test-sklearn/$v" \
            mlflow_uri="$MLFLOW_URI" gpus=0 2>/tmp/mh-err); then
    out=$(curl -s --max-time 30 "http://$ip:8080/invocations" -H 'Content-Type: application/json' \
          -d '{"dataframe_split":{"columns":["age","usage"],"data":[[20,10],[70,80],[40,60]]}}')
    [[ $out == *predictions* ]] && ok "ml: endpoint answered $out" || bad "ml: /invocations" "$out"
  else bad "ml: deploy" "$(cat /tmp/mh-err)"; fi
  cleanup mh-sklearn ;;
llm)
  echo "-- llm: $LLM_PATH -> vllm-openai on 1 $gpu_type"
  [ -f "$LLM_PATH/config.json" ] || { bad "llm: no model at $LLM_PATH (copy it there as $MODELHUB_USER)"; continue; }
  inpod=/models${LLM_PATH#"$MODELS_ROOT"}                              # MODELS_ROOT is mounted at /models
  if ip=$(deploy vllm mh-llm image="$VLLM_OPENAI" model_path="$inpod" gpus=1 gpu_type="$gpu_type" \
            max_model_len=4096 2>/tmp/mh-err); then
    key=$(kU get secret mh-llm-key -o jsonpath='{.data.api-key}' | base64 -d)
    noauth=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "http://$ip:8080/v1/models")
    [ "$noauth" = 401 ] && ok "llm: no API key -> 401" || bad "llm: no API key gave $noauth (want 401)"
    out=$(curl -s --max-time 120 "http://$ip:8080/v1/chat/completions" -H "Authorization: Bearer $key" \
          -H 'Content-Type: application/json' \
          -d '{"model":"mh-llm","messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":32}')
    msg=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"][:120])' <<<"$out" 2>/dev/null)
    [ -n "$msg" ] && ok "llm: chat answered: $msg" || bad "llm: /v1/chat/completions" "$out"
    kU get pod -l app=mh-llm -o jsonpath='      ran on {.items[0].spec.nodeName}{"\n"}'
  else bad "llm: deploy" "$(cat /tmp/mh-err)"; fi
  cleanup mh-llm ;;
torch)
  tg=${TORCH_GPUS:-1}
  echo "-- torch: tiny net in $(basename "$TORCH_TRAIN_SIF") -> MLflow -> mlflow-serve-torch ($([ "$tg" = 1 ] && echo "1 $gpu_type" || echo CPU))"
  v=$(register "$TORCH_TRAIN_SIF" mh-test-torch '
import sys, mlflow, numpy as np, torch
from mlflow.models import infer_signature
name, user = sys.argv[1], sys.argv[2]
mlflow.set_experiment(f"mh-test-{user}")
torch.manual_seed(0)
X = torch.rand(256, 4); y = (X.sum(1, keepdim=True) > 2).float()
net = torch.nn.Sequential(torch.nn.Linear(4, 8), torch.nn.ReLU(), torch.nn.Linear(8, 1), torch.nn.Sigmoid())
opt = torch.optim.Adam(net.parameters(), 0.05)
for _ in range(200):
    opt.zero_grad(); loss = torch.nn.functional.binary_cross_entropy(net(X), y); loss.backward(); opt.step()
with mlflow.start_run():
    mlflow.log_metric("loss", loss.item())
    # MLflow 3.15 saves torch as pt2 (torch.export) by default, which needs input_example to trace the model
    info = mlflow.pytorch.log_model(net, name="model", registered_model_name=name, input_example=X[:2].numpy(),
                                    signature=infer_signature(X.numpy(), net(X).detach().numpy()))
print(info.registered_model_version)')
  [[ $v =~ ^[0-9]+$ ]] || { bad "torch: train + register" "$v"; continue; }
  ok "torch: trained in the SIF, registered mh-test-torch v$v"
  if ip=$(deploy mlflow mh-torch image="$MLFLOW_SERVE_TORCH" model_uri="models:/mh-test-torch/$v" \
            mlflow_uri="$MLFLOW_URI" gpus="$tg" gpu_type="$gpu_type" 2>/tmp/mh-err); then
    out=$(curl -s --max-time 30 "http://$ip:8080/invocations" -H 'Content-Type: application/json' \
          -d '{"inputs":[[0.1,0.1,0.1,0.1],[0.9,0.9,0.9,0.9]]}')
    [[ $out == *predictions* ]] && ok "torch: endpoint answered $out" || bad "torch: /invocations" "$out"
    gpu=$(kU exec mh-torch -- python -c 'import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else "")' 2>&1 | tail -1)
    if [ "$tg" = 1 ]; then [[ $gpu == True* ]] && ok "torch: pod sees the GPU ($gpu)" || bad "torch: torch.cuda in the pod" "$gpu"; fi
  else bad "torch: deploy" "$(cat /tmp/mh-err)"; fi
  cleanup mh-torch ;;
*) echo "unknown test: $test (ml, llm, torch)" >&2 ;;
esac
done
rm -f /tmp/mh-err
echo; echo "Result: $pass passed, $fail failed"
[ "$fail" = 0 ]

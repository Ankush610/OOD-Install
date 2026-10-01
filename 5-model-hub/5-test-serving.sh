#!/usr/bin/env bash
# Does a model trained in the training SIF load and answer in its serving image? Train in ML_TRAIN_SIF (apptainer),
# serve with the mlflow-serve-ml image (podman, as a random non-root UID, like the pods), call /invocations.
# Models: sklearn + LightGBM in MLflow's default skops format, an sklearn Pipeline carrying a pickled pandas object
# (cloudpickle: the pandas 3 case), XGBoost, CatBoost. Local only: no k8s, no MLflow server. Rerun after changing a SIF or an image.
# Run on master (no root):  bash 5-test-serving.sh [image]      (default: MLFLOW_SERVE_ML from images/built.env)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
IMG=${1:-$(sed -n 's/^MLFLOW_SERVE_ML=//p' "$HERE/images/built.env" 2>/dev/null)}
[ -n "$IMG" ] || { echo "usage: bash 5-test-serving.sh <image>   (or run 4-images.sh first)" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"; podman rm -f mh-serve-test >/dev/null 2>&1 || true' EXIT
chmod 755 "$W"

echo "== 1. Train + save in $(basename "$ML_TRAIN_SIF")"
"$APPTAINER" exec --bind "$W:/w" --pwd /w "$ML_TRAIN_SIF" python - <<'EOF'
import mlflow, numpy as np, pandas as pd
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from mlflow.models import infer_signature
import xgboost, lightgbm, catboost

rng = np.random.default_rng(0)
X = pd.DataFrame({"age": rng.integers(18, 80, 200).astype(float), "usage": rng.random(200) * 100})
y = (X["age"] + X["usage"] > 90).astype(int)
sig = infer_signature(X, y)
mlflow.sklearn.save_model(make_pipeline(StandardScaler(), LogisticRegression()).fit(X, y), "/w/sklearn", signature=sig)
skl = make_pipeline(StandardScaler(), LogisticRegression()).fit(X, y)
skl.trained_on = pd.Series(["pandas", pd.__version__])     # a real pandas object inside the pickle
mlflow.sklearn.save_model(skl, "/w/sklearn-cloudpickle", signature=sig, serialization_format="cloudpickle")
mlflow.xgboost.save_model(xgboost.XGBClassifier(n_estimators=5).fit(X, y), "/w/xgboost", signature=sig)
mlflow.lightgbm.save_model(lightgbm.LGBMClassifier(n_estimators=5, verbose=-1).fit(X, y), "/w/lightgbm", signature=sig)
mlflow.catboost.save_model(catboost.CatBoostClassifier(iterations=5, verbose=0).fit(X, y), "/w/catboost", signature=sig)
X.head(3).to_json("/w/input.json", orient="split")
print("trained with pandas", pd.__version__)
EOF
chmod -R a+rX "$W"

echo "== 2. Serve each with $IMG (uid 4242) and call /invocations"
body=$(python3 -c "import json; print(json.dumps({'dataframe_split': json.load(open('$W/input.json'))}))")
fail=0
for m in sklearn sklearn-cloudpickle xgboost lightgbm catboost; do
  podman rm -f mh-serve-test >/dev/null 2>&1 || true
  # --passwd=false: like k8s, no /etc/passwd entry for the UID (podman adds one by default and hid a torch crash)
  podman run -d --name mh-serve-test --passwd=false --user 4242:4242 -e USER=test -e LOGNAME=test -p 127.0.0.1:18080:8080 \
    -v "$W/$m:/model:ro,Z" "$IMG" -m /model >/dev/null
  for _ in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:18080/ping && break; sleep 1; done
  if out=$(curl -sf http://127.0.0.1:18080/invocations -H 'Content-Type: application/json' -d "$body"); then
    echo "PASS  $m -> $out"
  else
    echo "FAIL  $m"; podman logs mh-serve-test 2>&1 | tail -8 | sed 's/^/      /'; fail=1
  fi
done
exit $fail

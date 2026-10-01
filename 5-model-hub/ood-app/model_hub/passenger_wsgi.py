"""Model Hub backend: an OOD Passenger app that runs AS the logged-in user.

Everything goes through the user's own credentials, so the app can never do more than the user could by hand:
  MLflow  ~/.mlflow/credentials          list their models, read a version's MLmodel (signature, flavors)
  k8s     ~/.kube/aistack.config         deploy / list / logs / delete endpoints in their namespace u-<user>
Endpoints are called server-side at their ClusterIP (v1 has no gateway), so no key or token reaches the browser
except the user's own vLLM key, shown on purpose for their scripts.
Standard library + PyYAML only (system python3). render.py (next to this file) builds the k8s objects.
site.json (written by 7-install-ood-app.sh from site.conf) holds the site values.
"""
import base64
import json
import mimetypes
import os
import pwd
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import render  # noqa: E402

SITE = json.load(open(os.path.join(HERE, "site.json")))
ME = pwd.getpwuid(os.getuid())
USER, HOME, UID, GID = ME.pw_name, ME.pw_dir, ME.pw_uid, ME.pw_gid
NS = f"u-{USER}"
KUBECONFIG = os.path.join(HOME, ".kube", "aistack.config")
CREDS = os.path.join(HOME, ".mlflow", "credentials")
PUBLIC = os.path.join(HERE, "public")
API = SITE["mlflow_uri"].rstrip("/") + "/api/2.0"


class Fail(Exception):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status


# ---------- MLflow (REST, the user's token) ----------
def mlflow_creds():
    if not os.path.isfile(CREDS):
        raise Fail(409, "No ~/.mlflow/credentials: ask the admin to run 3-mlflow/3-sync-tokens.sh")
    kv = dict(re.findall(r"^\s*(\w+)\s*=\s*(\S+)\s*$", open(CREDS).read(), re.M))
    return kv.get("mlflow_tracking_username", ""), kv.get("mlflow_tracking_password", "")


def mlflow(path, params=None, raw=False):
    url = API + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Basic " + base64.b64encode(":".join(mlflow_creds()).encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        raise Fail(502, f"MLflow {path}: HTTP {e.code} {e.read()[:300].decode(errors='replace')}")
    except OSError as e:
        raise Fail(502, f"MLflow not reachable: {e}")
    return data if raw else json.loads(data or b"{}")


def tags(obj):
    return {t["key"]: t.get("value", "") for t in obj.get("tags", [])}


def list_models():
    out, token = [], None
    while True:
        r = mlflow("/mlflow/registered-models/search", {"max_results": 200, **({"page_token": token} if token else {})})
        for m in r.get("registered_models", []):
            versions = sorted((int(v["version"]) for v in m.get("latest_versions", [])), reverse=True)
            out.append({"name": m["name"], "description": m.get("description", ""), "tags": tags(m),
                        "updated": m.get("last_updated_timestamp"), "latest": versions[0] if versions else None})
        token = r.get("next_page_token")
        if not token:
            return sorted(out, key=lambda m: -(m["updated"] or 0))


def model_version(name, version):
    v = mlflow("/mlflow/model-versions/get", {"name": name, "version": version})["model_version"]
    vt = tags(v)
    info = {"name": name, "version": int(version), "tags": vt, "run_id": v.get("run_id"),
            "created": v.get("creation_timestamp"), "description": v.get("description", "")}
    if vt.get("path"):                                       # an LLM folder registered with model-register
        info.update(kind="LLM", runtime="vllm", path=vt["path"], format=vt.get("format", "hf"))
        return info
    # the MLmodel file says which flavor it is and what goes in / comes out
    uri = mlflow("/mlflow/model-versions/get-download-uri", {"name": name, "version": version})["artifact_uri"]
    rel = re.sub(r"^mlflow-artifacts:/+", "", uri).rstrip("/")
    mlmodel = yaml.safe_load(mlflow(f"/mlflow-artifacts/artifacts/{urllib.parse.quote(rel)}/MLmodel", raw=True))
    flavors = sorted(k for k in (mlmodel.get("flavors") or {}) if k != "python_function")
    sig = mlmodel.get("signature") or {}
    parse = lambda s: json.loads(s) if isinstance(s, str) else (s or [])
    torch = "pytorch" in flavors
    info.update(kind="DL" if torch else "ML", runtime="mlflow", flavors=flavors,
                image="torch" if torch else "ml", inputs=parse(sig.get("inputs")), outputs=parse(sig.get("outputs")),
                artifacts=rel, size=mlmodel.get("model_size_bytes"), model_id=v.get("model_id"))
    return info


def lib_check(requirements, image_libs):
    """The model's requirements.txt (what it was trained with) vs the serving image's pinned versions.
    Only packages both list are compared; local labels (+cu129) are ignored."""
    norm = lambda n: {"xgboost-cpu": "xgboost", "mlflow-skinny": "mlflow"}.get(re.sub(r"[-_.]+", "-", n).lower(),
                                                                                 re.sub(r"[-_.]+", "-", n).lower())
    have = {norm(k): v.split("+")[0] for k, v in image_libs.items()}
    out = []
    for m in re.finditer(r"^\s*([A-Za-z0-9_.-]+)(?:\[[^]]*\])?\s*==\s*([^\s;#]+)", requirements, re.M):
        n, v = norm(m.group(1)), m.group(2).split("+")[0]
        if n in have:
            out.append({"name": n, "trained": v, "serving": have[n], "ok": v == have[n]})
    return out


def safetensors_params(folder):
    """Parameter count from the safetensors headers (8-byte length + JSON), without reading the weights."""
    total = 0
    for fn in os.listdir(folder):
        if fn.endswith(".safetensors"):
            with open(os.path.join(folder, fn), "rb") as fh:
                head = json.loads(fh.read(int.from_bytes(fh.read(8), "little")))
            for k, t in head.items():
                if k != "__metadata__":
                    n = 1
                    for d in t["shape"]:
                        n *= d
                    total += n
    return total or None


def llm_card(path):
    """What the folder says about an LLM: size on disk, architecture, context length, LoRA base."""
    out = {"size": sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)}
    cfg = os.path.join(path, "config.json")
    if os.path.isfile(cfg):
        c = json.load(open(cfg))
        c = {**c.get("text_config", {}), **c}                # multimodal configs keep the LLM part in text_config
        out.update(architecture=(c.get("architectures") or [c.get("model_type")])[0],
                   context=c.get("max_position_embeddings"), dtype=c.get("torch_dtype") or c.get("dtype"))
    ada = os.path.join(path, "adapter_config.json")
    if os.path.isfile(ada):
        a = json.load(open(ada))
        out.update(lora_base=a.get("base_model_name_or_path"), lora_rank=a.get("r"))
    out["params"] = safetensors_params(path)
    return out


def model_card(name, version):
    """model_version + what helps pick a version: the run (metrics, params, who, where), size, library check.
    Each extra is best effort: a missing piece leaves a gap on the page, never an error."""
    info = model_version(name, version)
    def tryit(fn):
        try:
            return fn()
        except (Fail, OSError, ValueError, KeyError, TypeError):
            return None
    if info.get("run_id"):
        run = tryit(lambda: mlflow("/mlflow/runs/get", {"run_id": info["run_id"]})["run"])
        if run:
            ri, rd = run["info"], run["data"]
            info["metrics"] = {m["key"]: m["value"] for m in rd.get("metrics", [])}
            info["params"] = {p["key"]: p["value"] for p in rd.get("params", [])}
            exp = tryit(lambda: mlflow("/mlflow/experiments/get", {"experiment_id": ri["experiment_id"]})["experiment"]["name"])
            info["run"] = {"id": ri["run_id"], "name": ri.get("run_name"), "experiment_id": ri["experiment_id"],
                           "experiment": exp, "user": ri.get("user_id") or tags(rd).get("mlflow.user"),
                           "start": ri.get("start_time"), "end": ri.get("end_time")}
    if not info.get("metrics") and info.get("model_id"):      # MLflow 3 can keep metrics on the logged model only
        lm = tryit(lambda: mlflow(f"/mlflow/logged-models/{info['model_id']}")["model"])
        if lm:
            info["metrics"] = {m["key"]: m["value"] for m in (lm.get("data") or {}).get("metrics", [])}
    if info["runtime"] == "vllm":
        info["llm"] = tryit(lambda: llm_card(info["path"]))
    else:
        req = tryit(lambda: mlflow(f"/mlflow-artifacts/artifacts/{urllib.parse.quote(info['artifacts'])}/requirements.txt",
                                   raw=True).decode())
        info["libs"] = lib_check(req, SITE.get("image_libs", {}).get(info["image"], {})) if req else None
    return info


# ---------- Kubernetes (kubectl, the user's kubeconfig) ----------
def kubectl(*args, stdin=None, check=True):
    if not os.path.isfile(KUBECONFIG):
        raise Fail(409, "No ~/.kube/aistack.config: ask the admin to run 5-model-hub/2-sync-users.sh " + USER)
    p = subprocess.run(["kubectl", "--kubeconfig", KUBECONFIG, "-n", NS, *args], input=stdin,
                       capture_output=True, text=True, timeout=60)
    if check and p.returncode != 0:
        raise Fail(502, "kubectl " + " ".join(args[:2]) + ": " + (p.stderr or p.stdout).strip()[-500:])
    return p.stdout


def kjson(*args):
    return json.loads(kubectl(*args, "-o", "json"))


def ensure_mlflow_secret():
    user, password = mlflow_creds()
    secret = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "mlflow-creds", "namespace": NS},
              "type": "Opaque", "stringData": {"username": user, "password": password}}
    kubectl("apply", "-f", "-", stdin=json.dumps(secret))


def deploy(body):
    name, version = body["model"], int(body["version"])
    info = model_version(name, version)
    ep = str(body.get("endpoint") or re.sub(r"[^a-z0-9-]+", "-", f"{name}-v{version}".lower()).strip("-"))[:42].strip("-")
    gpus = 1 if body.get("gpu") else 0
    gpu_type = body.get("gpu_type") or (SITE["gpu_types"][0] if SITE["gpu_types"] else "")
    hours = max(1, min(int(body.get("hours", SITE["endpoint_hours"])), SITE["endpoint_hours"]))
    p = {"name": ep, "user": USER, "uid": UID, "gid": GID, "partition": SITE["partition"], "hours": hours,
         "gpus": gpus, "gpu_type": gpu_type}
    if info["runtime"] == "vllm":
        path = info["path"]
        if path.startswith(SITE["models_root"] + "/"):
            inpod = "/models" + path[len(SITE["models_root"]):]
        elif path.startswith(HOME + "/models/"):
            inpod = "/my-models" + path[len(HOME + "/models"):]
        else:
            raise Fail(400, f"{path} is not under {SITE['models_root']} or ~/models: the endpoint can't mount it")
        p.update(image=SITE["images"]["vllm"], model_path=inpod, gpus=1, model_uri=f"models:/{name}/{version}")
    else:
        if info["image"] == "ml":
            p["gpus"] = 0                                     # classic ML is CPU only
        p.update(image=SITE["images"][info["image"]], model_uri=f"models:/{name}/{version}",
                 mlflow_uri=SITE["mlflow_uri"])
        ensure_mlflow_secret()
    try:
        manifest = render.endpoint(info["runtime"], {k: str(v) for k, v in p.items()})
    except ValueError as e:
        raise Fail(400, str(e))
    if body.get("preview"):
        return {"manifest": manifest}
    # a pod is immutable, and re-applying a running one would only move the UI's expiry, not Slurm's time limit
    if kubectl("get", "pod", ep, "--ignore-not-found", "-o", "name").strip():
        raise Fail(409, f"{ep} is still running: delete it first, or pick another endpoint name")
    kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    return {"endpoint": ep}


def pod_state(p):
    """One word + a reason, from what k8s and slurm-bridge report."""
    if not p:                                    # slurm-bridge deletes the pod when its Slurm job ends
        return "stopped", "its time is up (or it was stopped): deploy again to restart it"
    st = p.get("status", {})
    for c in st.get("initContainerStatuses", []) + st.get("containerStatuses", []):
        w = (c.get("state") or {}).get("waiting") or {}
        if w.get("reason") in ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError"):
            return "failed", f"{c['name']}: {w['reason']} {w.get('message', '')}".strip()
    if st.get("phase") == "Pending":
        if not p["spec"].get("nodeName"):
            return "queued", "waiting for Slurm to give it a node" + (" and a GPU" if gpu_of(p) else "")
        return "loading", "starting the container"
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in st.get("conditions", []))
    if ready:
        return "ready", ""
    if st.get("phase") in ("Failed", "Succeeded"):
        return "stopped", st.get("reason") or "the Slurm time limit ended it"
    return "loading", "loading the model"


def gpu_of(pod):
    return any("nvidia.com/gpu" in (c.get("resources", {}).get("limits") or {}) for c in pod["spec"]["containers"])


def endpoints():
    # an endpoint = a Service + a Pod of the same name (render.py); the Service outlives the pod, so a stopped
    # endpoint is still listed
    svcs = kjson("get", "svc", "-l", "model-hub/runtime")["items"]
    pods = {p["metadata"]["name"]: p for p in kjson("get", "pods", "-l", "model-hub/runtime")["items"]}
    out = []
    for s in svcs:
        name, ann = s["metadata"]["name"], s["metadata"].get("annotations", {})
        pod = pods.get(name)
        state, why = pod_state(pod)
        rt = s["metadata"]["labels"].get("model-hub/runtime")
        ctr = pod["spec"]["containers"][0] if pod else {}
        out.append({"name": name, "runtime": rt, "model": ann.get("model-hub/model"), "expires": ann.get("model-hub/expires"),
                    "state": state, "why": why, "image": ctr.get("image"), "gpu": bool(pod and gpu_of(pod)),
                    "node": pod["spec"].get("nodeName") if pod else None, "ip": s["spec"].get("clusterIP"),
                    "path": "/v1/chat/completions" if rt == "vllm" else "/invocations"})
    return sorted(out, key=lambda e: e["name"])


def api_key(name):
    s = kjson("get", "secret", f"{name}-key")
    return base64.b64decode(s["data"]["api-key"]).decode()


def predict(name, body):
    ep = next((e for e in endpoints() if e["name"] == name), None)
    if not ep:
        raise Fail(404, f"no endpoint {name}")
    if ep["state"] != "ready":
        raise Fail(409, f"{name} is {ep['state']}: {ep['why']}")
    req = urllib.request.Request(f"http://{ep['ip']}:8080{ep['path']}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    if ep["runtime"] == "vllm":
        req.add_header("Authorization", "Bearer " + api_key(name))
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise Fail(e.code, e.read()[:2000].decode(errors="replace"))
    except OSError as e:
        raise Fail(502, f"endpoint not reachable: {e}")


# ---------- routing ----------
def route(method, path, body):
    parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
    if parts[:1] != ["api"]:
        return None
    a = parts[1:]
    if method == "GET" and a == ["me"]:
        return {"user": USER, "namespace": NS, "mlflow": os.path.isfile(CREDS), "kube": os.path.isfile(KUBECONFIG),
                "gpu_types": SITE["gpu_types"], "endpoint_hours": SITE["endpoint_hours"],
                "mlflow_ui": SITE["mlflow_ui"], "models_root": SITE["models_root"],
                "ssh": SITE.get("ssh", {})}
    if method == "GET" and a == ["models"]:
        return list_models()
    if method == "GET" and len(a) == 3 and a[0] == "models":
        return model_card(a[1], a[2])
    if method == "POST" and a == ["deploy"]:
        return deploy(body)
    if method == "GET" and a == ["endpoints"]:
        return endpoints()
    if len(a) >= 2 and a[0] == "endpoints":
        name = a[1]
        if not render.NAME.match(name):
            raise Fail(400, "bad endpoint name")
        if method == "DELETE" and len(a) == 2:
            kubectl("delete", "pod,svc,secret", "-l", f"app={name}", "--wait=false")
            return {"deleted": name}
        if method == "GET" and a[2:] == ["logs"]:
            return {"logs": kubectl("logs", name, "--all-containers", "--tail=300", check=False)}
        if method == "GET" and a[2:] == ["key"]:
            return {"key": api_key(name)}
        if method == "POST" and a[2:] == ["predict"]:
            return predict(name, body)
    raise Fail(404, f"no route {method} {path}")


def static(path, script_name):
    # nginx serves public/ itself (OOD: `alias <app>/public$1`), so this only sees files it doesn't have.
    # index.html lives OUTSIDE public/ on purpose: for /pun/sys/model_hub (no slash) nginx would serve
    # public/index.html as the directory index, and relative style.css/app.js/api would resolve to /pun/sys/.
    rel = os.path.normpath(path.strip("/"))
    full = os.path.join(PUBLIC, rel)
    if rel and not rel.startswith("..") and os.path.isfile(full):
        return open(full, "rb").read(), mimetypes.guess_type(full)[0] or "application/octet-stream"
    base = (script_name.rstrip("/") + "/").encode()           # -> /pun/sys/model_hub/
    data = open(os.path.join(HERE, "index.html"), "rb").read()
    return data.replace(b"<head>", b'<head>\n  <base href="' + base + b'">', 1), "text/html"


def application(environ, start_response):
    method, path = environ["REQUEST_METHOD"], environ.get("PATH_INFO", "") or "/"
    try:
        n = int(environ.get("CONTENT_LENGTH") or 0)
        body = json.loads(environ["wsgi.input"].read(n) or b"{}") if n else {}
        result = route(method, path, body)
        if result is None:
            data, ctype = static(path, environ.get("SCRIPT_NAME", ""))
            start_response("200 OK", [("Content-Type", ctype), ("Cache-Control", "no-cache")])
            return [data]
        status, payload = "200 OK", result
    except Fail as e:
        status, payload = f"{e.status} Error", {"error": str(e)}
    except (KeyError, ValueError, json.JSONDecodeError) as e:
        status, payload = "400 Bad Request", {"error": f"bad request: {e}"}
    start_response(status, [("Content-Type", "application/json"), ("Cache-Control", "no-store")])
    return [json.dumps(payload).encode()]

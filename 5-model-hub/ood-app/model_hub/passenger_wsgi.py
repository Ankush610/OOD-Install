"""Model Hub backend: an OOD Passenger app that runs AS the logged-in user.

Everything goes through the user's own credentials, so the app can never do more than the user could by hand:
  MLflow  ~/.mlflow/credentials          list their models, read a version's MLmodel (signature, flavors)
  k8s     ~/.kube/aistack.config         deploy / list / logs / delete endpoints in their namespace u-<user>
The playground calls endpoints server-side at their ClusterIP; apps call them through the gateway with the user's
personal key (made here, shown once). No endpoint's own vLLM key ever reaches the browser.
Standard library + PyYAML only (system python3). render.py (next to this file) builds the k8s objects.
site.json (written by 7-install-ood-app.sh from site.conf) holds the site values.
"""
import base64
import hashlib
import json
import mimetypes
import os
import posixpath
import pwd
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import render  # noqa: E402

SITE = json.load(open(os.path.join(HERE, "site.json")))
# PUN processes get no SLURM_CONF (OOD hands it only to its own adapter, via clusters.d), and squeue then
# looks for the config in DNS and fails. Point it at the file.
os.environ.setdefault("SLURM_CONF", SITE.get("slurm_conf", "/etc/slurm/slurm.conf"))
ME = pwd.getpwuid(os.getuid())
USER, HOME, UID, GID = ME.pw_name, ME.pw_dir, ME.pw_uid, ME.pw_gid
NS = f"u-{USER}"
KUBECONFIG = os.path.join(HOME, ".kube", "aistack.config")
CREDS = os.path.join(HOME, ".mlflow", "credentials")
PUBLIC = os.path.join(HERE, "public")
DOWNLOADS = os.path.join(HOME, "model-downloads")           # "Download to my home folder" puts models here
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


def basic_auth():
    return "Basic " + base64.b64encode(":".join(mlflow_creds()).encode()).decode()


def mlflow(path, params=None, raw=False, body=None):
    """GET, or POST when body is given. Paths are under /api/2.0, except "/3.0/..." (MLflow's newer permission API)."""
    url = (API[:-4] if path.startswith("/3.0/") else API) + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": basic_auth()})
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
            # model-register tags each VERSION with path= (an LLM folder), not the model: look at the latest versions
            llm = any(tags(v).get("path") for v in m.get("latest_versions", []))
            out.append({"name": m["name"], "description": m.get("description", ""), "tags": tags(m), "llm": llm,
                        "updated": m.get("last_updated_timestamp"), "latest": versions[0] if versions else None})
        token = r.get("next_page_token")
        if not token:
            return sorted(out, key=lambda m: -(m["updated"] or 0))


def model_version(name, version):
    v = mlflow("/mlflow/model-versions/get", {"name": name, "version": version})["model_version"]
    vt, mt = tags(v), tags(mlflow("/mlflow/registered-models/get", {"name": name})["registered_model"])
    # Someone else's public model: its files come from the copy public-models.py made (the owner's own files stay
    # private to them). "owner" is set by that timer too, only on public models, before anyone else gets access:
    # no owner tag yet = only the owner can see it.
    public = mt.get("public") == "true"
    mine = not public or mt.get("owner", USER) == USER
    copy = None if mine else vt.get("public_copy") if vt.get("public_status") == "ready" else ""
    if copy == "":
        st = vt.get("public_status", "")
        raise Fail(409, f"{name} v{version} is public, but its files " + (
            f"couldn't be shared ({st[7:]}). Ask its owner, {mt.get('owner', '?')}." if st.startswith("error:")
            else "are still being copied for everyone. Try again in a minute."))
    info = {"name": name, "version": int(version), "tags": vt, "run_id": v.get("run_id"),
            "created": v.get("creation_timestamp"), "description": v.get("description", ""),
            "public": public, "owner": mt.get("owner") if public else USER, "mine": mine,
            "public_status": vt.get("public_status") if public else None}
    if vt.get("path"):                                       # an LLM folder registered with model-register
        info.update(kind="LLM", runtime="vllm", path=copy or vt["path"], format=vt.get("format", "hf"))
        return info
    # the MLmodel file says which flavor it is and what goes in / comes out
    uri = copy or mlflow("/mlflow/model-versions/get-download-uri", {"name": name, "version": version})["artifact_uri"]
    info["download_uri"] = copy or f"models:/{name}/{version}"
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


def can_manage(name):
    """Owner (MANAGE) of this model? Only they get Make public / Make private."""
    rows = mlflow("/3.0/mlflow/users/current/permissions").get("permissions", [])
    return any(r.get("resource_type") == "registered_model" and r.get("resource_pattern") == name
               and r.get("permission") == "MANAGE" for r in rows)


def set_public(name, body):
    """Only the tag: public-models.py (root, every minute) copies the files and gives or takes read access.
    MLflow itself checks that this user may change the model's tags."""
    if not can_manage(name):
        raise Fail(403, "only the model's owner can change this")
    on = bool(body.get("public"))
    if on and "'" not in name:                                # (a quote doesn't fit MLflow's filter; the timer skips those)
        for v in mlflow("/mlflow/model-versions/search", {"filter": f"name = '{name}'", "max_results": 1000}).get("model_versions", []):
            mlflow("/mlflow/model-versions/set-tag", body={"name": name, "version": v["version"], "key": "public_status",
                                                         "value": "waiting"})
    mlflow("/mlflow/registered-models/set-tag", body={"name": name, "key": "public", "value": "true" if on else "false"})
    return {"public": on}


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


def du(path):
    """Bytes in a folder (0 if it's gone); files may come and go while it's being written."""
    total = 0
    for d, _, fs in os.walk(path):
        for f in fs:
            try:
                total += os.path.getsize(os.path.join(d, f))
            except OSError:
                pass
    return total


def llm_card(path):
    """What the folder says about an LLM: size on disk, architecture, context length, LoRA base."""
    out = {"size": du(path)}
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
    info["can_manage"] = info["mine"] and can_manage(name)
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


# ---------- download: as the user, through MLflow (ML / DL) or from the folder (LLM) ----------
def artifact_files(rel, sub=""):
    """[(path inside the model, size)] of every file under an MLflow artifact folder (MLflow lists one level)."""
    out = []
    for f in mlflow("/mlflow-artifacts/artifacts", {"path": posixpath.join(rel, sub) if sub else rel}).get("files", []):
        p = posixpath.join(sub, f["path"])
        out += artifact_files(rel, p) if f.get("is_dir") else [(p, int(f.get("file_size") or 0))]
    return out


def artifact_open(rel, p):
    req = urllib.request.Request(API + "/mlflow-artifacts/artifacts/" + urllib.parse.quote(posixpath.join(rel, p)),
                                 headers={"Authorization": basic_auth()})
    return urllib.request.urlopen(req, timeout=60)


class _Sink:
    """zipfile writes here; the WSGI response hands out what piled up (zipfile streams to anything with write())."""
    def __init__(self):
        self.buf = []

    def write(self, b):
        self.buf.append(bytes(b))
        return len(b)

    def flush(self):
        pass

    def take(self):
        out, self.buf = b"".join(self.buf), []
        return out


def zip_stream(rel, files):
    sink = _Sink()
    with zipfile.ZipFile(sink, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as z:
        for p, _ in files:
            with artifact_open(rel, p) as r, z.open(p, "w", force_zip64=True) as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    yield sink.take()
    yield sink.take()


def download_dir(name, version):
    return os.path.join(DOWNLOADS, re.sub(r"[^A-Za-z0-9._-]+", "_", name), f"v{int(version)}")


def download_state(name, version):
    """none | running | done | error, from what's on disk: <dir>.part while it runs (+ <dir>.pid, <dir>.total = bytes
    to fetch, for the progress bar), <dir> when done."""
    d = download_dir(name, version)
    out = {"path": d}
    if os.path.isdir(d):
        return {**out, "state": "done"}
    if os.path.isdir(d + ".part"):
        try:
            os.kill(int(open(d + ".pid").read()), 0)
            try:
                total = int(open(d + ".total").read())
            except (OSError, ValueError):                    # not counted yet
                total = None
            return {**out, "state": "running", "done": du(d + ".part"), "total": total}
        except (OSError, ValueError):
            return {**out, "state": "error", "error": "it stopped before it finished; try again"}
    if os.path.isfile(d + ".error"):
        return {**out, "state": "error", "error": open(d + ".error").read()}
    return {**out, "state": "none"}


def start_download(name, version):
    """Starts a copy into the user's home that outlives this request (an LLM can be 100+ GB)."""
    info = model_version(name, version)
    st = download_state(name, version)
    if st["state"] in ("done", "running"):
        return st
    d = st["path"]
    for leftover in (d + ".error", d + ".pid", d + ".total"):
        if os.path.exists(leftover):
            os.remove(leftover)
    shutil.rmtree(d + ".part", ignore_errors=True)
    os.makedirs(d + ".part")
    kind, src = ("folder", info["path"]) if info["runtime"] == "vllm" else ("mlflow", info["artifacts"])
    p = subprocess.Popen([sys.executable or "python3", os.path.abspath(__file__), "--fetch", kind, src, d], cwd=HOME,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    with open(d + ".pid", "w") as f:
        f.write(str(p.pid))
    return {**download_state(name, version), "state": "running"}


def fetch(kind, src, dest):
    """The background half of start_download (python3 passenger_wsgi.py --fetch ...): dest.part -> dest when complete,
    or dest.error with the reason."""
    part = dest + ".part"
    try:
        files = None if kind == "folder" else artifact_files(src)
        with open(dest + ".total", "w") as f:
            f.write(str(du(src) if files is None else sum(n for _, n in files)))
        if kind == "folder":
            shutil.rmtree(part)
            shutil.copytree(src, part)                       # the user's own rights: only what they may read
        else:
            for p, _ in files:
                out = os.path.normpath(os.path.join(part, p))
                if not out.startswith(part + os.sep):
                    raise ValueError(f"bad file name {p!r}")
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with artifact_open(src, p) as r, open(out, "wb") as f:
                    shutil.copyfileobj(r, f, 1 << 20)
        os.rename(part, dest)
    except Exception as e:                                   # anything: the page shows it
        shutil.rmtree(part, ignore_errors=True)
        with open(dest + ".error", "w") as f:
            f.write(str(e)[:500] or type(e).__name__)
    finally:
        for f in (dest + ".pid", dest + ".total"):
            if os.path.exists(f):
                os.remove(f)


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


def limits():
    """This user's limits, as 2-sync-users.sh set them: GPUs = their ResourceQuota (the hard limit), max hours =
    its annotation (the pod-has-time-limit policy enforces the same number). Users can read but not change either."""
    try:
        q = kjson("get", "resourcequota", "gpus")
        gpus = int(q["spec"]["hard"].get("requests.nvidia.com/gpu", "0"))
        max_hours = int(q["metadata"].get("annotations", {}).get("model-hub/max-hours", SITE["hours_max"]))
    except (Fail, ValueError, KeyError):
        gpus, max_hours = 1, SITE["hours_max"]
    return {"gpus": gpus, "max_hours": max_hours, "default_hours": min(SITE["hours_default"], max_hours)}


def deploy(body):
    name, version = body["model"], int(body["version"])
    info = model_version(name, version)
    ep = str(body.get("endpoint") or re.sub(r"[^a-z0-9-]+", "-", f"{name}-v{version}".lower()).strip("-"))[:42].strip("-")
    lim = limits()
    gpus = max(1, int(body.get("gpus", 1))) if body.get("gpu") else 0
    if gpus > lim["gpus"]:
        raise Fail(400, f"you may use {lim['gpus']} GPU(s) at a time; ask the admin for more")
    gpu_type = body.get("gpu_type") or (SITE["gpu_types"][0] if SITE["gpu_types"] else "")
    hours = int(body.get("hours") or lim["default_hours"])
    if not 1 <= hours <= lim["max_hours"]:
        raise Fail(400, f"run time must be 1..{lim['max_hours']} hours; longer runs: ask the admin")
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
        p.update(image=SITE["images"]["vllm"], model_path=inpod, gpus=max(gpus, 1), model_uri=f"models:/{name}/{version}")
    else:
        if info["image"] == "ml":
            p["gpus"] = 0                                     # classic ML is CPU only
        p.update(image=SITE["images"][info["image"]], model_uri=f"models:/{name}/{version}",
                 download_uri=info["download_uri"], mlflow_uri=SITE["mlflow_uri"])
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


def queue_positions():
    """{job name: place among the waiting jobs of the partition}, best effort (squeue lists in priority order)."""
    try:
        out = subprocess.run([os.path.join(SITE.get("slurm_bin", ""), "squeue"), "-h", "-t", "PD", "-p", SITE["partition"],
                              "--sort=-p,i", "-o", "%j"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    return {j: i for i, j in enumerate(out.split(), 1)}


def pod_state(p, queue=None):
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
            pos = (queue or {}).get(p["metadata"].get("annotations", {}).get("slurmjob.slinky.slurm.net/job-name"))
            return "queued", ("waiting for a free GPU" if gpu_of(p) else "waiting for Slurm to give it a node") + \
                (f" (number {pos} in the queue)" if pos else "")
        return "loading", "starting the container"
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in st.get("conditions", []))
    if ready:
        return "ready", ""
    if st.get("phase") in ("Failed", "Succeeded"):
        return "stopped", st.get("reason") or "the Slurm time limit ended it"
    return "loading", "loading the model"


def gpu_of(pod):
    return sum(int((c.get("resources", {}).get("limits") or {}).get("nvidia.com/gpu", 0)) for c in pod["spec"]["containers"])


def endpoints():
    # an endpoint = a Service + a Pod of the same name (render.py); the Service outlives the pod, so a stopped
    # endpoint is still listed
    svcs = kjson("get", "svc", "-l", "model-hub/runtime")["items"]
    pods = {p["metadata"]["name"]: p for p in kjson("get", "pods", "-l", "model-hub/runtime")["items"]}
    queue = queue_positions() if any(not p["spec"].get("nodeName") for p in pods.values()) else {}
    out = []
    for s in svcs:
        name, ann = s["metadata"]["name"], s["metadata"].get("annotations", {})
        pod = pods.get(name)
        state, why = pod_state(pod, queue)
        rt = s["metadata"]["labels"].get("model-hub/runtime")
        ctr = pod["spec"]["containers"][0] if pod else {}
        out.append({"name": name, "runtime": rt, "model": ann.get("model-hub/model"), "expires": ann.get("model-hub/expires"),
                    "state": state, "why": why, "image": ctr.get("image"), "gpu": gpu_of(pod) if pod else 0,
                    "node": pod["spec"].get("nodeName") if pod else None, "ip": s["spec"].get("clusterIP"),
                    "share": share_of(ann),
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


# ---------- sharing (the gateway reads these annotations on the endpoint's Service) ----------
SHARE = ("model-hub/share-users", "model-hub/share-teams", "model-hub/share-all")
LINUX_NAME = re.compile(r"^[a-z_][a-z0-9_.-]{0,31}$")


def share_of(ann):
    split = lambda s: [n for n in (s or "").split(",") if n]
    return {"users": split(ann.get(SHARE[0])), "teams": split(ann.get(SHARE[1])), "all": ann.get(SHARE[2]) == "true"}


def teams():
    """All teams (../1-ldap/group.sh): groupOfNames that aren't someone's personal posixGroup."""
    out = subprocess.run(["ldapsearch", "-x", "-LLL", "-o", "ldif-wrap=no", "-H", "ldap://localhost",
                          "-b", f"ou=Groups,{SITE['ldap_base']}", "(&(objectClass=groupOfNames)(!(objectClass=posixGroup)))",
                          "cn"], capture_output=True, text=True, timeout=10).stdout
    return sorted(l[4:] for l in out.splitlines() if l.startswith("cn: "))


def set_share(name, body):
    users = sorted({u.strip() for u in body.get("users", []) if u.strip()} - {USER})
    tms = sorted({t.strip() for t in body.get("teams", []) if t.strip()})
    for n in users + tms:
        if not LINUX_NAME.match(n):
            raise Fail(400, f"bad name {n!r}")
    unknown = [u for u in users if subprocess.run(["getent", "passwd", u], capture_output=True).returncode]
    if unknown:
        raise Fail(400, "no such user: " + ", ".join(unknown))
    missing = set(tms) - set(teams())
    if missing:
        raise Fail(400, "no such team: " + ", ".join(sorted(missing)) + " (the admin makes teams: 1-ldap/group.sh)")
    if not kubectl("get", "svc", name, "--ignore-not-found", "-o", "name").strip():
        raise Fail(404, f"no endpoint {name}")
    kubectl("annotate", "svc", name, "--overwrite", f"{SHARE[0]}={','.join(users)}", f"{SHARE[1]}={','.join(tms)}",
            f"{SHARE[2]}={'true' if body.get('all') else 'false'}")
    return {"share": {"users": users, "teams": tms, "all": bool(body.get("all"))}}


def shared_with_me():
    """Other people's endpoints this user may call. Users can't look into other namespaces, so the gateway answers;
    it knows who is asking from the user's cluster client certificate (~/.kube/aistack.config), on its port 8444."""
    gw = SITE.get("gateway", {}).get("url")
    if not gw or not os.path.isfile(KUBECONFIG):
        return []
    user = yaml.safe_load(open(KUBECONFIG))["users"][0]["user"]
    ctx = ssl.create_default_context(cafile=os.path.join(HERE, "gateway-ca.crt") if SITE["gateway"].get("ca") else None)
    with tempfile.TemporaryDirectory() as d:                      # 0700, gone after the call
        for name, key in (("c", "client-certificate-data"), ("k", "client-key-data")):
            with open(os.path.join(d, name), "wb") as f:
                f.write(base64.b64decode(user[key]))
        ctx.load_cert_chain(os.path.join(d, "c"), os.path.join(d, "k"))
    host = urllib.parse.urlsplit(gw).hostname
    try:
        with urllib.request.urlopen(f"https://{host}:8444/shared", context=ctx, timeout=15) as r:
            out = json.loads(r.read())
    except (OSError, ValueError) as e:
        raise Fail(502, f"gateway didn't answer ({e}); ask the admin")
    for e in out:
        e["url"] = f"{gw}/{e['owner']}/{e['name']}{e['path']}"
    return out


# ---------- personal API key (the gateway checks it; one per person) ----------
def key_info():
    s = kubectl("get", "secret", "model-hub-key", "--ignore-not-found", "-o", "json").strip()
    if not s:
        return {"exists": False}
    return {"exists": True, "created": json.loads(s)["metadata"].get("annotations", {}).get("model-hub/created")}


def new_key():
    """A new key replaces the old one at once (the gateway sees it within a minute). Only its SHA-256 is stored, in
    the user's own namespace; the key itself is shown once and never kept anywhere."""
    key = f"mh~{USER}~{secrets.token_hex(24)}"
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    secret = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
              "metadata": {"name": "model-hub-key", "namespace": NS, "annotations": {"model-hub/created": created}},
              "stringData": {"sha256": hashlib.sha256(key.encode()).hexdigest()}}
    kubectl("apply", "-f", "-", stdin=json.dumps(secret))
    return {"key": key, "created": created}


# ---------- routing ----------
def route(method, path, body):
    parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
    if parts[:1] != ["api"]:
        return None
    a = parts[1:]
    if method == "GET" and a == ["me"]:
        return {"user": USER, "namespace": NS, "mlflow": os.path.isfile(CREDS), "kube": os.path.isfile(KUBECONFIG),
                "gpu_types": SITE["gpu_types"], "limits": limits(),
                "mlflow_ui": SITE["mlflow_ui"], "models_root": SITE["models_root"],
                "ssh": SITE.get("ssh", {}), "gateway": SITE.get("gateway", {})}
    if method == "GET" and a == ["shared"]:
        return shared_with_me()
    if method == "GET" and a == ["teams"]:
        return teams()
    if a == ["key"]:
        if method == "GET":
            return key_info()
        if method == "POST":
            return new_key()
        if method == "DELETE":
            kubectl("delete", "secret", "model-hub-key", "--ignore-not-found")
            return {"exists": False}
    if method == "GET" and a == ["models"]:
        return list_models()
    if method == "GET" and len(a) == 3 and a[0] == "models":
        return model_card(a[1], a[2])
    if method == "POST" and len(a) == 3 and a[0] == "models" and a[2] == "public":
        return set_public(a[1], body)
    if len(a) == 4 and a[0] == "models" and a[3] == "download":
        if method == "GET":
            return download_state(a[1], a[2])
        if method == "POST":
            return start_download(a[1], a[2])
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
        if method == "POST" and a[2:] == ["share"]:
            return set_share(name, body)
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
    # nginx serves app.js / style.css with no cache rule, so browsers keep an old copy for a while after an update
    # (heuristic caching). A ?v=<file time> makes a new install load at once; index.html itself is never cached.
    for f in (b"app.js", b"style.css"):
        v = str(int(os.path.getmtime(os.path.join(PUBLIC, f.decode())))).encode()
        data = data.replace(b'"' + f + b'"', b'"' + f + b"?v=" + v + b'"')
    return data.replace(b"<head>", b'<head>\n  <base href="' + base + b'">', 1), "text/html"


def application(environ, start_response):
    method, path = environ["REQUEST_METHOD"], environ.get("PATH_INFO", "") or "/"
    try:
        n = int(environ.get("CONTENT_LENGTH") or 0)
        body = json.loads(environ["wsgi.input"].read(n) or b"{}") if n else {}
        if method == "GET" and path.rstrip("/") == "/api/gateway-ca":
            ca = os.path.join(HERE, "gateway-ca.crt")
            if not os.path.isfile(ca):
                raise Fail(404, "no gateway CA here (the gateway uses the site's own certificate)")
            start_response("200 OK", [("Content-Type", "application/octet-stream"),
                                      ("Content-Disposition", 'attachment; filename="gateway-ca.crt"')])
            return [open(ca, "rb").read()]
        parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
        if method == "GET" and len(parts) == 5 and parts[:2] == ["api", "models"] and parts[4] == "zip":
            info = model_version(parts[2], parts[3])
            if info["runtime"] == "vllm":
                raise Fail(400, "chat models are too big for the browser: download them to your home folder")
            files = artifact_files(info["artifacts"])         # errors here still become a normal error reply
            fname = re.sub(r"[^A-Za-z0-9._-]+", "_", parts[2]) + f"-v{int(parts[3])}.zip"
            start_response("200 OK", [("Content-Type", "application/zip"),
                                      ("Content-Disposition", f'attachment; filename="{fname}"')])
            return zip_stream(info["artifacts"], files)
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


if __name__ == "__main__" and sys.argv[1:2] == ["--fetch"]:
    fetch(*sys.argv[2:5])

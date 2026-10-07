#!/usr/bin/env python3
"""Render one Model Hub endpoint (Secret + Pod + Service) for `kubectl apply -f -`, as the user.

Two runtimes:
  mlflow  classic ML / DL registered in MLflow. An initContainer downloads `models:/<name>/<version>` with the
          user's MLflow token (Secret mlflow-creds), then `mlflow models serve` answers /invocations.
  vllm    LLM folder on disk (MODELS_ROOT or ~/models, read-only PVCs). OpenAI API, needs an API key.

Every pod runs as the user (the UID policy insists), goes through slurm-bridge (a Slurm job with a time limit),
and asks for at most one GPU of the given type.

A bare Pod, not a Deployment, on purpose (slurm-bridge 1.2.2, see AI-Stack version-1 build-log 2026-10-01):
  - slurm-bridge reads the slurmjob.* annotations from the pod's TOP owner. Under a Deployment that is the
    Deployment's own metadata, so pod-template annotations (time limit, exclusive) were silently ignored.
  - when the Slurm job ends, slurm-bridge deletes the pod; a Deployment would make a new pod = a new job, forever.
The Service stays after the pod is gone: the UI shows the endpoint as stopped, and a redeploy reuses it.

Usage:  python3 render.py <mlflow|vllm> key=value ...     (keys: see REQUIRED / defaults in endpoint())
        python3 render.py --test
"""
import json
import re
import secrets
import sys
from datetime import datetime, timedelta, timezone

NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")      # k8s name, short enough for "-key" suffixes


def endpoint(runtime, p):
    """p: dict of strings. Returns a k8s List (dict)."""
    need = {"name", "user", "uid", "gid", "image", "partition", "hours"}
    need |= {"model_uri", "mlflow_uri"} if runtime == "mlflow" else {"model_path"}
    missing = need - p.keys()
    if missing:
        raise ValueError(f"missing: {', '.join(sorted(missing))}")
    if not NAME.match(p["name"]):
        raise ValueError(f"bad endpoint name {p['name']!r}: lowercase letters, digits, '-', max 42")
    uid, gid, hours = int(p["uid"]), int(p["gid"]), int(p["hours"])
    gpus = int(p.get("gpus", "1" if runtime == "vllm" else "0"))
    if gpus not in (0, 1):
        raise ValueError("gpus must be 0 or 1")
    if gpus and not p.get("gpu_type"):
        raise ValueError("gpus=1 needs gpu_type (Slurm GPU type, e.g. a30)")
    ns, name = f"u-{p['user']}", p["name"]
    cpu, mem = p.get("cpu", "4" if gpus else "2"), p.get("memory", "32Gi" if gpus else "4Gi")
    expires = (datetime.now(timezone.utc) + timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    labels = {"app": name, "model-hub/runtime": runtime}
    limits = {"cpu": cpu, "memory": mem, **({"nvidia.com/gpu": "1"} if gpus else {})}
    # No gres annotation: slurm-bridge derives gres/gpu=1 from the nvidia.com/gpu limit (GPU types: parked issue)
    annotations = {
        "slurmjob.slinky.slurm.net/partition": p["partition"],
        "slurmjob.slinky.slurm.net/timelimit": str(hours * 60),
        "slurmjob.slinky.slurm.net/job-name": f"mh-{p['user']}-{name}",
        "slurmjob.slinky.slurm.net/exclusive": "false",      # default is the whole node, even for a 2-CPU endpoint
    }
    info = {"model-hub/expires": expires, "model-hub/model": p.get("model_uri") or p["model_path"]}
    ctr_sec = {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}
    # The pod runs as the user's UID, which has no /etc/passwd entry in the image. Python's getpass.getuser()
    # (torch inductor, used to load MLflow's pt2 models; vLLM too) reads USER/LOGNAME before trying passwd.
    env = [{"name": "HOME", "value": "/tmp"}, {"name": "HF_HUB_OFFLINE", "value": "1"},
           {"name": "USER", "value": p["user"]}, {"name": "LOGNAME", "value": p["user"]},
           {"name": "TORCHINDUCTOR_CACHE_DIR", "value": "/tmp/torchinductor"}]
    mounts = [{"name": "tmp", "mountPath": "/tmp"}]
    volumes = [{"name": "tmp", "emptyDir": {}}]
    objects, init = [], []

    if runtime == "mlflow":
        # the token comes from the user's ~/.mlflow/credentials (the backend makes this Secret, never logged)
        creds = [{"name": f"MLFLOW_TRACKING_{k.upper()}",
                  "valueFrom": {"secretKeyRef": {"name": "mlflow-creds", "key": k}}} for k in ("username", "password")]
        mounts.append({"name": "model", "mountPath": "/model"})
        volumes.append({"name": "model", "emptyDir": {}})
        init.append({
            "name": "download", "image": p["image"], "securityContext": ctr_sec,
            "command": ["mlflow", "artifacts", "download", "--artifact-uri", p["model_uri"], "--dst-path", "/model"],
            "env": env + creds + [{"name": "MLFLOW_TRACKING_URI", "value": p["mlflow_uri"]}],
            "volumeMounts": mounts, "resources": {"limits": {"cpu": "1", "memory": "2Gi"}},
        })
        args, probe = ["-m", "/model"], "/ping"
    else:
        key = p.get("api_key") or secrets.token_hex(24)
        objects.append({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                        "metadata": {"name": f"{name}-key", "namespace": ns, "labels": labels},
                        "stringData": {"api-key": key}})
        env.append({"name": "VLLM_API_KEY", "valueFrom": {"secretKeyRef": {"name": f"{name}-key", "key": "api-key"}}})
        mounts += [{"name": "models", "mountPath": "/models", "readOnly": True},
                   {"name": "my-models", "mountPath": "/my-models", "readOnly": True},
                   {"name": "shm", "mountPath": "/dev/shm"}]
        volumes += [{"name": "models", "persistentVolumeClaim": {"claimName": "models-ro", "readOnly": True}},
                    {"name": "my-models", "persistentVolumeClaim": {"claimName": "my-models", "readOnly": True}},
                    {"name": "shm", "emptyDir": {"medium": "Memory", "sizeLimit": "8Gi"}}]
        args = ["--model", p.get("base_path") or p["model_path"], "--served-model-name", name,
                "--port", "8080", "--max-model-len", p.get("max_model_len", "8192")]
        if p.get("base_path"):                                         # LoRA: base model + the user's adapter
            args += ["--enable-lora", "--lora-modules", f"{name}-lora={p['model_path']}"]
        probe = "/health"

    objects.append({
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": ns, "labels": labels, "annotations": {**annotations, **info}},
        "spec": {
            "tolerations": [{"key": "slinky.slurm.net/managed-node", "operator": "Exists", "effect": "NoExecute"}],
            "securityContext": {"runAsUser": uid, "runAsGroup": gid, "runAsNonRoot": True,
                                "seccompProfile": {"type": "RuntimeDefault"}},
            "initContainers": init,
            "containers": [{
                "name": "serve", "image": p["image"], "args": args, "env": env,
                "securityContext": ctr_sec, "ports": [{"containerPort": 8080, "name": "http"}],
                "resources": {"requests": limits, "limits": limits}, "volumeMounts": mounts,
                "startupProbe": {"httpGet": {"path": probe, "port": 8080}, "periodSeconds": 10, "failureThreshold": 90},
                "readinessProbe": {"httpGet": {"path": probe, "port": 8080}, "periodSeconds": 10},
            }],
            "volumes": volumes,
        },
    })
    objects.append({"apiVersion": "v1", "kind": "Service",
                    "metadata": {"name": name, "namespace": ns, "labels": labels, "annotations": info},
                    "spec": {"selector": {"app": name}, "ports": [{"name": "http", "port": 8080, "targetPort": 8080}]}})
    return {"apiVersion": "v1", "kind": "List", "items": objects}


def test():
    base = {"name": "churn", "user": "alice", "uid": "1001", "gid": "1001", "image": "r/mlflow-serve-ml:1",
            "partition": "slurm-bridge", "hours": "24", "model_uri": "models:/churn/1", "mlflow_uri": "http://m"}
    m = endpoint("mlflow", base)["items"]
    dep = m[0]
    assert [o["kind"] for o in m] == ["Pod", "Service"]
    assert dep["spec"]["securityContext"]["runAsUser"] == 1001
    assert "nvidia.com/gpu" not in dep["spec"]["containers"][0]["resources"]["limits"]      # CPU by default
    assert "slurmjob.slinky.slurm.net/gres" not in dep["metadata"]["annotations"]
    # on the Pod's own metadata: slurm-bridge reads the top owner's annotations, and a bare pod is its own owner
    assert dep["metadata"]["annotations"]["slurmjob.slinky.slurm.net/timelimit"] == "1440"
    assert dep["metadata"]["annotations"]["slurmjob.slinky.slurm.net/exclusive"] == "false"
    assert "ownerReferences" not in dep["metadata"] and m[1]["metadata"]["annotations"]["model-hub/expires"]
    assert dep["spec"]["initContainers"][0]["command"][:3] == ["mlflow", "artifacts", "download"]
    env = {e["name"]: e.get("value") for e in dep["spec"]["containers"][0]["env"]}
    assert env["USER"] == env["LOGNAME"] == "alice"          # getpass.getuser() works without a passwd entry
    v = endpoint("vllm", {**base, "name": "qwen", "image": "r/vllm:1", "model_path": "/models/base/q", "gpu_type": "a30"})["items"]
    assert [o["kind"] for o in v] == ["Secret", "Pod", "Service"]
    vd = v[1]
    assert vd["spec"]["containers"][0]["resources"]["limits"]["nvidia.com/gpu"] == "1"
    assert "--enable-lora" not in vd["spec"]["containers"][0]["args"]
    lora = endpoint("vllm", {**base, "name": "q2", "image": "i", "model_path": "/my-models/x/v1",
                             "base_path": "/models/base/q", "gpu_type": "a30"})["items"][1]
    assert "--enable-lora" in lora["spec"]["containers"][0]["args"]
    for bad in ({"name": "Bad_Name"}, {"gpus": "2"}, {"gpus": "1", "gpu_type": ""}):
        try:
            endpoint("mlflow", {**base, **bad}); raise AssertionError(f"accepted {bad}")
        except ValueError:
            pass
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test(); sys.exit()
    if len(sys.argv) < 2 or sys.argv[1] not in ("mlflow", "vllm"):
        sys.exit(__doc__)
    params = dict(a.split("=", 1) for a in sys.argv[2:])
    print(json.dumps(endpoint(sys.argv[1], params), indent=1))

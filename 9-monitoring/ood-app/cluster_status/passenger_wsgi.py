"""Cluster monitor backend: an OOD Passenger app that runs as the logged-in user. Read-only.

It asks Prometheus (PROM_URL, ../1-install.sh) and turns its series into one JSON the page draws:
  GET api/status          every node (Slurm state, CPU/RAM/GPU reserved and in use, each GPU, users), jobs, alerts
  GET api/history/<node>  that node's CPU and GPU use over the last hour (only for the node a user opens)
Fixed queries only: the one value from the URL (a node name) is checked before it goes into a query.
Nothing here can change anything. Every user sees the same data, which is what squeue/sinfo already show them.
site.json (written by 2-install-ood-app.sh): {"prom_url": PROM_URL, "login_partition": VIEWER_PARTITION}.
"""
import json
import mimetypes
import os
import pwd
import re
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PUBLIC = os.path.join(HERE, "public")
SITE = json.load(open(os.path.join(HERE, "site.json")))
NODE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
# one request for every series the page needs (all named in ../rules.yml or written by the collectors)
# (one selector, not "a or up": `or` drops up wherever a recording rule has the same labels)
SERIES = ('{__name__=~"slurm_node_.*|slurm_jobs|gpu_(utilization_ratio|memory_used_bytes|memory_total_bytes|'
          'temperature_celsius|power_watts)|node:(cpu|mem)_used:ratio|up"}')


class Fail(Exception):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status


def prom(path, **params):
    url = f"{SITE['prom_url']}/api/v1/{path}?{urllib.parse.urlencode(params)}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)["data"]
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        raise Fail(502, f"monitoring doesn't answer ({SITE['prom_url']}): {getattr(e, 'reason', e)}")


def num(v):
    return None if v in ("NaN", "+Inf", "-Inf") else float(v)


def status():
    by_name = {}
    for r in prom("query", query=SERIES)["result"]:
        m = r["metric"]
        if m["__name__"] == "up" and m.get("job") != "node":
            continue
        by_name.setdefault(m["__name__"], []).append((m, num(r["value"][1])))
    infos = by_name.get("slurm_node_info", [])
    if not infos:
        raise Fail(502, "monitoring has no Slurm data: is slurm-metrics running on master? (journalctl -u slurm-metrics)")

    nodes = {}
    for m, _ in infos:
        parts = [p for p in m.get("partitions", "").split(",") if p]
        t = m.get("gpu_type", "").upper()
        nodes[m["node"]] = {
            "node": m["node"], "slurm": m.get("slurm_node", m["node"]), "state": m.get("state", ""),
            "reason": m.get("reason", ""), "partitions": parts,
            "type": "Login" if SITE.get("login_partition") in parts else t or "CPU",
            "gpu_type": t, "up": 0, "users": {}, "gpus": [],
        }
    fields = {"slurm_node_cpus": "cpus", "slurm_node_cpus_alloc": "cpus_alloc", "slurm_node_memory_bytes": "mem",
              "slurm_node_memory_alloc_bytes": "mem_alloc", "slurm_node_gpus": "gpu_count",
              "slurm_node_gpus_alloc": "gpus_alloc", "slurm_node_available": "available",
              "node:cpu_used:ratio": "cpu_used", "node:mem_used:ratio": "mem_used", "up": "up"}
    for name, key in fields.items():
        for m, v in by_name.get(name, []):
            if m.get("node") in nodes:
                nodes[m["node"]][key] = v

    # each GPU nvidia-smi reports (only the types Slurm schedules; gpu-metrics.sh filters)
    gpu = {}
    for name in ("gpu_utilization_ratio", "gpu_memory_used_bytes", "gpu_memory_total_bytes", "gpu_temperature_celsius", "gpu_power_watts"):
        for m, v in by_name.get(name, []):
            g = gpu.setdefault((m.get("node"), m.get("gpu")), {"gpu": m.get("gpu"), "name": m.get("name", "").replace("NVIDIA ", "")})
            g[{"gpu_utilization_ratio": "util", "gpu_memory_used_bytes": "mem_used", "gpu_memory_total_bytes": "mem_total",
               "gpu_temperature_celsius": "temp", "gpu_power_watts": "power"}[name]] = v
    reserved = {}
    for m, _ in by_name.get("slurm_node_gpu_reserved", []):
        reserved.setdefault(m.get("node"), set()).add(int(m["gpu"]))
    for n in nodes.values():
        mine = sorted((g for (node, _), g in gpu.items() if node == n["node"]), key=lambda g: int(g["gpu"]))
        count = int(n.get("gpu_count") or 0)
        # node (or its collector) silent, or a card fell off the bus: Slurm still knows how many GPUs there should be
        mine += [{"gpu": "?" if mine else str(i), "name": n["gpu_type"] or "GPU", "util": None}
                 for i in range(max(0, count - len(mine)))]
        # Slurm numbers a node's GPUs 0, 1, ... in gres.conf order; nvidia-smi numbers every card on the bus.
        # The n-th GPU Slurm knows = the n-th GPU we kept, in nvidia-smi order (a display card in between is skipped).
        # ponytail: assumes gres.conf lists the GPUs in bus order (true for AutoDetect=nvml and /dev/nvidia0..N)
        for pos, g in enumerate(mine):
            g["reserved"] = pos in reserved.get(n["node"], set())
        if not reserved.get(n["node"]) and n.get("gpus_alloc"):   # an older collector without slurm_node_gpu_reserved
            for g in mine[:int(n["gpus_alloc"])]:
                g["reserved"] = True
        n["gpus"] = mine
        n.pop("gpu_count", None)
        if mine and n["type"] == "CPU":   # collector from before gpu_type: name the type after the card
            n["type"] = n["gpu_type"] = next((g["name"] for g in mine if g["name"] not in ("", "GPU")), "GPU")

    for m, v in by_name.get("slurm_node_jobs", []):
        if m.get("node") in nodes:
            nodes[m["node"]]["users"][m.get("user", "?")] = int(v or 0)
    jobs = {"running": 0, "pending": 0}
    for m, v in by_name.get("slurm_jobs", []):
        if m.get("state") in jobs:
            jobs[m["state"]] += int(v or 0)
    alerts = [{"name": a["labels"].get("alertname", ""), "state": a.get("state", ""), "since": a.get("activeAt", ""),
               "summary": a.get("annotations", {}).get("summary", a["labels"].get("alertname", ""))}
              for a in prom("alerts").get("alerts", [])]
    stale = [m.get("__name__") for name in ("slurm_collector_ok", "gpu_collector_ok") for m, v in by_name.get(name, []) if v == 0]
    return {"user": pwd.getpwuid(os.getuid()).pw_name, "taken": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "nodes": sorted(nodes.values(), key=lambda n: n["node"]),
            "jobs": jobs, "alerts": alerts, "collectors_failing": stale}


def history(node):
    if not NODE.match(node):
        raise Fail(400, "bad node name")
    end = time.time()
    out = {}
    for key, q in (("cpu", f'1 - avg(rate(node_cpu_seconds_total{{mode="idle",node="{node}"}}[2m]))'),
                   ("gpu", f'avg(gpu_utilization_ratio{{node="{node}"}})')):
        res = prom("query_range", query=q, start=end - 3600, end=end, step=60)["result"]
        if res:
            out[key] = [None if v in ("NaN",) else round(float(v), 3) for _, v in res[0]["values"]]
    return out


def route(method, path):
    a = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
    if a[:1] != ["api"]:
        return None
    if method != "GET":
        raise Fail(405, "read-only")
    if a == ["api", "status"]:
        return status()
    if len(a) == 3 and a[1] == "history":
        return history(a[2])
    raise Fail(404, f"no route {path}")


def static(path, script_name):
    # like Model Hub: index.html outside public/, a <base> so relative links work, ?v= so a new install loads at once
    rel = os.path.normpath(path.strip("/"))
    full = os.path.join(PUBLIC, rel)
    if rel and not rel.startswith("..") and os.path.isfile(full):
        return open(full, "rb").read(), mimetypes.guess_type(full)[0] or "application/octet-stream"
    base = (script_name.rstrip("/") + "/").encode()
    data = open(os.path.join(HERE, "index.html"), "rb").read()
    for f in (b"app.js", b"style.css", b"cluster.css"):
        v = str(int(os.path.getmtime(os.path.join(PUBLIC, f.decode())))).encode()
        data = data.replace(b'"' + f + b'"', b'"' + f + b"?v=" + v + b'"')
    return data.replace(b"<head>", b'<head>\n  <base href="' + base + b'">', 1), "text/html"


def application(environ, start_response):
    method, path = environ["REQUEST_METHOD"], environ.get("PATH_INFO", "") or "/"
    try:
        result = route(method, path)
        if result is None:
            data, ctype = static(path, environ.get("SCRIPT_NAME", ""))
            start_response("200 OK", [("Content-Type", ctype), ("Cache-Control", "no-cache")])
            return [data]
        status_line, payload = "200 OK", result
    except Fail as e:
        status_line, payload = f"{e.status} Error", {"error": str(e)}
    except (KeyError, ValueError, TypeError) as e:
        status_line, payload = "500 Internal Server Error", {"error": f"unexpected data from monitoring: {e!r}"}
    start_response(status_line, [("Content-Type", "application/json"), ("Cache-Control", "no-store")])
    return [json.dumps(payload).encode()]

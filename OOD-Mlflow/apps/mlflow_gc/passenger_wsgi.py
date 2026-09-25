import glob, os, pwd, re, subprocess, urllib.request, html, json

MLFLOW = "/home/apps/mlflow-venv/bin/mlflow"
HOME = pwd.getpwuid(os.getuid()).pw_dir
SESSIONS = HOME + "/ondemand/data/sys/dashboard/batch_connect/sys/mlflow/output/*/connection.yml"
BACK = "/pun/sys/dashboard/batch_connect/sessions"

def running_uri():
    # newest MLflow session of this user that still answers
    for f in sorted(glob.glob(SESSIONS), key=os.path.getmtime, reverse=True):
        txt = open(f).read()
        host = re.search(r"^host:\s*(\S+)", txt, re.M)
        port = re.search(r"^port:\s*(\d+)", txt, re.M)
        if not (host and port):
            continue
        uri = f"http://{host[1]}:{port[1]}/node/{host[1]}/{port[1]}"
        try:
            urllib.request.urlopen(uri + "/api/2.0/mlflow/experiments/search?max_results=1", timeout=3)
            return uri
        except Exception:
            pass
    return None

def api(uri, path, body):
    req = urllib.request.Request(uri + "/api/2.0/mlflow/" + path, json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))

def trash(uri):
    # ponytail: single page (1000 experiments / 50000 runs), add page_token loop if anyone hits that
    exps = api(uri, "experiments/search", {"view_type": "ALL", "max_results": 1000}).get("experiments", [])
    names = {e["experiment_id"]: e["name"] for e in exps}
    dead_exps = [e["name"] for e in exps if e.get("lifecycle_stage") == "deleted"]
    runs = api(uri, "runs/search", {"experiment_ids": list(names), "run_view_type": "DELETED_ONLY",
                                    "max_results": 50000}).get("runs", []) if names else []
    dead_runs = [(r["info"].get("run_name") or r["info"]["run_id"], names.get(r["info"]["experiment_id"], "?"))
                 for r in runs]
    return dead_exps, dead_runs

def page(start_response, status, title, ok, body_html):
    color = "#2e7d32" if ok else "#c62828"
    start_response(status, [("Content-Type", "text/html; charset=utf-8")])
    return [f"""<!doctype html><html><head><meta charset="utf-8"><title>MLflow cleanup</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{{margin:0;background:#f4f5f7;font:15px/1.5 system-ui,sans-serif;color:#222}}
.card{{max-width:640px;margin:48px auto;background:#fff;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.12);border-top:4px solid {color}}}
.hd{{padding:16px 20px;border-bottom:1px solid #eee;font-size:18px;font-weight:600;color:{color}}}
.bd{{padding:16px 20px}} h4{{margin:12px 0 6px;font-size:14px;color:#555}}
ul{{margin:0;padding-left:20px}} li small{{color:#777}}
pre{{background:#f6f6f6;padding:10px;border-radius:4px;overflow:auto;font-size:12px}}
.ft{{padding:12px 20px;border-top:1px solid #eee;text-align:right}}
a.btn{{display:inline-block;background:#0d6efd;color:#fff;text-decoration:none;padding:7px 16px;border-radius:5px}}
</style></head><body><div class="card">
<div class="hd">{html.escape(title)}</div><div class="bd">{body_html}</div>
<div class="ft"><a class="btn" href="{BACK}">Back to My Interactive Sessions</a></div>
</div></body></html>""".encode()]

def listing(label, items):
    if not items:
        return ""
    return f"<h4>{label} ({len(items)})</h4><ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>"

def application(environ, start_response):
    if environ["REQUEST_METHOD"] != "POST" or environ.get("HTTP_SEC_FETCH_SITE", "same-origin") != "same-origin":
        return page(start_response, "400 Bad Request", "Not allowed", False,
                    "<p>Use the Clean button on the MLflow session card.</p>")
    uri = running_uri()
    if not uri:
        return page(start_response, "409 Conflict", "No running MLflow session", False,
                    "<p>Launch MLflow first, then press Clean again.</p>")
    try:
        dead_exps, dead_runs = trash(uri)
    except Exception as e:
        return page(start_response, "502 Bad Gateway", "Could not read the MLflow trash", False,
                    f"<pre>{html.escape(str(e))}</pre>")
    if not dead_exps and not dead_runs:
        return page(start_response, "200 OK", "Trash is already empty", True,
                    "<p>There were no deleted runs or experiments to remove.</p>")
    r = subprocess.run([MLFLOW, "gc",
                        "--backend-store-uri", f"sqlite:///{HOME}/mlflow/mlflow.db",
                        "--artifacts-destination", f"{HOME}/mlflow/artifacts",
                        "--tracking-uri", uri],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        return page(start_response, "500 Internal Server Error", "Cleanup failed", False,
                    f"<p>Nothing was guaranteed removed. Output:</p><pre>{html.escape(r.stdout + r.stderr)}</pre>")
    body = "<p>These were removed for good. Their names can be reused now.</p>"
    body += listing("Experiments", [html.escape(n) for n in dead_exps])
    body += listing("Runs", [f"{html.escape(n)} <small>in {html.escape(e)}</small>" for n, e in dead_runs])
    return page(start_response, "200 OK", "Cleanup done", True, body)

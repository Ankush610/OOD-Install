import html, json, os, pwd, urllib.request

# site.json is written next to this file by ../../4-install-ood-app.sh, from ../../../site.conf
SITE = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "site.json")))
HOST, PORT, PREFIX = SITE["host"], SITE["port"], SITE["prefix"]
URI = f"http://{HOST}:{PORT}{PREFIX}"
CREDS = pwd.getpwuid(os.getuid()).pw_dir + "/.mlflow/credentials"

def up():
    try:
        return urllib.request.urlopen(URI + "/health", timeout=3).status == 200
    except Exception:
        return False

def row(ok, text):
    color = "#2e7d32" if ok else "#c62828"
    return f'<p><span style="color:{color};font-weight:700">{"&#10003;" if ok else "&#10007;"}</span> {text}</p>'

def application(environ, start_response):
    server_ok, creds_ok = up(), os.path.isfile(CREDS)
    export = html.escape(f"export MLFLOW_TRACKING_URI={URI}")
    body = row(server_ok, "MLflow server is running" if server_ok else
               "MLflow server is not answering. Tell the admin (kubectl -n mlflow get pod).")
    body += row(creds_ok, "Your job login is set up in <code>~/.mlflow/credentials</code>" if creds_ok else
                "No <code>~/.mlflow/credentials</code>. Ask the admin to run 3-mlflow/3-sync-tokens.sh.")
    body += f"""
<h4>Tracking URI (use inside cluster jobs)</h4>
<div style="display:flex;gap:6px">
  <input readonly value="{export}" style="flex:1;font:13px monospace;padding:6px;border:1px solid #ccc;border-radius:4px">
  <button onclick="navigator.clipboard.writeText(this.previousElementSibling.value);this.textContent='Copied'"
          style="padding:6px 12px;border:1px solid #888;border-radius:4px;background:#fff;cursor:pointer">Copy</button>
</div>
<p><small>Your jobs log in with a token from <code>~/.mlflow/credentials</code>, so no password goes into your
scripts. In the MLflow web UI, use your normal cluster (SSH) password. The URI is fixed, it never changes.</small></p>
<h4>MLflow web UI</h4>
<p><small><b>Open MLflow</b> goes straight to MLflow on port {PORT}, not through OnDemand
(OnDemand drops the password, so MLflow would always refuse). Log in with your cluster (SSH) username and password.
From a laptop, your SSH tunnel needs <code>-L {PORT}:{HOST}:{PORT}</code> as well as <code>-L 443:localhost:443</code>.</small></p>"""
    start_response("200 OK", [("Content-Type", "text/html; charset=utf-8")])
    return [f"""<!doctype html><html><head><meta charset="utf-8"><title>MLflow (shared)</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{{margin:0;background:#f4f5f7;font:15px/1.5 system-ui,sans-serif;color:#222}}
.card{{max-width:680px;margin:48px auto;background:#fff;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.12);border-top:4px solid #0d6efd}}
.hd{{padding:16px 20px;border-bottom:1px solid #eee;font-size:18px;font-weight:600}}
.bd{{padding:16px 20px}} h4{{margin:16px 0 6px;font-size:14px;color:#555}} small{{color:#666}}
.ft{{padding:12px 20px;border-top:1px solid #eee;display:flex;justify-content:space-between}}
a.btn{{display:inline-block;color:#fff;text-decoration:none;padding:7px 16px;border-radius:5px}}
</style></head><body><div class="card">
<div class="hd">MLflow (shared)</div><div class="bd">{body}</div>
<div class="ft"><a class="btn" style="background:#6c757d" href="/pun/sys/dashboard">Dashboard</a>
<a class="btn" style="background:#0d6efd" href="#" target="_blank"
   onclick="this.href='http://'+location.hostname+':{PORT}{PREFIX}/'">Open MLflow</a></div>
</div></body></html>""".encode()]

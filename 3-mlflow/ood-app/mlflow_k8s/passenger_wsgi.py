import html, json, os, pwd, urllib.request

# site.json is written next to this file by ../../4-install-ood-app.sh, from ../../../site.conf
SITE = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "site.json")))
HOST, PORT, PREFIX = SITE["host"], SITE["port"], SITE["prefix"]
SSO = SITE.get("sso", False)     # Keycloak: the UI opens through OOD (same login), not on the port
URI = f"http://{HOST}:{PORT}{PREFIX}"
CREDS = pwd.getpwuid(os.getuid()).pw_dir + "/.mlflow/credentials"

def up():
    try:
        return urllib.request.urlopen(URI + "/health", timeout=3).status == 200
    except Exception:
        return False

USER = pwd.getpwuid(os.getuid()).pw_name
HUB = "/pun/sys/model_hub/"      # same look as Model Hub: reuse its Bootstrap, icons and style.css

def row(ok, title, hint):
    pill = ('<span class="status text-success-emphasis bg-success-subtle">OK</span>' if ok else
            '<span class="status text-danger-emphasis bg-danger-subtle">Problem</span>')
    return f"""<li class="list-group-item d-flex align-items-center gap-3 py-3">
  <div class="min-w-0 flex-grow-1"><div class="fw-medium">{title}</div><div class="small text-body-secondary">{hint}</div></div>{pill}</li>"""

def application(environ, start_response):
    server_ok, creds_ok = up(), os.path.isfile(CREDS)
    export = html.escape(f"export MLFLOW_TRACKING_URI={URI}")
    status = row(server_ok, "MLflow server", "Running" if server_ok else
                 "Not answering. Tell the admin (kubectl -n mlflow get pod).")
    status += row(creds_ok, "Job login", "Set up in <code>~/.mlflow/credentials</code>" if creds_ok else
                  "No <code>~/.mlflow/credentials</code>. Ask the admin to run 3-mlflow/3-sync-tokens.sh.")
    ui_note = ("Opens through OnDemand: you are already logged in." if SSO else
               f"Opens MLflow on port {PORT}, not through OnDemand (OnDemand drops the password, so MLflow would "
               f"always refuse). Log in with your cluster (SSH) username and password. If it doesn't open, your "
               f"network can't reach port {PORT} on {HOST}: ask the admin.")
    open_js = "location.origin+'" + PREFIX + "/'" if SSO else "'http://'+location.hostname+':" + str(PORT) + PREFIX + "/'"
    start_response("200 OK", [("Content-Type", "text/html; charset=utf-8")])
    return [f"""<!doctype html><html lang="en" data-bs-theme="light"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>MLflow</title>
<link rel="stylesheet" href="{HUB}vendor/bootstrap/bootstrap.min.css">
<link rel="stylesheet" href="{HUB}vendor/bootstrap-icons/bootstrap-icons.min.css">
<link rel="stylesheet" href="{HUB}style.css">
<script>try{{document.documentElement.dataset.bsTheme=localStorage.getItem('mh-theme')||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light')}}catch(e){{}}</script>
</head><body class="bg-body-tertiary">
<nav class="navbar bg-body border-bottom sticky-top py-2"><div class="container-xl">
  <span class="navbar-brand d-flex align-items-center gap-2 fw-semibold"><span class="brand-mark"><i class="bi bi-graph-up"></i></span>MLflow</span>
  <div class="d-flex align-items-center gap-2">
    <span class="d-flex align-items-center gap-2 small"><span class="avatar" aria-hidden="true">{html.escape(USER[0])}</span><span class="text-body-secondary">{html.escape(USER)}</span></span>
    <button class="btn btn-sm btn-icon" id="theme" type="button" aria-label="Toggle dark mode"><i class="bi bi-moon-stars"></i></button>
  </div></div></nav>
<main class="container-xl py-4" style="max-width:820px">
  <div class="d-flex flex-wrap align-items-start justify-content-between gap-3 mb-4">
    <div><h1 class="h3 mb-1">MLflow</h1><p class="text-body-secondary mb-0">Track experiments and register models. You see only your own.</p></div>
    <div class="d-flex gap-2">
      <a class="btn btn-outline-secondary" href="{HUB}"><i class="bi bi-boxes me-1"></i>Model Hub</a>
      <a class="btn btn-primary" href="#" target="_blank" rel="noopener" onclick="this.href={open_js}"><i class="bi bi-box-arrow-up-right me-1"></i>Open MLflow</a>
    </div>
  </div>
  <div class="card mb-4"><div class="card-body pb-0"><div class="eyebrow">Status</div></div>
    <ul class="list-group list-group-flush">{status}</ul></div>
  <div class="card mb-4"><div class="card-body">
    <div class="eyebrow mb-3">Use it in your jobs</div>
    <ol class="steps">
      <li><div class="fw-medium mb-2">Set the tracking address in your job script</div>
        <div class="code-wrap"><pre class="code mb-0" id="uri">{export}</pre>
          <button class="btn btn-sm btn-outline-secondary btn-copy" type="button" onclick="navigator.clipboard.writeText(document.getElementById('uri').textContent);this.innerHTML='<i class=\\'bi bi-check2\\'></i> Copied'"><i class="bi bi-clipboard"></i> Copy</button></div>
        <div class="small text-body-secondary mt-2">It never changes, so you can keep it in your scripts.</div></li>
      <li><div class="fw-medium">Log runs as usual</div>
        <div class="small text-body-secondary">Your jobs log in with a token from <code>~/.mlflow/credentials</code>, so no password goes into your scripts.</div></li>
    </ol></div></div>
  <div class="card"><div class="card-body">
    <div class="eyebrow mb-2">Web UI</div>
    <p class="small text-body-secondary mb-0">{ui_note}</p></div></div>
</main>
<script>
const t=document.getElementById('theme'),ic=()=>t.innerHTML='<i class="bi bi-'+(document.documentElement.dataset.bsTheme==='dark'?'sun':'moon-stars')+'"></i>';ic();
t.onclick=()=>{{const v=document.documentElement.dataset.bsTheme==='dark'?'light':'dark';document.documentElement.dataset.bsTheme=v;ic();try{{localStorage.setItem('mh-theme',v)}}catch(e){{}}}};
</script></body></html>""".encode()]

"""VS Code / Jupyter page: an OOD Passenger app that runs AS the logged-in user (stdlib only, system python3).
One page for both: site.json's "app" picks the texts below; each app brings its own job.sh.

Launch = `sbatch job.sh` as the user, on the partition picked (same Slurm options as the old batch_connect form).
job.sh writes ~/.<app>-sessions/<jobid>.json (host, port, password; mode 600) once the server answers;
Connect posts that password to the server's login through OOD's proxy. Stop = scancel.
Same look as Model Hub (its Bootstrap + style.css). site.json and job.sh come from ../../3-install-ood-app.sh
(VS Code) or ../../../7-jupyter/2-install-ood-app.sh (Jupyter).
"""
import html
import json
import os
import pwd
import re
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = json.load(open(os.path.join(HERE, "site.json")))
# PUN processes get no SLURM_CONF (OOD hands it only to its own adapter, via clusters.d), and squeue then
# looks for the config in DNS and fails. Point it at the file.
os.environ.setdefault("SLURM_CONF", SITE["slurm_conf"])
ME = pwd.getpwuid(os.getuid())
USER, HOME = ME.pw_name, ME.pw_dir
# connect: how Connect sends the password: (method, url, field). code-server wants to sit at / (/rnode strips the
# prefix) and takes a POSTed password. Jupyter knows its /node path (base_url in its job.sh); its login form needs an
# _xsrf value we don't have, so it gets the token the standard way (?token=, which sets its login cookie).
# note: the help line under the sessions.
APPS = {
    "vscode": dict(title="VS Code", icon="code-slash", light="Editor only",
                   connect=("post", "/rnode/{host}/{port}/login", "password"),
                   tagline="VS Code in your browser, running as you, on your own files.",
                   note="Extensions and settings you add are kept in your home folder for next time. Heavy or long "
                        "work belongs in <code>sbatch</code> from VS Code's terminal: it frees its CPUs and GPUs when "
                        "done. An editor with no browser attached for {idle} minutes stops by itself."),
    "jupyter": dict(title="Jupyter", icon="journal-code", light="Notebook only",
                    connect=("get", "/node/{host}/{port}/lab", "token"),
                    tagline="JupyterLab in your browser, running as you, on your own files.",
                    note="Pick a kernel: the <b>(container)</b> ones are the training containers (PyTorch, "
                         "classic ML), with the GPUs of a GPU session. Your own environment: <code>pip install "
                         "ipykernel</code> in it, then <code>python -m ipykernel install --user --name myenv</code>. "
                         "Long training belongs in <code>sbatch</code>: it frees its GPUs when done. A notebook idle "
                         "for {idle} minutes with no browser attached stops; a cell still running keeps it going."),
}
APP = APPS[SITE["app"]]
JOB = SITE["app"]                # Slurm job name: how the page finds its sessions
DIR = os.path.join(HOME, f".{JOB}-sessions")
HUB = "/pun/sys/model_hub/"      # same look as Model Hub: reuse its Bootstrap, icons and style.css
KEEP_DAYS = 7                    # logs of ended sessions in DIR


class Fail(Exception):
    pass


def slurm(cmd, *args):
    p = subprocess.run([os.path.join(SITE["slurm_bin"], cmd), *args], capture_output=True, text=True, timeout=30)
    if p.returncode:
        raise Fail(f"{cmd}: {(p.stderr or p.stdout).strip()}")
    return p.stdout


def choices():
    out = [("viewer", f"{APP['light']} (login node)", f"1 CPU (shared), {SITE['mem']} memory, no GPU. Starts at once.")]
    for n in range(1, SITE["gpu_max"] + 1):
        out.append((f"gpu{n}", f"GPU node: {n} x {SITE['gpu_type']}",
                    f"{n * SITE['cpus_per_gpu']} CPUs, {n * SITE['mem_per_gpu_mb'] // 1024} GB memory. "
                    "The GPUs stay yours until the session ends."))
    return out


def sessions():
    out = []
    for line in slurm("squeue", "-h", "-u", USER, "-n", JOB, "-o", "%i|%T|%P|%b|%L|%r").splitlines():
        jid, state, part, gres, left, reason = line.split("|")
        m = re.search(r"gpu(?::[^:]+)?:(\d+)", gres)
        where = f"GPU node: {m.group(1)} x {SITE['gpu_type']}" if m else APP["light"]
        f = os.path.join(DIR, jid + ".json")
        conn = json.load(open(f)) if state == "RUNNING" and os.path.isfile(f) else None
        out.append(dict(id=jid, state=state, where=where, left=left, reason=reason, conn=conn))
    return out


def prune():
    now = time.time()
    for name in os.listdir(DIR) if os.path.isdir(DIR) else []:
        f = os.path.join(DIR, name)
        if now - os.path.getmtime(f) > KEEP_DAYS * 86400:
            os.remove(f)


def launch(body):
    where, hours = body["where"], max(1, min(12, int(body["hours"])))
    m = re.fullmatch(r"gpu(\d+)", where)
    if where == "viewer":
        res = ["-p", SITE["viewer_partition"], "--cpus-per-task=1", f"--mem={SITE['mem']}"]
    elif m and 1 <= int(m.group(1)) <= SITE["gpu_max"]:
        n = int(m.group(1))
        res = ["-p", SITE["gpu_partition"], f"--gres=gpu:{n}", f"--cpus-per-task={n * SITE['cpus_per_gpu']}",
               f"--mem={n * SITE['mem_per_gpu_mb']}M"]
    else:
        raise Fail(f"unknown choice {where!r}")
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    jid = slurm("sbatch", "--parsable", "-J", JOB, f"--time={hours}:00:00", "--export=NONE", f"--chdir={HOME}",
                "-o", os.path.join(DIR, "%j.log"), *res, os.path.join(HERE, "job.sh")).strip()
    return {"id": jid}


def stop(body):
    jid = str(body["id"])
    if jid not in [s["id"] for s in sessions()]:
        raise Fail(f"no {APP['title']} session {jid}")
    slurm("scancel", jid)
    return {"stopped": jid}


def e(s):
    return html.escape(str(s))


def card(s):
    if s["conn"]:
        pill, hint = '<span class="status text-success-emphasis bg-success-subtle">Ready</span>', f"{e(s['left'])} left"
        c = s["conn"]
        method, url, field = APP["connect"]
        act = f"""<form action="{url.format(host=e(c['host']), port=int(c['port']))}" method="{method}" target="_blank" class="m-0">
  <input type="hidden" name="{field}" value="{e(c['password'])}">
  <button class="btn btn-sm btn-primary" type="submit"><i class="bi bi-box-arrow-up-right me-1"></i>Connect</button></form>"""
    elif s["state"] == "RUNNING":
        pill, hint, act = '<span class="status pulse text-info-emphasis bg-info-subtle">Starting</span>', f"Starting {APP['title']}…", ""
    elif s["state"] == "PENDING":
        why = "no free spot yet" if s["reason"] in ("Resources", "Priority") else s["reason"]
        pill, hint, act = ('<span class="status pulse text-warning-emphasis bg-warning-subtle">Waiting</span>',
                           f"In the queue: {e(why)}", "")
    else:
        pill, hint, act = f'<span class="status text-secondary-emphasis bg-secondary-subtle">{e(s["state"].title())}</span>', "", ""
    return f"""<li class="list-group-item d-flex flex-wrap align-items-center gap-3 py-3">
  <span class="kind-icon text-primary-emphasis bg-primary-subtle"><i class="bi bi-{APP['icon']}"></i></span>
  <div class="min-w-0 flex-grow-1"><div class="fw-medium">{e(s['where'])}</div>
    <div class="meta text-body-secondary"><span><i class="bi bi-hash"></i>{e(s['id'])}</span><span>{hint}</span></div></div>
  {pill}{act}
  <button class="btn btn-sm btn-outline-danger" type="button" onclick="post('stop',{{id:'{e(s['id'])}'}})"><i class="bi bi-stop-circle me-1"></i>Stop</button></li>"""


def page(base):
    try:
        prune()
        ss, err = sessions(), ""
    except (Fail, OSError) as x:
        ss, err = [], f'<div class="alert alert-danger">Could not ask Slurm for your sessions: {e(x)}</div>'
    opts = "".join(f'<option value="{v}" data-hint="{e(h)}">{e(label)}</option>' for v, label, h in choices())
    rows = "".join(card(s) for s in ss) or \
        '<li class="list-group-item py-4 text-center text-body-secondary">No sessions. Launch one above.</li>'
    busy = any(not s["conn"] for s in ss)
    return f"""<!doctype html><html lang="en" data-bs-theme="light"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{APP['title']}</title>
<link rel="stylesheet" href="{HUB}vendor/bootstrap/bootstrap.min.css">
<link rel="stylesheet" href="{HUB}vendor/bootstrap-icons/bootstrap-icons.min.css">
<link rel="stylesheet" href="{HUB}style.css">
<script>try{{document.documentElement.dataset.bsTheme=localStorage.getItem('mh-theme')||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light')}}catch(e){{}}</script>
</head><body class="bg-body-tertiary">
<nav class="navbar bg-body border-bottom sticky-top py-2"><div class="container-xl">
  <span class="navbar-brand d-flex align-items-center gap-2 fw-semibold"><span class="brand-mark"><i class="bi bi-{APP['icon']}"></i></span>{APP['title']}</span>
  <div class="d-flex align-items-center gap-2">
    <span class="d-flex align-items-center gap-2 small"><span class="avatar" aria-hidden="true">{e(USER[0])}</span><span class="text-body-secondary">{e(USER)}</span></span>
    <button class="btn btn-sm btn-icon" id="theme" type="button" aria-label="Toggle dark mode"><i class="bi bi-moon-stars"></i></button>
  </div></div></nav>
<main class="container-xl py-4" style="max-width:820px">
  <div class="d-flex flex-wrap align-items-start justify-content-between gap-3 mb-4">
    <div><h1 class="h3 mb-1">{APP['title']}</h1><p class="text-body-secondary mb-0">{APP['tagline']}</p></div>
    <a class="btn btn-outline-secondary" href="{HUB}"><i class="bi bi-boxes me-1"></i>Model Hub</a>
  </div>
  <div class="alert alert-danger d-none" id="err"></div>{err}
  <div class="card mb-4"><div class="card-body">
    <div class="eyebrow mb-3">New session</div>
    <div class="row g-3 align-items-end">
      <div class="col-md-7"><label class="form-label" for="where">Where to run</label>
        <select class="form-select" id="where">{opts}</select></div>
      <div class="col-6 col-md-2"><label class="form-label" for="hours">Hours</label>
        <input class="form-control" id="hours" type="number" min="1" max="12" value="4"></div>
      <div class="col-6 col-md-3"><button class="btn btn-primary w-100" id="launch" type="button"
        onclick="post('launch',{{where:where.value,hours:hours.value}},this)"><i class="bi bi-play-fill me-1"></i>Launch</button></div>
    </div>
    <div class="small text-body-secondary mt-2" id="hint"></div></div></div>
  <div class="card mb-4"><div class="card-body pb-0"><div class="eyebrow">Your sessions</div></div>
    <ul class="list-group list-group-flush">{rows}</ul></div>
  <div class="card"><div class="card-body small text-body-secondary">
    {APP['note'].format(idle=SITE['idle_seconds'] // 60)}</div></div>
</main>
<script>
const where=document.getElementById('where'),hours=document.getElementById('hours'),hint=document.getElementById('hint');
const showHint=()=>hint.textContent=where.selectedOptions[0].dataset.hint;where.onchange=showHint;showHint();
async function post(path,body,btn){{
  if(btn)btn.disabled=true;
  const r=await fetch('{base}api/'+path,{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify(body)}});
  if(r.ok)return location.reload();
  const err=document.getElementById('err');err.textContent=(await r.json().catch(()=>({{}}))).error||r.statusText;err.classList.remove('d-none');
  if(btn)btn.disabled=false;
}}
// ponytail: whole-page reload while a session waits or starts; switch to polling a JSON list if it gets in the way
{'setTimeout(()=>location.reload(),4000);' if busy else ''}
const t=document.getElementById('theme'),ic=()=>t.innerHTML='<i class="bi bi-'+(document.documentElement.dataset.bsTheme==='dark'?'sun':'moon-stars')+'"></i>';ic();
t.onclick=()=>{{const v=document.documentElement.dataset.bsTheme==='dark'?'light':'dark';document.documentElement.dataset.bsTheme=v;ic();try{{localStorage.setItem('mh-theme',v)}}catch(e){{}}}};
</script></body></html>"""


def application(environ, start_response):
    method, path = environ["REQUEST_METHOD"], (environ.get("PATH_INFO") or "/").rstrip("/")
    base = environ.get("SCRIPT_NAME", "").rstrip("/") + "/"
    if method == "GET":
        start_response("200 OK", [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store")])
        return [page(base).encode()]
    try:
        # JSON only: a plain cross-site form can't send it, so other sites can't launch or stop sessions
        if method != "POST" or not environ.get("CONTENT_TYPE", "").startswith("application/json"):
            raise Fail("POST JSON only")
        body = json.loads(environ["wsgi.input"].read(int(environ.get("CONTENT_LENGTH") or 0)) or b"{}")
        if path == "/api/launch":
            status, payload = "200 OK", launch(body)
        elif path == "/api/stop":
            status, payload = "200 OK", stop(body)
        else:
            status, payload = "404 Not Found", {"error": f"no route {path}"}
    except (Fail, KeyError, ValueError, OSError, subprocess.SubprocessError) as x:
        status, payload = "400 Bad Request", {"error": str(x)}
    start_response(status, [("Content-Type", "application/json"), ("Cache-Control", "no-store")])
    return [json.dumps(payload).encode()]

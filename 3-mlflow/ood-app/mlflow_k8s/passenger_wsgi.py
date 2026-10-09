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

def code(id, text):
    return (f'<div class="code-wrap mb-3"><pre class="code mb-0" id="{id}">{html.escape(text)}</pre><button class="btn btn-sm '
            f'btn-outline-secondary btn-copy" type="button" data-copy="{id}"><i class="bi bi-clipboard"></i> Copy</button></div>')

def faq_item(id, question, body):
    return f"""<div class="accordion-item" id="{id}"><h2 class="accordion-header">
  <button class="accordion-button collapsed fw-medium" type="button" data-bs-toggle="collapse" data-bs-target="#{id}-a">{question}</button></h2>
  <div id="{id}-a" class="accordion-collapse collapse" data-bs-parent="#faq"><div class="accordion-body small">{body}</div></div></div>"""

def faq():
    u = html.escape(USER)
    tree = f"""/home/{USER}/
├── projects/
│   └── my-project/      your code and job scripts
│       ├── data/        datasets
│       └── output/      checkpoints and logs
├── models/
│   └── my-llm/
│       └── v1/          a finished chat model, ready for Model Hub
└── model-downloads/     models you download from Model Hub"""
    save = (f'model = model.merge_and_unload()   # only if you used LoRA\n'
            f'model.save_pretrained("/home/{USER}/models/my-llm/v1")\n'
            f'tokenizer.save_pretrained("/home/{USER}/models/my-llm/v1")')
    return "".join([
        faq_item("faq-layout", "Where should I keep my files?",
            f"""<p>This layout always works:</p><pre class="code mb-3" style="white-space:pre;overflow-x:auto">{html.escape(tree)}</pre>
            <p class="mb-2">You can organise your files your own way. Only one rule is fixed: <b>chat models go in
            <code>~/models/</code></b>, because that is the only folder Model Hub can read.</p>
            <p class="text-body-secondary mb-0">Don't delete the hidden <code>.mlflow</code> folder in your home: it holds your job login.</p>"""),
        faq_item("faq-name", "Why must my experiment name start with my username?",
            f"""<p class="mb-2">Experiment names are shared by everyone on the cluster, but you only see your own.
            If someone else already used a name, you get <b>Permission denied (403)</b> and can't see why.</p>
            <p class="mb-0">Starting with <code>{u}/</code> means nobody else can have the same name. Example:
            <code>{u}/mnist-test</code>.</p>"""),
        faq_item("faq-model", "How do I put my model into Model Hub?",
            f"""<p class="mb-2"><b>Classic ML or deep learning</b> (scikit-learn, XGBoost, PyTorch&hellip;): log the model with a
            name in your training script. It appears in Model Hub straight away.</p>
            {code("c-ml", 'mlflow.sklearn.log_model(model, name="model", registered_model_name="my-model", input_example=X[:5])')}
            <p class="mb-0"><b>Chat models (LLMs)</b> work differently: see the next question.
            Model Hub's <a href="{HUB}#/help">Add your model</a> page has examples for each type.</p>"""),
        faq_item("faq-llm", "How do I put a chat model (LLM) into Model Hub?",
            f"""<p class="mb-2">Chat models are too big to store in MLflow, so they stay in your home folder and MLflow only
            remembers where they are.</p>
            <ol class="ps-3 mb-3">
              <li class="mb-2">At the end of training, save the <b>full model</b> into its own folder in <code>~/models/</code>.
                If you trained with LoRA, the first line merges it in. Otherwise leave that line out.
                {code("c-save", save)}</li>
              <li class="mb-2">On the login node, register it:
                {code("c-reg", "model-register ~/models/my-llm/v1 my-llm")}</li>
              <li>Open <a href="{HUB}">Model Hub</a>. It is listed as a <b>Chat model</b>: click it, then <b>Deploy</b>.</li>
            </ol>
            <div class="alert alert-warning small mb-0">Saving a chat model with <code>mlflow.transformers.log_model</code> or as
              an artifact does <b>not</b> work for Model Hub. Always use <code>model-register</code>.</div>"""),
        faq_item("faq-llm-missing", "My chat model doesn't show up, or won't deploy",
            """<p class="mb-2">Check these:</p><ul class="ps-3 mb-0">
              <li>The folder is inside <code>~/models/</code>.</li>
              <li>It is a full model: it has <code>config.json</code> and <code>.safetensors</code> files. A folder with only
                <code>adapter_config.json</code> is a LoRA adapter: merge it first.</li>
              <li>You ran <code>model-register</code>, and it printed <b>Registered &hellip; version &hellip;</b></li>
              <li>Each new version has its own folder (<code>v1</code>, <code>v2</code>&hellip;). Don't overwrite a folder that
                a running endpoint is using.</li></ul>"""),
        faq_item("faq-errors", "I get an error: 401, 403, 404 or connection refused",
            f"""<dl class="mb-0">
              <dt><code>401</code> &middot; Not authenticated</dt>
              <dd class="text-body-secondary mb-3">MLflow doesn't know who you are. Usually your job can't find your login:
                check that <b>Job login</b> above says OK.</dd>
              <dt><code>403</code> &middot; Permission denied</dt>
              <dd class="text-body-secondary mb-3">You're logged in, but it isn't yours. Usually the experiment name is already
                used by someone else: use <code>{u}/&hellip;</code></dd>
              <dt><code>404</code> &middot; Not found</dt>
              <dd class="text-body-secondary mb-3">The address, experiment or model name is wrong. Check for typos.</dd>
              <dt>Connection refused or timed out</dt>
              <dd class="text-body-secondary mb-0">MLflow can't be reached. Check the tracking address, and that
                <b>MLflow server</b> above says OK.</dd></dl>"""),
    ])

def application(environ, start_response):
    server_ok, creds_ok = up(), os.path.isfile(CREDS)
    export = html.escape(f"export MLFLOW_TRACKING_URI={URI}")
    user = html.escape(USER)
    exp_py = html.escape(f'mlflow.set_experiment("{USER}/my-experiment")')
    exp_sh = html.escape(f'export MLFLOW_EXPERIMENT_NAME="{USER}/my-experiment"')
    status = row(server_ok, "MLflow server", "Running" if server_ok else
                 "Not answering right now. Contact your administrator.")
    status += row(creds_ok, "Job login", "Set up in <code>~/.mlflow/credentials</code>" if creds_ok else
                  "Not set up for your account. Contact your administrator.")
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
<style>#faq .accordion-item{{scroll-margin-top:5rem}}</style>
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
        <div class="code-wrap"><pre class="code mb-0" id="uri">{export}</pre><button class="btn btn-sm btn-outline-secondary btn-copy" type="button" data-copy="uri"><i class="bi bi-clipboard"></i> Copy</button></div>
        <div class="small text-body-secondary mt-2">It never changes, so you can keep it in your scripts.</div></li>
      <li><div class="fw-medium mb-1">Name your experiment <span class="font-monospace">{user}/&hellip;</span></div>
        <div class="small text-body-secondary mb-2">Experiment names are shared across the cluster. Starting with your username keeps yours unique.</div>
        <div class="code-wrap mb-2"><pre class="code mb-0" id="exp-py">{exp_py}</pre><button class="btn btn-sm btn-outline-secondary btn-copy" type="button" data-copy="exp-py"><i class="bi bi-clipboard"></i> Copy</button></div>
        <div class="code-wrap"><pre class="code mb-0" id="exp-sh">{exp_sh}</pre><button class="btn btn-sm btn-outline-secondary btn-copy" type="button" data-copy="exp-sh"><i class="bi bi-clipboard"></i> Copy</button></div></li>
      <li><div class="fw-medium">Log runs as usual</div>
        <div class="small text-body-secondary">Your jobs log in with a token from <code>~/.mlflow/credentials</code>, so no password goes into your scripts.</div></li>
    </ol>
    <div class="alert alert-warning d-flex gap-2 small mt-4 mb-0"><i class="bi bi-chat-dots"></i>
      <div><b>Training a chat model (LLM)?</b> It reaches Model Hub only if you save it in <code>~/models/</code> and register it
        with <code>model-register</code>. <a href="#faq-llm" class="alert-link">Show me how</a></div></div></div></div>
  <div class="card mb-4"><div class="card-body pb-2"><div class="eyebrow mb-3">Questions</div></div>
    <div class="accordion accordion-flush" id="faq">{faq()}</div></div>
  <div class="card"><div class="card-body">
    <div class="eyebrow mb-2">Web UI</div>
    <p class="small text-body-secondary mb-0">{ui_note}</p></div></div>
</main>
<script src="{HUB}vendor/bootstrap/bootstrap.bundle.min.js"></script>
<script>
const $=id=>document.getElementById(id);
const openFaq=()=>{{const q=/^#faq-[a-z-]+$/.test(location.hash)&&$(location.hash.slice(1)+'-a');if(q){{bootstrap.Collapse.getOrCreateInstance(q,{{toggle:false}}).show();q.parentElement.scrollIntoView({{block:'start'}})}}}};
addEventListener('hashchange',openFaq);openFaq();
document.querySelectorAll('[data-copy]').forEach(b=>b.onclick=()=>navigator.clipboard.writeText($(b.dataset.copy).textContent)
  .then(()=>{{b.innerHTML='<i class="bi bi-check2"></i> Copied';setTimeout(()=>b.innerHTML='<i class="bi bi-clipboard"></i> Copy',1500)}}));
const t=document.getElementById('theme'),ic=()=>t.innerHTML='<i class="bi bi-'+(document.documentElement.dataset.bsTheme==='dark'?'sun':'moon-stars')+'"></i>';ic();
t.onclick=()=>{{const v=document.documentElement.dataset.bsTheme==='dark'?'light':'dark';document.documentElement.dataset.bsTheme=v;ic();try{{localStorage.setItem('mh-theme',v)}}catch(e){{}}}};
</script></body></html>""".encode()]

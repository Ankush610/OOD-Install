// Model Hub UI (Bootstrap 5.3). Talks only to this app's backend (passenger_wsgi.py, running as the logged-in user):
//   GET api/me | api/models | api/models/<name>/<version> | api/endpoints | api/endpoints/<n>/logs
//   GET api/models/<n>/<v>/download (state) | api/models/<n>/<v>/zip (the files)
//   POST api/deploy | api/endpoints/<n>/predict | api/models/<name>/public | api/models/<n>/<v>/download   DELETE api/endpoints/<n>
// Routes: #/  #/model/<name>[/<version>]  #/endpoints  #/endpoint/<name>  #/key  #/help
'use strict';
const $ = s => document.querySelector(s);
const app = $('#app');
const h = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const enc = encodeURIComponent;
let ME = null, timer = null;

async function api(path, opts = {}) {
  const r = await fetch('api/' + path, {
    method: opts.method || 'GET', headers: { 'Content-Type': 'application/json' },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const data = await r.json().catch(() => ({ error: `HTTP ${r.status}` }));
  if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
  return data;
}

// ---------- small UI helpers ----------
const toast = msg => { $('#toast-body').textContent = msg; bootstrap.Toast.getOrCreateInstance($('#toast'), { delay: 3500 }).show(); };
const copy = s => navigator.clipboard.writeText(s).then(() => toast('Copied to clipboard'), () => toast('Copy failed'));
const spinner = (msg = 'Loading…') => `<div class="text-center text-body-secondary py-5">
    <div class="spinner-border text-primary mb-3" role="status"></div><div>${h(msg)}</div></div>`;
const alertBox = (e, kind = 'danger', icon = 'exclamation-triangle') =>
  `<div class="alert alert-${kind} d-flex gap-2 align-items-start" role="alert"><i class="bi bi-${icon} mt-1"></i><div>${h(e.message || e)}</div></div>`;
const empty = (icon, title, html = '') => `<div class="text-center text-body-secondary py-5 px-3"><i class="bi bi-${icon} fs-1 d-block mb-2 opacity-50"></i>
    <div class="fw-semibold text-body mb-1">${title}</div>${html}</div>`;
const header = (title, sub = '', right = '') => `<div class="d-flex flex-wrap align-items-end gap-3 mb-4">
    <div class="me-auto"><h1 class="h3 fw-semibold mb-1">${title}</h1>${sub ? `<div class="text-body-secondary">${sub}</div>` : ''}</div>${right}</div>`;
const back = (href, label) => `<a class="d-inline-flex align-items-center gap-1 small text-body-secondary text-decoration-none mb-3" href="${href}"><i class="bi bi-arrow-left"></i>${label}</a>`;
const KIND = { ML: ['graph-up', 'primary', 'Classic ML'], DL: ['cpu', 'info', 'Deep learning'], LLM: ['chat-dots', 'success', 'Chat model'] };
const kindIcon = k => { const [i, c] = KIND[k] || ['box', 'secondary']; return `<span class="kind-icon bg-${c}-subtle text-${c}-emphasis"><i class="bi bi-${i}"></i></span>`; };
const kindName = k => KIND[k]?.[2] || 'Model';
// state word from the backend -> what a person reads, and its colour
const STATE = { ready: ['success', 'Ready'], loading: ['info', 'Starting'], starting: ['info', 'Starting'], queued: ['warning', 'Waiting for GPU'],
                failed: ['danger', 'Failed'], stopped: ['secondary', 'Stopped'] };
const stateBadge = s => { const [c, t] = STATE[s] || ['secondary', s];
  return `<span class="status bg-${c}-subtle text-${c}-emphasis ${['loading', 'starting', 'queued'].includes(s) ? 'pulse' : ''}">${h(t)}</span>`; };
const cap = s => s ? s[0].toUpperCase() + s.slice(1) : '';
// "models:/churn/3" -> "churn · v3"
const modelLabel = uri => { const m = /^models:\/(.+)\/(\d+)$/.exec(uri || ''); return m ? `${h(m[1])} · v${m[2]}` : h(uri); };
const pubBadge = (t = 'Public') => `<span class="badge rounded-pill bg-success-subtle text-success-emphasis fw-medium"><i class="bi bi-globe2 me-1"></i>${t}</span>`;
const hwLabel = n => n ? `<span><i class="bi bi-gpu-card"></i>${n > 1 ? n + ' GPUs' : 'GPU'}</span>` : '<span><i class="bi bi-cpu"></i>CPU</span>';
const when = ms => ms ? new Date(ms).toLocaleString() : '';
const ago = ms => {
  if (!ms) return '';
  const s = (ms - Date.now()) / 1000, rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
  for (const [u, n] of [['day', 86400], ['hour', 3600], ['minute', 60]]) if (Math.abs(s) >= n) return rtf.format(Math.round(s / n), u);
  return 'just now';
};
const bytes = n => { if (!n) return ''; const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (n >= 1024 && i < 4) { n /= 1024; i++; } return `${n.toFixed(i ? 1 : 0)} ${u[i]}`; };
const num = v => typeof v !== 'number' ? h(v) : Math.abs(v) >= 1e4 || Number.isInteger(v) ? v.toLocaleString() : +v.toPrecision(4);
// sso (Keycloak): through OOD's /node proxy, already logged in; else straight to MLflow's port (asks for a password)
const mlflowUI = () => ME.mlflow_ui.sso ? `${location.origin}${ME.mlflow_ui.prefix}/`
  : `${location.protocol}//${location.hostname}:${ME.mlflow_ui.port}${ME.mlflow_ui.prefix}/`;
// "float32 [-1,1,28,28]" or "3 columns: age, usage, plan" -- one line instead of the full schema (that's in the API tab)
const sigLine = cols => !cols?.length ? null : cols[0]['tensor-spec'] && cols.length === 1
  ? `${h(cols[0]['tensor-spec'].dtype)} tensor <code>${h(JSON.stringify(cols[0]['tensor-spec'].shape))}</code>`
  : `${cols.length} column${cols.length > 1 ? 's' : ''}: ${cols.slice(0, 6).map(c => h(c.name ?? '(tensor)')).join(', ')}${cols.length > 6 ? ', …' : ''}`;
function left(iso) {
  if (!iso) return '';
  const s = (Date.parse(iso) - Date.now()) / 1000;
  return s <= 0 ? 'Time is up' : `Stops in ${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m`;
}
const timeLeft = iso => iso ? `<span><i class="bi bi-clock"></i>${left(iso)}</span>` : '';
const codeBlock = (id, text, label = '') => `<div class="mb-3">${label ? `<div class="small fw-semibold mb-1">${label}</div>` : ''}
    <div class="code-wrap"><pre class="code mb-0" id="${id}">${h(text)}</pre>
    <button class="btn btn-sm btn-outline-secondary btn-copy bg-body" data-copy="${id}"><i class="bi bi-clipboard me-1"></i>Copy</button></div></div>`;
const wireCopies = (root = app) => root.querySelectorAll('[data-copy]').forEach(b => b.onclick = () => copy(document.getElementById(b.dataset.copy).textContent));
// the gateway's self-signed certificate: one file for everybody, whoever owns the endpoint
const caLink = (label = 'Download certificate') => `<a class="btn btn-sm btn-outline-secondary" href="api/gateway-ca" download="gateway-ca.crt"><i class="bi bi-download me-1"></i>${label}</a>`;
// the 3 steps to call any endpoint through the gateway: key, certificate, request
function callSteps(curl, py) {
  const ca = ME.gateway?.ca;
  return `<ol class="steps">
    <li><div class="fw-semibold">Get your API key</div>
      <div class="small text-body-secondary mb-2">Use your own key. It works for your endpoints and the ones shared with you.</div>
      <a class="btn btn-sm btn-outline-secondary" href="#/key"><i class="bi bi-key me-1"></i>Go to API key</a></li>
    ${ca ? `<li><div class="fw-semibold">Download the certificate</div>
      <div class="small text-body-secondary mb-2">One-time download. It's the same file for everyone. Save it in the folder you run your code from.</div>
      ${caLink('gateway-ca.crt')}</li>` : ''}
    <li><div class="fw-semibold mb-2">Send a request</div>
      ${py ? `<ul class="nav nav-underline small mb-2" role="tablist">
          <li class="nav-item"><button class="nav-link active" data-bs-toggle="tab" data-bs-target="#ex-curl" type="button" role="tab">curl</button></li>
          <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#ex-py" type="button" role="tab">Python</button></li></ul>
        <div class="tab-content"><div class="tab-pane show active" id="ex-curl" role="tabpanel">${codeBlock('x-curl', curl)}</div>
          <div class="tab-pane" id="ex-py" role="tabpanel">${codeBlock('x-py', py)}</div></div>` : codeBlock('x-curl', curl)}</li></ol>`;
}

// ---------- Models ----------
async function renderModels() {
  app.innerHTML = spinner('Loading models…');
  let list;
  try { list = await api('models'); } catch (e) { app.innerHTML = alertBox(e); return; }
  app.innerHTML = header('Models', 'Pick a model to try it, or put it online as an API.',
      `<a class="btn btn-outline-secondary" href="#/help"><i class="bi bi-plus-lg me-1"></i>Add your model</a>`) +
    (list.length ? `<div class="d-flex flex-wrap align-items-center gap-3 mb-3">
      <div class="input-group" style="max-width:24rem"><span class="input-group-text bg-body"><i class="bi bi-search"></i></span>
        <input class="form-control border-start-0" id="q" type="search" placeholder="Search by name or description" aria-label="Search models"></div>
      <span class="small text-body-secondary ms-auto" id="count"></span></div>` : '') +
    `<div class="row g-3" id="grid"></div>`;
  const draw = () => {
    const q = ($('#q')?.value || '').toLowerCase();
    const rows = list.filter(m => (m.name + ' ' + m.description).toLowerCase().includes(q));
    if ($('#count')) $('#count').textContent = `${rows.length} model${rows.length === 1 ? '' : 's'}`;
    $('#grid').innerHTML = rows.map(m => `<div class="col-md-6 col-xl-4">
        <a class="card h-100 text-decoration-none text-body model-card" href="#/model/${enc(m.name)}"><div class="card-body d-flex flex-column">
          <div class="d-flex gap-3 align-items-center mb-3">${kindIcon(m.tags.path ? 'LLM' : '')}
            <div class="min-w-0 me-auto"><div class="fw-semibold text-truncate" title="${h(m.name)}">${h(m.name)}</div>
              <div class="small text-body-secondary">${m.tags.path ? 'Chat model' : 'Model'}${m.tags.public === 'true' && m.tags.owner && m.tags.owner !== ME.user ? ` · by ${h(m.tags.owner)}` : ''}</div></div>
            ${m.tags.public === 'true' ? pubBadge() : ''}
            <span class="badge rounded-pill bg-body-secondary text-body-secondary fw-medium">v${m.latest ?? '–'}</span></div>
          <p class="card-text small text-body-secondary clamp-2 mb-3">${h(m.description) || 'No description yet.'}</p>
          <div class="small text-body-secondary mt-auto" title="${h(when(m.updated))}">Updated ${ago(m.updated)}</div></div></a></div>`).join('')
      || `<div class="col-12"><div class="card">${list.length ? empty('search', 'No matches', 'Try a different word.')
           : empty('box-seam', 'No models yet', 'Register a model in MLflow and it shows up here.<div class="mt-3"><a class="btn btn-primary" href="#/help">Show me how</a></div>')}</div></div>`;
  };
  if ($('#q')) $('#q').oninput = draw;
  draw();
}

// ---------- One model: details + deploy ----------
async function renderModel(name, version) {
  app.innerHTML = spinner();
  let latest = version, info, eps;
  try {
    const all = await api('models');
    latest = all.find(m => m.name === name)?.latest;
    if (!latest) throw new Error(`${name} has no versions`);
    [info, eps] = await Promise.all([api(`models/${enc(name)}/${version || latest}`), api('endpoints').catch(() => [])]);
  } catch (e) { app.innerHTML = alertBox(e); return; }
  const isLLM = info.kind === 'LLM', isML = info.kind === 'ML';
  const running = eps.filter(e => e.model === `models:/${name}/${info.version}` && e.state !== 'stopped');
  const run = info.run, llm = info.llm || {};
  const runUrl = run ? `${mlflowUI()}#/experiments/${enc(run.experiment_id)}/runs/${enc(run.id)}` : null;
  const metrics = Object.entries(info.metrics || {});
  const params = Object.entries(info.params || {});
  const libs = info.libs || [], drift = libs.filter(l => !l.ok);
  const took = run?.end && run?.start ? Math.round((run.end - run.start) / 60000) : null;
  const hw = (isML ? ['<option value="">CPU</option>'] : [!isLLM && '<option value="">CPU</option>',
    ...ME.gpu_types.flatMap(t => Array.from({ length: isLLM ? Math.max(1, ME.limits.gpus) : 1 }, (_, i) =>
      `<option value="${h(t)}" data-gpus="${i + 1}">${i + 1} GPU${i ? 's' : ''} · ${h(t.toUpperCase())}</option>`))]).filter(Boolean).join('');
  const gpuNote = `You can use up to ${ME.limits.gpus} GPU${ME.limits.gpus === 1 ? '' : 's'}` +
    (isLLM && ME.limits.gpus > 1 ? '. Pick 2 or more for very large models.' : '.');
  const defName = `${name}-v${info.version}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-|-$/g, '').slice(0, 42);
  const versions = Array.from({ length: latest }, (_, i) => latest - i);
  const fact = (k, v) => v ? `<div class="col-6 col-md"><div class="fact"><div class="small text-body-secondary">${k}</div><div class="v text-truncate" title="${h(String(v).replace(/<[^>]+>/g, ''))}">${v}</div></div></div>` : '';
  const facts = [
    fact('Type', kindName(info.kind)),
    isLLM && fact('Parameters', llm.params && `${(llm.params / 1e9).toFixed(llm.params < 1e10 ? 2 : 0)} B`),
    isLLM && fact('Context', llm.context && `${num(llm.context)} tokens`),
    fact('Size', bytes(isLLM ? llm.size : info.size)),
    fact('Added', `<span title="${h(when(info.created))}">${ago(info.created)}</span>`),
    (run?.user || !info.mine) && fact('By', h(run?.user || info.owner)),
  ].filter(Boolean).join('');
  const dd = (k, v) => v ? `<dt class="col-sm-4 fw-normal text-body-secondary">${k}</dt><dd class="col-sm-8">${v}</dd>` : '';
  app.innerHTML = `${back('#/', 'All models')}
    <div class="d-flex flex-wrap align-items-center gap-3 mb-4">${kindIcon(info.kind)}
      <div class="me-auto min-w-0"><h1 class="h3 fw-semibold mb-0 text-break">${h(name)}</h1>
        <div class="text-body-secondary">${info.description ? h(info.description) : kindName(info.kind)}</div></div>
      ${info.public ? pubBadge(info.mine ? 'Public' : `Public · by ${h(info.owner)}`) : ''}
      <select class="form-select w-auto" id="ver" aria-label="Version">${versions.map(v =>
        `<option value="${v}" ${v === info.version ? 'selected' : ''}>Version ${v}${v === latest ? ' (latest)' : ''}</option>`).join('')}</select></div>
    <div class="row g-4 align-items-start">
      <div class="col-lg-8 d-flex flex-column gap-4">
        <div class="card"><div class="card-body p-4">
          <div class="row g-2 mb-${metrics.length || !isLLM ? 4 : 0}">${facts}</div>
          ${!isLLM && (info.inputs?.length || info.outputs?.length) ? `<div class="eyebrow mb-2">What it does</div>
            <p class="mb-4">Takes ${sigLine(info.inputs) || '?'} <i class="bi bi-arrow-right mx-1 text-body-secondary"></i> returns ${sigLine(info.outputs) || '?'}</p>` : ''}
          ${metrics.length ? `<div class="eyebrow mb-2">Results</div><div class="row g-2 mb-${params.length ? 3 : 0}">${metrics.map(([k, v]) => `<div class="col-6 col-md-4"><div class="fact">
              <div class="small text-body-secondary text-truncate" title="${h(k)}">${h(k)}</div><div class="v font-monospace">${num(v)}</div></div></div>`).join('')}</div>`
            : isLLM ? '' : `<div class="eyebrow mb-2">Results</div><p class="small text-body-secondary mb-0">No results logged for this version. Add <code>mlflow.log_metric("accuracy", acc)</code> to your training to compare versions here.</p>`}
          ${params.length ? `<details class="mt-3"><summary class="small fw-semibold">Training settings (${params.length})</summary>
              <table class="table table-sm small mb-0 mt-2"><tbody>${params.map(([k, v]) => `<tr><td class="text-body-secondary">${h(k)}</td><td class="font-monospace text-break">${h(v)}</td></tr>`).join('')}</tbody></table></details>` : ''}
        </div></div>
        ${isLLM || !libs.length ? '' : `<div class="card"><div class="card-body p-4">
          <div class="d-flex align-items-center gap-2 mb-2"><div class="eyebrow me-auto">Library check</div>
            ${drift.length ? '<span class="status bg-warning-subtle text-warning-emphasis">Mismatch</span>' : '<span class="status bg-success-subtle text-success-emphasis">Match</span>'}</div>
          <p class="small text-body-secondary mb-3">${drift.length ? 'Some libraries differ from the ones used to serve it. It may not load, or may give different answers. Train with the cluster\'s containers to fix this.'
            : 'Trained with the same library versions used to serve it.'}</p>
          <div class="d-flex flex-wrap gap-2">${libs.map(l => `<span class="badge rounded-pill ${l.ok ? 'bg-body-secondary text-body-secondary' : 'bg-warning-subtle text-warning-emphasis'} fw-normal"
              title="trained ${h(l.trained)}, serving ${h(l.serving)}">${h(l.name)} ${h(l.trained)}${l.ok ? '' : ` → ${h(l.serving)}`}</span>`).join('')}</div></div></div>`}
        ${info.can_manage ? publicCard(name, info) : ''}
        ${!info.mine && !isLLM ? `<div class="alert alert-warning d-flex gap-2 mb-0" role="alert"><i class="bi bi-exclamation-triangle mt-1"></i>
          <div>Public model by <b>${h(info.owner)}</b>. When you deploy it, it runs ${h(info.owner)}'s code in your space. Deploy only models from people you trust.</div></div>` : ''}
        <details class="card"><summary class="card-body small fw-semibold">Technical details</summary>
          <div class="card-body pt-0"><dl class="row small mb-0">
          ${dd('Served with', isLLM ? 'vLLM (OpenAI-compatible API)' : 'MLflow serving (<code>/invocations</code>)')}
          ${isLLM ? dd('Folder', `<span class="font-monospace text-break">${h(info.path)}</span>`) : dd('Flavor', h((info.flavors || []).join(', ')))}
          ${isLLM ? dd('Architecture', h(llm.architecture)) + dd('Precision', h(llm.dtype)) : ''}
          ${isLLM && llm.lora_base ? dd('LoRA adapter', `on <code>${h(llm.lora_base)}</code>${llm.lora_rank ? `, rank ${h(llm.lora_rank)}` : ''}`) : ''}
          ${!isLLM && !libs.length ? dd('Library check', info.libs ? 'Not needed: no pinned libraries' : 'Skipped: no <code>requirements.txt</code>') : ''}
          ${dd('Registered', when(info.created))}
          ${run ? dd('Training run', `${h(run.experiment || 'experiment ' + run.experiment_id)} / ${h(run.name || run.id.slice(0, 8))}${took !== null ? ` · ${took} min` : ''}
              <a class="ms-1" href="${h(runUrl)}" target="_blank" rel="noopener">Open in MLflow <i class="bi bi-box-arrow-up-right"></i></a>`) : ''}
          </dl></div></details>
      </div>
      <div class="col-lg-4 sticky-lg"><div class="card"><div class="card-body p-4">
        <h2 class="h5 fw-semibold mb-1">Deploy</h2>
        <p class="small text-body-secondary mb-3">Put this model online. You get a private API and a page to try it.</p>
        ${running.map(e => `<a class="d-flex align-items-center gap-2 p-2 mb-3 rounded border text-decoration-none text-body list-row" href="#/endpoint/${enc(e.name)}">
            <i class="bi bi-broadcast text-success"></i><div class="min-w-0 me-auto small"><div class="fw-semibold text-truncate">${h(e.name)}</div>
            <div class="text-body-secondary">Already online · ${left(e.expires)}</div></div>${stateBadge(e.state)}</a>`).join('')}
        <form id="dep" novalidate>
          <div class="mb-3"><label class="form-label small fw-semibold" for="ep">Name</label>
            <input class="form-control" id="ep" value="${h(defName)}" maxlength="42" pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" required>
            <div class="invalid-feedback">Use lowercase letters, numbers and dashes.</div>
            <div class="form-text">Lowercase letters, numbers and dashes.</div></div>
          <div class="mb-3"><label class="form-label small fw-semibold" for="hw">Hardware</label>
            <select class="form-select" id="hw" ${hw ? '' : 'disabled'}>${hw || '<option>No GPUs available</option>'}</select>
            <div class="form-text">${isML ? 'Runs on CPU.' : isLLM ? 'Chat models need a GPU.' : 'GPU is faster. CPU works too.'} ${isML ? '' : gpuNote}</div></div>
          <div class="mb-4"><label class="form-label small fw-semibold" for="hours">Keep it running for</label>
            <div class="input-group"><input class="form-control" id="hours" type="number" min="1" max="${ME.limits.max_hours}" value="${ME.limits.default_hours}" required>
              <span class="input-group-text">hours</span>
              <div class="invalid-feedback">Pick 1 to ${ME.limits.max_hours} hours.</div></div>
            <div class="form-text">It stops on its own after this (max ${ME.limits.max_hours}). If GPUs are busy, it waits its turn.</div></div>
          <button class="btn btn-primary w-100" id="go" type="submit"><i class="bi bi-rocket-takeoff me-1"></i>Deploy</button>
          <button class="btn btn-link btn-sm w-100 mt-1 text-body-secondary text-decoration-none" id="pre" type="button">See what gets created</button>
        </form><div id="out" class="mt-3"></div>
      </div></div>
      ${isLLM && info.mine ? '' : `<div class="card mt-4"><div class="card-body p-4" id="dlcard"></div></div>`}</div>
    </div>`;
  // the cluster's timer is copying the files: refresh only this card until it's done (or failed)
  const size = isLLM ? llm.size : info.size, copying = i => i.public && !/^(ready|error)/.test(i.public_status || '');
  const wire = i => { if ($('#pub')) $('#pub').onclick = () => togglePublic(name, i, size);
    if (i.can_manage && copying(i)) timer = setTimeout(async () => {
      if (!$('#pubcard')) return;
      try { const n = await api(`models/${enc(name)}/${info.version}`); $('#pubcard').outerHTML = publicCard(name, n); wire(n); } catch (e) { /* next page load */ }
    }, 5000); };
  wire(info);
  if ($('#dlcard')) downloadCard(name, info, isLLM ? llm.size : info.size);
  $('#ver').onchange = () => { location.hash = `#/model/${enc(name)}/${$('#ver').value}`; };
  const body = extra => ({ model: name, version: info.version, endpoint: $('#ep').value.trim(), gpu: !!$('#hw').value,
                           gpu_type: $('#hw').value, gpus: +($('#hw').selectedOptions[0]?.dataset.gpus || 1),
                           hours: +$('#hours').value, ...extra });
  $('#pre').onclick = async () => {
    try { const r = await api('deploy', { method: 'POST', body: body({ preview: true }) });
          $('#yaml-title').textContent = 'What gets created';
          $('#yaml-body').innerHTML = `<p class="small text-body-secondary">The Kubernetes objects this deploy makes. For the curious: you don't need to read this.</p>
            <pre class="code mb-0">${h(JSON.stringify(r.manifest, null, 2))}</pre>`;
          bootstrap.Modal.getOrCreateInstance($('#yaml')).show(); }
    catch (e) { $('#out').innerHTML = alertBox(e); }
  };
  $('#dep').onsubmit = async ev => {
    ev.preventDefault();
    if (!$('#dep').checkValidity()) { $('#dep').classList.add('was-validated'); return; }
    $('#go').disabled = true; $('#go').innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Deploying…';
    try { const r = await api('deploy', { method: 'POST', body: body() });
          toast(`Starting ${r.endpoint}…`); location.hash = `#/endpoint/${enc(r.endpoint)}`; }
    catch (e) { $('#out').innerHTML = alertBox(e); $('#go').disabled = false; $('#go').innerHTML = '<i class="bi bi-rocket-takeoff me-1"></i>Deploy'; }
  };
}

// Make public / Make private (owner only). The button sets a tag; a timer on the cluster does the rest within a minute.
// a real progress bar: bytes copied so far of the total (null total = not counted yet: a moving bar)
const progressBar = (done, total, label) => {
  const pct = total ? Math.min(100, Math.floor(done / total * 100)) : 100;
  return `<div class="mt-2"><div class="progress" role="progressbar" aria-label="${h(label)}" aria-valuenow="${total ? pct : 0}" aria-valuemin="0" aria-valuemax="100" style="height:.5rem">
      <div class="progress-bar ${total ? '' : 'progress-bar-striped progress-bar-animated'}" style="width:${pct}%"></div></div>
    <div class="small text-body-secondary mt-1">${h(label)}${total ? ` · ${pct}% · ${bytes(done) || '0 B'} of ${bytes(total)}` : ''}</div></div>`;
};
// public_status from the cluster's timer: waiting | copying <done>/<total> | ready | error: …
const PSTATUS = { waiting: ['secondary', 'Waiting to start (within a minute)'], ready: ['success', 'Files shared'] };
function publicCard(name, info) {
  const st = info.public_status || 'waiting', cp = /^copying (\d+)\/(\d+)$/.exec(st);
  const [c, t] = PSTATUS[st] || (st.startsWith('error') ? ['danger', 'Sharing failed'] : ['info', 'Sharing the files…']);
  return `<div class="card" id="pubcard"><div class="card-body p-4"><div class="d-flex flex-wrap align-items-center gap-3">
      <div class="me-auto flex-grow-1"><div class="eyebrow mb-1">Who can use this model</div>
        <div>${info.public ? '<b>Everyone</b>: every user can see, deploy and download it.' : '<b>Only you.</b> Endpoints you share still work for the people you shared them with.'}</div>
        ${!info.public ? '' : cp ? progressBar(+cp[1], +cp[2], 'Sharing the files')
          : `<div class="small mt-1"><span class="status bg-${c}-subtle text-${c}-emphasis">${h(t)}</span>
          ${st.startsWith('error') ? `<span class="text-danger ms-1">${h(st.slice(7))}</span>` : ''}</div>`}</div>
      <button class="btn ${info.public ? 'btn-outline-secondary' : 'btn-outline-primary'}" id="pub" type="button">
        <i class="bi bi-${info.public ? 'lock' : 'globe2'} me-1"></i>${info.public ? 'Make private' : 'Make public'}</button></div></div></div>`;
}
function togglePublic(name, info, size) {
  const on = !info.public;
  confirmBox(on ? `Make ${h(name)} public?` : `Make ${h(name)} private?`, on
    ? `Every user will be able to see, deploy and download <b>all versions</b> of ${h(name)}.
       <ul class="small text-body-secondary mt-2 mb-0"><li>The files are copied once per version${size ? ` (this version: ${bytes(size)})` : ''}. That takes a minute or more.</li>
       <li>You can make it private again later, but files people already downloaded stay with them.</li></ul>`
    : `Within a minute other users can't see or deploy ${h(name)} any more, and its shared copy is deleted.
       <div class="small text-body-secondary mt-2">Endpoints others already run from it keep running until they stop. Files they downloaded stay with them.</div>`,
    on ? '<i class="bi bi-globe2 me-1"></i>Make public' : '<i class="bi bi-lock me-1"></i>Make private', 'btn-primary', async () => {
      try { await api(`models/${enc(name)}/public`, { method: 'POST', body: { public: on } });
            toast(on ? 'Public: sharing the files now' : 'Private again'); route(); }
      catch (e) { toast(e.message); }
    });
}
function confirmBox(title, body, ok, okClass, fn) {
  $('#confirm-title').innerHTML = title; $('#confirm-body').innerHTML = body;
  $('#confirm-ok').className = `btn ${okClass}`; $('#confirm-ok').innerHTML = ok;
  const m = bootstrap.Modal.getOrCreateInstance($('#confirm'));
  $('#confirm-ok').onclick = () => { m.hide(); fn(); };
  m.show();
}

// Download: a .zip to this computer (ML / DL), or a copy into ~/model-downloads on the cluster (any model, runs
// in the background: refreshes itself until done)
async function downloadCard(name, info, size) {
  const el = $('#dlcard'), base = `models/${enc(name)}/${info.version}/download`;
  let st; try { st = await api(base); } catch (e) { el.innerHTML = alertBox(e); return; }
  if (!document.body.contains(el)) return;
  const where = `<code class="text-break">${h(st.path.replace(/^\/home\/[^/]+/, '~'))}</code>`;
  const home = { none: '', running: progressBar(st.done || 0, st.total, 'Downloading') + `<div class="small text-body-secondary">into ${where}</div>`,
    done: `<div class="small mt-2"><span class="status bg-success-subtle text-success-emphasis">In your home folder</span> ${where}</div>`,
    error: `<div class="small mt-2 text-danger">Download failed: ${h(st.error)}</div>` }[st.state];
  el.innerHTML = `<h2 class="h5 fw-semibold mb-1">Download</h2>
    <p class="small text-body-secondary mb-3">Get the model's files${size ? ` (${bytes(size)})` : ''}.</p>
    <div class="d-grid gap-2">
      ${info.kind === 'LLM' ? '' : `<a class="btn btn-outline-secondary" href="api/${base.replace(/download$/, 'zip')}" download><i class="bi bi-laptop me-1"></i>To my computer (.zip)</a>`}
      <button class="btn btn-outline-secondary" id="dlhome" type="button" ${st.state === 'running' || st.state === 'done' ? 'disabled' : ''}>
        <i class="bi bi-hdd me-1"></i>To my cluster home</button></div>
    ${home}${info.kind === 'LLM' ? '<div class="form-text">Chat models are too big for the browser. From your home folder, copy them with OOD\'s Files app or <code>scp</code>.</div>' : ''}`;
  $('#dlhome').onclick = async () => {
    try { await api(base, { method: 'POST' }); toast('Downloading into your home folder'); downloadCard(name, info, size); }
    catch (e) { toast(e.message); }
  };
  if (st.state === 'running') setTimeout(() => downloadCard(name, info, size), 5000);
}

// ---------- Endpoints ----------
const modelHref = uri => { const m = /^models:\/(.+)\/(\d+)$/.exec(uri || ''); return m ? `#/model/${enc(m[1])}/${m[2]}` : '#/'; };
const isShared = s => s && (s.all || s.users.length || s.teams.length);
// the list's second line: only what the status pill doesn't already say
const whyLine = e => {
  const pos = /number (\d+)/.exec(e.why || '')?.[1];
  const t = e.state === 'queued' ? (pos ? `Number ${pos} in line` : '') : e.state === 'stopped' || e.state === 'ready' ? '' : cap(e.why);
  return t ? `<div class="small mt-1 ${e.state === 'failed' ? 'text-danger' : 'text-body-secondary'}">${h(t)}</div>` : '';
};
async function renderEndpoints() {
  if (!$('#eps')) app.innerHTML = header('My endpoints', 'Models you put online. This page updates by itself.',
      `<a class="btn btn-primary" href="#/"><i class="bi bi-plus-lg me-1"></i>Deploy a model</a>`) + `<div id="eps">${spinner()}</div>`;
  let list;
  try { list = await api('endpoints'); } catch (e) { $('#eps').innerHTML = alertBox(e); return; }
  $('#eps').innerHTML = list.length ? `<div class="card overflow-hidden"><div class="list-group list-group-flush">${list.map(e => `
      <div class="list-group-item list-row position-relative py-3 px-3 px-md-4 ${e.state === 'stopped' ? 'opacity-75' : ''}"><div class="d-flex align-items-center gap-3">
        ${kindIcon(e.runtime === 'vllm' ? 'LLM' : '')}
        <div class="me-auto min-w-0">
          <div class="d-flex flex-wrap align-items-center gap-2 mb-1"><a class="fw-semibold text-body text-decoration-none stretched-link text-break" href="#/endpoint/${enc(e.name)}">${h(e.name)}</a>
            ${stateBadge(e.state)}${isShared(e.share) ? `<span class="small text-body-secondary" title="${h(shareText(e.share))}"><i class="bi bi-people me-1"></i>${e.share.all ? 'Everyone' : 'Shared'}</span>` : ''}</div>
          <div class="meta"><span>${modelLabel(e.model)}</span>${hwLabel(e.gpu)}${e.state === 'stopped' ? '' : timeLeft(e.expires)}</div>
          ${whyLine(e)}</div>
        <div class="d-flex align-items-center gap-1 position-relative z-2">
          ${e.state === 'stopped' ? `<a class="btn btn-sm btn-outline-primary text-nowrap" href="${modelHref(e.model)}">Deploy again</a>` : ''}
          <button class="btn btn-icon" data-del="${h(e.name)}" title="Delete" aria-label="Delete ${h(e.name)}"><i class="bi bi-trash"></i></button></div>
        <i class="bi bi-chevron-right text-body-secondary d-none d-md-inline"></i>
      </div></div>`).join('')}</div></div>`
    : `<div class="card">${empty('hdd-network', 'Nothing online yet', 'Pick a model and deploy it. It shows up here.<div class="mt-3"><a class="btn btn-primary" href="#/">Browse models</a></div>')}</div>`;
  app.querySelectorAll('[data-del]').forEach(b => b.onclick = () => del(b.dataset.del));
  renderShared();
  timer = setTimeout(renderEndpoints, 5000);
}

// Other people's endpoints this user may call (the gateway knows; see passenger_wsgi.shared_with_me).
let sharedAt = 0;
async function renderShared() {
  if (!$('#shared')) { sharedAt = 0; $('#eps').insertAdjacentHTML('afterend', `<div class="mt-5 mb-3"><h2 class="h5 fw-semibold mb-1">Shared with me</h2>
      <div class="small text-body-secondary">Endpoints other people let you use, with your own API key.</div></div><div id="shared">${spinner()}</div>`); }
  if (Date.now() - sharedAt < 10000) return;                      // fresh page: load now; then every 10 s (gateway caches 5 s)
  sharedAt = Date.now();
  let list;
  try { list = await api('shared'); } catch (e) { $('#shared').innerHTML = alertBox(e, 'warning'); return; }
  $('#shared').innerHTML = list.length ? `<div class="card overflow-hidden"><div class="list-group list-group-flush">${list.map((e, i) => `
      <div class="list-group-item py-3 px-3 px-md-4"><div class="d-flex flex-wrap align-items-center gap-3">
        ${kindIcon(e.runtime === 'vllm' ? 'LLM' : '')}
        <div class="me-auto min-w-0">
          <div class="d-flex flex-wrap align-items-center gap-2 mb-1"><span class="fw-semibold text-break">${h(e.name)}</span>${stateBadge(e.ready ? 'ready' : 'stopped')}</div>
          <div class="meta"><span><i class="bi bi-person"></i>From ${h(e.owner)}</span>${e.model ? `<span>${modelLabel(e.model)}</span>` : ''}${e.ready ? timeLeft(e.expires) : ''}</div></div>
        <button class="btn btn-sm btn-primary" data-ex="${i}" ${e.ready ? '' : 'disabled'}><i class="bi bi-code-slash me-1"></i>How to use</button>
      </div></div>`).join('')}</div></div>`
    : `<div class="card"><div class="card-body small text-body-secondary px-4">Nothing yet. When someone shares an endpoint with you or your team, it shows up here.</div></div>`;
  $('#shared').querySelectorAll('[data-ex]').forEach(b => b.onclick = () => howToCall(list[+b.dataset.ex]));
}
// a shared endpoint: same 3 steps as your own (your key, the one certificate, a request)
function howToCall(e) {
  const llm = e.runtime === 'vllm', ca = ME.gateway?.ca ? '--cacert gateway-ca.crt ' : '';
  const body = llm ? `{"model":"${e.name}","messages":[{"role":"user","content":"Hello!"}]}` : '{"inputs": [[0]]}';
  const curl = `export MH_KEY='mh~${ME.user}~…'   # your key\n\ncurl ${ca}${e.url} \\\n  -H "Authorization: Bearer $MH_KEY" \\\n  -H 'Content-Type: application/json' \\\n  -d '${body}'`;
  const py = llm ? `from openai import OpenAI          # pip install openai
import os, httpx
client = OpenAI(base_url="${e.url.replace(/\/chat\/completions$/, '')}", api_key=os.environ["MH_KEY"]${ME.gateway?.ca ? ',\n                http_client=httpx.Client(verify="gateway-ca.crt")' : ''})
r = client.chat.completions.create(model="${e.name}", messages=[{"role": "user", "content": "Hello"}])
print(r.choices[0].message.content)` : '';
  $('#yaml-title').textContent = `Use ${e.name}`;
  $('#yaml-body').innerHTML = `<p class="small text-body-secondary mb-4"><i class="bi bi-person me-1"></i>Shared by <b>${h(e.owner)}</b>. It runs on their GPU,
      so it stops when their time runs out.${llm ? '' : ' The input format depends on their model: ask them for an example.'}</p>${callSteps(curl, py)}`;
  wireCopies($('#yaml-body'));
  bootstrap.Modal.getOrCreateInstance($('#yaml')).show();
}
const shareText = s => s.all ? 'Shared with everyone' : 'Shared with ' +
  [...s.users, ...s.teams.map(t => `team ${t}`)].join(', ');
async function shareDialog(ep) {
  const s = ep.share || { users: [], teams: [], all: false };
  let teams = [];
  try { teams = await api('teams'); } catch (e) { /* no LDAP from here: people still work */ }
  const mode = s.all ? 'all' : (s.users.length || s.teams.length) ? 'some' : 'me';
  $('#share-title').textContent = `Share ${ep.name}`;
  $('#share-body').innerHTML = `<p class="small text-body-secondary">Who can use this endpoint?</p>
    <div class="list-group mb-3">${[['me', 'Only me', 'lock'], ['some', 'Specific people or teams', 'people'], ['all', 'Everyone on the cluster', 'globe2']].map(([v, t, i]) => `
      <label class="list-group-item d-flex align-items-center gap-2"><input class="form-check-input mt-0" type="radio" name="smode" value="${v}" ${mode === v ? 'checked' : ''}>
        <i class="bi bi-${i} text-body-secondary"></i>${t}</label>`).join('')}</div>
    <div id="some" class="mb-3">
      <label class="form-label small fw-semibold" for="susers">People</label>
      <input class="form-control mb-1" id="susers" value="${h(s.users.join(', '))}" placeholder="e.g. bob, carol">
      <div class="form-text mb-3">Their cluster user names, separated by commas.</div>
      <div class="small fw-semibold mb-1">Teams</div>
      ${teams.length ? teams.map(t => `<div class="form-check form-check-inline"><input class="form-check-input" type="checkbox" id="st-${h(t)}" value="${h(t)}" ${s.teams.includes(t) ? 'checked' : ''}>
          <label class="form-check-label small" for="st-${h(t)}">${h(t)}</label></div>`).join('')
        : '<div class="small text-body-secondary">No teams yet. Your admin can create them.</div>'}</div>
    <div class="small text-body-secondary"><i class="bi bi-info-circle me-1"></i>They use their own API key. It runs on your GPU and your time. Changes apply within a minute.</div>
    <div id="share-err" class="mt-2"></div>`;
  const sync = () => $('#some').classList.toggle('d-none', $('input[name=smode]:checked').value !== 'some');
  $('#share-body').querySelectorAll('input[name=smode]').forEach(r => r.onchange = sync); sync();
  const m = bootstrap.Modal.getOrCreateInstance($('#share'));
  $('#share-ok').onclick = async () => {
    const v = $('input[name=smode]:checked').value;
    const body = v === 'all' ? { all: true, users: [], teams: [] } : v === 'me' ? { all: false, users: [], teams: [] }
      : { all: false, users: $('#susers').value.split(',').map(x => x.trim()).filter(Boolean),
          teams: [...$('#share-body').querySelectorAll('input[type=checkbox]:checked')].map(c => c.value) };
    try { await api(`endpoints/${enc(ep.name)}/share`, { method: 'POST', body }); m.hide(); toast('Sharing updated'); route(); }
    catch (e) { $('#share-err').innerHTML = alertBox(e); }
  };
  m.show();
}
function del(name) {
  confirmBox('Delete this endpoint?', `<b>${h(name)}</b> stops right away, and anyone using it loses access. Its GPU or CPU is freed for others.
    <div class="small text-body-secondary mt-2">The model itself is not deleted. You can deploy it again later.</div>`,
    '<i class="bi bi-trash me-1"></i>Delete', 'btn-danger', async () => {
      try { await api(`endpoints/${enc(name)}`, { method: 'DELETE' }); toast(`Deleted ${name}`);
            if (location.hash.startsWith('#/endpoint/')) location.hash = '#/endpoints'; else route(); }
      catch (e) { toast(e.message); }
    });
}

// ---------- One endpoint: playground, API, logs ----------
const cards = {};      // model card per models:/ URI (a version never changes)
// what's going on, in one sentence, when it isn't ready
function stateBanner(ep) {
  const box = (kind, icon, title, text, extra = '') => `<div class="alert alert-${kind} d-flex gap-3 align-items-start mb-4" role="status">
      <i class="bi bi-${icon} fs-5"></i><div class="me-auto"><div class="fw-semibold">${title}</div><div class="small">${text}</div></div>${extra}</div>`;
  const pos = /number (\d+)/.exec(ep.why || '')?.[1];
  if (ep.state === 'queued') return box('warning', 'hourglass-split', ep.gpu ? 'Waiting for a free GPU' : 'Waiting for a free node',
    `${pos ? `You're number ${pos} in line. ` : ''}It starts by itself, so you can leave this page.`);
  if (ep.state === 'loading' || ep.state === 'starting') return box('info', 'arrow-repeat', 'Starting up', `${h(cap(ep.why || 'loading the model'))}. Big models can take a few minutes.`);
  if (ep.state === 'failed') return box('danger', 'exclamation-octagon', 'It couldn\'t start', `${h(ep.why)}. The <b>Logs</b> tab shows what went wrong.`);
  if (ep.state === 'stopped') return box('secondary', 'stop-circle', 'This endpoint has stopped', 'Its time ran out, or it was stopped. Deploy the model again to use it.',
    `<a class="btn btn-sm btn-primary text-nowrap" href="${modelHref(ep.model)}">Deploy again</a>`);
  return '';
}
async function renderEndpoint(name, tab = 'play') {
  if (!$('#tab')) app.innerHTML = spinner();
  let ep;
  try { ep = (await api('endpoints')).find(e => e.name === name); } catch (e) { app.innerHTML = alertBox(e); return; }
  if (!ep) { app.innerHTML = back('#/endpoints', 'My endpoints') + `<div class="card">${empty('question-circle', `No endpoint called ${h(name)}`, 'It may have been deleted.')}</div>`; return; }
  const m = /^models:\/([^/]+)\/(\d+)$/.exec(ep.model || '');
  const info = m ? (cards[ep.model] ??= await api(`models/${enc(m[1])}/${m[2]}`).catch(() => null)) : null;
  const waiting = ep.state !== 'ready';
  app.innerHTML = `${back('#/endpoints', 'My endpoints')}
    <div class="d-flex flex-wrap align-items-center gap-3 mb-4">${kindIcon(ep.runtime === 'vllm' ? 'LLM' : '')}
      <div class="me-auto min-w-0"><div class="d-flex flex-wrap align-items-center gap-2 mb-1"><h1 class="h3 fw-semibold mb-0 text-break">${h(name)}</h1>${stateBadge(ep.state)}</div>
        <div class="meta"><a class="text-body-secondary text-decoration-none" href="${modelHref(ep.model)}" title="Open the model">${modelLabel(ep.model)}</a>${hwLabel(ep.gpu)}${ep.state === 'stopped' ? '' : timeLeft(ep.expires)}
          ${isShared(ep.share) ? `<span><i class="bi bi-people"></i>${h(shareText(ep.share))}</span>` : ''}</div></div>
      <div class="d-flex gap-2"><button class="btn btn-outline-secondary" id="shr"><i class="bi bi-people me-1"></i>Share</button>
        <button class="btn btn-outline-danger" id="del" aria-label="Delete endpoint" title="Delete"><i class="bi bi-trash"></i></button></div></div>
    ${stateBanner(ep)}
    <ul class="nav nav-underline mb-4 border-bottom">${[['play', 'Try it'], ['api', 'Use the API'], ['logs', 'Logs']].map(([k, t]) =>
      `<li class="nav-item"><button class="nav-link ${tab === k ? 'active' : ''}" data-tab="${k}">${t}</button></li>`).join('')}</ul>
    <div id="tab"></div>`;
  $('#del').onclick = () => del(name);
  $('#shr').onclick = () => shareDialog(ep);
  app.querySelectorAll('[data-tab]').forEach(b => b.onclick = () => { clearTimeout(timer); renderEndpoint(name, b.dataset.tab); });
  if (tab === 'play') playground(ep, info);
  if (tab === 'api') apiTab(ep, info);
  if (tab === 'logs') logsTab(ep);
  if (waiting && ep.state !== 'failed' && tab !== 'logs') timer = setTimeout(() => renderEndpoint(name, tab), 5000);
}

function exampleBody(ep, info) {
  if (ep.runtime === 'vllm') return { model: ep.name, messages: [{ role: 'user', content: 'Hello!' }], max_tokens: 128 };
  const cols = info?.inputs || [];
  if (cols.length && cols.every(c => c.name)) {
    const v = c => /int|long|double|float/.test(c.type) ? 0 : c.type === 'boolean' ? false : '';
    return { dataframe_split: { columns: cols.map(c => c.name), data: [cols.map(v)] } };
  }
  // a tensor: zeros in its full shape, batch of 1 (-1 dims become 1)
  const shape = (cols[0]?.['tensor-spec']?.shape || [-1, 1]).map(d => d < 1 ? 1 : d);
  const zeros = dims => dims.length ? Array.from({ length: dims[0] }, () => zeros(dims.slice(1))) : 0;
  return { inputs: zeros(shape) };
}

// Image-shaped tensor? -> how to lay out pixels. shape includes the batch dim.
//   [-1,784] flat grey 28x28 | [-1,H,W] grey | [-1,C,H,W] (C 1 or 3) | [-1,H,W,C]
function imageLayout(info) {
  const spec = (info?.inputs || [])[0]?.['tensor-spec'];
  if (!spec || (info.inputs || []).length !== 1) return null;
  const s = spec.shape.slice(1);
  if (s.some(d => d < 1)) return null;
  const ok = (hh, ww) => hh >= 8 && ww >= 8;
  if (s.length === 1) { const r = Math.sqrt(s[0]); return Number.isInteger(r) && ok(r, r) ? { h: r, w: r, c: 1, order: 'flat' } : null; }
  if (s.length === 2) return ok(s[0], s[1]) ? { h: s[0], w: s[1], c: 1, order: 'hw' } : null;
  if (s.length === 3 && [1, 3].includes(s[0]) && ok(s[1], s[2])) return { c: s[0], h: s[1], w: s[2], order: 'chw' };
  if (s.length === 3 && [1, 3].includes(s[2]) && ok(s[0], s[1])) return { h: s[0], w: s[1], c: s[2], order: 'hwc' };
  return null;
}
const MEAN = [0.485, 0.456, 0.406], STD = [0.229, 0.224, 0.225];   // ImageNet
function canvasToTensor(src, L, scale, invert) {
  const c = document.createElement('canvas'); c.width = L.w; c.height = L.h;
  const g = c.getContext('2d', { willReadFrequently: true });
  g.imageSmoothingQuality = 'high'; g.drawImage(src, 0, 0, L.w, L.h);
  const px = g.getImageData(0, 0, L.w, L.h).data;
  const val = (i, ch) => {                       // pixel i, channel ch -> number
    let v = L.c === 1 ? 0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2] : px[i * 4 + ch];
    if (invert) v = 255 - v;
    return scale === '255' ? v : scale === 'imagenet' ? (v / 255 - MEAN[ch % 3]) / STD[ch % 3] : v / 255;
  };
  const r = (n, f) => Array.from({ length: n }, (_, k) => f(k));
  const t = L.order === 'flat' ? r(L.h * L.w, i => val(i, 0))
    : L.order === 'hw' ? r(L.h, y => r(L.w, x => val(y * L.w + x, 0)))
    : L.order === 'chw' ? r(L.c, ch => r(L.h, y => r(L.w, x => val(y * L.w + x, ch))))
    : r(L.h, y => r(L.w, x => r(L.c, ch => val(y * L.w + x, ch))));
  return { tensor: [t], preview: c };
}

// Output: class scores -> top-5 bars (softmax if they look like logits); always the raw JSON below.
function renderOutput(r) {
  const rows = r?.predictions ?? r?.outputs ?? r;
  const row = Array.isArray(rows) && Array.isArray(rows[0]) ? rows[0] : null;
  let bars = '';
  if (row && row.length >= 2 && row.length <= 1000 && row.every(x => typeof x === 'number')) {
    const sum = row.reduce((a, b) => a + b, 0);
    const probs = row.every(x => x >= 0 && x <= 1) && Math.abs(sum - 1) < 0.02;
    const m = Math.max(...row), ex = row.map(x => Math.exp(x - m)), z = ex.reduce((a, b) => a + b, 0);
    const p = probs ? row : ex.map(x => x / z);
    const top = p.map((v, i) => [i, v]).sort((a, b) => b[1] - a[1]).slice(0, 5);
    bars = `<div class="mb-3"><div class="d-flex align-items-baseline gap-2 mb-2"><span class="display-6">${top[0][0]}</span>
        <span class="text-body-secondary small">top class · ${(top[0][1] * 100).toFixed(1)}% sure${probs ? '' : ' (softmax of the outputs)'}</span></div>
      ${top.map(([i, v]) => `<div class="d-flex align-items-center gap-2 small mb-1"><span class="font-monospace" style="width:3rem">${i}</span>
        <div class="progress flex-grow-1" role="progressbar" aria-label="class ${i}" aria-valuenow="${(v * 100).toFixed(0)}" aria-valuemin="0" aria-valuemax="100" style="height:.75rem">
          <div class="progress-bar" style="width:${(v * 100).toFixed(1)}%"></div></div>
        <span class="font-monospace text-end" style="width:3.5rem">${(v * 100).toFixed(1)}%</span></div>`).join('')}</div>`;
  }
  return bars + (bars ? `<details><summary class="small text-body-secondary">Raw response</summary><pre class="code mt-2 mb-0">${h(JSON.stringify(r, null, 2))}</pre></details>`
                      : `<pre class="code mb-0">${h(JSON.stringify(r, null, 2))}</pre>`);
}

function playground(ep, info) {
  const t = $('#tab'), off = ep.state !== 'ready' ? 'disabled' : '';
  if (ep.runtime === 'vllm') {
    const msgs = [];
    t.innerHTML = `<div class="row g-4"><div class="col-lg-8"><div class="card"><div class="card-body">
        <div class="chat mb-3" id="log"><div class="text-body-secondary text-center my-auto small" id="hint"><i class="bi bi-chat-dots fs-3 d-block mb-2 opacity-50"></i>Send a message to start chatting.</div></div>
        <form class="input-group" id="chatf"><input class="form-control" id="say" placeholder="${off ? 'Available when the endpoint is ready' : 'Type a message…'}" autocomplete="off" aria-label="Message" ${off}>
          <button class="btn btn-primary" id="send" ${off}><i class="bi bi-send"></i></button></form></div></div></div>
      <div class="col-lg-4"><div class="card"><div class="card-body">
        <div class="eyebrow mb-3">Settings</div>
        <label class="form-label small" for="mt">Max answer length <span class="text-body-secondary">(tokens)</span></label><input class="form-control mb-3" id="mt" type="number" value="512" min="1">
        <label class="form-label small d-flex" for="temp">Creativity <span class="text-body-secondary ms-1">(temperature)</span><span class="ms-auto" id="tv">0.7</span></label>
        <input class="form-range" id="temp" type="range" min="0" max="2" step="0.1" value="0.7">
        <div class="d-flex small text-body-secondary"><span>Focused</span><span class="ms-auto">Creative</span></div>
        <button class="btn btn-sm btn-outline-secondary w-100 mt-3" id="clear" type="button"><i class="bi bi-eraser me-1"></i>New chat</button>
      </div></div></div></div>`;
    $('#temp').oninput = () => { $('#tv').textContent = $('#temp').value; };
    const draw = () => { $('#log').innerHTML = msgs.map(m => `<div class="bubble ${m.role}">${h(m.content)}</div>`).join('')
                                             || '<div class="text-body-secondary text-center my-auto small"><i class="bi bi-chat-dots fs-3 d-block mb-2 opacity-50"></i>Send a message to start chatting.</div>'; $('#log').scrollTop = 1e9; };
    $('#clear').onclick = () => { msgs.length = 0; draw(); };
    $('#chatf').onsubmit = async ev => {
      ev.preventDefault();
      const text = $('#say').value.trim(); if (!text) return;
      msgs.push({ role: 'user', content: text }); $('#say').value = ''; draw(); $('#send').disabled = true;
      $('#log').insertAdjacentHTML('beforeend', '<div class="bubble assistant" id="typing"><span class="spinner-grow spinner-grow-sm"></span></div>');
      try {
        const r = await api(`endpoints/${enc(ep.name)}/predict`, { method: 'POST',
          body: { model: ep.name, messages: msgs, max_tokens: +$('#mt').value, temperature: +$('#temp').value } });
        msgs.push({ role: 'assistant', content: r.choices?.[0]?.message?.content ?? JSON.stringify(r) });
      } catch (e) { msgs.push({ role: 'assistant', content: '⚠ ' + e.message }); }
      draw(); $('#send').disabled = false; $('#say').focus();
    };
    return;
  }
  const cols = (info?.inputs || []).filter(c => c.name);
  const num = c => /int|long|double|float/.test(c.type);
  const L = imageLayout(info);
  const form = cols.length ? `<div class="row g-3">${cols.map(c => `<div class="col-sm-6">
      <label class="form-label small mb-1">${h(c.name)} <span class="text-body-secondary">${h(c.type)}</span></label>
      ${c.type === 'boolean' ? `<select class="form-select" data-col="${h(c.name)}"><option>false</option><option>true</option></select>`
        : `<input class="form-control" data-col="${h(c.name)}" ${num(c) ? 'type="number" step="any" value="0"' : ''}>`}</div>`).join('')}</div>` : '';
  const image = L ? `<div class="d-flex flex-wrap gap-2 mb-2">
        <label class="btn btn-sm btn-outline-primary mb-0"><i class="bi bi-upload me-1"></i>Upload image<input type="file" accept="image/*" id="file" hidden></label>
        <button class="btn btn-sm btn-outline-secondary" id="clr" type="button"><i class="bi bi-eraser me-1"></i>Clear</button>
        <span class="small text-body-secondary align-self-center">or draw one below</span></div>
      <div class="row g-3 align-items-start">
        <div class="col-auto"><canvas id="pad" width="280" height="280" class="draw-pad rounded border" aria-label="Drawing area"></canvas></div>
        <div class="col small" style="min-width:11rem">
          <div class="text-body-secondary mb-1">What the model sees</div>
          <canvas id="prev" width="${L.w}" height="${L.h}" class="pixelated border rounded mb-2" style="width:84px;height:84px"></canvas>
          <div class="font-monospace mb-3">${L.c === 1 ? 'grey' : 'RGB'} ${L.h}×${L.w} · ${L.order === 'flat' ? 'flattened' : L.order.toUpperCase()}</div>
          <label class="form-label mb-1" for="scale">Pixel values</label>
          <select class="form-select form-select-sm mb-2" id="scale"><option value="01">0 – 1</option><option value="255">0 – 255</option>
            ${L.c === 3 ? '<option value="imagenet">ImageNet mean/std</option>' : ''}</select>
          <div class="form-check"><input class="form-check-input" type="checkbox" id="inv"><label class="form-check-label" for="inv">Invert colours</label></div>
          <div class="form-text">Drawing makes white on black, like MNIST. If your image is dark on white, turn on Invert.</div>
        </div></div>` : '';
  const modes = [image && ['image', 'Image'], form && ['form', 'Form'], ['json', 'JSON']].filter(Boolean);
  t.innerHTML = `<div class="row g-4"><div class="col-lg-7"><div class="card h-100"><div class="card-body">
      <div class="d-flex align-items-center mb-3"><div class="eyebrow me-auto">Input</div>
        ${modes.length > 1 ? `<div class="btn-group btn-group-sm" role="group" aria-label="Input mode">${modes.map(([v, l], i) =>
          `<input type="radio" class="btn-check" name="mode" id="m-${v}" value="${v}" ${i ? '' : 'checked'}><label class="btn btn-outline-secondary" for="m-${v}">${l}</label>`).join('')}</div>` : ''}</div>
      <div data-box="image" ${modes[0][0] === 'image' ? '' : 'hidden'}>${image}</div>
      <div data-box="form" ${modes[0][0] === 'form' ? '' : 'hidden'}>${form}</div>
      <div data-box="json" ${modes[0][0] === 'json' ? '' : 'hidden'}><textarea class="form-control font-monospace small" id="json" rows="12">${h(JSON.stringify(exampleBody(ep, info), null, 2))}</textarea></div>
      <button class="btn btn-primary mt-3" id="run" ${off}><i class="bi bi-play-fill me-1"></i>Run</button></div></div></div>
    <div class="col-lg-5"><div class="card h-100"><div class="card-body"><div class="eyebrow mb-3">Result</div>
      <div id="res" class="text-body-secondary small">Fill in the input and press <b>Run</b>.</div></div></div></div></div>`;
  let mode = modes[0][0];
  app.querySelectorAll('[name="mode"]').forEach(r => r.onchange = () => {
    mode = r.value; app.querySelectorAll('[data-box]').forEach(b => { b.hidden = b.dataset.box !== mode; });
  });

  let refresh = () => {};
  if (L) {
    const pad = $('#pad'), g = pad.getContext('2d');
    const blank = () => { g.fillStyle = '#000'; g.fillRect(0, 0, pad.width, pad.height); refresh(); };
    refresh = () => { const pc = $('#prev').getContext('2d'); const { preview } = canvasToTensor(pad, L, '01', $('#inv').checked);
                      pc.clearRect(0, 0, L.w, L.h); pc.drawImage(preview, 0, 0); };
    let down = false;
    const at = e => { const r = pad.getBoundingClientRect(); return [(e.clientX - r.left) * pad.width / r.width, (e.clientY - r.top) * pad.height / r.height]; };
    pad.onpointerdown = e => { down = true; pad.setPointerCapture(e.pointerId); g.beginPath(); g.moveTo(...at(e)); };
    pad.onpointermove = e => { if (!down) return; g.lineTo(...at(e)); g.strokeStyle = '#fff'; g.lineWidth = 20; g.lineCap = g.lineJoin = 'round'; g.stroke(); };
    pad.onpointerup = pad.onpointercancel = () => { down = false; refresh(); };
    $('#clr').onclick = blank;
    $('#inv').onchange = refresh;
    $('#file').onchange = () => {
      const f = $('#file').files[0]; if (!f) return;
      const img = new Image();
      img.onload = () => {                                   // fit (contain), centred, on black
        g.fillStyle = '#000'; g.fillRect(0, 0, pad.width, pad.height);
        const k = Math.min(pad.width / img.width, pad.height / img.height), w = img.width * k, hh = img.height * k;
        g.drawImage(img, (pad.width - w) / 2, (pad.height - hh) / 2, w, hh); URL.revokeObjectURL(img.src); refresh();
      };
      img.src = URL.createObjectURL(f);
    };
    blank();
  }

  $('#run').onclick = async () => {
    let body;
    try {
      if (mode === 'image') body = { inputs: canvasToTensor($('#pad'), L, $('#scale').value, $('#inv').checked).tensor };
      else if (mode === 'form') body = { dataframe_split: { columns: cols.map(c => c.name), data: [cols.map(c => {
              const el = app.querySelector(`[data-col="${CSS.escape(c.name)}"]`);
              return num(c) ? +el.value : c.type === 'boolean' ? el.value === 'true' : el.value; })] } };
      else body = JSON.parse($('#json').value);
    } catch (e) { $('#res').innerHTML = alertBox('That isn\'t valid JSON: ' + e.message); return; }
    $('#run').disabled = true; $('#res').innerHTML = '<div class="spinner-border spinner-border-sm text-primary"></div>';
    try { $('#res').innerHTML = renderOutput(await api(`endpoints/${enc(ep.name)}/predict`, { method: 'POST', body })); }
    catch (e) { $('#res').innerHTML = alertBox(e); }
    $('#run').disabled = false;
  };
}

// Everything an app (Flask, FastAPI, Streamlit, Gradio, a notebook, a script…) needs to call this endpoint, + one curl.
// Through the gateway with the user's personal key, from anywhere (laptop or cluster): the only way in.
function apiTab(ep, info) {
  const llm = ep.runtime === 'vllm';
  const body = JSON.stringify(exampleBody(ep, info));
  const big = body.length > 300;                 // e.g. an image tensor: a file beats 784 numbers on the command line
  const shape = c => c['tensor-spec'] ? `${c['tensor-spec'].dtype} ${JSON.stringify(c['tensor-spec'].shape)}` : c.type;
  const cols = list => (list || []).map(c => `<code>${h(c.name || '(tensor)')}</code> ${h(shape(c))}`).join('<br>') || '<span class="text-body-secondary">not in the model signature</span>';
  const tensor = (info?.inputs || []).some(c => c['tensor-spec']);
  const copyable = (id, v) => `<span class="d-inline-flex align-items-center gap-2"><code id="${id}" class="text-break">${h(v)}</code>
      <button class="btn btn-sm btn-link p-0" data-copy="${id}" aria-label="Copy"><i class="bi bi-clipboard"></i></button></span>`;
  const gw = ME.gateway?.url, gbase = `${gw}/${ME.user}/${ep.name}`, gurl = gbase + ep.path;
  const ca = ME.gateway?.ca ? '--cacert gateway-ca.crt ' : '';
  const gcurl = `curl ${ca}${gurl} \\\n  -H "Authorization: Bearer $MH_KEY" \\\n  -H 'Content-Type: application/json' \\\n  -d ${big ? '@input.json' : `'${body}'`}`;
  const gpy = llm ? `from openai import OpenAI          # pip install openai
import os
client = OpenAI(base_url="${gbase}/v1", api_key=os.environ["MH_KEY"]${ME.gateway?.ca ? ',\n                http_client=__import__("httpx").Client(verify="gateway-ca.crt")' : ''})
r = client.chat.completions.create(model="${ep.name}", messages=[{"role": "user", "content": "Hello"}])
print(r.choices[0].message.content)`
    : `import os, requests                 # pip install requests
r = requests.post("${gurl}", json=${big ? 'json.load(open("input.json"))' : body},
                  headers={"Authorization": "Bearer " + os.environ["MH_KEY"]}${ME.gateway?.ca ? ', verify="gateway-ca.crt"' : ''})
print(r.json())`;
  const info2 = (k, v) => `<div class="mb-3"><div class="small text-body-secondary mb-1">${k}</div><div class="small">${v}</div></div>`;
  $('#tab').innerHTML = `<div class="row g-4 align-items-start">
    <div class="col-lg-8"><div class="card"><div class="card-body p-4">
      <h2 class="h5 fw-semibold mb-1">Call it from your app</h2>
      <p class="small text-body-secondary mb-4">It's a normal web API. Call it from your laptop or the cluster, in any language or tool.
        Only you and the people you <b>share</b> it with can use it.</p>
      ${gw ? callSteps(`export MH_KEY='mh~${ME.user}~…'   # your key\n\n${gcurl}`, gpy) : alertBox('The gateway is not set up yet, so this endpoint can\'t be called from outside Model Hub. Ask your admin.', 'warning')}
    </div></div></div>
    <div class="col-lg-4"><div class="card"><div class="card-body p-4">
      <div class="eyebrow mb-3">Details</div>
      ${gw ? info2('URL', copyable('g-url', gurl)) : ''}
      ${gw && llm ? info2('Base URL <span class="text-body-secondary">(OpenAI libraries)</span>', copyable('g-base', gbase + '/v1')) : ''}
      ${llm ? info2('Model name', copyable('g-model', ep.name)) : ''}
      ${info2('Send', llm ? 'OpenAI chat format: <code>messages</code>, plus <code>max_tokens</code> if you like'
          : (tensor ? '<code>{"inputs": [ … ]}</code>, one item per input' : '<code>{"dataframe_split": …}</code> or <code>{"dataframe_records": …}</code>')
          + (big ? '<div class="mt-1"><a href="#" id="dl"><i class="bi bi-download me-1"></i>Example input.json</a></div>' : ''))}
      ${!llm ? info2('Inputs', cols(info?.inputs)) + info2('Outputs', cols(info?.outputs)) : ''}
      ${info2('You get back', llm ? 'The answer is in <code>choices[0].message.content</code>' : '<code>{"predictions": [...]}</code>, one per input')}
    </div></div></div></div>`;
  wireCopies();
  if (big) $('#dl').onclick = e => {
    e.preventDefault();
    const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(new Blob([body], { type: 'application/json' })), download: 'input.json' });
    a.click(); URL.revokeObjectURL(a.href);
  };
}

async function logsTab(ep) {
  $('#tab').innerHTML = `<div class="card"><div class="card-body">
      <div class="d-flex align-items-center mb-2"><div class="me-auto"><div class="fw-semibold">Logs</div><div class="small text-body-secondary">The last 300 lines. Useful when it won't start.</div></div>
        <button class="btn btn-sm btn-outline-secondary" id="rl"><i class="bi bi-arrow-clockwise me-1"></i>Refresh</button></div>
      <pre class="code mb-0" id="lg">…</pre></div></div>`;
  const load = async () => {
    try { $('#lg').textContent = (await api(`endpoints/${enc(ep.name)}/logs`)).logs || 'No logs yet. It may still be waiting for a GPU.'; }
    catch (e) { $('#lg').textContent = e.message; }
  };
  $('#rl').onclick = load; load();
}

// ---------- Help ----------
function renderHelp() {
  const ui = mlflowUI();
  const step = (n, icon, title, tag, body) => `<div class="accordion-item"><h2 class="accordion-header">
      <button class="accordion-button ${n ? 'collapsed' : ''} gap-2" type="button" data-bs-toggle="collapse" data-bs-target="#h${n}" aria-expanded="${!n}">
        <i class="bi bi-${icon}"></i><span class="me-auto">${title}</span>${tag ? `<span class="badge rounded-pill bg-body-secondary text-body-secondary fw-medium me-2">${tag}</span>` : ''}</button></h2>
      <div id="h${n}" class="accordion-collapse collapse ${n ? '' : 'show'}" data-bs-parent="#acc"><div class="accordion-body">${body}</div></div></div>`;
  app.innerHTML = header('Add your model', 'Register a model in MLflow and it shows up in Models. Pick your type below.') +
    `<div class="row g-4 align-items-start"><div class="col-lg-8">
    <div class="accordion mb-4" id="acc">
      ${step(0, 'graph-up', 'Classic ML: scikit-learn, XGBoost, LightGBM, CatBoost', 'CPU', codeBlock('h-ml',
`mlflow.set_experiment("my-project")
with mlflow.start_run():
    mlflow.sklearn.log_model(model, name="model", registered_model_name="churn",
                             input_example=X[:5])   # its columns become the form`, 'Add to your training script'))}
      ${step(1, 'cpu', 'Deep learning: PyTorch', 'GPU or CPU', codeBlock('h-dl',
`mlflow.pytorch.log_model(net, name="model", registered_model_name="my-net",
                         input_example=X[:2].numpy())   # required: MLflow uses it to trace the model`, 'Add to your training script'))}
      ${step(2, 'chat-dots', 'Chat model (LLM): a Hugging Face folder', 'GPU', codeBlock('h-llm',
`model-register ~/models/my-llm/v1 my-llm   # the weights stay in ~/models`, 'Run on the login node'))}
      ${step(3, 'arrow-repeat', 'Already trained? Register an existing run', '', `<p class="small">In the <a href="${h(ui)}" target="_blank" rel="noopener">MLflow UI</a>:
          open the run, go to <b>Logged models</b> or <b>Artifacts</b>, select the model, then click <b>Register model</b>. Or in Python:</p>` +
        codeBlock('h-reg', 'mlflow.register_model("runs:/<RUN_ID>/model", "my-model")'))}
      ${step(4, 'window-stack', 'Build your own app on top', '', `<p class="small mb-2"><b>Try it</b> covers the common cases: chat for LLMs,
          a form for table data, image upload or drawing for image models, and raw JSON for everything else. For more, build your own app
          (Flask, FastAPI, Streamlit, Gradio…):</p>
        <ol class="small mb-0"><li>Open your endpoint and go to <b>Use the API</b>. It has the URL and copy-paste examples.</li>
          <li>Your app can run anywhere, on your laptop or the cluster. It uses your <a href="#/key">API key</a>.</li>
          <li>To open an app running on the cluster in this browser, use <code>${h(location.origin)}/rnode/&lt;host&gt;/&lt;port&gt;/</code>.
            Make it listen on <code>0.0.0.0:&lt;port&gt;</code> with base path <code>/rnode/&lt;host&gt;/&lt;port&gt;</code>.
            Add a password: any cluster user can open <code>/rnode</code> addresses.</li></ol>`)}
    </div></div>
    <div class="col-lg-4"><div class="card"><div class="card-body p-4 small"><div class="eyebrow mb-3">Good to know</div><ul class="mb-0 ps-3 d-flex flex-column gap-2">
      <li>Train with the cluster's containers (ml-classic, pytorch-mlflow). Then your model uses the same library versions it's served with.</li>
      <li>Your jobs sign in to MLflow with <code>~/.mlflow/credentials</code>. The <a href="${h(ui)}" target="_blank" rel="noopener">MLflow UI</a> uses your cluster password.</li>
      <li>You can use up to ${ME.limits.gpus} GPU${ME.limits.gpus === 1 ? '' : 's'} at once. An endpoint runs for ${ME.limits.default_hours} hours by default
        (max ${ME.limits.max_hours}), then stops. Deploy again to restart it. Need more? Ask your admin.</li></ul></div></div></div></div>`;
  wireCopies();
}

// ---------- API key ----------
async function renderKey() {
  const top = header('API key', 'One key lets your apps use your endpoints, and the ones shared with you.');
  app.innerHTML = top + spinner();
  let k; try { k = await api('key'); } catch (e) { app.innerHTML = top + alertBox(e); return; }
  const gw = ME.gateway?.url;
  app.innerHTML = top + `
    <div class="row g-4 align-items-start"><div class="col-lg-7"><div class="card"><div class="card-body p-4">
      <div class="d-flex align-items-center gap-3 mb-4">
        <span class="kind-icon ${k.exists ? 'bg-success-subtle text-success-emphasis' : 'bg-body-secondary text-body-secondary'}"><i class="bi bi-key${k.exists ? '-fill' : ''}"></i></span>
        <div class="me-auto"><div class="fw-semibold">${k.exists ? 'Your key is active' : 'You don\'t have a key yet'}</div>
          <div class="small text-body-secondary">${k.exists ? `Created <span title="${h(when(Date.parse(k.created)))}">${ago(Date.parse(k.created))}</span>` : 'Create one to call endpoints from your code.'}</div></div></div>
      <div id="newkey"></div>
      <div class="d-flex flex-wrap gap-2">
        <button class="btn btn-primary" id="mk"><i class="bi bi-${k.exists ? 'arrow-repeat' : 'plus-lg'} me-1"></i>${k.exists ? 'Replace key' : 'Create key'}</button>
        ${k.exists ? '<button class="btn btn-outline-danger" id="rv">Revoke</button>' : ''}</div>
      <hr class="my-4">
      <ul class="small text-body-secondary mb-0 ps-3 d-flex flex-column gap-1">
        <li>You see the key <b>only once</b>, so copy it right away. We don't store it.</li>
        <li>Treat it like a password. Keep it in an environment variable, never in your code or git.</li>
        <li>Replacing or revoking a key takes effect within a minute.</li></ul>
    </div></div></div>
    <div class="col-lg-5"><div class="card"><div class="card-body p-4">
      <div class="eyebrow mb-3">How to use it</div>
      <ol class="steps small">
        <li>Save it in your terminal:<div class="mt-2"><code>export MH_KEY='mh~${h(ME.user)}~…'</code></div></li>
        ${ME.gateway?.ca ? `<li>Download the certificate once. It's the same for everyone.<div class="mt-2">${caLink('gateway-ca.crt')}</div></li>` : ''}
        <li>Open any endpoint and go to <b>Use the API</b> for ready-to-run examples.
          <div class="mt-2"><a class="btn btn-sm btn-outline-secondary" href="#/endpoints">My endpoints</a></div></li></ol>
      ${gw ? `<div class="small text-body-secondary mt-4">Gateway: <code>${h(gw)}</code></div>` : '<div class="small text-warning-emphasis mt-4">The gateway is not set up yet. Ask your admin.</div>'}
    </div></div></div></div>`;
  $('#mk').onclick = async () => {
    if (k.exists && !confirm('Replace your key? The old one stops working within a minute.')) return;
    try {
      const r = await api('key', { method: 'POST' });
      $('#newkey').innerHTML = `<div class="alert alert-success mb-4"><div class="fw-semibold mb-1"><i class="bi bi-check-circle me-1"></i>Here's your new key</div>
        <div class="small mb-2">Copy it now. You won't see it again.</div>
        <div class="input-group"><input class="form-control font-monospace" id="kv" readonly value="${h(r.key)}" aria-label="Your new key">
        <button class="btn btn-success" id="kc"><i class="bi bi-clipboard me-1"></i>Copy</button></div></div>`;
      $('#kc').onclick = () => copy(r.key);
      $('#mk').innerHTML = '<i class="bi bi-arrow-repeat me-1"></i>Replace key'; k.exists = true;
    } catch (e) { $('#newkey').innerHTML = alertBox(e); }
  };
  if (k.exists) $('#rv').onclick = async () => {
    if (!confirm('Revoke your key? Anything using it stops working within a minute.')) return;
    try { await api('key', { method: 'DELETE' }); toast('Key revoked'); renderKey(); } catch (e) { toast(e.message); }
  };
}

// ---------- routing ----------
async function route() {
  clearTimeout(timer);
  const [page, a, b] = location.hash.replace(/^#\/?/, '').split('/').map(decodeURIComponent);
  const nav = { endpoints: 'endpoints', endpoint: 'endpoints', key: 'key', help: 'help' }[page] || 'models';
  document.querySelectorAll('[data-nav]').forEach(x => {
    x.classList.toggle('active', x.dataset.nav === nav);
    x.toggleAttribute('aria-current', x.dataset.nav === nav);
  });
  if (!ME) {
    try { ME = await api('me'); } catch (e) { app.innerHTML = alertBox(e); return; }
    $('#who').innerHTML = `<span class="avatar" aria-hidden="true">${h(ME.user[0])}</span><span class="text-body-secondary">${h(ME.user)}</span>`;
    const missing = [!ME.mlflow && 'an MLflow token (<code>~/.mlflow/credentials</code>)',
                     !ME.kube && 'a cluster login (<code>~/.kube/aistack.config</code>)'].filter(Boolean);
    if (missing.length) {
      app.innerHTML = `<div class="alert alert-warning"><h2 class="h5"><i class="bi bi-person-gear me-2"></i>Your account isn't set up for Model Hub yet</h2>
        Missing ${missing.join(' and ')}. Ask the admin to run the Model Hub user setup for <b>${h(ME.user)}</b>.</div>`;
      ME = null; return;
    }
  }
  if (page === 'model' && a) return renderModel(a, b ? +b : null);
  if (page === 'endpoints') return renderEndpoints();
  if (page === 'endpoint' && a) return renderEndpoint(a);
  if (page === 'help') return renderHelp();
  if (page === 'key') return renderKey();
  return renderModels();
}
window.addEventListener('hashchange', () => { app.innerHTML = ''; route(); });
$('#yaml').addEventListener('hidden.bs.modal', () => { $('#yaml-body').innerHTML = ''; });   // its ids (x-curl…) shouldn't linger

// dark mode: Bootstrap's own data-bs-theme; remembered per browser
const setTheme = t => { document.documentElement.dataset.bsTheme = t; $('#theme').innerHTML = `<i class="bi bi-${t === 'dark' ? 'sun' : 'moon-stars'}"></i>`; };
$('#theme').onclick = () => {
  const t = document.documentElement.dataset.bsTheme === 'dark' ? 'light' : 'dark';
  setTheme(t); try { localStorage.setItem('mh-theme', t); } catch {}
};
try { setTheme(localStorage.getItem('mh-theme') || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')); } catch { setTheme('light'); }
route();

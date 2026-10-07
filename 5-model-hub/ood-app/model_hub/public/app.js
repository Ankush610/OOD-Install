// Model Hub UI (Bootstrap 5.3). Talks only to this app's backend (passenger_wsgi.py, running as the logged-in user):
//   GET api/me | api/models | api/models/<name>/<version> | api/endpoints | api/endpoints/<n>/logs | /key
//   POST api/deploy | api/endpoints/<n>/predict      DELETE api/endpoints/<n>
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
const empty = (icon, html) => `<div class="text-center text-body-secondary py-5"><i class="bi bi-${icon} display-5 d-block mb-3"></i>${html}</div>`;
const header = (title, sub = '', right = '') => `<div class="d-flex flex-wrap align-items-center gap-3 mb-4">
    <div class="me-auto"><h1 class="h3 mb-0">${title}</h1>${sub ? `<div class="text-body-secondary small mt-1">${sub}</div>` : ''}</div>${right}</div>`;
const KIND = { ML: ['graph-up', 'primary'], DL: ['cpu', 'info'], LLM: ['chat-dots', 'success'] };
const kindIcon = k => { const [i, c] = KIND[k] || ['box', 'secondary']; return `<span class="kind-icon bg-${c}-subtle text-${c}-emphasis"><i class="bi bi-${i}"></i></span>`; };
const STATE = { ready: 'success', loading: 'info', starting: 'info', queued: 'warning', failed: 'danger', stopped: 'secondary' };
const stateBadge = s => `<span class="badge rounded-pill text-bg-${STATE[s] || 'secondary'}">${h(s)}</span>`;
const when = ms => ms ? new Date(ms).toLocaleString() : '';
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
  return s <= 0 ? 'time limit reached' : `${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m left`;
}
const codeBlock = (id, text, label) => `<div class="mb-3"><div class="d-flex align-items-center mb-1"><span class="fw-semibold small me-auto">${label}</span>
    <button class="btn btn-sm btn-link text-decoration-none" data-copy="${id}"><i class="bi bi-clipboard me-1"></i>Copy</button></div>
    <pre class="code mb-0" id="${id}">${h(text)}</pre></div>`;
const wireCopies = () => app.querySelectorAll('[data-copy]').forEach(b => b.onclick = () => copy($('#' + b.dataset.copy).textContent));

// ---------- Models ----------
async function renderModels() {
  app.innerHTML = spinner('Reading your models from MLflow…');
  let list;
  try { list = await api('models'); } catch (e) { app.innerHTML = alertBox(e); return; }
  app.innerHTML = header('Models', `${list.length} registered in MLflow`,
      `<a class="btn btn-outline-primary" href="#/help"><i class="bi bi-question-circle me-1"></i>How do I add mine?</a>`) +
    `<div class="input-group mb-4" style="max-width:36rem"><span class="input-group-text"><i class="bi bi-search"></i></span>
      <input class="form-control" id="q" placeholder="Search models" aria-label="Search models"></div>
    <div class="row g-3" id="grid"></div>`;
  const draw = () => {
    const q = $('#q').value.toLowerCase();
    const rows = list.filter(m => (m.name + ' ' + m.description).toLowerCase().includes(q));
    $('#grid').innerHTML = rows.map(m => `<div class="col-md-6 col-xl-4">
        <a class="card h-100 border-0 shadow-sm text-decoration-none model-card" href="#/model/${enc(m.name)}"><div class="card-body">
          <div class="d-flex gap-3 align-items-center mb-2">${kindIcon(m.tags.path ? 'LLM' : '')}
            <div class="min-w-0"><div class="fw-semibold text-truncate">${h(m.name)}</div>
              <div class="small text-body-secondary">latest v${m.latest ?? '–'}${m.tags.path ? ' · LLM' : ''}</div></div></div>
          <p class="card-text text-body-secondary small mb-0">${h(m.description) || '<span class="fst-italic">No description</span>'}</p></div>
          <div class="card-footer bg-transparent border-0 small text-body-secondary pt-0"><i class="bi bi-clock me-1"></i>${when(m.updated)}</div></a></div>`).join('')
      || `<div class="col-12">${empty('inbox', list.length ? 'No models match your search.'
           : 'No registered models yet.<br><a href="#/help">How to register one</a>')}</div>`;
  };
  $('#q').oninput = draw; draw();
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
  const dd = (k, v) => v ? `<dt class="col-sm-3">${k}</dt><dd class="col-sm-9">${v}</dd>` : '';
  const metrics = Object.entries(info.metrics || {});
  const params = Object.entries(info.params || {});
  const libs = info.libs || [], drift = libs.filter(l => !l.ok);
  const took = run?.end && run?.start ? Math.round((run.end - run.start) / 60000) : null;
  const hw = (isML ? ['<option value="">CPU</option>'] : [!isLLM && '<option value="">CPU</option>',
    ...ME.gpu_types.flatMap(t => Array.from({ length: isLLM ? Math.max(1, ME.limits.gpus) : 1 }, (_, i) =>
      `<option value="${h(t)}" data-gpus="${i + 1}">${i + 1} GPU${i ? 's' : ''} · ${h(t.toUpperCase())}</option>`))]).filter(Boolean).join('');
  const gpuNote = `You may use ${ME.limits.gpus} GPU${ME.limits.gpus === 1 ? '' : 's'} at a time` +
    (isLLM && ME.limits.gpus > 1 ? ' (2+ GPUs split one big model, e.g. a 70B).' : '.');
  const defName = `${name}-v${info.version}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-|-$/g, '').slice(0, 42);
  const versions = Array.from({ length: latest }, (_, i) => latest - i);
  app.innerHTML = `<nav aria-label="breadcrumb"><ol class="breadcrumb small"><li class="breadcrumb-item"><a href="#/">Models</a></li>
      <li class="breadcrumb-item active" aria-current="page">${h(name)}</li></ol></nav>
    <div class="d-flex align-items-center gap-3 mb-4">${kindIcon(info.kind)}<h1 class="h3 mb-0">${h(name)}</h1>
      <span class="badge text-bg-${KIND[info.kind]?.[1] || 'secondary'}">${info.kind}</span></div>
    <div class="row g-4">
      <div class="col-lg-7"><div class="card border-0 shadow-sm h-100"><div class="card-body">
        <div class="d-flex align-items-center gap-3 mb-3"><h2 class="h5 mb-0 me-auto">Details</h2>
          <select class="form-select form-select-sm w-auto" id="ver" aria-label="Version">${versions.map(v =>
            `<option value="${v}" ${v === info.version ? 'selected' : ''}>Version ${v}${v === latest ? ' (latest)' : ''}</option>`).join('')}</select></div>
        ${info.description ? `<p class="mb-3">${h(info.description)}</p>` : ''}
        <dl class="row small mb-3">
          ${dd('Served with', isLLM ? 'vLLM (OpenAI API)' : 'MLflow serving (<code>/invocations</code>)')}
          ${isLLM ? dd('Folder', `<span class="font-monospace">${h(info.path)}</span>`) : dd('Flavor', h((info.flavors || []).join(', ')))}
          ${!isLLM && (info.inputs?.length || info.outputs?.length) ? dd('Does', `${sigLine(info.inputs) || '?'} <i class="bi bi-arrow-right mx-1"></i> ${sigLine(info.outputs) || '?'}
              <div class="text-body-secondary">Full request format: the endpoint's <b>API</b> tab.</div>`) : ''}
          ${isLLM ? dd('Model', [llm.architecture && h(llm.architecture), llm.params && `${(llm.params / 1e9).toFixed(llm.params < 1e10 ? 2 : 0)} B parameters`,
               llm.dtype && h(llm.dtype), llm.context && `${num(llm.context)} tokens context`].filter(Boolean).join(' · ')) : ''}
          ${isLLM && llm.lora_base ? dd('LoRA adapter', `on <code>${h(llm.lora_base)}</code>${llm.lora_rank ? `, rank ${h(llm.lora_rank)}` : ''}`) : ''}
          ${dd('Size', bytes(isLLM ? llm.size : info.size))}
          ${dd('Registered', `${when(info.created)}${run?.user ? ` · by <b>${h(run.user)}</b>` : ''}`)}
          ${run ? dd('Training run', `${h(run.experiment || 'experiment ' + run.experiment_id)} / ${h(run.name || run.id.slice(0, 8))}${took !== null ? ` · ${took} min` : ''}
              <a class="ms-2" href="${h(runUrl)}" target="_blank" rel="noopener">Open in MLflow <i class="bi bi-box-arrow-up-right"></i></a>`) : ''}
        </dl>
        ${isLLM && !metrics.length ? '' : '<h3 class="h6">Results</h3>'}
        ${isLLM && !metrics.length ? '' : metrics.length ? `<div class="row g-2 mb-3">${metrics.map(([k, v]) => `<div class="col-6 col-md-4"><div class="border rounded p-2 h-100">
            <div class="small text-body-secondary text-truncate" title="${h(k)}">${h(k)}</div><div class="fs-5 font-monospace">${num(v)}</div></div></div>`).join('')}</div>`
          : `<p class="small text-body-secondary">No metrics logged. Use <code>mlflow.log_metric("accuracy", acc)</code> in the training run to compare versions here.</p>`}
        ${params.length ? `<details class="mb-3"><summary class="small fw-semibold">Training settings (${params.length})</summary>
            <table class="table table-sm small mb-0 mt-2"><tbody>${params.map(([k, v]) => `<tr><td class="text-body-secondary">${h(k)}</td><td class="font-monospace text-break">${h(v)}</td></tr>`).join('')}</tbody></table></details>` : ''}
        ${isLLM ? '' : `<h3 class="h6">Libraries</h3>${!libs.length ? `<p class="small text-body-secondary mb-0">Not checked: ${info.libs ? 'none of its libraries are pinned in the serving image' : 'the model has no <code>requirements.txt</code>'}.</p>`
          : drift.length ? `<div class="alert alert-warning small py-2 mb-2"><i class="bi bi-exclamation-triangle me-1"></i>Trained with different versions than the
              serving image has: it may fail to load or give different results. Train in the cluster's containers to match.</div>`
          : `<p class="small text-success mb-2"><i class="bi bi-check-circle me-1"></i>Trained with the same versions the serving image has.</p>`}
          ${libs.length ? `<div class="d-flex flex-wrap gap-2">${libs.map(l => `<span class="badge rounded-pill ${l.ok ? 'bg-body-secondary text-body border' : 'text-bg-warning'} fw-normal"
              title="trained ${h(l.trained)}, serving ${h(l.serving)}">${l.ok ? '' : '<i class="bi bi-exclamation-triangle me-1"></i>'}${h(l.name)} ${h(l.trained)}${l.ok ? '' : ` → ${h(l.serving)}`}</span>`).join('')}</div>` : ''}`}
      </div></div></div>
      <div class="col-lg-5"><div class="card border-0 shadow-sm"><div class="card-body">
        <h2 class="h5 mb-3"><i class="bi bi-rocket-takeoff me-2"></i>Deploy as an endpoint</h2>
        ${running.map(e => `<div class="alert alert-info small py-2"><i class="bi bi-broadcast me-1"></i>Already running as
            <a href="#/endpoint/${enc(e.name)}" class="alert-link">${h(e.name)}</a> (${h(e.state)}, ${left(e.expires)}).</div>`).join('')}
        <form id="dep" novalidate>
          <div class="mb-3"><label class="form-label" for="ep">Endpoint name</label>
            <input class="form-control" id="ep" value="${h(defName)}" maxlength="42" pattern="[a-z0-9]([a-z0-9-]*[a-z0-9])?" required>
            <div class="form-text">Lowercase letters, digits and dashes.</div></div>
          <div class="mb-3"><label class="form-label" for="hw">Hardware</label>
            <select class="form-select" id="hw" ${hw ? '' : 'disabled'}>${hw || '<option>No GPU types found</option>'}</select>
            <div class="form-text">${isML ? 'Classic ML runs on CPU.' : isLLM ? 'LLMs need a GPU.' : 'PyTorch runs on GPU or CPU.'} ${gpuNote}</div></div>
          <div class="mb-3"><label class="form-label" for="hours">Run for</label>
            <div class="input-group"><input class="form-control" id="hours" type="number" min="1" max="${ME.limits.max_hours}" value="${ME.limits.default_hours}">
              <span class="input-group-text">hours</span></div>
            <div class="form-text">1 to ${ME.limits.max_hours} hours. The endpoint is a Slurm job: it waits in the queue when GPUs are busy, and stops when its time is up. Longer: ask the admin.</div></div>
          <div class="d-flex gap-2"><button class="btn btn-primary flex-grow-1" id="go" type="submit"><i class="bi bi-rocket-takeoff me-1"></i>Deploy</button>
            <button class="btn btn-outline-secondary" id="pre" type="button"><i class="bi bi-code-slash me-1"></i>Preview</button></div>
        </form><div id="out" class="mt-3"></div>
      </div></div></div>
    </div>`;
  $('#ver').onchange = () => { location.hash = `#/model/${enc(name)}/${$('#ver').value}`; };
  const body = extra => ({ model: name, version: info.version, endpoint: $('#ep').value.trim(), gpu: !!$('#hw').value,
                           gpu_type: $('#hw').value, gpus: +($('#hw').selectedOptions[0]?.dataset.gpus || 1),
                           hours: +$('#hours').value, ...extra });
  $('#pre').onclick = async () => {
    try { const r = await api('deploy', { method: 'POST', body: body({ preview: true }) });
          $('#yaml-body').textContent = JSON.stringify(r.manifest, null, 2); bootstrap.Modal.getOrCreateInstance($('#yaml')).show(); }
    catch (e) { $('#out').innerHTML = alertBox(e); }
  };
  $('#dep').onsubmit = async ev => {
    ev.preventDefault();
    if (!$('#dep').checkValidity()) { $('#dep').classList.add('was-validated'); return; }
    $('#go').disabled = true; $('#go').innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Deploying…';
    try { const r = await api('deploy', { method: 'POST', body: body() });
          toast(`Deploying ${r.endpoint}`); location.hash = `#/endpoint/${enc(r.endpoint)}`; }
    catch (e) { $('#out').innerHTML = alertBox(e); $('#go').disabled = false; $('#go').innerHTML = '<i class="bi bi-rocket-takeoff me-1"></i>Deploy'; }
  };
}

// ---------- Endpoints ----------
async function renderEndpoints() {
  if (!$('#eps')) app.innerHTML = header('My endpoints', `namespace <code>${h(ME.namespace)}</code> · refreshes every 5 s`,
      `<a class="btn btn-primary" href="#/"><i class="bi bi-plus-lg me-1"></i>Deploy a model</a>`) + `<div id="eps">${spinner()}</div>`;
  let list;
  try { list = await api('endpoints'); } catch (e) { $('#eps').innerHTML = alertBox(e); return; }
  $('#eps').innerHTML = list.length ? `<div class="card border-0 shadow-sm"><div class="list-group list-group-flush">${list.map(e => `
      <div class="list-group-item py-3"><div class="d-flex flex-wrap align-items-center gap-3">
        ${kindIcon(e.runtime === 'vllm' ? 'LLM' : '')}
        <div class="me-auto min-w-0"><div class="d-flex align-items-center gap-2"><a class="fw-semibold text-decoration-none" href="#/endpoint/${enc(e.name)}">${h(e.name)}</a>${stateBadge(e.state)}</div>
          <div class="small text-body-secondary text-truncate">${h(e.model)} · ${e.runtime === 'vllm' ? 'vLLM' : 'MLflow'} ·
            <i class="bi bi-${e.gpu ? 'gpu-card' : 'cpu'}"></i> ${e.gpu ? (e.gpu > 1 ? e.gpu + ' GPUs' : 'GPU') : 'CPU'}${e.node ? ' · ' + h(e.node) : ''} · <i class="bi bi-hourglass-split"></i> ${left(e.expires)}</div>
          ${e.why ? `<div class="small text-${STATE[e.state] === 'danger' ? 'danger' : 'body-secondary'}">${h(e.why)}</div>` : ''}</div>
        <div class="btn-group"><a class="btn btn-sm btn-outline-primary" href="#/endpoint/${enc(e.name)}"><i class="bi bi-box-arrow-up-right me-1"></i>Open</a>
          <button class="btn btn-sm btn-outline-danger" data-del="${h(e.name)}" aria-label="Delete ${h(e.name)}"><i class="bi bi-trash"></i></button></div>
      </div></div>`).join('')}</div></div>`
    : `<div class="card border-0 shadow-sm"><div class="card-body">${empty('hdd-network', 'No endpoints yet.<br><a href="#/">Pick a model and deploy it</a>')}</div></div>`;
  app.querySelectorAll('[data-del]').forEach(b => b.onclick = () => del(b.dataset.del));
  timer = setTimeout(renderEndpoints, 5000);
}
function del(name) {
  $('#confirm-body').innerHTML = `Delete <b>${h(name)}</b>? It stops answering, and its GPU/CPU go back to the cluster.`;
  const m = bootstrap.Modal.getOrCreateInstance($('#confirm'));
  $('#confirm-ok').onclick = async () => {
    m.hide();
    try { await api(`endpoints/${enc(name)}`, { method: 'DELETE' }); toast(`Deleted ${name}`);
          if (location.hash.startsWith('#/endpoint/')) location.hash = '#/endpoints'; else route(); }
    catch (e) { toast(e.message); }
  };
  m.show();
}

// ---------- One endpoint: playground, API, logs ----------
const cards = {};      // model card per models:/ URI (a version never changes)
async function renderEndpoint(name, tab = 'play') {
  if (!$('#tab')) app.innerHTML = spinner();
  let ep;
  try { ep = (await api('endpoints')).find(e => e.name === name); } catch (e) { app.innerHTML = alertBox(e); return; }
  if (!ep) { app.innerHTML = alertBox(`No endpoint called ${name}.`) + '<a href="#/endpoints">Back to endpoints</a>'; return; }
  const m = /^models:\/([^/]+)\/(\d+)$/.exec(ep.model || '');
  const info = m ? (cards[ep.model] ??= await api(`models/${enc(m[1])}/${m[2]}`).catch(() => null)) : null;
  const waiting = ep.state !== 'ready';
  app.innerHTML = `<nav aria-label="breadcrumb"><ol class="breadcrumb small"><li class="breadcrumb-item"><a href="#/endpoints">Endpoints</a></li>
      <li class="breadcrumb-item active" aria-current="page">${h(name)}</li></ol></nav>
    <div class="d-flex flex-wrap align-items-center gap-3 mb-3">${kindIcon(ep.runtime === 'vllm' ? 'LLM' : '')}
      <div class="me-auto"><div class="d-flex align-items-center gap-2"><h1 class="h3 mb-0">${h(name)}</h1>${stateBadge(ep.state)}</div>
        <div class="small text-body-secondary">${h(ep.model)} · ${ep.gpu ? (ep.gpu > 1 ? ep.gpu + ' GPUs' : 'GPU') : 'CPU'}${ep.node ? ' on ' + h(ep.node) : ''} · ${left(ep.expires)}</div></div>
      <button class="btn btn-outline-danger" id="del"><i class="bi bi-trash me-1"></i>Delete</button></div>
    ${waiting ? (ep.state === 'failed' ? alertBox(`Failed: ${ep.why}. Check the Logs tab.`)
       : alertBox(`${ep.state[0].toUpperCase() + ep.state.slice(1)}${ep.why ? ': ' + ep.why : ''}. This page refreshes by itself.`, 'warning', 'hourglass-split')) : ''}
    <ul class="nav nav-tabs mb-3">${[['play', 'Playground', 'play-circle'], ['api', 'API', 'code-square'], ['logs', 'Logs', 'terminal']].map(([k, t, i]) =>
      `<li class="nav-item"><button class="nav-link ${tab === k ? 'active' : ''}" data-tab="${k}"><i class="bi bi-${i} me-1"></i>${t}</button></li>`).join('')}</ul>
    <div id="tab"></div>`;
  $('#del').onclick = () => del(name);
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
        <span class="text-body-secondary small">predicted class · ${(top[0][1] * 100).toFixed(1)}%${probs ? '' : ' (softmax of the outputs)'}</span></div>
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
    t.innerHTML = `<div class="row g-4"><div class="col-lg-8"><div class="card border-0 shadow-sm"><div class="card-body">
        <div class="chat mb-3" id="log"><div class="text-body-secondary text-center my-auto small" id="hint">Say something to ${h(ep.name)}.</div></div>
        <form class="input-group" id="chatf"><input class="form-control" id="say" placeholder="Message" autocomplete="off" ${off}>
          <button class="btn btn-primary" id="send" ${off}><i class="bi bi-send"></i></button></form></div></div></div>
      <div class="col-lg-4"><div class="card border-0 shadow-sm"><div class="card-body">
        <h2 class="h6 mb-3">Settings</h2>
        <label class="form-label small" for="mt">Max tokens</label><input class="form-control mb-3" id="mt" type="number" value="512" min="1">
        <label class="form-label small d-flex" for="temp">Temperature <span class="ms-auto" id="tv">0.7</span></label>
        <input class="form-range" id="temp" type="range" min="0" max="2" step="0.1" value="0.7">
        <button class="btn btn-sm btn-outline-secondary w-100 mt-3" id="clear" type="button"><i class="bi bi-eraser me-1"></i>Clear chat</button>
      </div></div></div></div>`;
    $('#temp').oninput = () => { $('#tv').textContent = $('#temp').value; };
    const draw = () => { $('#log').innerHTML = msgs.map(m => `<div class="bubble ${m.role}">${h(m.content)}</div>`).join('')
                                             || '<div class="text-body-secondary text-center my-auto small">Say something.</div>'; $('#log').scrollTop = 1e9; };
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
        <span class="small text-body-secondary align-self-center">or draw below</span></div>
      <div class="row g-3 align-items-start">
        <div class="col-auto"><canvas id="pad" width="280" height="280" class="draw-pad rounded border" aria-label="Drawing area"></canvas></div>
        <div class="col small" style="min-width:11rem">
          <div class="text-body-secondary mb-1">Model gets</div>
          <canvas id="prev" width="${L.w}" height="${L.h}" class="pixelated border rounded mb-2" style="width:84px;height:84px"></canvas>
          <div class="font-monospace mb-3">${L.c === 1 ? 'grey' : 'RGB'} ${L.h}×${L.w} · ${L.order === 'flat' ? 'flattened' : L.order.toUpperCase()}</div>
          <label class="form-label mb-1" for="scale">Pixel values</label>
          <select class="form-select form-select-sm mb-2" id="scale"><option value="01">0 – 1</option><option value="255">0 – 255</option>
            ${L.c === 3 ? '<option value="imagenet">ImageNet mean/std</option>' : ''}</select>
          <div class="form-check"><input class="form-check-input" type="checkbox" id="inv"><label class="form-check-label" for="inv">Invert colours</label></div>
          <div class="form-text">MNIST-style models want a white digit on black: drawing does that; for a dark digit on white paper, tick Invert.</div>
        </div></div>` : '';
  const modes = [image && ['image', 'Image'], form && ['form', 'Form'], ['json', 'JSON']].filter(Boolean);
  t.innerHTML = `<div class="row g-4"><div class="col-lg-7"><div class="card border-0 shadow-sm h-100"><div class="card-body">
      <div class="d-flex align-items-center mb-3"><h2 class="h6 mb-0 me-auto">Input</h2>
        ${modes.length > 1 ? `<div class="btn-group btn-group-sm" role="group" aria-label="Input mode">${modes.map(([v, l], i) =>
          `<input type="radio" class="btn-check" name="mode" id="m-${v}" value="${v}" ${i ? '' : 'checked'}><label class="btn btn-outline-secondary" for="m-${v}">${l}</label>`).join('')}</div>` : ''}</div>
      <div data-box="image" ${modes[0][0] === 'image' ? '' : 'hidden'}>${image}</div>
      <div data-box="form" ${modes[0][0] === 'form' ? '' : 'hidden'}>${form}</div>
      <div data-box="json" ${modes[0][0] === 'json' ? '' : 'hidden'}><textarea class="form-control font-monospace small" id="json" rows="12">${h(JSON.stringify(exampleBody(ep, info), null, 2))}</textarea></div>
      <button class="btn btn-primary mt-3" id="run" ${off}><i class="bi bi-play-fill me-1"></i>Predict</button></div></div></div>
    <div class="col-lg-5"><div class="card border-0 shadow-sm h-100"><div class="card-body"><h2 class="h6 mb-3">Output</h2>
      <div id="res" class="text-body-secondary small">Press Predict.</div></div></div></div></div>`;
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
    } catch (e) { $('#res').innerHTML = alertBox('Invalid JSON: ' + e.message); return; }
    $('#run').disabled = true; $('#res').innerHTML = '<div class="spinner-border spinner-border-sm text-primary"></div>';
    try { $('#res').innerHTML = renderOutput(await api(`endpoints/${enc(ep.name)}/predict`, { method: 'POST', body })); }
    catch (e) { $('#res').innerHTML = alertBox(e); }
    $('#run').disabled = false;
  };
}

// Everything an app (Flask, FastAPI, Streamlit, Gradio, a notebook, a script…) needs to call this endpoint, + one curl.
// From anywhere: the gateway + the user's personal key. Inside the cluster also: the endpoint's ClusterIP.
function apiTab(ep, info) {
  const llm = ep.runtime === 'vllm', ip = ep.ip || '<cluster-ip>';
  const base = `http://${ip}:8080`, url = base + ep.path;
  const body = JSON.stringify(exampleBody(ep, info));
  const big = body.length > 300;                 // e.g. an image tensor: a file beats 784 numbers on the command line
  const shape = c => c['tensor-spec'] ? `${c['tensor-spec'].dtype} ${JSON.stringify(c['tensor-spec'].shape)}` : c.type;
  const cols = list => (list || []).map(c => `<code>${h(c.name || '(tensor)')}</code> ${h(shape(c))}`).join('<br>') || '<span class="text-body-secondary">not in the model signature</span>';
  const tensor = (info?.inputs || []).some(c => c['tensor-spec']);
  const row = (k, v) => `<tr><th class="text-nowrap fw-semibold pe-4" style="width:1%">${k}</th><td>${v}</td></tr>`;
  const copyable = (id, v) => `<span class="d-inline-flex align-items-center gap-2"><code id="${id}" class="text-break">${h(v)}</code>
      <button class="btn btn-sm btn-link p-0" data-copy="${id}" aria-label="Copy"><i class="bi bi-clipboard"></i></button></span>`;
  const table = rows => `<table class="table table-sm align-middle small mb-3"><tbody>${rows.filter(Boolean).join('')}</tbody></table>`;
  const curl = `curl ${url} \\\n  -H 'Content-Type: application/json' \\\n${llm ? '  -H "Authorization: Bearer $KEY" \\\n' : ''}  -d ${big ? '@input.json' : `'${body}'`}`;
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
  $('#tab').innerHTML = `<div class="card border-0 shadow-sm"><div class="card-body">
      <p class="text-body-secondary small">A plain HTTP JSON API: use it from any app or tool (Flask, FastAPI, Streamlit, Gradio, a notebook, a script).</p>
      ${gw ? `<h2 class="h6"><i class="bi bi-globe2 me-1"></i>From anywhere: your laptop or the cluster</h2>
      <p class="small text-body-secondary mb-2">Through the gateway, with your personal API key (<a href="#/key">My API key</a>).
        Put it in an environment variable: <code>export MH_KEY=mh~…</code>. Only you can call your endpoints.</p>
      ${table([
        row('URL', copyable('g-url', gurl)),
        llm && row('Base URL', `${copyable('g-base', gbase + '/v1')} <span class="text-body-secondary">for OpenAI client libraries (api_key = your key, model = <code>${h(ep.name)}</code>)</span>`),
        row('Header', '<code>Authorization: Bearer $MH_KEY</code>'),
        ME.gateway?.ca && row('Certificate', 'Self-signed: download <a href="api/gateway-ca" download="gateway-ca.crt"><i class="bi bi-download me-1"></i>gateway-ca.crt</a> once and pass it as shown (or your browser/OS can trust it).'),
      ])}
      ${codeBlock('g-curl', gcurl, 'Example (curl)')}
      ${codeBlock('g-py', gpy, 'Example (Python)')}` : ''}

      <h2 class="h6 mt-4"><i class="bi bi-hdd-network me-1"></i>Directly, inside the cluster</h2>
      <p class="small text-body-secondary mb-2">Jobs, VS Code sessions and apps on the cluster can also call the endpoint's own address (changes when it is redeployed).</p>
      ${table([
        row('URL', copyable('a-url', url)),
        llm && row('Base URL', `${copyable('a-base', base + '/v1')} <span class="text-body-secondary">for OpenAI client libraries</span>`),
        llm && row('API key', `<div class="input-group input-group-sm" style="max-width:32rem"><input class="form-control font-monospace" id="keyval" type="password" placeholder="hidden" readonly>
            <button class="btn btn-outline-secondary" id="key"><i class="bi bi-eye me-1"></i>Show</button>
            <button class="btn btn-outline-secondary" id="keycopy" aria-label="Copy key"><i class="bi bi-clipboard"></i></button></div>
            <div class="text-body-secondary mt-1">Header <code>Authorization: Bearer &lt;key&gt;</code>. Keep it private: put it in an environment variable, not in your code.</div>`),
        llm && row('Model name', copyable('a-model', ep.name)),
        row('Method', 'POST, header <code>Content-Type: application/json</code>'),
        llm ? row('Request body', `OpenAI chat format: <code>{"model": "${h(ep.name)}", "messages": [{"role": "user", "content": "…"}], "max_tokens": 256}</code>`)
            : row('Request body', (tensor ? '<code>{"inputs": [ … ]}</code>: a list of inputs, each in the input shape below (without the first -1)'
            : '<code>{"dataframe_split": {"columns": [...], "data": [[...], ...]}}</code> or <code>{"dataframe_records": [{"col": value, ...}]}</code>')
            + (big ? '<br><a href="#" id="dl"><i class="bi bi-download me-1"></i>Download an example input.json</a>' : '')),
        !llm && row('Inputs', cols(info?.inputs)),
        !llm && row('Outputs', cols(info?.outputs)),
        row('Response', llm ? 'OpenAI chat completion: the answer is in <code>choices[0].message.content</code>'
            : '<code>{"predictions": [...]}</code>, one entry per input'),
        row('Health check', `<code>GET ${h(base)}${llm ? '/health' : '/ping'}</code>: 200 when ready`),
      ])}
      ${codeBlock('c-curl', curl, 'Example (curl)')}</div></div>`;
  wireCopies();
  if (big) $('#dl').onclick = e => {
    e.preventDefault();
    const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(new Blob([body], { type: 'application/json' })), download: 'input.json' });
    a.click(); URL.revokeObjectURL(a.href);
  };
  if (llm) {
    const load = async () => $('#keyval').value || ($('#keyval').value = (await api(`endpoints/${enc(ep.name)}/key`)).key);
    $('#key').onclick = async () => { try { await load(); $('#keyval').type = $('#keyval').type === 'password' ? 'text' : 'password'; } catch (e) { toast(e.message); } };
    $('#keycopy').onclick = async () => { try { copy(await load()); } catch (e) { toast(e.message); } };
  }
}

async function logsTab(ep) {
  $('#tab').innerHTML = `<div class="card border-0 shadow-sm"><div class="card-body">
      <div class="d-flex align-items-center mb-2"><h2 class="h6 mb-0 me-auto">Last 300 lines</h2>
        <button class="btn btn-sm btn-outline-secondary" id="rl"><i class="bi bi-arrow-clockwise me-1"></i>Refresh</button></div>
      <pre class="code mb-0" id="lg">…</pre></div></div>`;
  const load = async () => {
    try { $('#lg').textContent = (await api(`endpoints/${enc(ep.name)}/logs`)).logs || '(no logs yet: the pod may still be waiting for Slurm)'; }
    catch (e) { $('#lg').textContent = e.message; }
  };
  $('#rl').onclick = load; load();
}

// ---------- Help ----------
function renderHelp() {
  const ui = mlflowUI();
  const step = (n, icon, title, body) => `<div class="accordion-item"><h2 class="accordion-header">
      <button class="accordion-button ${n ? 'collapsed' : ''}" type="button" data-bs-toggle="collapse" data-bs-target="#h${n}" aria-expanded="${!n}">
        <i class="bi bi-${icon} me-2"></i>${title}</button></h2>
      <div id="h${n}" class="accordion-collapse collapse ${n ? '' : 'show'}" data-bs-parent="#acc"><div class="accordion-body">${body}</div></div></div>`;
  app.innerHTML = header('How to get your model here', 'Model Hub lists the models you <b>registered</b> in MLflow. A run that only logged metrics does not show up.') +
    `<div class="accordion shadow-sm mb-4" id="acc">
      ${step(0, 'graph-up', 'Classic ML (sklearn, XGBoost, LightGBM, CatBoost) · CPU', codeBlock('h-ml',
`mlflow.set_experiment("my-project")
with mlflow.start_run():
    mlflow.sklearn.log_model(model, name="model", registered_model_name="churn",
                             input_example=X[:5])   # its columns become the playground form`, 'In your training script'))}
      ${step(1, 'cpu', 'Deep learning (PyTorch) · GPU or CPU', codeBlock('h-dl',
`mlflow.pytorch.log_model(net, name="model", registered_model_name="my-net",
                         input_example=X[:2].numpy())   # required: MLflow 3 traces the model with it`, 'In your training script'))}
      ${step(2, 'chat-dots', 'LLM (Hugging Face folder) · GPU', codeBlock('h-llm',
`model-register ~/models/my-llm/v1 my-llm   # weights stay in ~/models; MLflow keeps the path`, 'On master'))}
      ${step(3, 'arrow-repeat', 'Already trained? Register an existing run', `<p class="small">In the <a href="${h(ui)}" target="_blank" rel="noopener">MLflow UI</a>:
          open the run → <b>Logged models</b> / <b>Artifacts</b> → select the model → <b>Register model</b>. Or in Python:</p>` +
        codeBlock('h-reg', 'mlflow.register_model("runs:/<RUN_ID>/model", "my-model")', 'Python'))}
      ${step(4, 'window-stack', 'Build your own app on the endpoint', `<p class="small mb-2">The playground covers the
          common cases: <b>JSON</b> always, a <b>form</b> for table models, <b>image</b> upload/draw for image tensors, <b>chat</b> for LLMs.
          For anything else write your own app in any tool (Flask, FastAPI, Streamlit, Gradio…):</p>
        <ol class="small mb-0"><li>Open your endpoint → <b>API</b> tab: URL, headers, request/response format and a curl example.</li>
          <li>Your app can run <b>anywhere</b>, your computer or the cluster: it calls the gateway address from the API tab
            with your personal key (<a href="#/key">My API key</a>).</li>
          <li>An app on the cluster opens in this browser through OOD: <code>${h(location.origin)}/rnode/&lt;host&gt;/&lt;port&gt;/</code>, listening on
            <code>0.0.0.0:&lt;port&gt;</code> with its base path set to <code>/rnode/&lt;host&gt;/&lt;port&gt;</code>. Give it a password:
            every OOD user can open any <code>/rnode</code> address.</li></ol>`)}
    </div>
    <div class="card border-0 shadow-sm"><div class="card-body small"><h2 class="h6">Good to know</h2><ul class="mb-0">
      <li>Train with the cluster's containers (ml-classic, pytorch-mlflow): the serving images use the same library versions.</li>
      <li>Jobs log in to MLflow with the token in <code>~/.mlflow/credentials</code>; the <a href="${h(ui)}" target="_blank" rel="noopener">MLflow UI</a> uses your cluster password.</li>
      <li>You may use ${ME.limits.gpus} GPU${ME.limits.gpus === 1 ? '' : 's'} at a time. Endpoints stop after their hours (default ${ME.limits.default_hours}, max ${ME.limits.max_hours}); deploy again to restart. The admin can give you more.</li></ul></div></div>`;
  wireCopies();
}

// ---------- routing ----------
async function renderKey() {
  app.innerHTML = header('My API key', 'One key for all your endpoints, from anywhere.') + spinner();
  let k; try { k = await api('key'); } catch (e) { app.innerHTML = header('My API key') + alertBox(e); return; }
  const gw = ME.gateway?.url;
  app.innerHTML = header('My API key', 'One key for all your endpoints, from anywhere.') + `
    <div class="row g-4"><div class="col-lg-7"><div class="card border-0 shadow-sm"><div class="card-body">
      <p>${k.exists ? `<i class="bi bi-key-fill text-success me-1"></i>You have a key, made ${h(new Date(k.created).toLocaleString())}.`
                    : '<i class="bi bi-key me-1"></i>You have no key yet.'}</p>
      <div id="newkey"></div>
      <div class="d-flex gap-2">
        <button class="btn btn-primary" id="mk"><i class="bi bi-plus-lg me-1"></i>${k.exists ? 'Make a new key' : 'Make my key'}</button>
        ${k.exists ? '<button class="btn btn-outline-danger" id="rv"><i class="bi bi-x-lg me-1"></i>Revoke</button>' : ''}</div>
      <p class="small text-body-secondary mt-3 mb-0">The key is shown <b>once</b>; only a fingerprint of it is stored. A new key replaces the
        old one, and revoking stops it; both take effect within a minute. Treat it like a password: keep it in an
        environment variable (<code>export MH_KEY=…</code>), never in code or git.</p>
    </div></div></div>
    <div class="col-lg-5"><div class="card border-0 shadow-sm"><div class="card-body small">
      <h2 class="h6">Using it</h2>
      <p>Gateway: <code>${h(gw || 'not installed yet')}</code></p>
      <p>Call <code>${h(gw || '')}/${h(ME.user)}/&lt;endpoint&gt;/…</code> with the header <code>Authorization: Bearer $MH_KEY</code>.
        Each endpoint's <b>API</b> tab has ready-made examples.</p>
      ${ME.gateway?.ca ? `<p class="mb-0">The gateway uses a self-signed certificate. Download it once:
        <a href="api/gateway-ca" download="gateway-ca.crt"><i class="bi bi-download me-1"></i>gateway-ca.crt</a>, then <code>curl --cacert gateway-ca.crt …</code></p>` : ''}
    </div></div></div></div>`;
  $('#mk').onclick = async () => {
    if (k.exists && !confirm('Make a new key? The old one stops working within a minute.')) return;
    try {
      const r = await api('key', { method: 'POST' });
      $('#newkey').innerHTML = `<div class="alert alert-success"><b>Your new key</b>, copy it now: it won't be shown again.
        <div class="input-group input-group-sm mt-2"><input class="form-control font-monospace" id="kv" readonly value="${h(r.key)}">
        <button class="btn btn-outline-secondary" id="kc"><i class="bi bi-clipboard me-1"></i>Copy</button></div>
        <div class="mt-2"><code>export MH_KEY='${h(r.key)}'</code></div></div>`;
      $('#kc').onclick = () => copy(r.key);
      $('#mk').innerHTML = '<i class="bi bi-plus-lg me-1"></i>Make a new key'; k.exists = true;
    } catch (e) { $('#newkey').innerHTML = alertBox(e); }
  };
  if (k.exists) $('#rv').onclick = async () => {
    if (!confirm('Revoke your key? Scripts using it stop working within a minute.')) return;
    try { await api('key', { method: 'DELETE' }); toast('Key revoked'); renderKey(); } catch (e) { toast(e.message); }
  };
}

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
    $('#who').innerHTML = `<i class="bi bi-person me-1"></i>${h(ME.user)}`;
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

// dark mode: Bootstrap's own data-bs-theme; remembered per browser
const setTheme = t => { document.documentElement.dataset.bsTheme = t; $('#theme').innerHTML = `<i class="bi bi-${t === 'dark' ? 'sun' : 'moon-stars'}"></i>`; };
$('#theme').onclick = () => {
  const t = document.documentElement.dataset.bsTheme === 'dark' ? 'light' : 'dark';
  setTheme(t); try { localStorage.setItem('mh-theme', t); } catch {}
};
try { setTheme(localStorage.getItem('mh-theme') || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')); } catch { setTheme('light'); }
route();

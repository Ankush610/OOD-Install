// Admin page (Bootstrap 5.3, Model Hub's look). Talks only to this app's backend (passenger_wsgi.py), which runs every
// read and change through the root helper (sudo aistack-admin):
//   GET  api/me | api/jobs | api/endpoints | api/users | api/teams | api/log
//   POST api/users {name,password} | api/users/<u>/remove {delete_home,delete_mlflow} | api/users/<u>/password {password}
//        api/users/<u>/limits {gpus,max_hours}|{reset} | api/teams {name} | api/teams/<t>/members {add,remove}
//        api/endpoints/<owner>/<name>/stop {reason} | api/jobs/<id>/cancel {reason}  DELETE api/teams/<t>
// Routes: #/ (running)  #/users  #/teams  #/log
'use strict';
const $ = s => document.querySelector(s);
const app = $('#app');
const h = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const enc = encodeURIComponent;
const NAME = /^[a-z_][a-z0-9_-]{0,31}$/, TEAM = /^[a-z_][a-z0-9_.-]{0,31}$/;   // = the scripts' rules
let timer = null;

async function api(path, opts = {}) {
  const r = await fetch('api/' + path, {
    method: opts.method || 'GET', headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  // signed out (Keycloak back-channel logout): OOD answers background calls with 401; reload goes to the login page
  if (r.status === 401 || (r.redirected && r.url.includes('/protocol/openid-connect/'))) { location.reload(); return new Promise(() => {}); }
  const data = await r.json().catch(() => ({ error: `HTTP ${r.status}` }));
  if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
  return data;
}

// ---------- small UI helpers (same as Model Hub's) ----------
const toast = msg => { $('#toast-body').textContent = msg; bootstrap.Toast.getOrCreateInstance($('#toast'), { delay: 3500 }).show(); };
const spinner = (msg = 'Loading…') => `<div class="text-center text-body-secondary py-5">
    <div class="spinner-border text-primary mb-3" role="status"></div><div>${h(msg)}</div></div>`;
const alertBox = (e, kind = 'danger', icon = 'exclamation-triangle') =>
  `<div class="alert alert-${kind} d-flex gap-2 align-items-start" role="alert"><i class="bi bi-${icon} mt-1"></i><div>${h(e.message || e)}</div></div>`;
const empty = (icon, title, html = '') => `<div class="text-center text-body-secondary py-5 px-3"><i class="bi bi-${icon} fs-1 d-block mb-2 opacity-50"></i>
    <div class="fw-semibold text-body mb-1">${title}</div>${html}</div>`;
const header = (title, sub = '', right = '') => `<div class="d-flex flex-wrap align-items-end gap-3 mb-4">
    <div class="me-auto"><h1 class="h3 fw-semibold mb-1">${title}</h1>${sub ? `<div class="text-body-secondary">${sub}</div>` : ''}</div>${right}</div>`;
const STATE = { running: ['success', 'Running'], loading: ['info', 'Starting'], queued: ['warning', 'Waiting for GPU'],
                stopped: ['secondary', 'Stopped'], failed: ['danger', 'Failed'] };
const stateBadge = s => { const [c, t] = STATE[s] || ['secondary', s];
  return `<span class="status bg-${c}-subtle text-${c}-emphasis ${['loading', 'queued'].includes(s) ? 'pulse' : ''}">${h(t)}</span>`; };
const ago = iso => {
  if (!iso) return '';
  const s = (Date.parse(iso) - Date.now()) / 1000, rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
  for (const [u, n] of [['day', 86400], ['hour', 3600], ['minute', 60]]) if (Math.abs(s) >= n) return rtf.format(Math.round(s / n), u);
  return 'just now';
};
const when = iso => iso ? `<span title="${h(new Date(iso).toLocaleString())}">${h(ago(iso))}</span>` : '<span class="text-body-secondary">–</span>';
const modelLabel = m => { const x = /^models:\/(.+)\/(\d+)$/.exec(m || ''); return x ? `${h(x[1])} · v${x[2]}` : h((m || '').split('/').pop()); };
const output = s => s ? `<pre class="output mb-0">${h(s.trim())}</pre>` : '';
const randomPassword = () => { const a = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789', b = new Uint32Array(14);
  crypto.getRandomValues(b); return Array.from(b, x => a[x % a.length]).join(''); };

// ---------- the one dialog: a form, a button; on success it shows what the script printed ----------
const dlg = bootstrap.Modal.getOrCreateInstance($('#dlg'));
function dialog({ title, body, ok, okClass = 'btn-primary', run, check = () => '' }) {
  $('#dlg-title').textContent = title;
  $('#dlg-body').innerHTML = body + '<div id="dlg-msg" class="mt-3"></div>';
  const btn = $('#dlg-ok'), form = $('#dlg-form');
  btn.className = `btn ${okClass}`; btn.innerHTML = ok; btn.disabled = false; $('#dlg-cancel').hidden = false;
  form.onsubmit = async ev => {
    ev.preventDefault();
    if (btn.dataset.done) { dlg.hide(); return; }
    const f = Object.fromEntries(new FormData(form)), problem = check(f, form);
    if (problem) { $('#dlg-msg').innerHTML = alertBox(problem, 'warning'); return; }
    btn.disabled = true; btn.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>Working…';
    $('#dlg-msg').innerHTML = '<div class="small text-body-secondary">Adding or removing someone can take a minute.</div>';
    try {
      const res = await run(f, form);
      $('#dlg-body').innerHTML = alertBox('Done.', 'success', 'check-circle') + output(res && res.output);
      btn.dataset.done = '1'; btn.className = 'btn btn-primary'; btn.textContent = 'Close'; btn.disabled = false;
      $('#dlg-cancel').hidden = true;
      route(false);                                    // the page behind shows the change
    } catch (e) {
      btn.disabled = false; btn.innerHTML = ok; $('#dlg-msg').innerHTML = alertBox(e) ;
    }
  };
  delete btn.dataset.done;
  dlg.show();
  setTimeout(() => form.querySelector('input:not([type=checkbox]),select,textarea')?.focus(), 300);
}
const field = (name, label, attrs = '', help = '') => `<div class="mb-3"><label class="form-label" for="f-${name}">${label}</label>
    <input class="form-control" id="f-${name}" name="${name}" ${attrs}>${help ? `<div class="form-text">${help}</div>` : ''}</div>`;
const passwordField = () => `<div class="mb-3"><label class="form-label" for="f-password">One-time password</label>
    <div class="input-group"><input class="form-control font-monospace" id="f-password" name="password" type="text" autocomplete="off" minlength="8" required>
    <button class="btn btn-outline-secondary" type="button" onclick="document.getElementById('f-password').value = randomPassword()">
    <i class="bi bi-shuffle me-1"></i>Generate</button></div>
    <div class="form-text">8+ characters. Give it to them; at their first web login they must choose their own.</div></div>`;
const pwCheck = f => (f.password || '').length < 8 ? 'The password needs 8 or more characters.' : '';
// the message the owner of a stopped session/job/endpoint gets (helper: cancel-job / stop-endpoint REASON; same 1000-character limit)
const reasonField = who => `<div class="mt-3"><label class="form-label" for="f-reason">Message to ${who}: why is it stopped?</label>
    <textarea class="form-control" id="f-reason" name="reason" rows="3" maxlength="1000" required></textarea>
    <div class="form-text">They get it under the bell in the portal's top bar (and in VS Code / Jupyter / Model Hub).</div></div>`;
const reasonCheck = f => (f.reason || '').trim() ? '' : 'Write why you stop it: the user gets this message.';

// ---------- Running: everything in Slurm (sessions, training jobs, endpoints), on which GPU, since when ----------
const KIND = { endpoint: ['hdd-network', 'primary', 'Endpoint'], session: ['window', 'info', 'Session'], job: ['cpu', 'secondary', 'Job'] };
const kindBadge = r => { const [i, c, t] = KIND[r.kind]; const label = r.kind === 'session' ? r.app : t;
  return `<span class="badge rounded-pill bg-${c}-subtle text-${c}-emphasis fw-medium"><i class="bi bi-${i} me-1"></i>${h(label)}</span>`; };
const JOBSTATE = { running: ['success', 'Running'], pending: ['warning', 'Waiting'], completing: ['info', 'Ending'] };
const jobBadge = r => { const [c, t] = JOBSTATE[r.state] || ['secondary', r.state];
  return `<span class="status bg-${c}-subtle text-${c}-emphasis ${r.state === 'pending' ? 'pulse' : ''}">${h(t)}</span>`; };
const what = r => r.kind === 'endpoint' ? `${h(r.name)}<div class="small text-body-secondary">${modelLabel(r.model)}</div>`
  : `${h(r.name)}<div class="small text-body-secondary">job ${r.id}</div>`;

async function viewRunning(first) {
  if (first) app.innerHTML = header('Running', 'Everything on the cluster now: VS Code and Jupyter sessions, training jobs, Model Hub endpoints. Refreshes every 5 s.',
    `<div class="d-flex gap-2"><select class="form-select" id="kind" aria-label="Show"><option value="">Everything</option>
      <option value="endpoint">Endpoints</option><option value="session">Sessions</option><option value="job">Jobs</option></select>
      <input class="form-control" style="max-width:14rem" id="filter" type="search" placeholder="Filter by user or name" aria-label="Filter"></div>`)
    + '<div id="eps">' + spinner() + '</div>';
  let rows;
  try { rows = await api('jobs'); } catch (e) { $('#eps').innerHTML = alertBox(e); return; }
  const q = ($('#filter')?.value || '').trim().toLowerCase(), k = $('#kind')?.value || '';
  const shown = rows.filter(r => (!k || r.kind === k) && (!q || (r.owner || '').includes(q) || (r.name || '').toLowerCase().includes(q)));
  const live = rows.filter(r => r.state === 'running'), gpus = live.flatMap(r => r.gpus.map(g => ({ g, r })));
  const nodes = {};                     // per node: the GPUs in use and by what ("who is using GPU 3 on node 2, since when")
  for (const { g, r } of gpus) { const [n, d] = g.split('/'); (nodes[n] ||= []).push({ d, r }); }
  const stat = (v, label, icon) => `<div class="col-6 col-md-3"><div class="card h-100"><div class="card-body stat">
      <div class="eyebrow mb-1"><i class="bi bi-${icon} me-1"></i>${label}</div><div class="v">${v}</div></div></div></div>`;
  $('#eps').innerHTML = `<div class="row g-3 mb-4">
      ${stat(live.length, 'Running', 'play-circle')}
      ${stat(rows.filter(r => r.state === 'pending').length, 'Waiting', 'hourglass-split')}
      ${stat(gpus.length, 'GPUs in use', 'gpu-card')}
      ${stat(new Set(live.map(r => r.owner)).size, 'Users running something', 'people')}</div>
    ${Object.keys(nodes).length ? `<div class="card mb-4"><div class="card-body"><div class="eyebrow mb-2">GPUs in use, by node</div>
      ${Object.entries(nodes).sort().map(([n, list]) => `<div class="d-flex flex-wrap align-items-center gap-2 mb-2">
        <span class="fw-semibold me-2" style="min-width:5rem"><i class="bi bi-hdd-rack me-1"></i>${h(n)}</span>
        ${list.sort((a, b) => a.d.localeCompare(b.d, undefined, { numeric: true })).map(({ d, r }) => `<div class="gpu-slot busy small">
          <div class="fw-semibold">${h(d)}</div><div>${h(r.owner)} · ${r.kind === 'session' ? h(r.app) : h(r.name)}</div>
          <div class="text-body-secondary">since ${when(r.since)}</div></div>`).join('')}
      </div>`).join('')}</div></div>` : ''}
    <div class="card">${!shown.length ? empty('cpu', q || k ? 'Nothing matches' : 'Nothing is running', q || k ? '' : 'Sessions, jobs and endpoints show up here while they run.')
      : `<div class="table-responsive"><table class="table table-hover table-admin">
      <thead><tr><th>User</th><th>Type</th><th>What</th><th>State</th><th>Where</th><th>Since</th><th>Ends</th><th></th></tr></thead><tbody>
      ${shown.map(r => `<tr>
        <td class="fw-semibold">${h(r.owner)}</td><td>${kindBadge(r)}</td><td>${what(r)}</td>
        <td>${jobBadge(r)}${r.why ? `<div class="small text-body-secondary">${h(r.why)}</div>` : ''}</td>
        <td class="small">${r.gpus.length ? r.gpus.map(h).join('<br>') : r.node ? `${h(r.node)} · CPU` : '–'}</td>
        <td class="small">${when(r.since)}</td><td class="small">${when(r.until)}</td>
        <td class="text-end"><button class="btn btn-sm btn-outline-danger" data-stop="${r.id}"><i class="bi bi-stop-circle me-1"></i>Stop</button></td></tr>`).join('')}
      </tbody></table></div>`}</div>`;
  const byId = Object.fromEntries(rows.map(r => [r.id, r]));
  $('#eps').querySelectorAll('[data-stop]').forEach(b => b.onclick = () => {
    const r = byId[b.dataset.stop], who = `<b>${h(r.owner)}</b>`;
    if (r.kind === 'endpoint') dialog({ title: `Stop ${r.name}?`, ok: '<i class="bi bi-stop-circle me-1"></i>Stop it', okClass: 'btn-danger',
      body: `<p>${who}'s endpoint <b>${h(r.name)}</b> stops now${r.gpus.length ? ' and its GPU is free for others' : ''}.</p>
        <p class="mb-0 text-body-secondary">${h(r.owner)} sees it as stopped in Model Hub and can deploy it again. Nothing is deleted.</p>`
        + reasonField(who),
      check: reasonCheck,
      run: f => api(`endpoints/${enc(r.owner)}/${enc(r.name)}/stop`, { method: 'POST', body: { reason: f.reason.trim() } }) });
    else dialog({ title: r.kind === 'session' ? `Stop ${r.owner}'s ${r.app} session?` : `Cancel job ${r.id}?`,
      ok: '<i class="bi bi-stop-circle me-1"></i>Stop it', okClass: 'btn-danger',
      body: (r.kind === 'session'
        ? `<p>${who}'s ${h(r.app)} session (job ${r.id}${r.node ? ` on ${h(r.node)}` : ''}) ends now${r.gpus.length ? ' and its GPU is free for others' : ''}.</p>
           <p class="mb-0 text-body-secondary">Anything not saved in it is lost. Their files stay; they can start a new session.</p>`
        : `<p>${who}'s job <b>${h(r.name)}</b> (${r.id}) ends now${r.gpus.length ? ` and frees ${r.gpus.length} GPU${r.gpus.length > 1 ? 's' : ''}` : ''}.</p>
           <p class="mb-0 text-body-secondary">Slurm doesn't run it again. Whatever it wrote so far stays in their files.</p>`)
        + reasonField(who),
      check: reasonCheck,
      run: f => api(`jobs/${r.id}/cancel`, { method: 'POST', body: { reason: f.reason.trim() } }) });
  });
  const f = $('#filter'); if (f && !f.oninput) f.oninput = () => viewRunning(false);
  const kd = $('#kind'); if (kd && !kd.onchange) kd.onchange = () => viewRunning(false);
  timer = setTimeout(() => viewRunning(false), 5000);
}

// ---------- Users ----------
async function viewUsers() {
  app.innerHTML = header('Users', 'Everyone with a cluster account. Changes apply everywhere: SSH, Slurm, OOD, MLflow, Model Hub.',
    `<button class="btn btn-primary" id="add"><i class="bi bi-person-plus me-1"></i>Add user</button>`) + spinner();
  $('#add').onclick = () => dialog({ title: 'Add a user', ok: '<i class="bi bi-person-plus me-1"></i>Add',
    body: field('name', 'Username', 'required autocomplete="off" spellcheck="false" maxlength="32"',
      'Lowercase letters, digits, - or _. This is their Linux name: it can\'t be changed later.') + passwordField(),
    check: f => !NAME.test(f.name || '') ? 'Usernames are lowercase letters, digits, - or _, starting with a letter.' : pwCheck(f),
    run: f => api('users', { method: 'POST', body: { name: f.name, password: f.password } }) });
  let users;
  try { users = await api('users'); } catch (e) { app.querySelector('.spinner-border').parentElement.outerHTML = alertBox(e); return; }
  app.querySelector('.spinner-border').parentElement.outerHTML = `<div class="card"><div class="table-responsive"><table class="table table-hover table-admin">
    <thead><tr><th>User</th><th>UID</th><th>Teams</th><th>GPUs</th><th>Longest run</th><th></th></tr></thead><tbody>
    ${users.map(u => `<tr><td class="fw-semibold">${h(u.name)}${u.model_hub ? '' : ' <span class="badge text-bg-warning" title="No Model Hub namespace">no Model Hub</span>'}</td>
      <td class="small text-body-secondary">${u.uid}</td>
      <td>${u.teams.map(t => `<span class="chip me-1">${h(t)}</span>`).join('') || '<span class="text-body-secondary">–</span>'}</td>
      <td>${u.gpus}</td><td>${u.max_hours} h${u.custom_limits ? ' <span class="badge bg-info-subtle text-info-emphasis" title="Not the site default">custom</span>' : ''}</td>
      <td class="text-end text-nowrap">
        <button class="btn btn-sm btn-outline-secondary" data-act="password" data-u="${h(u.name)}" title="Reset password"><i class="bi bi-key"></i><span class="d-none d-lg-inline ms-1">Password</span></button>
        <button class="btn btn-sm btn-outline-secondary" data-act="limits" data-u="${h(u.name)}" title="GPUs and run time"><i class="bi bi-sliders"></i><span class="d-none d-lg-inline ms-1">Limits</span></button>
        <button class="btn btn-sm btn-outline-danger" data-act="remove" data-u="${h(u.name)}" title="Remove"><i class="bi bi-person-x"></i><span class="d-none d-lg-inline ms-1">Remove</span></button>
      </td></tr>`).join('')}</tbody></table></div></div>`;
  const byName = Object.fromEntries(users.map(u => [u.name, u]));
  app.querySelectorAll('[data-act]').forEach(b => b.onclick = () => {
    const u = byName[b.dataset.u], n = h(u.name);
    if (b.dataset.act === 'password') dialog({ title: `New password for ${u.name}`, ok: '<i class="bi bi-key me-1"></i>Set password',
      body: `<p class="text-body-secondary">For a forgotten password. Their old one stops working at once.</p>` + passwordField(),
      check: pwCheck, run: f => api(`users/${enc(u.name)}/password`, { method: 'POST', body: { password: f.password } }) });
    if (b.dataset.act === 'limits') dialog({ title: `Limits for ${u.name}`, ok: '<i class="bi bi-check-lg me-1"></i>Save',
      body: `<div class="row g-3"><div class="col-6">${field('gpus', 'GPUs at once', `type="number" min="0" max="8" value="${u.gpus}"`)}</div>
        <div class="col-6">${field('max_hours', 'Longest run (hours)', `type="number" min="1" max="8760" value="${u.max_hours}"`)}</div></div>
        <div class="form-check"><input class="form-check-input" type="checkbox" id="f-reset" name="reset">
        <label class="form-check-label" for="f-reset">Back to the site defaults</label></div>`,
      run: f => api(`users/${enc(u.name)}/limits`, { method: 'POST', body: f.reset ? { reset: true }
        : { gpus: +f.gpus === u.gpus ? null : +f.gpus, max_hours: +f.max_hours === u.max_hours ? null : +f.max_hours } }) });
    if (b.dataset.act === 'remove') dialog({ title: `Remove ${u.name}?`, ok: '<i class="bi bi-person-x me-1"></i>Remove', okClass: 'btn-danger',
      body: `<p>Stops everything <b>${n}</b> runs (jobs, sessions, endpoints) and deletes their logins, API key, Model Hub
        space and team memberships. Their UID is never given to anyone else.</p>
        <div class="form-check"><input class="form-check-input" type="checkbox" id="f-home" name="delete_home">
          <label class="form-check-label" for="f-home">Also delete <code>/home/${n}</code> (their files and models)</label></div>
        <div class="form-check mb-3"><input class="form-check-input" type="checkbox" id="f-mlflow" name="delete_mlflow">
          <label class="form-check-label" for="f-mlflow">Also delete their MLflow experiments and models</label></div>
        ${field('confirm', `Type <b>${n}</b> to confirm`, 'required autocomplete="off" spellcheck="false"')}`,
      check: f => f.confirm !== u.name ? `Type ${u.name} exactly to confirm.` : '',
      run: f => api(`users/${enc(u.name)}/remove`, { method: 'POST', body: { delete_home: !!f.delete_home, delete_mlflow: !!f.delete_mlflow } }) });
  });
}

// ---------- Teams ----------
async function viewTeams() {
  app.innerHTML = header('Teams', 'Groups of people to share Model Hub endpoints with.',
    `<button class="btn btn-primary" id="add"><i class="bi bi-plus-lg me-1"></i>New team</button>`) + spinner();
  $('#add').onclick = () => dialog({ title: 'New team', ok: '<i class="bi bi-plus-lg me-1"></i>Create',
    body: field('name', 'Team name', 'required autocomplete="off" spellcheck="false" maxlength="32"', 'Lowercase letters, digits, . - or _.'),
    check: f => !TEAM.test(f.name || '') ? 'Team names are lowercase letters, digits, . - or _, starting with a letter.' : '',
    run: f => api('teams', { method: 'POST', body: { name: f.name } }) });
  let teams, users;
  try { [teams, users] = await Promise.all([api('teams'), api('users')]); }
  catch (e) { app.querySelector('.spinner-border').parentElement.outerHTML = alertBox(e); return; }
  const names = users.map(u => u.name);
  const entries = Object.entries(teams).sort();
  app.querySelector('.spinner-border').parentElement.outerHTML = !entries.length ? `<div class="card">${empty('diagram-3', 'No teams yet', 'Create one, then add people to it.')}</div>`
    : `<div class="row g-3">${entries.map(([t, members]) => `<div class="col-md-6 col-xl-4"><div class="card h-100"><div class="card-body">
      <div class="d-flex align-items-center mb-3"><h2 class="h5 mb-0 me-auto"><i class="bi bi-diagram-3 me-2 text-primary"></i>${h(t)}</h2>
        <button class="btn btn-sm btn-icon text-danger" data-del="${h(t)}" title="Delete team" aria-label="Delete team ${h(t)}"><i class="bi bi-trash"></i></button></div>
      <div class="d-flex flex-wrap gap-1 mb-3">${members.map(m => `<span class="chip">${h(m)}
        <button type="button" class="btn btn-link p-0 lh-1 text-body-secondary" data-rm="${h(t)}/${h(m)}" title="Remove from ${h(t)}"
        aria-label="Remove ${h(m)} from ${h(t)}"><i class="bi bi-x-lg"></i></button></span>`).join('')
        || '<span class="text-body-secondary small">No members yet</span>'}</div>
      <div class="input-group input-group-sm"><select class="form-select" data-pick="${h(t)}" aria-label="Add someone to ${h(t)}">
        <option value="">Add someone…</option>${names.filter(n => !members.includes(n)).map(n => `<option>${h(n)}</option>`).join('')}</select>
        <button class="btn btn-outline-primary" data-addto="${h(t)}"><i class="bi bi-person-plus"></i></button></div>
    </div></div></div>`).join('')}</div>`;
  const change = async (t, body, label) => {
    try { await api(`teams/${enc(t)}/members`, { method: 'POST', body }); toast(label); viewTeams(); } catch (e) { toast(e.message); }
  };
  app.querySelectorAll('[data-rm]').forEach(b => b.onclick = () => { const [t, m] = b.dataset.rm.split('/'); change(t, { remove: [m] }, `${m} left ${t}`); });
  app.querySelectorAll('[data-addto]').forEach(b => b.onclick = () => {
    const t = b.dataset.addto, m = app.querySelector(`[data-pick="${CSS.escape(t)}"]`).value;
    if (m) change(t, { add: [m] }, `${m} joined ${t}`);
  });
  app.querySelectorAll('[data-del]').forEach(b => b.onclick = () => {
    const t = b.dataset.del;
    dialog({ title: `Delete team ${t}?`, ok: '<i class="bi bi-trash me-1"></i>Delete', okClass: 'btn-danger',
      body: `<p class="mb-0">Endpoints shared with <b>${h(t)}</b> stop being shared with its members (within a minute). The people themselves aren't touched.</p>`,
      run: () => api(`teams/${enc(t)}`, { method: 'DELETE' }) });
  });
}

// ---------- Log ----------
async function viewLog() {
  app.innerHTML = header('Log', 'Every change made with the admin tools (this page or the terminal), and every refused attempt. Newest first.') + spinner();
  let rows;
  try { rows = await api('log'); } catch (e) { app.querySelector('.spinner-border').parentElement.outerHTML = alertBox(e); return; }
  app.querySelector('.spinner-border').parentElement.outerHTML = `<div class="card">${!rows.length ? empty('journal-text', 'Nothing yet')
    : `<div class="table-responsive"><table class="table table-admin">
    <thead><tr><th>When</th><th>By</th><th>Action</th><th>Result</th><th>Details</th></tr></thead><tbody>
    ${rows.map(r => `<tr><td class="small text-nowrap" title="${h(r.time)}">${h(new Date(r.time.replace(/([+-]\d\d)(\d\d)$/, '$1:$2')).toLocaleString())}</td>
      <td>${h(r.by)}</td><td><code>${h(r.action)}</code> ${h((r.args || []).join(' '))}</td>
      <td>${r.ok ? '<span class="status bg-success-subtle text-success-emphasis">Done</span>' : '<span class="status bg-danger-subtle text-danger-emphasis">Failed</span>'}</td>
      <td class="small" style="max-width:28rem">${r.detail ? `<details><summary class="text-body-secondary">output</summary>${output(r.detail)}</details>` : ''}</td></tr>`).join('')}
    </tbody></table></div>`}</div>`;
}

// ---------- routing ----------
async function route(first = true) {
  clearTimeout(timer);
  const page = (location.hash.replace(/^#\/?/, '') || 'running').split('/')[0];
  document.querySelectorAll('[data-nav]').forEach(a => a.classList.toggle('active', a.dataset.nav === page));
  if (page === 'users') return viewUsers();
  if (page === 'teams') return viewTeams();
  if (page === 'log') return viewLog();
  return viewRunning(first || !$('#eps'));
}
window.addEventListener('hashchange', () => { app.innerHTML = ''; route(); });
api('me').then(me => { $('#who').innerHTML = `<i class="bi bi-person-circle me-1"></i>Logged in as ${h(me.user)}`; route(); },
               e => { app.innerHTML = alertBox(e); });

// dark mode: Bootstrap's own data-bs-theme; shared with Model Hub's setting
const setTheme = t => { document.documentElement.dataset.bsTheme = t; $('#theme').innerHTML = `<i class="bi bi-${t === 'dark' ? 'sun' : 'moon-stars'}"></i>`; };
$('#theme').onclick = () => {
  const t = document.documentElement.dataset.bsTheme === 'dark' ? 'light' : 'dark';
  setTheme(t); try { localStorage.setItem('mh-theme', t); } catch {}
};
try { setTheme(localStorage.getItem('mh-theme') || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')); } catch { setTheme('light'); }

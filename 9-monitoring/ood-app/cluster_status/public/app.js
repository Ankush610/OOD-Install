// Cluster monitor (Bootstrap 5.3, Model Hub's look). Read-only. Talks only to this app's backend (passenger_wsgi.py):
//   GET api/status            the whole cluster (refreshed every 30 s while the tab is visible)
//   GET api/history/<node>    one node's last hour, when its detail panel opens
// Built to scale: a summary, a one-square-per-node map, a sortable/filterable table grouped by node type, and a side
// panel per node. Up to 8 nodes it starts with cards instead. Filters and the open node live in the URL
// (#type=H100&free=1, #node=cn02), so a view can be shared or bookmarked.
'use strict';
const $ = s => document.querySelector(s);
const app = $('#app');
const h = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const GiB = 1073741824, REFRESH_MS = 30000;
const gb = b => b == null ? '–' : b >= 1024 * GiB ? `${(b / 1024 / GiB).toFixed(1)} TB` : `${Math.round(b / GiB)} GB`;
const pair = (a, b) => b >= 1024 * GiB ? `${(a / 1024 / GiB).toFixed(1)}/${(b / 1024 / GiB).toFixed(1)} TB` : `${Math.round(a / GiB)}/${Math.round(b / GiB)} GB`;
const pct = r => r == null ? '–' : `${Math.round(r * 100)}%`;
const ago = iso => { const m = Math.max(1, Math.round((Date.now() - Date.parse(iso)) / 60000));
  return m < 60 ? `${m} min` : m < 1440 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${Math.floor(m / 1440)} d`; };

async function api(path) {
  const r = await fetch('api/' + path, { headers: { 'X-Requested-With': 'XMLHttpRequest' } });
  // signed out (Keycloak back-channel logout): OOD answers background calls with 401; reload goes to the login page
  if (r.status === 401 || (r.redirected && r.url.includes('/protocol/openid-connect/'))) { location.reload(); return new Promise(() => {}); }
  const data = await r.json().catch(() => ({ error: `HTTP ${r.status}` }));
  if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
  return data;
}

// ---------- what a node's numbers mean ----------
// Slurm state -> word + colour + sort rank (problems first when sorting by state). Slurm decides the word; a silent
// node_exporter only means "no live numbers" (n.up = 0), not that the node is down.
function stateOf(n) {
  const s = n.state || '';
  if (s.includes('down') || s.includes('not_responding') || s.includes('fail')) return { k: 'down', word: 'Down', c: 'danger', rank: 0 };
  if (s.includes('drain') || !n.available) return { k: 'drain', word: /^(mixed|alloc)/.test(s) ? 'Draining' : 'Drained', c: 'warning', rank: 1 };
  if (s.includes('alloc')) return { k: 'full', word: 'Full', c: 'primary', rank: 2 };
  if (s.includes('mixed')) return { k: 'partly', word: 'Partly used', c: 'info', rank: 3 };
  return { k: 'free', word: 'Free', c: 'success', rank: 4 };
}
const takesJobs = n => !['down', 'drain'].includes(stateOf(n).k);
const freeGpus = n => takesJobs(n) ? n.gpus.filter(g => !g.reserved).length : 0;
const gpuClass = (g, n) => !n.up || g.util == null || (!g.reserved && !takesJobs(n)) ? 'off'
  : !g.reserved ? '' : g.util < .1 ? 'idle' : g.util < .5 ? 'mid' : 'busy';
const gpuTitle = (g, n) => `GPU ${g.gpu} ${g.name}: ` + (!n.up || g.util == null ? 'no data'
  : g.reserved ? `reserved, ${pct(g.util)} busy${g.temp != null ? `, ${Math.round(g.temp)} °C` : ''}${g.util < .1 ? ' (reserved but idle)' : ''}`
  : takesJobs(n) ? 'free' : 'not available (node takes no new jobs)');
const gpuSquares = n => n.gpus.length ? `<span class="gpus" role="img" aria-label="${freeGpus(n)} of ${n.gpus.length} GPUs free">${n.gpus.map(g =>
  `<span class="g ${gpuClass(g, n)} ${g.temp >= 85 ? 'hot' : ''}" title="${h(gpuTitle(g, n))}"></span>`).join('')}</span>` : '<span class="sub">–</span>';
const mini = (ratio, text, c = 'primary', warn = false) => {
  const r = Math.max(0, Math.min(1, ratio || 0)), cc = warn && r > .95 ? 'danger' : warn && r > .85 ? 'warning' : c;
  return `<div class="mini"><div class="progress" role="progressbar" aria-valuenow="${Math.round(r * 100)}" aria-valuemin="0" aria-valuemax="100">
    <div class="progress-bar bg-${cc}" style="width:${r * 100}%"></div></div><span class="t">${text}</span></div>`;
};
const mapClass = n => { const s = stateOf(n).k; if (s === 'down') return 't-down'; if (s === 'drain') return 't-drain';
  const r = Math.max(n.cpus ? n.cpus_alloc / n.cpus : 0, n.gpus.length ? n.gpus.filter(g => g.reserved).length / n.gpus.length : 0);
  return r === 0 ? 't-free' : r < .5 ? 't-l1' : r < .9 ? 't-l2' : 't-l3'; };
const usersShort = n => { const u = Object.keys(n.users); return !u.length ? '<span class="sub">–</span>'
  : `<span title="${h(u.join(', '))}">${u.slice(0, 2).map(h).join(', ')}${u.length > 2 ? ` <span class="sub">+${u.length - 2}</span>` : ''}</span>`; };
const typeLabel = t => ({ CPU: 'CPU-only nodes', Login: 'Login node (editors and notebooks)', GPU: 'GPU nodes' })[t] || `${t} GPU nodes`;
const typesOf = d => [...new Set(d.nodes.map(n => n.type))].sort((a, b) => {
  const rank = t => t === 'Login' ? 3 : t === 'CPU' ? 2 : 1; return rank(a) - rank(b) || a.localeCompare(b); });

// ---------- view state (in the URL, so a filtered view can be shared or bookmarked) ----------
const ui = { q: '', type: '', state: '', free: false, view: '', group: true, sort: 'state', dir: 1, node: '', closed: new Set() };
function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  Object.assign(ui, { q: p.get('q') || '', type: p.get('type') || '', state: p.get('state') || '', free: p.get('free') === '1',
    view: p.get('view') || '', group: p.get('group') !== '0', sort: p.get('sort') || 'state', dir: p.get('dir') === '-1' ? -1 : 1, node: p.get('node') || '' });
}
function writeHash() {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries({ q: ui.q, type: ui.type, state: ui.state, free: ui.free ? '1' : '', view: ui.view,
    group: ui.group ? '' : '0', sort: ui.sort === 'state' ? '' : ui.sort, dir: ui.dir < 0 ? '-1' : '', node: openNode || '' })) if (v) p.set(k, v);
  history.replaceState(null, '', p.toString() ? `#${p}` : location.pathname + location.search);
}

const SORTS = { node: n => n.node, state: n => stateOf(n).rank, cpu: n => -(n.cpus_alloc / (n.cpus || 1)),
  mem: n => -(n.mem_alloc / (n.mem || 1)), gpu: n => -freeGpus(n), users: n => -Object.keys(n.users).length };
const nameCmp = (a, b) => a.node.localeCompare(b.node, undefined, { numeric: true });
function visible(d) {
  const q = ui.q.trim().toLowerCase(), f = SORTS[ui.sort] || SORTS.state;
  return d.nodes.filter(n => (!q || [n.node, n.slurm, n.type, n.reason, ...Object.keys(n.users)].join(' ').toLowerCase().includes(q))
      && (!ui.type || n.type === ui.type) && (!ui.state || stateOf(n).k === ui.state) && (!ui.free || freeGpus(n) > 0))
    .sort((a, b) => { const x = f(a), y = f(b); return (x < y ? -1 : x > y ? 1 : nameCmp(a, b)) * ui.dir; });
}

// ---------- page ----------
let DATA = null, ERR = null, timer = null, openNode = null;   // openNode: the node in the side panel

function render() {
  if (!DATA) { app.innerHTML = ERR ? `<div class="alert alert-danger d-flex gap-2"><i class="bi bi-exclamation-triangle mt-1"></i><div>
      <div class="fw-semibold">Cluster monitor isn't available</div>${h(ERR)}</div></div>` : `<div class="text-center text-body-secondary py-5">
      <div class="spinner-border text-primary mb-3" role="status"></div><div>Loading…</div></div>`; return; }
  const d = DATA, types = typesOf(d), list = visible(d);
  const view = ui.view || (d.nodes.length > 8 ? 'table' : 'cards');
  const counts = {}; d.nodes.forEach(n => { const k = stateOf(n).k; counts[k] = (counts[k] || 0) + 1; });
  const focused = document.activeElement?.id;
  app.innerHTML = `
    <div class="d-flex flex-wrap align-items-end gap-3 mb-3">
      <div class="me-auto"><h1 class="h3 fw-semibold mb-1">Cluster monitor</h1>
        <div class="text-body-secondary">What's free, what's busy, and who is using it.</div></div></div>
    ${ERR ? `<div class="alert alert-danger small py-2 d-flex gap-2"><i class="bi bi-wifi-off"></i><div>Couldn't refresh: ${h(ERR)}
      Showing what it said at ${h(new Date(d.taken).toLocaleTimeString())}.</div></div>` : ''}
    ${d.collectors_failing?.length ? `<div class="alert alert-secondary small py-2"><i class="bi bi-info-circle me-1"></i>Part of the
      monitoring isn't collecting (${h(d.collectors_failing.join(', '))}): some numbers may be missing.</div>` : ''}
    ${problems(d)}${kpis(d, types)}${legend(d)}${clusterMap(d, types)}
    <div class="card"><div class="card-body p-0">
      ${toolbar(d, counts, types, view, list.length)}
      ${!list.length ? `<div class="text-center text-body-secondary py-5"><i class="bi bi-funnel fs-2 d-block mb-2 opacity-50"></i>No node matches these filters.
          <div class="mt-2"><button class="btn btn-sm btn-outline-secondary" data-act="clear">Clear filters</button></div></div>`
        : view === 'table' ? table(list, types) : cards(list)}
    </div></div>`;
  wire();
  if (focused === 'q') { const q = $('#q'); q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
}

function problems(d) {
  const firing = d.alerts.filter(a => a.state === 'firing');
  if (!firing.length) return '';
  const icon = a => ({ GpuHot: 'thermometer-high', DiskAlmostFull: 'device-hdd', MemoryAlmostFull: 'memory' })[a.name] || 'exclamation-circle';
  const row = a => `<div class="d-flex gap-2 small py-1 border-top border-warning-subtle"><i class="bi bi-${icon(a)}"></i>
    <span class="me-auto">${h(a.summary)}</span>${a.since ? `<span class="text-nowrap opacity-75">for ${ago(a.since)}</span>` : ''}</div>`;
  const open = $('#more-problems')?.classList.contains('show');
  return `<div class="alert alert-warning py-2 mb-3" role="alert">
    <div class="d-flex align-items-center gap-2 py-1"><i class="bi bi-exclamation-triangle-fill"></i><span class="fw-semibold me-auto">${firing.length} problem${firing.length > 1 ? 's' : ''} right now</span>
      ${firing.length > 3 ? `<button class="btn btn-sm btn-link p-0 text-reset" data-bs-toggle="collapse" data-bs-target="#more-problems" aria-expanded="${!!open}">Show all</button>` : ''}</div>
    ${firing.slice(0, 3).map(row).join('')}
    ${firing.length > 3 ? `<div class="collapse ${open ? 'show' : ''}" id="more-problems">${firing.slice(3).map(row).join('')}</div>` : ''}</div>`;
}

function kpis(d, types) {
  const ok = d.nodes.filter(n => n.up && takesJobs(n));
  const down = d.nodes.filter(n => stateOf(n).k === 'down').length, drain = d.nodes.filter(n => stateOf(n).k === 'drain').length;
  const cpus = d.nodes.reduce((s, n) => s + (n.cpus || 0), 0), cpusRes = d.nodes.reduce((s, n) => s + (n.cpus_alloc || 0), 0);
  const gTypes = types.filter(t => d.nodes.some(n => n.type === t && n.gpus.length));
  const byType = gTypes.map(t => { const ns = d.nodes.filter(n => n.type === t);
    return `<span class="text-nowrap">${h(t)}: <b>${ns.reduce((s, n) => s + freeGpus(n), 0)}</b>/${ns.reduce((s, n) => s + n.gpus.length, 0)}</span>`; }).join(' · ');
  const gFree = d.nodes.reduce((s, n) => s + freeGpus(n), 0), gAll = d.nodes.reduce((s, n) => s + n.gpus.length, 0);
  const idle = d.nodes.reduce((s, n) => s + n.gpus.filter(g => g.reserved && g.util != null && g.util < .1).length, 0);
  const k = (icon, label, v, sub, c = '') => `<div class="col-6 col-lg"><div class="card h-100 kpi"><div class="card-body py-2 px-3">
      <div class="small text-body-secondary"><i class="bi bi-${icon} me-1"></i>${label}</div><div class="v ${c}">${v}</div><div class="split text-body-secondary">${sub}</div></div></div></div>`;
  const of = (a, b) => `${a}<span class="fs-6 fw-normal text-body-secondary"> / ${b}</span>`;
  return `<div class="row g-2 mb-3">
    ${k('hdd-network', 'Nodes working', of(ok.length, d.nodes.length), down || drain
      ? [down && `<span class="text-danger-emphasis">${down} down</span>`, drain && `<span class="text-warning-emphasis">${drain} drained</span>`].filter(Boolean).join(' · ') : 'all working')}
    ${gAll ? k('gpu-card', 'GPUs free now', of(gFree, gAll), byType, gFree ? 'text-success' : 'text-warning') : ''}
    ${k('cpu', 'CPUs reserved', pct(cpus ? cpusRes / cpus : 0), `${cpusRes.toLocaleString()} of ${cpus.toLocaleString()} cores`)}
    ${k('play-circle', 'Jobs', `${d.jobs.running}<span class="fs-6 fw-normal text-body-secondary"> running</span>`, `${d.jobs.pending} waiting in the queue`)}
    ${idle ? k('hourglass', 'Reserved but idle', idle, 'GPUs held by jobs that use < 10%', 'text-warning') : ''}
  </div>`;
}

// how to read the page: the GPU squares, and reserved vs used (right under the summary, before any node)
function legend(d) {
  const gpus = d.nodes.some(n => n.gpus.length);
  return `<div class="card mb-3"><div class="card-body py-2 px-3 d-flex flex-wrap align-items-center gap-2">
    ${gpus ? `<span class="small fw-semibold me-1">GPU squares</span><span class="legend me-lg-auto">
      <span><span class="g"></span>free</span><span><span class="g busy"></span>reserved, busy</span><span><span class="g mid"></span>reserved, partly busy</span>
      <span><span class="g idle"></span>reserved but idle</span><span><span class="g off"></span>not available / no data</span><span><span class="g busy hot"></span>too hot</span></span>` : ''}
    <span class="small text-body-secondary${gpus ? '' : ' me-auto'}"><i class="bi bi-info-circle me-1"></i><b>Reserved</b> = given to jobs by Slurm.
      <b>Used</b> = what the hardware actually does: a job can reserve 8 CPUs and use 1.</span>
  </div></div>`;
}

function clusterMap(d, types) {
  if (d.nodes.length <= 8) return '';
  return `<div class="card mb-3"><div class="card-body py-2 px-3">
    <div class="d-flex flex-wrap align-items-center gap-2 mb-2"><span class="small fw-semibold me-auto">At a glance <span class="fw-normal text-body-secondary">· one square per node</span></span>
      <span class="legend"><span><span class="tile t-free"></span>free</span><span><span class="tile t-l1"></span>&lt; half</span><span><span class="tile t-l2"></span>most</span>
        <span><span class="tile t-l3"></span>full</span><span><span class="tile t-drain"></span>drained</span><span><span class="tile t-down"></span>down</span></span></div>
    <div class="d-flex flex-wrap gap-4">${types.map(t => `<div><div class="sub mb-1">${h(t)}</div><div class="map-group">${d.nodes.filter(n => n.type === t).sort(nameCmp).map(n =>
      `<button class="tile ${mapClass(n)}" data-node="${h(n.node)}" title="${h(n.node)}: ${stateOf(n).word}${n.gpus.length ? `, ${freeGpus(n)}/${n.gpus.length} GPUs free` : ''}" aria-label="${h(n.node)}, ${stateOf(n).word}"></button>`).join('')}</div></div>`).join('')}</div>
  </div></div>`;
}

function toolbar(d, counts, types, view, shown) {
  const chip = (k, label) => `<button class="btn btn-sm ${ui.state === k ? 'btn-secondary' : 'btn-outline-secondary'}" data-state="${k}" aria-pressed="${ui.state === k}">${label}
      <span class="badge rounded-pill ${ui.state === k ? 'text-bg-light' : 'bg-body-secondary text-body'} ms-1">${k ? counts[k] || 0 : d.nodes.length}</span></button>`;
  return `<div class="d-flex flex-wrap align-items-center gap-2 p-3 border-bottom">
    <div class="input-group input-group-sm" style="max-width:16rem"><span class="input-group-text bg-body"><i class="bi bi-search"></i></span>
      <input class="form-control" id="q" type="search" placeholder="Node, user or reason" value="${h(ui.q)}" aria-label="Search nodes"></div>
    ${types.length > 1 ? `<select class="form-select form-select-sm w-auto" id="type" aria-label="Node type"><option value="">All types</option>
      ${types.map(t => `<option value="${h(t)}" ${ui.type === t ? 'selected' : ''}>${h(typeLabel(t))}</option>`).join('')}</select>` : ''}
    <div class="d-flex flex-wrap gap-1" role="group" aria-label="State">${chip('', 'All')}${chip('free', 'Free')}${chip('partly', 'Partly used')}${chip('full', 'Full')}${chip('drain', 'Drained')}${chip('down', 'Down')}</div>
    ${d.nodes.some(n => n.gpus.length) ? `<div class="form-check form-switch mb-0 ms-1"><input class="form-check-input" type="checkbox" role="switch" id="free" ${ui.free ? 'checked' : ''}>
      <label class="form-check-label small" for="free">Has a free GPU</label></div>` : ''}
    <div class="ms-auto d-flex align-items-center gap-2">
      <span class="small text-body-secondary">${shown} of ${d.nodes.length}</span>
      ${view === 'table' && types.length > 1 ? `<div class="form-check form-switch mb-0"><input class="form-check-input" type="checkbox" role="switch" id="group" ${ui.group ? 'checked' : ''}>
        <label class="form-check-label small" for="group">Group by type</label></div>` : ''}
      <div class="btn-group btn-group-sm" role="group" aria-label="View">
        <button class="btn btn-outline-secondary ${view === 'table' ? 'active' : ''}" data-view="table" title="Table" aria-pressed="${view === 'table'}"><i class="bi bi-list-ul"></i><span class="visually-hidden">Table</span></button>
        <button class="btn btn-outline-secondary ${view === 'cards' ? 'active' : ''}" data-view="cards" title="Cards" aria-pressed="${view === 'cards'}"><i class="bi bi-grid-3x2-gap"></i><span class="visually-hidden">Cards</span></button></div>
    </div></div>`;
}

function row(n) {
  const st = stateOf(n), dead = st.k === 'down';
  return `<tr class="node-row" data-node="${h(n.node)}" tabindex="0">
    <td><div class="fw-semibold">${h(n.node)}</div><div class="sub">${h(n.type)}${n.slurm !== n.node ? ` · Slurm: ${h(n.slurm)}` : ''}</div></td>
    <td><span class="status bg-${st.c}-subtle text-${st.c}-emphasis">${st.word}</span>${n.reason ? `<div class="sub text-truncate" style="max-width:11rem" title="${h(n.reason)}">${h(n.reason)}</div>` : ''}</td>
    <td>${mini(n.cpus_alloc / (n.cpus || 1), `${n.cpus_alloc}/${n.cpus}`)}<div class="sub">${dead || n.cpu_used == null ? 'no data' : `used ${pct(n.cpu_used)}`}</div></td>
    <td class="d-none d-md-table-cell">${mini(n.mem_alloc / (n.mem || 1), pair(n.mem_alloc, n.mem))}<div class="sub">${dead || n.mem_used == null ? 'no data' : `used ${pct(n.mem_used)}`}</div></td>
    <td>${gpuSquares(n)}${n.gpus.length ? `<div class="sub">${freeGpus(n)} of ${n.gpus.length} free</div>` : ''}</td>
    <td class="d-none d-lg-table-cell">${usersShort(n)}</td>
    <td class="text-end text-body-secondary"><i class="bi bi-chevron-right"></i></td></tr>`;
}

function table(list, types) {
  const th = (k, label, cls = '') => `<th class="${cls}" data-sort="${k}" aria-sort="${ui.sort === k ? (ui.dir > 0 ? 'ascending' : 'descending') : 'none'}">${label}${ui.sort === k ? ` <i class="bi bi-caret-${ui.dir > 0 ? 'down' : 'up'}-fill"></i>` : ''}</th>`;
  const grouped = ui.group && types.length > 1;
  const body = !grouped ? list.map(row).join('') : types.map(t => {
    const ns = list.filter(n => n.type === t); if (!ns.length) return '';
    const gAll = ns.reduce((s, n) => s + n.gpus.length, 0), open = !ui.closed.has(t), bad = ns.filter(n => !takesJobs(n)).length;
    return `<tr class="group-row" data-group="${h(t)}" tabindex="0" aria-expanded="${open}"><td colspan="7"><i class="bi bi-chevron-${open ? 'down' : 'right'} me-2"></i>${h(typeLabel(t))}
        <span class="fw-normal text-body-secondary ms-2">${ns.length} node${ns.length > 1 ? 's' : ''}${gAll ? ` · ${ns.reduce((s, n) => s + freeGpus(n), 0)} of ${gAll} GPUs free` : ''}${bad ? ` · ${bad} unavailable` : ''}</span></td></tr>
      ${open ? ns.map(row).join('') : ''}`; }).join('');
  return `<div class="table-responsive" style="max-height:70vh"><table class="table table-sm table-hover node-table mb-0">
    <thead><tr>${th('node', 'Node')}${th('state', 'State')}${th('cpu', 'CPU reserved')}${th('mem', 'Memory reserved', 'd-none d-md-table-cell')}${th('gpu', 'GPUs')}${th('users', 'Users', 'd-none d-lg-table-cell')}<th><span class="visually-hidden">Open</span></th></tr></thead>
    <tbody>${body}</tbody></table></div>`;
}

function cards(list) {
  return `<div class="row g-3 p-3">${list.map(n => { const st = stateOf(n), dead = st.k === 'down';
    return `<div class="col-sm-6 col-lg-4 col-xxl-3"><div class="card h-100 node-row" data-node="${h(n.node)}" tabindex="0" style="cursor:pointer"><div class="card-body d-flex flex-column gap-2">
      <div class="d-flex align-items-start gap-2"><div class="me-auto min-w-0"><div class="fw-semibold">${h(n.node)}</div>
        <div class="sub">${h(n.type)} · ${n.cpus} CPUs · ${gb(n.mem)}${n.slurm !== n.node ? ` · Slurm: ${h(n.slurm)}` : ''}</div></div>
        <span class="status bg-${st.c}-subtle text-${st.c}-emphasis">${st.word}</span></div>
      ${n.reason ? `<div class="small text-${st.c}-emphasis"><i class="bi bi-info-circle me-1"></i>${h(n.reason)}</div>` : ''}
      ${!n.up ? '<div class="small text-body-secondary">No live numbers from this node.</div>' : `<div><div class="sub">CPU reserved · used ${pct(n.cpu_used)}</div>${mini(n.cpus_alloc / (n.cpus || 1), `${n.cpus_alloc}/${n.cpus}`)}</div>
      <div><div class="sub">Memory reserved · used ${pct(n.mem_used)}</div>${mini(n.mem_alloc / (n.mem || 1), pair(n.mem_alloc, n.mem))}</div>`}
      ${n.gpus.length ? `<div><div class="sub mb-1">GPUs · ${freeGpus(n)} of ${n.gpus.length} free</div>${gpuSquares(n)}</div>` : ''}
      <div class="mt-auto pt-2 border-top small">${Object.keys(n.users).length ? `<span class="text-body-secondary">Users:</span> ${usersShort(n)}`
        : `<span class="text-body-secondary">${dead ? 'Nothing can run here now.' : 'Nothing running.'}</span>`}</div>
    </div></div></div>`; }).join('')}</div>`;
}

// ---------- one node, in the side panel ----------
function spark(series) {
  const lines = [['cpu', 'var(--bs-primary)', 'CPU'], ['gpu', 'var(--bs-success)', 'GPU']].filter(([k]) => series?.[k]?.filter(v => v != null).length > 1);
  if (!lines.length) return '<div class="small text-body-secondary">No history yet for this node.</div>';
  const path = v => v.map((y, i) => y == null ? '' : `${i && v[i - 1] != null ? 'L' : 'M'}${(i / (v.length - 1) * 100).toFixed(2)},${(46 - y * 44).toFixed(2)}`).join(' ');
  return `<svg class="spark" viewBox="0 0 100 48" preserveAspectRatio="none" role="img" aria-label="Use over the last hour">
      <line x1="0" y1="46" x2="100" y2="46" stroke="var(--bs-border-color)" vector-effect="non-scaling-stroke"/>
      ${lines.map(([k, c]) => `<path d="${path(series[k])}" fill="none" stroke="${c}" stroke-width="1.5" vector-effect="non-scaling-stroke"/>`).join('')}</svg>
    <div class="legend mt-1"><span>Last hour, % in use</span>${lines.map(([, c, l]) => `<span><span class="tile" style="background:${c};width:10px;height:10px"></span>${l}</span>`).join('')}</div>`;
}

function detail(n, hist) {
  const st = stateOf(n), dead = st.k === 'down';
  $('#detail-head').innerHTML = `<div class="d-flex align-items-center gap-2"><h2 class="h5 fw-semibold mb-0" id="detail-title">${h(n.node)}</h2>
      <span class="status bg-${st.c}-subtle text-${st.c}-emphasis">${st.word}</span></div>
    <div class="sub">${h(n.type)} · ${n.cpus} CPUs · ${gb(n.mem)}${n.gpus.length ? ` · ${n.gpus.length} × ${h(n.gpus[0].name)}` : ''}${n.slurm !== n.node ? ` · Slurm name ${h(n.slurm)}` : ''}</div>`;
  const line = (label, r, text, c, warn) => `<div class="d-flex align-items-center gap-2 small"><span class="text-body-secondary" style="width:4.5rem">${label}</span><div class="flex-grow-1">${mini(r, text, c, warn)}</div></div>`;
  const bar2 = (label, res, used, text, warn) => `<div class="mb-3"><div class="fw-semibold small mb-1">${label}</div>
      ${line('Reserved', res, text, 'primary')}${used == null ? '' : line('In use', used, pct(used), 'info', warn)}</div>`;
  const users = Object.entries(n.users).sort((a, b) => b[1] - a[1]);
  $('#detail-body').innerHTML = `
    ${n.reason ? `<div class="alert alert-${st.c} small py-2"><i class="bi bi-info-circle me-1"></i><b>${h(n.reason)}.</b> ${st.k === 'drain' ? 'Running jobs finish; Slurm sends it no new ones.' : 'Slurm sends it no new jobs.'}</div>` : ''}
    ${!n.up ? `<p class="text-body-secondary small">${dead ? 'The node doesn\'t answer' : 'Monitoring can\'t reach this node right now'}, so there are no live numbers.</p>` : `
    <div class="eyebrow mb-2">CPU and memory</div>
    ${bar2('CPU', n.cpus_alloc / (n.cpus || 1), n.cpu_used, `${n.cpus_alloc}/${n.cpus}`)}
    ${bar2('Memory', n.mem_alloc / (n.mem || 1), n.mem_used, pair(n.mem_alloc, n.mem), true)}
    <div class="mt-3" id="spark">${hist === undefined ? '<div class="small text-body-secondary"><span class="spinner-border spinner-border-sm me-1"></span>Loading the last hour…</div>'
      : hist === null ? '<div class="small text-body-secondary">Couldn\'t load the history.</div>' : spark(hist)}</div>`}
    ${n.gpus.length ? `<div class="eyebrow mt-4 mb-2">GPUs · ${freeGpus(n)} of ${n.gpus.length} free</div>
      <div class="table-responsive"><table class="table table-sm small align-middle"><thead><tr><th>#</th><th><span class="visually-hidden">Colour</span></th><th>Status</th><th>Busy</th><th>Memory</th><th class="text-end">Temp</th><th class="text-end">Power</th></tr></thead><tbody>
      ${n.gpus.map(g => `<tr><td>${h(g.gpu)}</td><td><span class="g ${gpuClass(g, n)} ${g.temp >= 85 ? 'hot' : ''} d-inline-block"></span></td>
        <td>${!n.up || g.util == null ? '<span class="text-body-secondary">no data</span>' : g.reserved ? (g.util < .1 ? '<span class="text-warning-emphasis">reserved, idle</span>' : 'reserved')
          : takesJobs(n) ? '<span class="text-success-emphasis">free</span>' : '<span class="text-body-secondary">not available</span>'}</td>
        <td>${pct(g.util)}</td><td class="font-monospace text-nowrap">${g.mem_total ? `${((g.mem_used || 0) / GiB).toFixed(1)} / ${Math.round(g.mem_total / GiB)} GB` : '–'}</td>
        <td class="text-end ${g.temp >= 85 ? 'text-danger fw-semibold' : ''}">${g.temp != null ? `${Math.round(g.temp)} °C` : '–'}</td><td class="text-end">${g.power != null ? `${Math.round(g.power)} W` : '–'}</td></tr>`).join('')}
      </tbody></table></div>` : ''}
    <div class="eyebrow mt-4 mb-2">Running here</div>
    ${users.length ? `<ul class="list-group list-group-flush small">${users.map(([u, k]) => `<li class="list-group-item px-0 d-flex"><i class="bi bi-person me-2"></i><span class="me-auto">${h(u)}</span><span class="text-body-secondary">${k} job${k > 1 ? 's' : ''}</span></li>`).join('')}</ul>`
      : `<p class="small text-body-secondary">${dead ? 'Nothing can run here now.' : 'Nothing running.'}</p>`}
    <div class="eyebrow mt-4 mb-2">Partitions</div><div>${n.partitions.map(p => `<span class="badge rounded-pill bg-body-secondary text-body fw-normal me-1">${h(p)}</span>`).join('') || '–'}</div>`;
}

const histCache = {};
async function openDetail(name) {
  const n = DATA?.nodes.find(x => x.node === name); if (!n) return;
  openNode = name; writeHash();
  detail(n, histCache[name]?.data);
  bootstrap.Offcanvas.getOrCreateInstance($('#detail')).show();
  if (histCache[name] && Date.now() - histCache[name].at < 60000) return;   // the history moves by the minute
  try { histCache[name] = { at: Date.now(), data: await api(`history/${encodeURIComponent(name)}`) }; }
  catch { histCache[name] = { at: Date.now(), data: null }; }
  if (openNode === name && $('#spark')) $('#spark').innerHTML = histCache[name].data ? spark(histCache[name].data) : '<div class="small text-body-secondary">Couldn\'t load the history.</div>';
}
$('#detail').addEventListener('hidden.bs.offcanvas', () => { openNode = null; writeHash(); });

// ---------- events ----------
function wire() {
  const set = (patch) => { Object.assign(ui, patch); writeHash(); render(); };
  $('#q').oninput = e => set({ q: e.target.value });
  if ($('#type')) $('#type').onchange = e => set({ type: e.target.value });
  if ($('#free')) $('#free').onchange = e => set({ free: e.target.checked });
  if ($('#group')) $('#group').onchange = e => set({ group: e.target.checked });
  app.querySelectorAll('[data-state]').forEach(b => b.onclick = () => set({ state: ui.state === b.dataset.state ? '' : b.dataset.state }));
  app.querySelectorAll('[data-view]').forEach(b => b.onclick = () => set({ view: b.dataset.view }));
  app.querySelectorAll('[data-sort]').forEach(t => t.onclick = () => set({ dir: ui.sort === t.dataset.sort ? -ui.dir : 1, sort: t.dataset.sort }));
  app.querySelectorAll('[data-group]').forEach(t => { const toggle = () => { const g = t.dataset.group; ui.closed.has(g) ? ui.closed.delete(g) : ui.closed.add(g); render(); };
    t.onclick = toggle; t.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } }; });
  app.querySelectorAll('[data-node]').forEach(t => { t.onclick = () => openDetail(t.dataset.node);
    t.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openDetail(t.dataset.node); } }; });
  app.querySelectorAll('[data-act=clear]').forEach(b => b.onclick = () => set({ q: '', type: '', state: '', free: false }));
}

async function load() {
  clearTimeout(timer);
  $('#refresh').classList.add('spin');
  try {
    DATA = await api('status'); ERR = null;
    $('#who').innerHTML = `<i class="bi bi-person-fill" aria-hidden="true"></i> Logged in as ${h(DATA.user)}`;
    $('#updated').textContent = `Updated ${new Date(DATA.taken).toLocaleTimeString()} · every 30 s`;
  } catch (e) { ERR = e.message; }
  $('#refresh').classList.remove('spin');
  render();
  if (openNode) { const n = DATA?.nodes.find(x => x.node === openNode); if (n) detail(n, histCache[openNode]?.data); }
  else if (ui.node && DATA) { const want = ui.node; ui.node = ''; openDetail(want); }   // #node=... on first load
  if (document.visibilityState === 'visible') timer = setTimeout(load, REFRESH_MS);   // a hidden tab doesn't poll
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') load(); else clearTimeout(timer); });
$('#refresh').onclick = load;
window.addEventListener('hashchange', () => { readHash(); render(); });

// dark mode: Bootstrap's own data-bs-theme; shared with Model Hub's setting
const setTheme = t => { document.documentElement.dataset.bsTheme = t; $('#theme').innerHTML = `<i class="bi bi-${t === 'dark' ? 'sun' : 'moon-stars'}"></i>`; };
$('#theme').onclick = () => { const t = document.documentElement.dataset.bsTheme === 'dark' ? 'light' : 'dark'; setTheme(t); try { localStorage.setItem('mh-theme', t); } catch {} };
try { setTheme(localStorage.getItem('mh-theme') || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')); } catch { setTheme('light'); }

readHash();
render();
load();

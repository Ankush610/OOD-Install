// Cluster monitor (Bootstrap 5.3, Model Hub's look). Read-only. Talks only to this app's backend (passenger_wsgi.py):
//   GET api/status            the whole cluster (refreshed every 30 s while the tab is visible)
//   GET api/history/<node>    one node's last hour, when its detail popup opens
// Two tabs. Nodes: a summary, a one-square-per-node map, a sortable/filterable table grouped by node type (cards up to
// 8 nodes), a side panel per node. Services: is every service answering (as a user calls it), the core services on
// each node, and the monitoring's own health. Problems (firing alerts) sit above both, each with "Show" and "How to fix".
// Tab, filters and the open node live in the URL (#tab=services, #type=H100&free=1, #node=cn02): shareable, bookmarkable.
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
const gpuTitle = (g, n) => `GPU ${g.gpu} ${g.name}: ` + (g.missing ? 'missing: Slurm has it, the node doesn\'t see it' : !n.up || g.util == null ? 'no data'
  : g.reserved ? `reserved, ${pct(g.util)} busy${g.temp != null ? `, ${Math.round(g.temp)} °C` : ''}${g.util < .1 ? ' (reserved but idle)' : ''}`
  : takesJobs(n) ? 'free' : 'not available (node takes no new jobs)') + (gpuIssue(g) && !g.missing ? ` (${gpuIssue(g)[1]})` : '');
const gpuRing = g => g.missing ? 'gone' : g.temp >= 85 || gpuIssue(g) ? 'hot' : '';
const gpuSquares = n => n.gpus.length ? `<span class="gpus" role="img" aria-label="${freeGpus(n)} of ${n.gpus.length} GPUs free">${n.gpus.map(g =>
  `<span class="g ${gpuClass(g, n)} ${gpuRing(g)}" title="${h(gpuTitle(g, n))}"></span>`).join('')}</span>` : '<span class="sub">–</span>';
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

// ---------- services: the names people know them by ----------
// [key, name, what it is, what breaks when it's down]. Order = the order a user meets them.
const SERVICES = [
  ['ood', 'Portal', 'Open OnDemand: apps, files and jobs in the browser', 'Nobody can open the portal'],
  ['keycloak', 'Sign-in', 'Keycloak: the portal\'s login page', 'Nobody can sign in to the portal'],
  ['ldap', 'User accounts', 'LDAP: every login, on every node', 'Nobody can log in'],
  ['mlflow', 'Experiment tracking', 'MLflow: runs, metrics and registered models', 'Runs can\'t log and models can\'t be registered'],
  ['registry', 'Container registry', 'Images for model serving and Kubernetes', 'New deployments can\'t pull their image'],
  ['gateway', 'Model API gateway', 'The one address for every deployed model', 'Deployed models can\'t be called'],
];
// systemd units (MONITOR_UNITS in site.conf); a key ending in @ matches every instance (dirsrv@aistack)
const UNITS = [
  ['slurmctld', 'Job scheduler', 'Slurm controller: queues and starts every job', 'No new jobs start'],
  ['slurmd', 'Slurm node agent', 'Runs the jobs Slurm sends to this node', 'This node takes no jobs'],
  ['slurmrestd', 'Slurm web API', 'Slurm for the portal\'s apps', 'Apps that read Slurm over REST fail'],
  ['munge', 'Slurm authentication', 'Proves who sent a Slurm request', 'Slurm commands fail on this node'],
  ['sssd', 'Account lookup', 'Users and groups from LDAP, on this node', 'Nobody can log in to this node'],
  ['dirsrv@', 'User directory', 'The LDAP server itself (389 DS)', 'Nobody can log in'],
  ['httpd', 'Portal web server', 'Apache, in front of Open OnDemand', 'The portal is unreachable'],
  ['keycloak', 'Sign-in service', 'Keycloak, behind the portal\'s login page', 'Nobody can sign in to the portal'],
  ['keycloak-db', 'Sign-in database', 'Postgres for Keycloak', 'Sign-in fails'],
  ['kubelet', 'Kubernetes node agent', 'Runs model endpoints and MLflow', 'Pods on this node are not looked after'],
  ['containerd', 'Container runtime', 'Starts containers for Kubernetes', 'Pods on this node can\'t start'],
  ['nfs-server', 'Shared home folders', 'NFS: everyone\'s /home', 'Every node loses /home and jobs hang'],
];
const unitInfo = u => UNITS.find(([k]) => k.endsWith('@') ? u.startsWith(k) : u === k) || [u, u, '', ''];
const unitRank = u => { const i = UNITS.findIndex(([k]) => k.endsWith('@') ? u.startsWith(k) : u === k); return i < 0 ? 99 : i; };
// every known service gets a row, checked or not; one the checker reports but we don't know is listed after them
function serviceRows(d) {
  const by = Object.fromEntries((d.services || []).map(s => [s.service, s]));
  const known = SERVICES.map(([k, name, what, impact]) => ({ key: k, name, what, impact, ...by[k] }));
  const extra = (d.services || []).filter(s => !SERVICES.some(([k]) => k === s.service)).map(s => ({ key: s.service, name: s.service, what: '', impact: '', ...s }));
  return [...known, ...extra].map(s => ({ ...s, state: s.ok == null ? 'none' : s.ok ? 'ok' : 'down' }));
}
const unitsDown = d => (d.units || []).filter(u => u.down.length);
const servicesDown = d => serviceRows(d).filter(s => s.state === 'down');
const runbook = (d, alert) => d.runbook_url ? `${d.runbook_url}#${alert.toLowerCase()}` : '';

// GPU and node health: [colour, words, the alert that explains it]
const gpuIssue = g => g.missing ? ['danger', 'not seen by the node', 'GpuMissing'] : g.ecc > 0 ? ['danger', `${g.ecc} memory error${g.ecc > 1 ? 's' : ''}`, 'GpuEccErrors']
  : g.remap ? ['warning', 'needs a reset', 'GpuRemapPending'] : g.slow ? ['warning', 'slowed by the hardware', 'GpuThrottled'] : null;
function nodeIssues(n) {
  const out = [];
  if (n.gpu_missing) out.push({ c: 'danger', text: `Slurm has ${n.gpus.length} GPUs here, the node reports ${n.gpus.length - n.gpu_missing}`, alert: 'GpuMissing' });
  n.gpus.forEach(g => { const i = gpuIssue(g); if (i && !g.missing) out.push({ c: i[0], text: `GPU ${g.gpu}: ${i[1]}`, alert: i[2] }); });
  (DATA?.units || []).forEach(u => u.down.forEach(x => { if (x.node === n.node) out.push({ c: 'danger', text: `${unitInfo(u.unit)[1]} (${u.unit}) isn't running`, alert: 'ServiceDown' }); }));
  return out.sort((a, b) => (a.c === 'danger' ? 0 : 1) - (b.c === 'danger' ? 0 : 1));
}
const mark = n => { const is = nodeIssues(n); if (!is.length) return '';
  const t = is.map(i => i.text).join('; ');
  return ` <i class="bi bi-exclamation-triangle-fill text-${is[0].c} node-mark" title="${h(t)}" role="img" aria-label="${h(t)}"></i>`; };

// ---------- view state (in the URL, so a filtered view can be shared or bookmarked) ----------
const ui = { tab: '', q: '', type: '', state: '', free: false, view: '', group: true, sort: 'state', dir: 1, node: '', closed: new Set() };
function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  Object.assign(ui, { tab: p.get('tab') === 'services' ? 'services' : '', q: p.get('q') || '', type: p.get('type') || '', state: p.get('state') || '', free: p.get('free') === '1',
    view: p.get('view') || '', group: p.get('group') !== '0', sort: p.get('sort') || 'state', dir: p.get('dir') === '-1' ? -1 : 1, node: p.get('node') || '' });
}
function writeHash() {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries({ tab: ui.tab, q: ui.q, type: ui.type, state: ui.state, free: ui.free ? '1' : '', view: ui.view,
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
    ${problems(d)}${tabs(d)}
    ${ui.tab === 'services' ? servicesTab(d) : `
    ${d.collectors_failing?.length ? `<div class="alert alert-secondary small py-2"><i class="bi bi-info-circle me-1"></i>Part of the
      monitoring isn't collecting (${h(d.collectors_failing.join(', '))}): some numbers may be missing or old.</div>` : ''}
    ${kpis(d, types)}${legend(d)}${clusterMap(d, types)}
    <div class="card"><div class="card-body p-0">
      ${toolbar(d, counts, types, view, list.length)}
      ${!list.length ? `<div class="text-center text-body-secondary py-5"><i class="bi bi-funnel fs-2 d-block mb-2 opacity-50"></i>No node matches these filters.
          <div class="mt-2"><button class="btn btn-sm btn-outline-secondary" data-act="clear">Clear filters</button></div></div>`
        : view === 'table' ? table(list, types) : cards(list)}
    </div></div>`}`;
  wire();
  if (focused === 'q') { const q = $('#q'); q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
}

// alert name -> icon, by family (the README "Alerts: what to do" table follows the same families)
const FAMILIES = [[/^Certificate/, 'shield-lock'], [/^Service/, 'plug'], [/^TargetDown/, 'hdd-network'], [/^GpuHot/, 'thermometer-high'],
  [/^Gpu/, 'gpu-card'], [/^NodeFilesystem/, 'device-hdd'], [/^NodeRAID/, 'hdd-stack'], [/^NodeMemory/, 'memory'], [/^NodeClock/, 'clock'],
  [/^Node(Network|HighNumberConntrack|Bonding)/, 'ethernet'], [/^(Prometheus|Collector|NodeTextFile)/, 'activity'], [/^Slurm/, 'diagram-3']];
const alertIcon = name => (FAMILIES.find(([re]) => re.test(name)) || [, 'exclamation-circle'])[1];
function problems(d) {
  // most harm first: critical before warning, then what stops the most people (a service, a node, a GPU, a certificate)
  const IMPACT = [/^Service/, /^TargetDown/, /^Gpu/, /^Certificate/, /^Node(RAID|Filesystem)/, /^Prometheus/];
  const rank = a => (a.severity === 'critical' ? 0 : 100) + ((i => i < 0 ? 50 : i)(IMPACT.findIndex(re => re.test(a.name))));
  const firing = d.alerts.filter(a => a.state === 'firing').sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
  if (!firing.length) return '';
  const crit = firing.some(a => a.severity === 'critical'), c = crit ? 'danger' : 'warning';
  const show = a => /^(Service|Certificate)/.test(a.name) ? `<button class="link-btn" data-tab="services">Show</button>`
    : a.node && d.nodes.some(n => n.node === a.node) ? `<button class="link-btn" data-node="${h(a.node)}">Show ${h(a.node)}</button>` : '';
  const fix = a => runbook(d, a.name) ? `<a class="text-reset" href="${h(runbook(d, a.name))}" target="_blank" rel="noopener">How to fix</a>` : '';
  const row = a => `<div class="d-flex align-items-baseline gap-2 small py-1 border-top border-${c}-subtle">
    <i class="bi bi-${alertIcon(a.name)}" title="${h(a.name)}" aria-hidden="true"></i>
    <div class="d-flex flex-wrap align-items-baseline column-gap-3 flex-grow-1 min-w-0"><span class="me-auto min-w-0">${h(a.summary)}${a.severity === 'warning' && crit ? ' <span class="badge text-bg-warning fw-normal">warning</span>' : ''}</span>
    ${a.since ? `<span class="text-nowrap opacity-75">for ${ago(a.since)}</span>` : ''}
    <span class="d-flex gap-3 text-nowrap">${show(a)}${fix(a)}</span></div></div>`;
  const open = $('#more-problems')?.classList.contains('show');
  return `<div class="alert alert-${c} py-2 mb-3" role="alert">
    <div class="d-flex align-items-center gap-2 py-1"><i class="bi bi-exclamation-triangle-fill"></i><span class="fw-semibold me-auto">${firing.length} problem${firing.length > 1 ? 's' : ''} right now</span>
      ${firing.length > 3 ? `<button class="btn btn-sm btn-link p-0 text-reset" data-bs-toggle="collapse" data-bs-target="#more-problems" aria-expanded="${!!open}">Show all</button>` : ''}</div>
    ${firing.slice(0, 3).map(row).join('')}
    ${firing.length > 3 ? `<div class="collapse ${open ? 'show' : ''}" id="more-problems">${firing.slice(3).map(row).join('')}</div>` : ''}</div>`;
}

function tabs(d) {
  const bad = servicesDown(d).length + unitsDown(d).length;
  const tab = (k, label, extra) => `<li class="nav-item" role="presentation"><button class="nav-link ${ui.tab === k ? 'active' : ''}" data-tab="${k}" role="tab"
      aria-selected="${ui.tab === k}">${label}${extra}</button></li>`;
  return `<ul class="nav nav-underline mb-3" role="tablist">
    ${tab('', 'Nodes', ` <span class="badge rounded-pill bg-body-secondary text-body fw-normal ms-1">${d.nodes.length}</span>`)}
    ${tab('services', 'Services', bad ? ` <span class="badge rounded-pill text-bg-danger ms-1" title="${bad} down">${bad}</span>`
      : (d.services || []).length ? ' <i class="bi bi-check-circle-fill text-success ms-1" role="img" aria-label="all answering"></i>' : '')}</ul>`;
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
  const k = (icon, label, v, sub, c = '', attrs = '') => `<div class="col-6 col-lg"><div class="card h-100 kpi" ${attrs}><div class="card-body py-2 px-3">
      <div class="small text-body-secondary"><i class="bi bi-${icon} me-1"></i>${label}</div><div class="v ${c}">${v}</div><div class="split text-body-secondary">${sub}</div></div></div></div>`;
  const of = (a, b) => `${a}<span class="fs-6 fw-normal text-body-secondary"> / ${b}</span>`;
  return `<div class="row g-2 mb-3">
    ${k('hdd-network', 'Nodes working', of(ok.length, d.nodes.length), down || drain
      ? [down && `<span class="text-danger-emphasis">${down} down</span>`, drain && `<span class="text-warning-emphasis">${drain} drained</span>`].filter(Boolean).join(' · ') : 'all working')}
    ${gAll ? k('gpu-card', 'GPUs free now', of(gFree, gAll), byType, gFree ? 'text-success' : 'text-warning') : ''}
    ${k('cpu', 'CPUs reserved', pct(cpus ? cpusRes / cpus : 0), `${cpusRes.toLocaleString()} of ${cpus.toLocaleString()} cores`)}
    ${k('play-circle', 'Jobs', `${d.jobs.running}<span class="fs-6 fw-normal text-body-secondary"> running</span>`, `${d.jobs.pending} waiting in the queue`)}
    ${idle ? k('hourglass', 'Reserved but idle', idle, 'GPUs held by jobs that use < 10%', 'text-warning') : ''}
    ${services(d)}
  </div>`;
  function services(d) {
    if (!(d.services || []).length && !(d.units || []).length) return '';
    const rows = serviceRows(d), units = d.units || [], down = [...servicesDown(d).map(s => s.name), ...unitsDown(d).map(u => unitInfo(u.unit)[1])];
    const ok = rows.filter(s => s.state === 'ok').length + units.filter(u => !u.down.length).length;
    return k('plug', 'Services', of(ok, rows.length + units.length), down.length ? `<span class="text-danger-emphasis">${h(down.slice(0, 2).join(', '))}${down.length > 2 ? ` +${down.length - 2}` : ''} down</span>`
      : 'all answering', down.length ? 'text-danger' : '', 'data-tab="services" role="button" tabindex="0" title="Open the Services tab" style="cursor:pointer"');
  }
}

// how to read the page: the GPU squares, and reserved vs used (right under the summary, before any node)
function legend(d) {
  const gpus = d.nodes.some(n => n.gpus.length);
  return `<div class="card mb-3"><div class="card-body py-2 px-3 d-flex flex-wrap align-items-center gap-2">
    ${gpus ? `<span class="small fw-semibold me-1">GPU squares</span><span class="legend me-lg-auto">
      <span><span class="g"></span>free</span><span><span class="g busy"></span>reserved, busy</span><span><span class="g mid"></span>reserved, partly busy</span>
      <span><span class="g idle"></span>reserved but idle</span><span><span class="g off"></span>not available / no data</span><span><span class="g busy hot"></span>too hot or faulty</span>${d.nodes.some(n => n.gpu_missing) ? '<span><span class="g gone"></span>missing</span>' : ''}</span>` : ''}
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
    <td><div class="fw-semibold">${h(n.node)}${mark(n)}</div><div class="sub">${h(n.type)}${n.slurm !== n.node ? ` · Slurm: ${h(n.slurm)}` : ''}</div></td>
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
      <div class="d-flex align-items-start gap-2"><div class="me-auto min-w-0"><div class="fw-semibold">${h(n.node)}${mark(n)}</div>
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

// ---------- Services tab ----------
const pill = (state, extra = '') => ({ ok: `<span class="status bg-success-subtle text-success-emphasis">OK</span>`,
  down: `<span class="status bg-danger-subtle text-danger-emphasis">Down</span>`,
  none: `<span class="status bg-secondary-subtle text-secondary-emphasis">Not checked</span>` })[state] + extra;
const forHow = since => since ? `<div class="sub text-danger-emphasis">for ${ago(since)}</div>` : '';

function servicesTab(d) {
  return `${statement(d)}${serviceTable(d)}${unitTable(d)}${monitoringCard(d)}`;
}

// one sentence first: is everything working, and if not, what does it break
function statement(d) {
  const sv = servicesDown(d).map(s => ({ name: s.name, impact: s.impact })), un = unitsDown(d).map(u => { const i = unitInfo(u.unit);
    return { name: `${i[1]} on ${u.down.map(x => x.node).join(', ')}`, impact: i[3] }; });
  const down = [...sv, ...un], m = d.monitoring || {};
  const box = (cls, icon, title, body) => `<section class="statement ${cls} mb-3" aria-live="polite"><i class="bi bi-${icon} ic" aria-hidden="true"></i>
    <div class="min-w-0"><h2>${title}</h2>${body}</div></section>`;
  if (down.length) return box('bad', 'x-octagon-fill', down.length === 1 ? `${h(down[0].name)} is down` : `${down.length} services are down`,
    `<ul class="list-unstyled mb-0 small">${down.map(x => `<li>${down.length > 1 ? `<b>${h(x.name)}</b>: ` : ''}${h(x.impact || 'Not answering')}.</li>`).join('')}</ul>`);
  if (m.checker_ok === false || !(d.services || []).length) return box('warn', 'question-octagon-fill', 'Service checks aren\'t running',
    '<p class="small mb-0">The statuses below may be old or missing. On master: <code>systemctl status blackbox_exporter</code>.</p>');
  const nodes = new Set((d.units || []).flatMap(u => u.ok.map(x => x.node))).size;
  return box('ok', 'check-circle-fill', 'Everything is answering', `<p class="small mb-0 text-body-secondary">${serviceRows(d).length} services, tried the way you'd use them,
    and ${(d.units || []).length} background services on ${nodes} node${nodes === 1 ? '' : 's'}. Checked every 15 seconds.</p>`);
}

function serviceTable(d) {
  const ms = s => s.seconds == null ? '–' : `<span class="${s.seconds > 2 ? 'text-warning-emphasis' : ''}">${Math.max(1, Math.round(s.seconds * 1000))} ms</span>`;
  const cert = s => s.cert_days == null ? '<span class="sub" title="Plain HTTP inside the cluster: no certificate">–</span>'
    : s.cert_days < 7 ? `<span class="text-danger-emphasis fw-semibold"><i class="bi bi-shield-exclamation me-1"></i>${Math.max(0, Math.floor(s.cert_days))} days</span>`
    : s.cert_days < 30 ? `<span class="text-warning-emphasis"><i class="bi bi-shield-exclamation me-1"></i>${Math.floor(s.cert_days)} days</span>`
    : `<span title="Certificate valid for ${Math.floor(s.cert_days)} more days">${Math.floor(s.cert_days)} days</span>`;
  return `<div class="card mb-3"><div class="card-body pb-0"><h2 class="h6 fw-semibold mb-1">What you connect to</h2>
      <p class="small text-body-secondary mb-2">Each one is called the way a user or job would, from inside the cluster.</p></div>
    <div class="table-responsive"><table class="table table-sm node-table align-middle mb-0">
      <thead><tr><th>Service</th><th>Status</th><th class="text-end d-none d-md-table-cell">Response</th><th class="text-end">Certificate</th><th class="d-none d-lg-table-cell">Address checked</th></tr></thead>
      <tbody>${serviceRows(d).map(s => `<tr id="svc-${h(s.key)}">
        <td><div class="fw-semibold">${h(s.name)}</div><div class="sub ${s.state === 'down' ? 'text-danger-emphasis' : ''}">${h(s.state === 'down' && s.impact ? s.impact : s.what)}</div></td>
        <td>${pill(s.state)}${s.state === 'down' ? forHow(s.since) : ''}</td>
        <td class="text-end font-monospace small d-none d-md-table-cell">${s.state === 'ok' ? ms(s) : '–'}</td>
        <td class="text-end small">${cert(s)}</td>
        <td class="d-none d-lg-table-cell"><span class="sub font-monospace text-break">${h(s.target || '')}</span></td></tr>`).join('')}</tbody></table></div></div>`;
}

function unitTable(d) {
  const units = [...(d.units || [])].sort((a, b) => (b.down.length ? 1 : 0) - (a.down.length ? 1 : 0) || unitRank(a.unit) - unitRank(b.unit) || a.unit.localeCompare(b.unit));
  const chip = (x, bad) => `<button class="badge rounded-pill border-0 ${bad ? 'text-bg-danger' : 'bg-body-secondary text-body'} fw-normal me-1 mb-1" data-node="${h(x.node)}"
      title="${bad ? `Not running on ${h(x.node)}${x.since ? ` for ${ago(x.since)}` : ''}` : `Running on ${h(x.node)}`}">${bad ? '<i class="bi bi-x-lg me-1" aria-hidden="true"></i>' : ''}${h(x.node)}</button>`;
  const where = u => { const ok = [...u.ok].sort((a, b) => a.node.localeCompare(b.node, undefined, { numeric: true }));
    return u.down.map(x => chip(x, true)).join('') + ok.slice(0, 6).map(x => chip(x, false)).join('')
      + (ok.length > 6 ? `<span class="sub" title="${h(ok.slice(6).map(x => x.node).join(', '))}">+${ok.length - 6} more</span>` : ''); };
  return `<div class="card mb-3"><div class="card-body pb-0"><h2 class="h6 fw-semibold mb-1">Running on the nodes</h2>
      <p class="small text-body-secondary mb-2">The background services the cluster needs. Each node is checked for the ones it's set up to run.</p></div>
    ${!units.length ? '<p class="small text-body-secondary px-3 pb-3 mb-0">No node reports its services yet. Run <code>9-monitoring/1-install.sh</code> on master.</p>' : `
    <div class="table-responsive"><table class="table table-sm node-table align-middle mb-0">
      <thead><tr><th>Service</th><th>Status</th><th>Where</th></tr></thead>
      <tbody>${units.map(u => { const i = unitInfo(u.unit), bad = u.down.length;
        return `<tr><td><div class="fw-semibold">${h(i[1])} <span class="sub font-monospace fw-normal">${h(u.unit)}</span></div><div class="sub ${bad ? 'text-danger-emphasis' : ''}">${h(bad ? i[3] || i[2] : i[2])}</div></td>
          <td class="text-nowrap">${pill(bad ? 'down' : 'ok')}${bad ? `<div class="sub text-danger-emphasis">on ${u.down.length} of ${u.down.length + u.ok.length}</div>` : ''}</td>
          <td>${where(u)}</td></tr>`; }).join('')}</tbody></table></div>`}</div>`;
}

// the monitoring watching itself: if this card isn't green, the rest of the page may be wrong
function monitoringCard(d) {
  const m = d.monitoring || {}, stale = d.collectors_failing || [];
  const item = (ok, good, bad, none) => { const st = ok == null ? 'none' : ok ? 'ok' : 'bad';
    const [icon, c, text] = { ok: ['check-circle-fill', 'success', good], bad: ['x-circle-fill', 'danger', bad], none: ['dash-circle', 'secondary', none] }[st];
    return `<li class="d-flex gap-2 align-items-start"><i class="bi bi-${icon} text-${c}" aria-hidden="true"></i><span class="${st === 'bad' ? 'text-danger-emphasis' : ''}">${text}</span></li>`; };
  return `<div class="card"><div class="card-body"><h2 class="h6 fw-semibold mb-2">Monitoring</h2>
    <ul class="list-unstyled small mb-2 monitor-list">
      ${item(m.config_ok, 'Settings loaded', 'New settings were rejected: it still runs the old ones', 'Settings: unknown')}
      ${item(m.rules == null ? null : !(m.rules_failing || []).length, `All ${m.rules} alert rules working`, `${(m.rules_failing || []).length} alert rule(s) failing: ${h((m.rules_failing || []).join(', '))}`, 'Alert rules: unknown')}
      ${item(!stale.length, 'Data collectors up to date', `Not collecting: ${h(stale.join(', '))}`, '')}
      ${item(m.checker_ok, 'Service checks running', 'The service checker doesn\'t answer: the statuses above may be old', 'Service checks aren\'t set up')}
    </ul>
    ${d.runbook_url ? `<a class="small" href="${h(d.runbook_url)}#alerts-what-to-do" target="_blank" rel="noopener">Every alert and how to fix it</a>` : ''}</div></div>`;
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
  $('#detail-head').innerHTML = `<div class="d-flex align-items-center gap-2"><h2 class="h5 fw-semibold mb-0" id="detail-title">${h(n.node)}${mark(n)}</h2>
      <span class="status bg-${st.c}-subtle text-${st.c}-emphasis">${st.word}</span></div>
    <div class="sub">${h(n.type)} · ${n.cpus} CPUs · ${gb(n.mem)}${n.gpus.length ? ` · ${n.gpus.length} × ${h(n.gpus[0].name)}` : ''}${n.slurm !== n.node ? ` · Slurm name ${h(n.slurm)}` : ''}</div>`;
  const line = (label, r, text, c, warn) => `<div class="d-flex align-items-center gap-2 small"><span class="text-body-secondary" style="width:4.5rem">${label}</span><div class="flex-grow-1">${mini(r, text, c, warn)}</div></div>`;
  const bar2 = (label, res, used, text, warn) => `<div class="mb-3"><div class="fw-semibold small mb-1">${label}</div>
      ${line('Reserved', res, text, 'primary')}${used == null ? '' : line('In use', used, pct(used), 'info', warn)}</div>`;
  const users = Object.entries(n.users).sort((a, b) => b[1] - a[1]);
  const issues = nodeIssues(n);
  $('#detail-body').innerHTML = `
    ${issues.length ? `<div class="alert alert-${issues[0].c} small py-2"><div class="fw-semibold mb-1"><i class="bi bi-exclamation-triangle-fill me-1"></i>Needs attention</div>
      <ul class="list-unstyled mb-0">${issues.map(i => `<li class="d-flex gap-2"><span class="me-auto">${h(i.text)}</span>${runbook(DATA, i.alert)
        ? `<a class="text-reset text-nowrap" href="${h(runbook(DATA, i.alert))}" target="_blank" rel="noopener">How to fix</a>` : ''}</li>`).join('')}</ul></div>` : ''}
    ${n.reason ? `<div class="alert alert-${st.c} small py-2"><i class="bi bi-info-circle me-1"></i><b>${h(n.reason)}.</b> ${st.k === 'drain' ? 'Running jobs finish; Slurm sends it no new ones.' : 'Slurm sends it no new jobs.'}</div>` : ''}
    ${!n.up ? `<p class="text-body-secondary small">${dead ? 'The node doesn\'t answer' : 'Monitoring can\'t reach this node right now'}, so there are no live numbers.</p>` : `
    <div class="eyebrow mb-2">CPU and memory</div>
    <div class="row g-4"><div class="col-md-6">${bar2('CPU', n.cpus_alloc / (n.cpus || 1), n.cpu_used, `${n.cpus_alloc}/${n.cpus}`)}</div>
    <div class="col-md-6">${bar2('Memory', n.mem_alloc / (n.mem || 1), n.mem_used, pair(n.mem_alloc, n.mem), true)}</div></div>
    <div class="mt-3" id="spark">${hist === undefined ? '<div class="small text-body-secondary"><span class="spinner-border spinner-border-sm me-1"></span>Loading the last hour…</div>'
      : hist === null ? '<div class="small text-body-secondary">Couldn\'t load the history.</div>' : spark(hist)}</div>`}
    ${n.gpus.length ? `<div class="eyebrow mt-4 mb-2">GPUs · ${freeGpus(n)} of ${n.gpus.length} free</div>
      <div class="table-responsive"><table class="table table-sm small align-middle gpu-table"><thead><tr><th>#</th><th><span class="visually-hidden">Colour</span></th><th>Status</th><th>In use</th><th>Memory, GB</th><th class="text-end">Temp</th><th class="text-end">Power</th></tr></thead><tbody>
      ${n.gpus.map(g => `<tr><td>${h(g.gpu)}</td><td><span class="g ${gpuClass(g, n)} ${gpuRing(g)} d-inline-block"></span></td>
        <td>${!n.up || g.util == null ? '<span class="text-body-secondary">no data</span>' : g.reserved ? (g.util < .1 ? '<span class="text-warning-emphasis">reserved, idle</span>' : 'reserved')
          : takesJobs(n) ? '<span class="text-success-emphasis">free</span>' : '<span class="text-body-secondary">not available</span>'}
          ${(i => i ? `<div class="sub text-${i[0]}-emphasis text-nowrap"><i class="bi bi-exclamation-triangle-fill me-1"></i>${i[1]}</div>`
            : g.ecc != null || g.slow != null ? '<div class="sub text-success-emphasis"><i class="bi bi-check-circle me-1"></i>healthy</div>' : '')(gpuIssue(g))}</td>
        <td>${!n.up || g.util == null ? '–' : mini(g.util, pct(g.util), 'success')}</td>
        <td>${g.mem_total ? mini((g.mem_used || 0) / g.mem_total, `${((g.mem_used || 0) / GiB).toFixed(1)}/${Math.round(g.mem_total / GiB)}`, 'info', true) : '–'}</td>
        <td class="text-end ${g.temp >= 85 ? 'text-danger fw-semibold' : ''}">${g.temp != null ? `${Math.round(g.temp)} °C` : '–'}</td><td class="text-end">${g.power != null ? `${Math.round(g.power)} W` : '–'}</td></tr>`).join('')}
      </tbody></table></div>` : ''}
    <div class="row g-4 mt-0"><div class="col-md-6"><div class="eyebrow mb-2">Running here</div>
    ${users.length ? `<ul class="list-group list-group-flush small">${users.map(([u, k]) => `<li class="list-group-item px-0 d-flex"><i class="bi bi-person me-2"></i><span class="me-auto">${h(u)}</span><span class="text-body-secondary">${k} job${k > 1 ? 's' : ''}</span></li>`).join('')}</ul>`
      : `<p class="small text-body-secondary">${dead ? 'Nothing can run here now.' : 'Nothing running.'}</p>`}</div>
    <div class="col-md-6"><div class="eyebrow mb-2">Partitions</div><div>${n.partitions.map(p => `<span class="badge rounded-pill bg-body-secondary text-body fw-normal me-1">${h(p)}</span>`).join('') || '–'}</div></div></div>`;
}

const histCache = {};
async function openDetail(name) {
  const n = DATA?.nodes.find(x => x.node === name); if (!n) return;
  openNode = name; writeHash();
  detail(n, histCache[name]?.data);
  bootstrap.Modal.getOrCreateInstance($('#detail')).show();
  if (histCache[name] && Date.now() - histCache[name].at < 60000) return;   // the history moves by the minute
  try { histCache[name] = { at: Date.now(), data: await api(`history/${encodeURIComponent(name)}`) }; }
  catch { histCache[name] = { at: Date.now(), data: null }; }
  if (openNode === name && $('#spark')) $('#spark').innerHTML = histCache[name].data ? spark(histCache[name].data) : '<div class="small text-body-secondary">Couldn\'t load the history.</div>';
}
$('#detail').addEventListener('hidden.bs.modal', () => { openNode = null; writeHash(); });

// ---------- events ----------
function wire() {
  const set = (patch) => { Object.assign(ui, patch); writeHash(); render(); };
  if ($('#q')) $('#q').oninput = e => set({ q: e.target.value });
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
  app.querySelectorAll('[data-tab]').forEach(t => { const go = () => { set({ tab: t.dataset.tab }); window.scrollTo({ top: 0 }); $(`[role=tab][data-tab="${t.dataset.tab}"]`)?.focus(); };
    t.onclick = go; t.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); } }; });
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

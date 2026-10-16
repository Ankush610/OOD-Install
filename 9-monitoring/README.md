# 9-monitoring: one Prometheus for the whole cluster

One Prometheus on master. Every app reads cluster metrics from it: OOD, Model Hub, and anything you add later.
Everything it collects comes from what `1-install.sh` installs. It doesn't use Kubernetes or the GPU operator, and
it doesn't change Slurm's config. It's plain binaries under systemd, so it keeps working when Kubernetes has a problem.

```
every node:  node_exporter :9100 ── CPU, RAM, disk, network
               + /var/lib/node_exporter/textfile/
                   gpu.prom    gpu-metrics.timer, 15 s, GPU nodes: nvidia-smi
                   slurm.prom  slurm-metrics.timer, 30 s, master only: scontrol/squeue --json
master:      Prometheus  PROM_URL (:9090) ── collects every node_exporter ──> OOD, Model Hub, Grafana, curl ...
login node:  OOD app "Cluster monitor" (Interactive Apps menu + home page card) ── reads PROM_URL, read-only, OOD_ADMIN only
```

| File | What |
|---|---|
| `1-install.sh` | Run on master. Does everything: checks, downloads, every node, Prometheus, and a final check. |
| `node-setup.sh` | One node's part. `1-install.sh` pipes it over ssh. |
| `gpu-metrics.sh` | nvidia-smi → `gpu_*`. Keeps only the GPU types Slurm schedules, so a display card next to an A30 is dropped. |
| `slurm-metrics.py` | scontrol/squeue → `slurm_*`. Read-only. `--test` checks the parsing. |
| `rules.yml` | Named queries for apps, plus alerts |
| `rules_test.yml` | Tests for `rules.yml` with made-up series. `1-install.sh` runs them first; a failure stops it. |
| `node-alerts.yml` | node_exporter's own alerts (disk, inode, RAID, memory, clock, network), rendered from `node-alerts.jsonnet` |
| `2-install-ood-app.sh` | Run on the login node. Installs the OOD app below. |
| `ood-app/cluster_status/` | The OOD app: `passenger_wsgi.py` (asks Prometheus, read-only) + `public/app.js` (the page) |

## What it installs, and what it only checks

| | |
|---|---|
| **Installs** | Prometheus, node_exporter, the two collectors (systemd timers), their system users, folders and units. It also installs `curl`, `python3` and `tar` through dnf if they're missing. |
| **Checks only** | Slurm answers (stops if not). `nvidia-smi` on GPU nodes (a warning, plus `gpu_collector_ok 0`). Root ssh and the shared `/home` (nodes without them are skipped). firewalld: adds the rules if it's running, warns if it's off, never turns it on. Internet (if it's missing, says which file to copy into `MONITOR_ROOT` by hand). |

## Install and run

```bash
sudo bash 1-install.sh            # on master
sudo bash 2-install-ood-app.sh    # on LOGIN_HOST, then in OOD: Help -> Restart Web Server
```

`1-install.sh` reruns safely. It only changes what differs and keeps the data.
Nodes it can't reach are skipped. Rerun it when they're back.

- **Settings:** `site.conf` → `# --- Monitoring`. That covers the versions and their sha256, the ports, the data folder and how long data is kept.
- **Stop or start:** `systemctl stop|start prometheus`. The data stays in `PROM_DATA`. On a node, `systemctl stop node_exporter gpu-metrics.timer`.
- **Web UI:** `PROM_URL`, opened from the login node, or through `ssh -L 9090:<MASTER_IP>:9090`.
- **New node:** add it to `COMPUTE_NODES` and rerun. If Slurm lists GPUs on it, it gets the GPU collector too.
- **New version:** change `*_VERSION` and `*_SHA256` together (from the release's `sha256sums.txt`), then rerun.
- **Offline site:** copy `prometheus-<ver>.linux-amd64.tar.gz` and `node_exporter-<ver>.linux-amd64.tar.gz` into `MONITOR_ROOT`, then rerun. The checksum is still verified.

## The OOD app: Cluster monitor

Interactive Apps → Cluster monitor, and a card in the Admin section of the home page, for `OOD_ADMIN` only (its folder is readable by that account's group alone, like the Admin page; for anyone else it's not in the menu and not reachable by URL). Read-only. It refreshes every 30 s (not while the tab is hidden).

- **Problems** (both tabs): Prometheus' firing alerts, most harm first (critical, then services, nodes, GPUs,
  certificates), an icon per kind, **Show** (opens the node or the Services tab) and **How to fix** (its row in the docs
  site's alerts runbook, via `RUNBOOK_URL`).
- **Nodes tab, top:** nodes working, GPUs free by type, CPUs reserved, jobs, GPUs reserved but idle, and services
  answering (click: Services tab).
- **At a glance** (more than 8 nodes): one square per node, by type, coloured by load. Click one for its details.
- **Nodes:** a table (more than 8 nodes) or cards. Search by node, user or reason; filter by type, state, "has a free
  GPU"; sort by any column; problems first by default. One square per GPU: empty = free, filled = reserved (colour =
  how busy it really is), grey = not available.
  A ⚠ next to a node: a faulty GPU (memory errors, needs a reset, slowed down), a missing GPU (dashed square: Slurm has
  it, the node doesn't see it), or a core service not running there.
- **Side panel** per node: what needs attention (each with How to fix), CPU and memory reserved vs in use, each GPU and
  its health, the last hour, who runs what there.
- **Services tab:** one sentence first ("Everything is answering", or what is down and what that breaks); the services
  people connect to (portal, sign-in, LDAP, MLflow, registry, gateway) with OK / Down, since when, response time and
  certificate days left (amber < 30, red < 7); the core services on each node (`MONITOR_UNITS`) with the nodes they
  run on, down ones first; the monitoring's own health (settings loaded, alert rules, collectors, service checks).
- **Links:** tab, filters and the open node are in the URL, e.g. `#tab=services`, `#type=A30&free=1` or `#node=cn02`.

`passenger_wsgi.py` makes one Prometheus query per refresh (plus `alerts` and `rules`), and the last-hour history only for the
node someone opens. It never takes a query from the browser: the only value from the URL (a node name) is checked.

## For apps: how to read it

The API is read-only. Ask for the named queries in `rules.yml`, not your own PromQL.
`node` is always the hostname. Slurm series also carry `slurm_node`, Slurm's own name for the node (for example `viewer01` is master).

```bash
curl -s "$PROM_URL/api/v1/query" --data-urlencode 'query=slurm:node_gpus_free'
```

| Name | Value | Labels |
|---|---|---|
| `node:cpu_used:ratio`, `node:mem_used:ratio`, `node:disk_used:ratio`, `node:load1_per_cpu:ratio` | 0 to 1, actual use | `node` |
| `gpu:util:ratio`, `gpu:mem_used:ratio` | 0 to 1 | `node`, `gpu`, `name`, `uuid` |
| `gpu:mem_used:bytes`, `gpu:temp:celsius`; raw `gpu_memory_total_bytes`, `gpu_power_watts` | | same |
| `slurm_node_info` | 1. The data is in the labels: `state` (e.g. `mixed`, `down+not_responding`), `reason`, `partitions`, `gpu_type` (from gres, e.g. `a30`) | `node`, `slurm_node` |
| `slurm_node_gpu_reserved` | 1 per GPU a job holds: `gpu` = Slurm's number for it (0 = the node's first GPU in gres.conf order) | `node`, `slurm_node`, `gpu` |
| `slurm_node_available` | 1 = takes new jobs, 0 = down, drained and so on | `node`, `slurm_node` |
| `slurm_node_cpus`, `_memory_bytes`, `_gpus`, and each one's `_alloc` | What jobs can get, and what's reserved now | `node`, `slurm_node` |
| `slurm:node_cpus_alloc:ratio`, `slurm:node_mem_alloc:ratio` | 0 to 1, reserved by Slurm | `node`, `slurm_node` |
| `slurm:node_gpus_free`, `slurm:gpus_free` | GPUs a new job or endpoint could get now (per node, whole cluster) | |
| `slurm_jobs` | Number of running or pending jobs | `state`, `partition`, `user` |
| `slurm_node_jobs` | Running jobs on that node (who is where) | `node`, `slurm_node`, `user` |
| `up` | 1 = answering, 0 = down | `job`, `node` |
| Firing alerts: `$PROM_URL/api/v1/alerts` | | |

"Reserved" means what Slurm has handed to jobs. "Used" means what the hardware is actually doing.
A job can reserve 8 CPUs and use 1.

Who can read it: Prometheus listens on `MASTER_IP`, and firewalld lets in only `LOGIN_IP` and master itself.
There's no password. OOD apps run as the logged-in user, so every user could read a password the app can read.
The data is usage and job counts, which users can already see with `squeue` and `sinfo`.
The admin and lifecycle APIs are off, so nobody can change or delete anything through the port.

## Alerts: what to do

The runbook (every alert, what it means, what to do) is on the docs site:
[Monitoring reference → Alerts](https://ankush610.github.io/AI-Factory-Docs/reference/monitoring/#alerts).
"How to fix" links are built from the alert's name: `$RUNBOOK_URL#<alertname, lower case>` (`RUNBOOK_URL` in
`site.conf`), and "Every alert and how to fix it" opens `#alerts-what-to-do`. **A new alert in `rules.yml` or
`node-alerts.yml` needs a row there with `<a id="<alertname lower case>"></a>`**, in the AI-Factory-Docs repo.

## Symptom | Cause | Fix

| Symptom | Cause | Fix |
|---|---|---|
| `1-install.sh`: Slurm doesn't answer | slurmctld or munge is down, or `SLURM_BIN` is wrong in `site.conf` | `systemctl status slurmctld munge`; `which sinfo` |
| `node` target down, `no route to host` | The node is off or unreachable (cn02 on 2026-10-15) | Bring it back, then rerun `1-install.sh` (it was skipped) |
| `node` target down, `connection refused` | node_exporter isn't running there | `ssh <node> systemctl status node_exporter`; rerun `1-install.sh` |
| `node` target down, `context deadline exceeded`, node is fine | firewalld on the node doesn't let `MASTER_IP` in | Rerun `1-install.sh` (it adds the rule) |
| `gpu_collector_ok 0` / `CollectorFailing` | nvidia-smi is missing or failing on that node (driver) | `ssh <node> nvidia-smi`; `journalctl -u gpu-metrics -n 20` |
| `slurm_collector_ok 0` | scontrol/squeue fail as the `node_exporter` user | `journalctl -u slurm-metrics -n 20`; `sudo -u node_exporter squeue` |
| `CollectorStale` | The timer stopped, or the textfile folder isn't writable | `systemctl list-timers gpu-metrics.timer slurm-metrics.timer` |
| GPU count lower than Slurm's | A GPU node is down, or nvidia-smi's name doesn't contain the Slurm type (`gpu:a30` → "NVIDIA A30") | Match Slurm's gres type to the card name |
| `1-install.sh`: checksum doesn't match | `*_VERSION` changed without `*_SHA256` | Copy the hash from the release's `sha256sums.txt` into `site.conf` |
| Cluster monitor: "monitoring doesn't answer" | Prometheus is stopped, or the firewall doesn't let `LOGIN_IP` in | `systemctl status prometheus` on master; `curl $PROM_URL/-/ready` from the login node |
| Cluster monitor: "monitoring has no Slurm data" | slurm-metrics isn't running on master | `systemctl list-timers slurm-metrics.timer`; `journalctl -u slurm-metrics -n 20` |
| Cluster monitor: the wrong GPU shows as reserved | gres.conf lists the GPUs in a different order than the PCI bus (nvidia-smi's order) | List them in bus order (`/dev/nvidia0..N`, or `AutoDetect=nvml`) |
| Cluster monitor not in the Interactive Apps menu | OOD caches the app list | Help → Restart Web Server |
| No Cluster monitor card on the home page | The home page is our own widget, with a fixed list of cards (`2-ood/branding/_ai_tools.html.erb`) | Rerun `2-ood/setup-ood.sh` on the login node (it installs the widget), then Restart Web Server |
| Prometheus won't start after an edit | Bad config or rules | `promtool check config /etc/prometheus/prometheus.yml`; `journalctl -u prometheus -n 50` |

## Not in here (yet)

- **Notifications** (email or Slack) for alerts: needs Alertmanager. Until then, alerts show at `/alerts` and `/api/v1/alerts`.
- **Grafana:** optional. Point it at `PROM_URL` if you want graphs.
- **Per-process GPU use** (which job uses how much of a GPU): nvidia-smi can give it; add it when an app needs it.
- **The Prometheus in Kubernetes (`monitoring` namespace)** is a different one, used for KEDA autoscaling. Leave it alone.

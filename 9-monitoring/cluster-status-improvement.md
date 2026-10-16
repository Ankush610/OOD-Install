# Cluster status improvement: plan to make monitoring production grade

Status on 2026-10-16: **Phase 1 and Phase 3 done.** Order now: Phase 3, UI (U.1–U.6), then Phase 2 (needs the SMTP details below).

## Why: what's missing today

| # | Gap | Effect |
|---|---|---|
| 1 | Alerts exist (7 rules), nobody is told: no Alertmanager, no email | An outage is only visible on a page nobody watches |
| 2 | Prometheus runs on master next to everything else, nothing watches it from outside | Master dies → monitoring dies silently |
| 3 | Core services not monitored: slurmctld, munge, LDAP, httpd (OOD), Keycloak, NFS, kubelet | LDAP down → nobody can log in, no alert |
| 4 | Only `/` has a disk alert, not `/home` (13 TB NFS, everyone's data) | `/home` full stops the cluster with no warning |
| 5 | Cluster monitor can show old Slurm numbers as live (collector killed by its 60 s timeout leaves the old file, still `ok 1`) | Up to ~7 min of wrong data on the page |
| 6 | GPU health = temperature only: no ECC errors, no remapped rows, no "GPU fell off the bus" | Failing GPUs go unnoticed |
| 7 | `slurm-metrics.py` runs one `scontrol show hostnames` per bracketed node list per run | Fine at 3 nodes, hundreds of slurmctld calls per 30 s at scale |

Not standard yet (switch, both make the code smaller): hand-written node alerts instead of the community
**node-mixin** set, and `exported_node` relabel rules instead of `honor_labels: true`.

Standard already, keep: Prometheus + node_exporter as release binaries under systemd, textfile collectors written
atomically, metric and recording rule naming, pinned versions + sha256, read-only API, systemd hardening.
Kept on purpose: nvidia-smi instead of DCGM (works without k8s), own Slurm collector (no `slurm.conf` change),
own Cluster monitor page (users' page; Grafana can come later for admins).

## Phase 1: watch what matters (no outside input, ~1.5 days)

| # | Change | Files | Done when |
|---|---|---|---|
| 1.1 ✅ | `honor_labels: true` on the `node` job, drop the `exported_node` metric_relabel rules | `1-install.sh`, `../CLAUDE.md` (design note) | Same `node` labels on `slurm_*` and `node_*` before and after reload |
| 1.2 ✅ | node_exporter systemd collector for core services, list in new `MONITOR_UNITS` (site.conf); critical alert `ServiceDown` = `node_systemd_unit_state{state="active"} == 0` for 2m | `node-setup.sh`, `1-install.sh`, `../site.conf`, `rules.yml` | `systemctl stop httpd` → `ServiceDown` firing within 2 min |
| 1.3 ✅ | node-mixin alerts, pinned to node_exporter's tag, rendered once into `node-alerts.yml`; drop our `DiskAlmostFull`, `MemoryAlmostFull` | new `node-alerts.jsonnet` + `node-alerts.yml`, `1-install.sh`, `rules.yml` | `/home`, inode, RAID, clock alerts listed at `PROM_URL/alerts` |
| 1.4 ✅ | GPU health: ECC uncorrected, remapped rows pending, HW slowdown; alerts `GpuEccErrors`, `GpuRemapPending`, `GpuThrottled`, `GpuMissing` | `gpu-metrics.sh`, `rules.yml` | New `gpu_*` series for cn01's A30 |
| 1.5 ✅ | Stale data: Slurm command timeout 30 → 20 s; app flags a collector file older than 120 s | `slurm-metrics.py`, `ood-app/cluster_status/passenger_wsgi.py` | Stop `slurm-metrics.timer` → page warns after 2 min |
| 1.6 ✅ | Prometheus watches itself: config reload failed, rule evaluation failures, compactions failing | `rules.yml` | Listed at `/alerts` |
| 1.7 ✅ | Rule tests: `rules_test.yml`, `promtool test rules` runs in `1-install.sh` **before** the files are copied | new `rules_test.yml`, `1-install.sh` | A broken rule stops the install, the running config stays |

### Findings from starting Phase 1 (use when implementing)

- **1.2 services seen on master:** `slurmctld`, `slurmd` (viewer01), `slurmrestd`, `munge`, `sssd`, `dirsrv@aistack`,
  `httpd`, `keycloak`, `keycloak-db`, `kubelet`, `containerd`, `nfs-server`. Proposed
  `MONITOR_UNITS='slurmctld|slurmd|slurmrestd|munge|sssd|dirsrv@.*|httpd|keycloak|keycloak-db|kubelet|containerd|nfs-server'`;
  one list for every node; each node watches only the ones it has enabled (done in 1.2).
  The registry runs as a hash-named podman unit: can't be watched by name, Phase 3's blackbox check on `:5000` covers it.
- **1.2 unit file:** no backslashes or `%`/`$` in the systemd `ExecStart` (systemd unescapes them): write the regex as
  `--collector.systemd.unit-include=(...)[.]service`.
- **1.3 node-mixin:** source = `github.com/prometheus/node_exporter` tag `v1.12.1`, `docs/node-mixin`. Render only
  `config.libsonnet` + `alerts/alerts.libsonnet` (dashboards need grafonnet; not needed). Tool: go-jsonnet v0.20.0 binary.
  Overrides: `fsSelector: 'fstype=~"ext4|xfs|btrfs"'` (local disks only: NFS clients would repeat `/home` alerts, and
  tmpfs/vfat/fuse are noise).
  Drop: `NodeCPUHighUsage`, `NodeSystemSaturation` (compute nodes at 100% is the point of HPC),
  `NodeSystemdServiceFailed` (our `ServiceDown` covers failed **and** stopped).
  Keep the rest, including `NodeRAIDDegraded`/`NodeRAIDDiskFailure` (master's disks are md RAID: `/dev/md126`),
  `NodeSystemdServiceCrashlooping`, clock, inode, file descriptor, network error alerts.
- **1.4 nvidia-smi:** fields `ecc.errors.uncorrected.volatile.total`, `remapped_rows.pending`,
  `clocks_throttle_reasons.hw_slowdown` go in a **second** nvidia-smi call: a field this driver doesn't know must
  not take the existing numbers down with it. Map `Yes`/`Active` → 1, `No`/`Not Active` → 0, `[N/A]` → left out.
  Verified on cn01 (driver 580.142, 2026-10-16):
  `ssh cn01 nvidia-smi --query-gpu=index,ecc.errors.uncorrected.volatile.total,remapped_rows.pending,clocks_throttle_reasons.hw_slowdown --format=csv`
  (newer drivers also accept `clocks_event_reasons.hw_slowdown`).
- **1.4 `GpuMissing`:** `slurm_node_gpus > on (node) group_left () (count by (node) (gpu_memory_total_bytes) or on (node) (0 * gpu_collector_ok))`, `for: 10m`.
  A node that's down has no `gpu_collector_ok` → no alert (`TargetDown` covers it).
- **1.5:** the app compares `node_textfile_mtime_seconds` with the query's own timestamp (Prometheus' clock), and adds
  stale files to the existing `collectors_failing` list, which the page already shows.

## Phase 2: tell someone (needs SMTP details, ~1 day)

| # | Change | Done when |
|---|---|---|
| 2.1 | Alertmanager installed like Prometheus (same `fetch()`, version + sha256 in `site.conf`, systemd, `127.0.0.1:9093`) | `amtool check-config` passes |
| 2.2 | Routing: critical → email now, repeat 1 h; warning → grouped, repeat 12 h | Admins receive a test alert |
| 2.3 | Inhibit: `TargetDown` on a node mutes that node's Slurm/collector/GPU alerts | cn02 off → **one** email |
| 2.4 | SMTP password via `smtp_auth_password_file` (root:alertmanager 0640), never on a command line | `ls -l` |
| 2.5 | Dead man's switch: always-firing `Watchdog` → outside heartbeat every 5 min | Stop Prometheus → email from outside within 10 min |
| 2.6 | Maintenance silences documented: `amtool silence add node=cn02 --duration 4h` | Drain + silence → no email |

Needed from the site: SMTP relay host, port, sender address, login (if any); admin email list; heartbeat target
(healthchecks.io from master, or a cron check on `network-node`).

## Phase 3: hardening (~1 day)

| # | Change | Why |
|---|---|---|
| 3.1 ✅ | blackbox_exporter: OOD https, LDAP ldaps 636, Keycloak, MLflow `:30500`, registry `:5000`, gateway `GATEWAY_IP:443` | systemd can't see k8s pods; "active" isn't "answering" |
| 3.2 ✅ | TLS certificate expiry alert (from blackbox) | Self-signed OOD and gateway certificates expire |
| 3.3 ✅ | README "Alerts: what to do": one row per alert with an anchor; link = `RUNBOOK_URL#<alertname lower case>` (site.conf), built by the UI (U.6) and the email template (Phase 2) instead of a `runbook_url` annotation on ~40 rules | The page and the email say what to do |
| 3.4 ✅ | Expand Slurm node lists in Python (one call or none), with an assert in `--test` | slurmctld load stays flat as jobs grow |

## UI: every check visible in the Cluster monitor (after Phase 3, before Phase 2)

Rule: anything we watch must also show on the page, not only as an alert. Green "OK" when fine, a clear mark when
not. One request per refresh stays (add the series to the app's one query).

| # | Change | Shows | Source |
|---|---|---|---|
| U.1 | **Services tab**: one row per service: OK (green) / Down (red) / Not checked, since when, response time | OOD, LDAP, Keycloak, MLflow, registry, gateway answering; core systemd services per node (slurmctld, munge, sssd, httpd, …) | `probe_success`, `probe_duration_seconds` (3.1), `node_systemd_unit_state` (1.2) |
| U.2 | Certificate column in the Services tab: days left, amber < 30, red < 7 | OOD, LDAP, gateway certificates | `probe_ssl_earliest_cert_expiry` (3.2) |
| U.3 | GPU health in the node panel's GPU table: ECC errors, repair pending, slowed down; a badge on the node when any is set | Per GPU | `gpu_ecc_errors_uncorrected`, `gpu_remapped_rows_pending`, `gpu_hw_slowdown` (1.4) |
| U.4 | Missing GPU marked on the node ("Slurm 2, seen 1") | Per node | `GpuMissing` (1.4) |
| U.5 | Monitoring health line: Prometheus config OK, rules OK, collectors fresh | Bottom of the page | `prometheus_config_last_reload_successful`, rule failures (1.6), stale files (1.5, done) |
| U.6 | Problems box: icon per alert family (service, certificate, GPU, disk), link to its row in the Services tab or node panel | Top of the page | firing alerts |

## Phase 4: features (separate track)

1. "GPUs free now" on Model Hub's deploy card (`slurm:node_gpus_free` + `gpu_type`), ~½ day
2. Idle-GPU alert for admins: `gpu_utilization_ratio < 0.1 and on (node, gpu) slurm_node_gpu_reserved`, `for: 1h`
3. `slurm_user_gpus{user}` gauge in `slurm-metrics.py` → GPU-hours rule → Usage tab (own for users, all for admin), 1–2 days.
   Slurm accounting is off (no slurmdbd), so history starts that day and is capped by `PROM_RETENTION` (30 d).
4. Grafana for admins (optional)

## Left out on purpose

- Prometheus HA / Thanos / long-term storage: the outside heartbeat (2.5) covers "monitoring is down" at this size.
- Password or TLS on Prometheus: OOD apps run as the user, so every user could read it anyway.
- DCGM: 1.4 covers GPU errors; switch for XID errors or per-job GPU use.

## Production-grade checklist

- [ ] Stop `dirsrv@aistack` → email within 5 min
- [ ] Node off → one email, not three
- [ ] Prometheus stopped → alert from **outside** the cluster
- [ ] Drain with a silence → no email
- [ ] `/home` at 90% → alert
- [x] Broken rule → install stops, running config untouched
- [x] Cluster monitor never shows numbers older than 2 min without saying so

## How to test (with root on master)

```bash
bash -n 9-monitoring/*.sh
python3 9-monitoring/slurm-metrics.py --test
promtool check rules 9-monitoring/rules.yml 9-monitoring/node-alerts.yml
promtool test rules 9-monitoring/rules_test.yml
sudo bash 9-monitoring/1-install.sh          # on master
sudo bash 9-monitoring/2-install-ood-app.sh  # on LOGIN_HOST, then Help -> Restart Web Server
```

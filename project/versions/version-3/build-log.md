# Model Hub v3 — build log

Problems and fixes as we go, newest at the bottom. Earlier logs: [v2](../version-2/build-log.md),
[v1](../version-1/build-log.md).

## 2026-10-13 — v3 planned

- v2 closed: steps 6 and 6b passed for LLM and ML too (admin). Open v2 steps (network lock, NVMe cache, packaging,
  usage logs on disk) moved here as steps A–D.
- New: Model Hub deploys any model with sensible hardware by itself (presets, "won't fit" check, context length)
  and knows the model's kind (image / audio input, embeddings, generators). Why: the deploy form had one GPU
  dropdown and fixed CPUs / RAM (`render.py`: 4 CPU / 32 Gi with a GPU, 2 / 4 Gi without).
- Next: step 0 (v2 reruns), then step 1.

## 2026-10-13 — v3 plan: serving images from the SIFs, model inspector, deploy parameters

- **Why:** checked what DL serving covers: only plain PyTorch (`torch` + `torchvision`). Models from `pytorch-vision`,
  `pytorch-nlp`, `tensorflow`, ONNX or pyfunc with extra packages fail, and any non-`pytorch` flavor is sent to the
  ML image.
- **Decided:** serving images made from the training SIFs themselves (full `mlflow` in the `.def`s, `podman import`
  in a loop) + an image catalog; one model inspector reads the model's files (no questions) and gives a deploy
  plan; the form shows 3 fields + 3 under Advanced (README "Deploy parameters"). Steps 1–3 rewritten, old step 1
  (tags at registration) folded into step 2.
- Next: step 0, then step 1's test (full `mlflow` in `pytorch-vision`).

## 2026-10-15 — step 1 built: one serving image per training SIF

- **Found:** `mlflow-skinny` (in every SIF) already serves: `mlflow models serve` + the FastAPI/uvicorn scoring server
  import and run. So no full `mlflow` in the `.def`s and no SIF rebuild (README decision row changed).
- **Built** (`5-model-hub/4-images.sh`, `sif_image`): sandbox of the SIF → `tar | podman import` with the def's
  exported env, `USER 65534`, `HOME=/tmp`, `STOPSIGNAL SIGINT`, ENTRYPOINT `mlflow models serve --env-manager local`;
  torch images get `sitecustomize.py`. `bash 4-images.sh <sif>` builds one; plain `bash 4-images.sh` builds all and
  writes `images/catalog.json` (8 images: SIF, GPU yes/no, packages). Built in parallel (one agent per SIF, ~20 min
  each with 7 at once; ml-classic ~2 min alone), then rebuilt once sequentially with the fixes below.

| Image (`master:5000/…`) | Size | Tested (CPU, `podman run` as 65534, answers = the model's own in the SIF) |
|---|---|---|
| `serve-ml-classic-cpu:943e17f6` | ~1 GB SIF | sklearn |
| `serve-pytorch-2.10.0-cuda12.9:ba605a18` | 17.4 GB | `nn.Sequential` as pt2, sitecustomize active |
| `serve-pytorch-vision-2.10.0-cuda12.9:8a11c265` | 18.7 GB | timm resnet18 (pt2); smp Unet as pyfunc |
| `serve-pytorch-nlp-2.10.0-cuda12.9:fdfa0be7` | 12.2 GB | transformers text-classification |
| `serve-pytorch-llm-2.10.0-cuda12.9:6aaaf782` | 11.7 GB | transformers text-generation (tiny GPT-2) + peft LoRA |
| `serve-tensorflow-2.21.0-cuda12.9:2243ad73` | 18.4 GB | Keras 3 via `mlflow.keras` and `mlflow.tensorflow` |
| `serve-tensorflow-nlp-2.21.0-cuda12.9:82c5f25e` | 17.8 GB | Keras TextVectorization model on raw strings |
| `serve-tensorflow-vision-2.21.0-cuda12.9:753b39fa` | 19.0 GB | MobileNetV3Small; wrong shape → clean 400 |

- **Problems → fixes:**
  - `tar: ./etc/shadow: Cannot open: Permission denied`: mode-000 files in the unprivileged sandbox → `chmod -R u+rX` first.
  - `podman stop` waited 10 s then SIGKILL (k8s: the whole 30 s grace): `mlflow` is PID 1 with no SIGTERM handler,
    uvicorn is its child → `STOPSIGNAL SIGINT` in the image; stop now 0.7 s.
  - `LD_LIBRARY_PATH` carried apptainer's `/.singularity.d/libs` and an empty entry (= cwd) → filtered out.
  - Tag only hashed the SIF, so a recipe change would be skipped as "already built" → the function's text is hashed too.
- **Found in the SIFs / MLflow (not fixed here):**
  - `pytorch-nlp`, `pytorch-llm` have no torchvision → `mlflow.transformers.save_model` / `log_model` fails
    (`No module named 'torchvision'`: MLflow's default requirements always add it). Workaround: `pip_requirements=[…]`;
    fix: torchvision 0.25 (cu129) in both `.def`s.
  - MLflow 3.15.1: `mlflow.keras.save_model(path=…)` fails if the folder doesn't exist (`log_model` is fine).
  - Keras text models: log the input example as `dtype=object`, or Keras rejects the strings.
- **Registry:** the 8 pre-fix tags and the v1 images `mlflow-serve-ml:3.15.1-9141c12c`,
  `mlflow-serve-torch:3.15.1-346a6fb0` deleted; then `sudo podman exec registry registry garbage-collect --delete-untagged …` to free the disk.
- **Not yet:** GPU (master has no GPU / CDI: pull + serve on cn01/cn02 next), vLLM part of the catalog, Model Hub
  still deploys with `mlflow-serve-ml` / `-torch` (switch in steps 2–3, then retire them).

## 2026-10-15 — step 3 deploy page: mockup and what it showed

- **Mockup** (throwaway, not kept): the real model page with the new deploy card, for 9 fake models (sklearn,
  torch, timm, transformers, Keras, LLM fits / capped / too big, missing package).
- **Presets, not CPU/RAM/GPU sliders:** serving platforms (HF Endpoints, SageMaker, Vertex, Azure ML) all pick an
  instance type; sliders fit jobs, not endpoints. Users don't know the numbers, GPUs are whole cards (quota 1 = a
  0/1 switch), free combinations can fit no node. A "Custom" preset under Advanced only if users ask.
- **Where the numbers come from:** the admin sizes `ENDPOINT_PRESETS`; the inspector picks one. LLM: weights
  (params × dtype bytes) + KV cache per token (2 × layers × KV heads × head dim × 2 B) must fit in card memory × 0.9
  minus ~1.5 GB. vLLM checks the same at start; the inspector only predicts it.
- **Nodes from Slurm only:** `sinfo -h -N -o "%P|%N|%c|%m|%G"` gives nodes, CPUs, RAM, GPU type/count in one call
  (cn01/cn02: 48 CPUs, 185000 MB, 1 A30; nothing reserved for the system). GPU memory isn't in Slurm: a site.conf
  table (`a30=24`) or DRA ResourceSlices (24Gi). k8s allocatable (~201 GB) is above Slurm's 185 GB, so Slurm is the
  limit to check presets against.
- **Gaps for step 3** (to write into the plan): the ML/DL sizing rule ("preset from the size") has no numbers yet;
  install must check every preset fits a node in `BRIDGE_PARTITION`; GPU presets need a GPU type once nodes differ.
- **Correction:** the mockup's "qwen2.5-7b capped" example is wrong: with GQA (4 KV heads) its KV cache is ~56 KB
  per token, so 32k context fits on an A30. Llama 3.1 8B (~128 KB per token) is the one that gets capped (~31k).

## 2026-10-15 — cluster monitoring (`OOD-Install/9-monitoring`) + "Cluster monitor" OOD app

Not a Model Hub step, but the deploy form (free GPUs, "over your GPU limit") and the admin page read from it.

- **Found first:** a hand-installed Prometheus + Grafana + node_exporter on master (scraping master and cn01 only,
  no GPUs, no Slurm, no alerts; used once via Grafana on Oct 12–13) → removed with the team's OK. The Prometheus in
  k8s (`monitoring` ns) is Sanket's, for KEDA: left alone (its `vllm-bench-autoscaler` points at a deleted deployment).
- **Built:** `1-install.sh` (master) installs Prometheus 3.5.5 + node_exporter 1.12.1 on every node (systemd, plain
  binaries, checksums pinned in site.conf), and two collectors of our own into node_exporter's textfile folder:
  `gpu-metrics.sh` (nvidia-smi, 15 s) and `slurm-metrics.py` (`scontrol`/`squeue --json`, 30 s). **Nothing from
  someone else's setup**: not the GPU operator's DCGM pods, not k8s, not Slurm's `metrics/openmetrics` (no
  slurm.conf change). `rules.yml`: named queries for apps + 7 alerts. Installs what's ours (+ curl/python3/tar);
  Slurm, the driver, firewalld, ssh, /home it only checks.
- **App:** `2-install-ood-app.sh` (login node) → OOD app `cluster_status`, "Cluster monitor" (Interactive Apps menu +
  home card, every user, read-only). Designed for scale on a 34-node mockup (not kept): summary (GPUs free by type, reserved
  but idle), one-square-per-node map, table grouped by node type with filters/sort, side panel per node; cards up
  to 8 nodes. One Prometheus query per 30 s refresh; filters and the open node in the URL.
- **Problems → fixes:**
  - Prometheus restarted in a loop: a `\` line continuation in the unit's ExecStart came out literal → one line.
  - cn01 skipped: no `/usr/local/bin` there → `install -D`.
  - slurmctld answers `/metrics` with an empty 200 when the plugin is off (we don't use it, but checks must look for
    `slurm_` lines, not the status code).
  - Slurm series are collected on master: Prometheus renamed their `node` to `exported_node` → `metric_relabel` back.
  - `up{job="node"}` vanished in `{…} or up`: `or` drops series whose labels match a recording rule's → one selector.
  - The A400 display card next to each A30 counted as a GPU → only the GPU types Slurm schedules are kept.
  - CPU showed 85 % right after a restart: a 5 min `rate()` on 2 min of data. Settles after 5 min.
  - App not on the home page: the cards are our own widget (`2-ood/branding/_ai_tools.html.erb`) → card added there.
- **Found, not fixed:** cn02 is down (no route to host, Slurm `down+not_responding`). firewalld is off on every node
  (ports 9090/9100 open to the LAN; the script never turns it on). The installed Keycloak listened on 127.0.0.1
  (unit from before the login-node split) while site.conf says MASTER_IP, so `setup-ood.sh` refused to run until
  `6-keycloak/1-install.sh` was rerun (done).
- **Not yet:** alert notifications (Alertmanager), "free GPUs now" line in Model Hub's deploy card (`slurm:gpus_free`).

## 2026-10-16 — monitoring hardening ([plan](../../../9-monitoring/cluster-status-improvement.md))

- **1.1 done:** `honor_labels: true` on the `node` job; the two `exported_node` metric_relabel rules are gone.
  Checked live: same series per `node` for `slurm_*`, `node_*`, `gpu_*` before and after; no `exported_node` left.
- **1.2 done:** node_exporter's systemd collector + critical alert `ServiceDown` (2 min). List = `MONITOR_UNITS` in
  site.conf; each node watches only the ones it has **enabled** (or `generated`: Keycloak's quadlets).
  - Problem: cn01 has `nfs-server` installed but disabled → read as "down" forever. Fix: node-setup.sh keeps only
    enabled/generated units. `list-unit-files` misses template instances (`dirsrv@aistack`) → `is-enabled` per
    loaded unit instead.
  - Test: `systemctl stop httpd` on master → pending after 30 s, firing at 2.5 min; httpd started again.
- **1.3 done:** node_exporter's own alert set (node-mixin, tag v1.12.1) in `node-alerts.yml`, rendered once from
  `node-alerts.jsonnet` (go-jsonnet 0.20.0, by hand; the install needs no jsonnet). Local filesystems only
  (`ext4|xfs|btrfs`); dropped `NodeCPUHighUsage`, `NodeSystemSaturation`, `NodeSystemdServiceFailed`; summary =
  the mixin's description with `node` instead of `instance` (the Cluster monitor shows summaries). Our
  `DiskAlmostFull`/`MemoryAlmostFull` removed; the app's alert icons follow the new names.
  - Live: 23 alerts loaded, all healthy, none firing. Covers `/` on master + cn01 and master's `/home`; RAID
    `md126`/`md127` seen on both nodes.
  - Gotcha: root's `mv` is `mv -i`: a scripted overwrite waits for an answer forever → `command mv -f`.
- **1.4 done:** `gpu-metrics.sh` adds `gpu_ecc_errors_uncorrected`, `gpu_remapped_rows_pending`, `gpu_hw_slowdown`
  from a **second** nvidia-smi call (an unknown field fails only that call). Alerts `GpuEccErrors` (critical),
  `GpuRemapPending`, `GpuThrottled`, `GpuMissing` (critical: Slurm has more GPUs than nvidia-smi shows).
  - cn01 (driver 580.142) knows all fields; uses `clocks_event_reasons.hw_slowdown` (the old `clocks_throttle_reasons`
    name still works). The A400 display card says `[N/A]` for ECC: left out (and filtered by GPU_TYPES anyway).
  - Live: 3 new series for cn01's A30, all 0; `GpuMissing` empty now, shows cn01 when Slurm's count is faked +1.
- **1.5 done:** Slurm command timeout 30 → 20 s (two calls stay under the unit's 60 s kill). The Cluster monitor
  lists a collector file older than 2 min (`node_textfile_mtime_seconds` vs Prometheus' own clock) in its
  "monitoring isn't collecting" note, as "slurm.prom on master, 2 min old".
  - Bug found: the app's one query never asked for `*_collector_ok`, so that note could never show. Added.
  - Test: `systemctl stop slurm-metrics.timer` → note after 2 min; timer started again, note gone.
- **1.6 done:** rule group `prometheus` (from prometheus-mixin): `PrometheusBadConfig` (reload failed, old config
  still running), `PrometheusRuleFailures`, `PrometheusTSDBCompactionsFailing`. Loaded, healthy, inactive.
  - Found with it: 18 evaluation failures of `SlurmNodeUnavailable` on 2026-10-15 16:45–16:52, "duplicate series"
    for `slurm_node_info`: a Prometheus **restart** at the same time as a collector label change (gpu_type added).
    A restart doesn't mark the old series stale, so old and new labels overlapped for the 5 min lookback. One-off,
    0 since; `for: 15m` wouldn't page on it. Not fixed (rare: needs a restart + a label change together).
- **1.7 done:** `rules_test.yml` (made-up series): `ServiceDown`, `GpuMissing` (incl. "node down → no alert"),
  `GpuEccErrors`, `GpuRemapPending`, `SlurmNodeUnavailable`'s join, `slurm:node_gpus_free`. `1-install.sh` runs
  `promtool check rules` + `promtool test rules` on the repo files **before** copying anything.
  - Test: `GpuMissing`'s `>` flipped to `<` in a copy → test FAILED; the installer run from that copy stopped with
    "Rules rejected", `/etc/prometheus/rules.yml` unchanged.
- **Phase 1 done.** Phase 2 (Alertmanager + email) waits for SMTP relay, sender, admin list, heartbeat target.
- **Order changed:** Phase 3 next, then UI changes, Phase 2 (email) last.
- **3.1 done:** blackbox_exporter 0.28.0 on master (`127.0.0.1:9115`, systemd `DynamicUser`; 0.29.0 skipped, 9 days
  old). Prometheus job `blackbox` tries OOD `https://master/` (2xx/3xx, redirect not followed), LDAP `master:636`
  (TLS handshake), Keycloak `/realms/aistack`, MLflow `<prefix>/health`, registry `/v2/`, gateway `/healthz`.
  Alert `ServiceUnreachable` (`probe_success == 0`, 3 min, critical) + rule test. Any certificate accepted (ours are
  self-signed), expiry still measured.
  - Live: all 6 answer (4–32 ms). Cert expiry: OOD 2027-09-24, gateway 2027-10-07, LDAP 2028-09-29. A closed port
    reads `probe_success 0` on both modules.
  - Keycloak's management `/health/ready` (`:9180`) is 404 (health endpoint not enabled): the realm URL is used,
    which also proves its database answers.
- **Plan:** new UI section U.1–U.6 in the plan (after Phase 3, before Phase 2): everything we watch must show on the
  Cluster monitor too, not only as an alert: Services tab (OK / Down per service), certificate days left, GPU health
  in the node panel, missing-GPU mark, monitoring health line, alert icons by family.
- **3.2 done:** `CertificateExpiresSoon` (7–30 days left, warning, 1 h) and `CertificateExpiresVerySoon` (< 7 days,
  critical) on `probe_ssl_earliest_cert_expiry`; rule tests for 20 / 3 / 400 days left. Live: OOD 343 days,
  gateway 356, LDAP 714; nothing firing.
- **3.3 done (changed from plan):** no `runbook_url` annotation on every rule (≈40 rules, the generated
  node-alerts.yml and every test's exp_annotations would all change). Instead: README "Alerts: what to do", one row
  per alert (34) with an anchor `<a id="<alertname lower case>">`, and `RUNBOOK_URL` in site.conf; the Cluster
  monitor (U.6) and the email template (Phase 2) build `RUNBOOK_URL#<alertname>`. `1-install.sh` warns when an
  alert has no row (checked both ways). Live install: no warning.
- **3.4 done:** `slurm-metrics.py` expands Slurm node lists (`cn[01-03,07]`, `r[1-2]n[09-10]`, zero padding) itself
  instead of one `scontrol show hostnames` per job: every run = exactly 2 Slurm calls (`scontrol show node`,
  `squeue`), whatever the job count. (The old cache never helped: each run is a new process.) Asserts in `--test`;
  same output as `scontrol show hostnames` for 5 lists. Live: service Result=success, `slurm_collector_ok 1`.
- **Phase 3 done.** Next: UI U.1–U.6, then Phase 2.
- **UI done (U.1–U.6), Cluster monitor:**
  - **Tabs** Nodes / Services (`#tab=services`); the Services tab shows a red count when something is down.
  - **Services tab:** a one-sentence status first ("Everything is answering" / "User accounts is down: Nobody can log
    in"); "What you connect to" (6 probes: OK / Down / Not checked, since when, response ms, certificate days, amber
    < 30, red < 7); "Running on the nodes" (systemd units in users' words + unit name, node chips, down first, chips
    open the node); "Monitoring" (settings loaded, N alert rules working, collectors fresh, service checks running).
  - **Nodes tab:** "Services 16/18" card (click → tab); ⚠ next to a node with a faulty GPU, a missing GPU or a core
    service down; GPU squares: faulty = red ring (like too hot), missing = dashed red; panel: "Needs attention" list
    with How to fix, GPU health under Status.
  - **Problems box:** most harm first (critical; then Service, TargetDown, Gpu, Certificate, disk, Prometheus), icon
    per family, **Show** (node panel or Services tab), **How to fix** (`RUNBOOK_URL#<alertname>`).
  - **Backend:** the same one query now also fetches probes, GPU health, Prometheus config and
    `node_systemd_unit_state{state="active"}` (via `or`: its labels clash with nothing); plus `rules` for rule health.
    New fields: `services`, `units`, `monitoring`, `runbook_url`, `gpu_missing`, GPU `ecc/remap/slow/missing`, alert
    `severity/node/service/unit`. `site.json` gets `runbook_url`.
  - Checked with headless Firefox screenshots of a harness (live data + staged LDAP down, slurmd down on cn01, GPU
    ECC errors, certificates 21 / 4 days): light, dark, 400 px phone, node panel. Fixed from them: problems sorted by
    name hid "LDAP down" behind Show all → sorted by impact; Services card mixed counts → probes + units; GPU table
    too wide in the panel → health under Status; problem rows wrapped badly on phones.
  - Gotcha: root's `cp` is `cp -i` too (like `mv`): `command cp -f` in scripts.
- **Cluster monitor = admin only:** like the Admin page, its folder is `root:<OOD_ADMIN's group>` 750/640, so OOD
  lists it only for `admin` and, since the app runs as the logged-in user, nobody else can open it by URL either.
  Home page card moved from Data & Cluster to the Admin section (hidden for others: the widget shows only apps the
  user can open). `2-install-ood-app.sh` checks both ways: a normal LDAP user can't read it (narmada: OK), the
  backend answers as `admin`. The home widget was redeployed with setup-ood.sh's own envsubst line.

# 4-vscode

VS Code in the browser (**code-server**) from an OOD page in the Model Hub look: **Interactive Apps -> VS Code**, pick where, **Launch**, then **Connect** on the session card. Every user gets **their own session, running as them**, so they see exactly the files they can see on disk (their home, anything shared with them) and nothing else.

```
                   one install on shared /home: $CODE_SERVER_ROOT/current/bin/code-server
page "Launch" ──sbatch─►  ┌─ "Editor only" → partition viewer on master: 1 CPU (shared), VSCODE_MEM
                         └─ "GPU node: n x <type>" → GPU partition: n GPUs + n x their share of CPUs/RAM
browser ◄── /rnode/<ip>/<port>/ (OOD proxy, per-session password) ──► code-server as <user>
```

**Why our own page, not OOD's batch_connect form:** same look as Model Hub and MLflow, and launch, status, Connect and Stop sit on one page.
OnDemand runs the page as the logged-in user, so it simply calls `sbatch`, `squeue` and `scancel` as them. It is still
one Slurm job per session (one code-server per user, see the Slurm note above): only the screen around it changed.
These sessions don't show under OOD's **My Interactive Sessions**; the VS Code page lists them.

```
```

## Run (on master, after ../1-ldap and ../2-ood)

```bash
sudo bash 1-install-code-server.sh   # code-server CODE_SERVER_VERSION -> CODE_SERVER_ROOT (shared /home)
sudo bash 2-slurm-viewer.sh          # partition "viewer" on master with OverSubscribe=FORCE:<n>
sudo bash 3-install-ood-app.sh       # the OOD app, then Restart Web Server in OOD
```

**Why master's Slurm node is called `viewer01` (`VIEWER_NODE`), not `master`:** slurm-bridge taints every k8s node
whose name matches a Slurm node (`slinky.slurm.net/managed-node:NoExecute`) and re-adds the taint if removed.
Named `master`, that evicted every pod on master without the toleration: coredns (cluster DNS), cert-manager,
gpu-operator, KEDA, Prometheus, MetalLB. A different `NodeName` with `NodeHostname=master` is the same machine to
Slurm but no match for slurm-bridge (tested 2026-09-30: taint removed, not re-added).

## GPU sessions

`3-install-ood-app.sh` asks Slurm (`gpu-detect.sh`) what the GPU nodes have and writes one choice per GPU count into the form: this cluster gets `GPU node: 1 x A30`, a cluster with 8 × H100 per node gets `1 x H100` … `8 x H100`. Nothing to type per cluster: `GPU_PARTITION=auto` in `site.conf` (or a partition name, or `""` for no GPU choice).

A session with n GPUs asks Slurm for `--gres=gpu:n` (any GPU type), `n x` the per-GPU share of cores and `n x` the per-GPU share of RAM, so 8 GPUs = the whole node, 1 GPU = 1/8 of it. VS Code then runs **on that node**: its terminal, notebooks and debugger see those GPUs (`CUDA_VISIBLE_DEVICES`). The GPUs stay held until the session ends (hours picked, or `VSCODE_IDLE_SECONDS` without a browser), so long training belongs in `sbatch`, which frees them when done.

## Master: sessions and SSH side by side

Master (48 cores / 192 GB here) runs the tool sessions **and** everything else: SSH logins, OOD, LDAP, the k8s control plane, MLflow, slurmctld, the registry. `2-slurm-viewer.sh` splits it with Slurm's own reservation settings, taking the hardware from `slurmd -C`:

| | Cores | Memory | Used by |
|---|---|---|---|
| **kept out of Slurm** (`CoreSpecCount`, `MemSpecLimit`) | `VIEWER_RESERVED_CORES` = 8 | `VIEWER_RESERVED_MEM_MB` = 48 GB | SSH users, OOD, LDAP, k8s, MLflow, slurmctld, registry |
| **partition `viewer`** | the other 40, shared `FORCE:4` | the other ~135 GB | OOD tool sessions |

Slurm never gives the reserved share to a session, so SSH and the services always have room, however many editors are open. cgroups (`ConstrainCores`, `ConstrainRAMSpace` in `cgroup.conf`) hold every session to what it asked for.

**How many sessions fit:** an open editor uses almost no CPU, so up to `VIEWER_OVERSUBSCRIBE` (4) share a core: 40 × 4 = **160 by CPU**. Memory is reserved per session (`VSCODE_MEM` = 2 GB), so **~67 at once** by memory, which is the real limit. More users: lower `VSCODE_MEM` or the reservation. Heavy work goes to the compute nodes, not the editor: `sbatch` from VS Code's terminal, or a **GPU node** session (that one holds its GPUs and their share of the node for the whole session).

SSH users themselves are not limited by Slurm: one of them running something huge on master still competes with everyone. They share fairly (cgroup CPU weights), and heavy work belongs in `sbatch`.

## Per user

| | Where | Shared with others? |
|---|---|---|
| the program | `CODE_SERVER_ROOT/current` | yes, one read-only install |
| the process | a Slurm job, as the user | no, one per session |
| files it can open | whatever the user can read on disk | no, Linux permissions |
| extensions, settings, keybindings | `~/.local/share/code-server/` | no, theirs, kept between sessions |
| session password | random per session, in `~/.vscode-sessions/<job>.json` (mode 600), sent on **Connect** | no |

Extensions install from **Open VSX** (open-vsx.org), not Microsoft's marketplace, so a few Microsoft-only ones (Pylance, Remote-SSH, Copilot) aren't there. Python, Jupyter, GitLens, Ruff and most others are. Nodes need internet for that, or users install `.vsix` files.

## Files

| File | What it does |
|---|---|
| `1-install-code-server.sh` | release tarball (resumes a dropped download) -> `CODE_SERVER_ROOT/<version>`, `current` symlink, checks `--version` on master and each compute node |
| `2-slurm-viewer.sh` | sets `NodeName=<VIEWER_NODE> NodeHostname=<master>` from `slurmd -C` (98% of RAM) + `CoreSpecCount`/`MemSpecLimit`, and the `viewer` partition with `OverSubscribe=FORCE:n`; copies `slurm.conf` to the compute nodes; restarts slurmctld + master's slurmd only if the node line changed, then `scontrol reconfigure` |
| `3-install-ood-app.sh` | copies `ood-app/vscode` to `/var/www/ood/apps/sys/vscode`, fills `${...}` in `job.sh` from `site.conf`, writes `site.json` (partitions, `VSCODE_MEM`, GPU sizes from `gpu-detect.sh`) |
| `gpu-detect.sh` | reads `sinfo`: the GPU partition (`GPU_PARTITION=auto`: the default one with GPUs, else the first), GPU type, GPUs per node, and each GPU's share of the node (cores ÷ GPUs, 90% of RAM ÷ GPUs, smallest node) |
| `ood-app/vscode/passenger_wsgi.py` | the page (stdlib only, Model Hub's Bootstrap + `style.css`): choices, `sbatch` with the Slurm options for each, session list from `squeue -n vscode`, Connect, Stop (`scancel`). Deletes files older than 7 days in `~/.vscode-sessions` |
| `ood-app/vscode/job.sh` | the Slurm job: free port, session password, starts code-server, writes `~/.vscode-sessions/<job>.json` once it answers (the page shows **Starting** until then), removes it on exit. Log: `~/.vscode-sessions/<job>.log` |

`/rnode` (not `/node`) strips the `/rnode/<host>/<port>` prefix, because code-server expects to sit at `/`.

## Upgrade code-server

Set `CODE_SERVER_VERSION` in `site.conf`, rerun `1-install-code-server.sh` (it flips `current`). Running sessions keep the old version until they end. Delete old version folders when nothing uses them.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `1-install-code-server.sh`: `unexpected end of file` / `Download failed` | the download dropped | rerun: it resumes the partial file |
| session stays **Waiting** | `viewer` is out of memory (sessions × `VSCODE_MEM` > RAM − `VIEWER_RESERVED_MEM_MB`), or no free GPU | `squeue -p viewer`; lower `VSCODE_MEM` or the reservation, or wait |
| master **drained**, `Reason=Low RealMemory` | `RealMemory` above what the kernel reports | rerun `2-slurm-viewer.sh` (it takes 98% of `slurmd -C`), then `scontrol update nodename=<VIEWER_NODE> state=resume` |
| GPU choices are wrong or missing after adding/changing GPU nodes | the form is written at install time from `sinfo` | rerun `3-install-ood-app.sh`, then Restart Web Server |
| `sbatch` from VS Code's terminal fails, the same script works from SSH | the session is itself a Slurm job; its `SLURM_*` variables leaked into the new job (e.g. `SLURM_MEM_PER_NODE` vs `SLURM_MEM_PER_CPU`) | the job script clears `SLURM_*`/`SBATCH_*` before starting code-server; rerun `3-install-ood-app.sh` and start a new session |
| cluster DNS down; coredns, KEDA, Prometheus… **Pending** (`untolerated taint`) | master's Slurm node is named like the k8s node (`NodeName=master`), so slurm-bridge taints master `NoExecute` | set `VIEWER_NODE` (≠ hostname), rerun `2-slurm-viewer.sh`: it renames the node and removes the taint |
| code-server exits at once, printing nothing | `VSCODE_IPC_HOOK_CLI` is set (started from a VS Code terminal): it hands the folder to that editor and quits | `unset VSCODE_IPC_HOOK_CLI` (the job script does this) |
| session starts then disappears, `~/.vscode-sessions/<job>.log`: `code-server did not start` | wrong `CODE_SERVER_ROOT`, or code-server crashed (the log shows why) | check `CODE_SERVER_ROOT/current/bin/code-server --version` on that node |
| page: `Could not ask Slurm for your sessions` | `SLURM_BIN` in `site.conf` is not the folder of `squeue`/`sbatch` | fix it, rerun `3-install-ood-app.sh` |
| old sessions under **My Interactive Sessions** show errors after the upgrade | they were started by the old batch_connect form, which is gone | they still run until their hours end; `scancel <job>` to end them now |
| **Connect** shows code-server's login page | the password didn't reach it (`$PASSWORD` not exported) | relaunch; check `job.sh` exports `PASSWORD` |
| `slurmd: command not found` (or `sinfo`, `srun`) under `sudo` | sudo's `secure_path` drops `/usr/local/bin` and `/usr/local/sbin` | the scripts add `SLURM_BIN` and its `sbin` to `PATH`; set `SLURM_BIN` in `site.conf` to the folder of `sbatch` |
| `2-slurm-viewer.sh`: `Could not copy to <node>` | no root ssh to that node | copy `SLURM_CONF` there by hand (it must match everywhere), rerun |
| extension missing from the marketplace | not on Open VSX | install a `.vsix` (Extensions → … → Install from VSIX) |

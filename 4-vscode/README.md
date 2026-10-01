# 4-vscode

VS Code in the browser (**code-server**) as an OOD Interactive App: **Interactive Apps -> VS Code -> Launch**. Every user gets **their own session, running as them**, so they see exactly the files they can see on disk (their home, anything shared with them) and nothing else.

```
                   one install on shared /home: $CODE_SERVER_ROOT/current/bin/code-server
OOD "Launch" ──Slurm──►  ┌─ "Editor only" → partition viewer on master: 1 CPU (shared), VSCODE_MEM
                         └─ "GPU node: n x <type>" → GPU partition: n GPUs + n x their share of CPUs/RAM
browser ◄── /rnode/<ip>/<port>/ (OOD proxy, per-session password) ──► code-server as <user>
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
| session password | random per session, only on the owner's session card | no |

Extensions install from **Open VSX** (open-vsx.org), not Microsoft's marketplace, so a few Microsoft-only ones (Pylance, Remote-SSH, Copilot) aren't there. Python, Jupyter, GitLens, Ruff and most others are. Nodes need internet for that, or users install `.vsix` files.

## Files

| File | What it does |
|---|---|
| `1-install-code-server.sh` | release tarball (resumes a dropped download) -> `CODE_SERVER_ROOT/<version>`, `current` symlink, checks `--version` on master and each compute node |
| `2-slurm-viewer.sh` | sets `NodeName=<VIEWER_NODE> NodeHostname=<master>` from `slurmd -C` (98% of RAM) + `CoreSpecCount`/`MemSpecLimit`, and the `viewer` partition with `OverSubscribe=FORCE:n`; copies `slurm.conf` to the compute nodes; restarts slurmctld + master's slurmd only if the node line changed, then `scontrol reconfigure` |
| `3-install-ood-app.sh` | fills `${...}` in `ood-app/vscode` from `site.conf` (`envsubst`), copies to `/var/www/ood/apps/sys/vscode` |
| `ood-app/vscode/form.yml` | where (editor only, or `GPU node: n x <type>` for n = 1 .. GPUs per node, written in at install), hours |
| `gpu-detect.sh` | reads `sinfo`: the GPU partition (`GPU_PARTITION=auto`: the default one with GPUs, else the first), GPU type, GPUs per node, and each GPU's share of the node (cores ÷ GPUs, 90% of RAM ÷ GPUs, smallest node) |
| `ood-app/vscode/submit.yml.erb` | the Slurm options for each choice |
| `ood-app/vscode/template/before.sh.erb` | node IP, free port, session password (`$PASSWORD` for code-server) |
| `ood-app/vscode/template/script.sh.erb` | `cd` into the chosen folder, `exec code-server --auth password` |
| `ood-app/vscode/view.html.erb` | **Connect to VS Code**: posts the password to code-server's login through `/rnode` |

`/rnode` (not `/node`) strips the `/rnode/<host>/<port>` prefix, because code-server expects to sit at `/`.

## Upgrade code-server

Set `CODE_SERVER_VERSION` in `site.conf`, rerun `1-install-code-server.sh` (it flips `current`). Running sessions keep the old version until they end. Delete old version folders when nothing uses them.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `1-install-code-server.sh`: `unexpected end of file` / `Download failed` | the download dropped | rerun: it resumes the partial file |
| session stays **Queued** | `viewer` is out of memory (sessions × `VSCODE_MEM` > RAM − `VIEWER_RESERVED_MEM_MB`), or no free GPU | `squeue -p viewer`; lower `VSCODE_MEM` or the reservation, or wait |
| master **drained**, `Reason=Low RealMemory` | `RealMemory` above what the kernel reports | rerun `2-slurm-viewer.sh` (it takes 98% of `slurmd -C`), then `scontrol update nodename=<VIEWER_NODE> state=resume` |
| launch fails: `undefined local variable or method '<field>'` | job templates (`template/*.erb`) get form values as `context.<field>`; only `submit.yml.erb` gets bare names | use `context.<field>` in templates, then rerun `3-install-ood-app.sh` |
| a field meant for one choice shows for all | per-option hiding (`data-hide-*`) needs OOD's `bc_dynamic_js`, which is off by default | keep the form flat (it is): the GPU count is part of the "Where to run" choice |
| GPU choices are wrong or missing after adding/changing GPU nodes | the form is written at install time from `sinfo` | rerun `3-install-ood-app.sh`, then Restart Web Server |
| `sbatch` from VS Code's terminal fails, the same script works from SSH | the session is itself a Slurm job; its `SLURM_*` variables leaked into the new job (e.g. `SLURM_MEM_PER_NODE` vs `SLURM_MEM_PER_CPU`) | the job script clears `SLURM_*`/`SBATCH_*` before starting code-server; rerun `3-install-ood-app.sh` and start a new session |
| cluster DNS down; coredns, KEDA, Prometheus… **Pending** (`untolerated taint`) | master's Slurm node is named like the k8s node (`NodeName=master`), so slurm-bridge taints master `NoExecute` | set `VIEWER_NODE` (≠ hostname), rerun `2-slurm-viewer.sh`: it renames the node and removes the taint |
| code-server exits at once, printing nothing | `VSCODE_IPC_HOOK_CLI` is set (started from a VS Code terminal): it hands the folder to that editor and quits | `unset VSCODE_IPC_HOOK_CLI` (the job script does this) |
| session starts then ends, `output.log`: `code-server did not start` | wrong path, or the folder can't be opened | check `CODE_SERVER_ROOT/current/bin/code-server --version` on that node; leave "Folder" empty |
| **Connect** shows code-server's login page | the password didn't reach it (old session card, or `$PASSWORD` not exported) | relaunch; check `before.sh.erb` exports `PASSWORD` |
| `slurmd: command not found` (or `sinfo`, `srun`) under `sudo` | sudo's `secure_path` drops `/usr/local/bin` and `/usr/local/sbin` | the scripts add `SLURM_BIN` and its `sbin` to `PATH`; set `SLURM_BIN` in `site.conf` to the folder of `sbatch` |
| `2-slurm-viewer.sh`: `Could not copy to <node>` | no root ssh to that node | copy `SLURM_CONF` there by hand (it must match everywhere), rerun |
| extension missing from the marketplace | not on Open VSX | install a `.vsix` (Extensions → … → Install from VSIX) |

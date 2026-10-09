# 7-jupyter

JupyterLab in the browser from an OOD page that looks like VS Code's: **Interactive Apps -> Jupyter**, pick where, **Launch**, then **Connect** on the session card. Every user gets **their own session, running as them**, so they see exactly the files they can see on disk and nothing else. Same as [../4-vscode](../4-vscode/README.md), with JupyterLab instead of code-server.

```
                   one install on shared /home: $JUPYTER_ROOT/current/bin/jupyter (own Python 3.12)
page "Launch" ──sbatch─►  ┌─ "Notebook only" → partition viewer on master: 1 CPU (shared), JUPYTER_MEM
                         └─ "GPU node: n x <type>" → GPU partition: n GPUs + n x their share of CPUs/RAM
browser ◄── /node/<ip>/<port>/ (OOD proxy, per-session token) ──► jupyter lab as <user>
                                                                   └─ kernels: containers (apptainer --nv) or the user's own
```

**Why a Slurm job, not one shared server like MLflow:** MLflow only stores data, so one server can check permissions for everyone. Jupyter **runs the user's code**, and a process can only run as one Linux user, so each person needs their own Jupyter. JupyterHub would still start one Jupyter per user (on Slurm, the same as here) and add a second login and a second server to run. OOD already does its job.

**Shared with 4-vscode (not copied):** the page (`../4-vscode/ood-app/vscode/passenger_wsgi.py`, `site.json` `"app": "jupyter"` picks the texts), `gpu-detect.sh`, and the `viewer` partition. Change the page there; rerun both installers.

## Run (on master, after ../4-vscode)

```bash
sudo bash 1-install-jupyter.sh    # own Python + JupyterLab (requirements.txt) -> JUPYTER_ROOT, container kernels
sudo bash 2-install-ood-app.sh    # the OOD page, then Restart Web Server in OOD
```

## Kernels

| Kernel | What it is | Packages |
|---|---|---|
| `<sif name> (container)` | every `CONTAINERS_ROOT/training/*/*.sif`: `apptainer exec --nv <sif> python -m ipykernel_launcher`, like the training scripts | the container's (torch, transformers, sklearn…); GPU in a GPU session |
| `Python 3 (ipykernel)` | JupyterLab's own Python | almost nothing; read-only |
| anything in `/usr/local/share/jupyter/kernels` on a node | Jupyter also lists a node's system kernels (on this cluster: master's quantum conda envs) | only in sessions on that node |
| the user's own | any env with `ipykernel`: `python -m ipykernel install --user --name myenv` | theirs, in `~/.local/share/jupyter/kernels` |

**New images show up by themselves:** `job.sh` looks in `CONTAINERS_ROOT/training/` when a session starts and writes one kernel per SIF into `~/.jupyter-sessions/<job>.kernels/` (on `JUPYTER_PATH`, deleted when the session ends). Copy a SIF in, and the next session has it; no installer, no restart. The rule that makes this cheap: **every training image has `ipykernel`** (`/home/apps/containers/README.md`), so nothing is checked per image. Images in `serving/` are never kernels.

## Per user

| | Where | Shared with others? |
|---|---|---|
| the program | `JUPYTER_ROOT/current` (venv on its own Python) | yes, one read-only install |
| the process | a Slurm job, as the user | no, one per session |
| files it can open | whatever the user can read on disk (the file browser starts at `$HOME`) | no, Linux permissions |
| settings, own kernels | `~/.jupyter`, `~/.local/share/jupyter` | no, theirs, kept between sessions |
| session token | random per session, in `~/.jupyter-sessions/<job>.json` (mode 600); **Connect** opens `/node/<ip>/<port>/lab?token=…`, which sets Jupyter's login cookie | no |

**Idle:** a kernel that is idle (not running a cell) with no browser attached for `JUPYTER_IDLE_SECONDS` is stopped. Once no kernels are left and no browser has called in for that long, the session ends and frees its CPUs, memory and GPUs. A cell that is still running keeps the session alive until its hours run out.

**Why its own Python:** JupyterLab 4.6 needs Python ≥ 3.10; AlmaLinux 9 nodes have 3.9. A python-build-standalone build (`JUPYTER_PYTHON`) unpacked on the shared `/home` runs on every node without installing anything there. JupyterLab sits in a **venv** on top of it: a venv ignores `~/.local/lib/python3.12`, so a user's `pip install --user` (from a container kernel, also Python 3.12) can't break their Jupyter server.

## Files

| File | What it does |
|---|---|
| `1-install-jupyter.sh` | Python tarball (resumes a dropped download) -> `JUPYTER_ROOT/<lab>-py<python>/python`, venv + `pip install -r requirements.txt` (no-op when already there), removes container kernels older installs wrote, `current` symlink, checks on master and each compute node |
| `requirements.txt` | JupyterLab + ipykernel, fully pinned (`pip freeze`). The install folder is named after its `jupyterlab==` |
| `2-install-ood-app.sh` | copies the shared page + `ood-app/jupyter` to `/var/www/ood/apps/sys/jupyter`, fills `${...}` in `job.sh` from `site.conf`, writes `site.json` (partitions, `JUPYTER_MEM`, GPU sizes) |
| `ood-app/jupyter/job.sh` | the Slurm job: container kernels from `CONTAINERS_ROOT/training/`, free port, session token, `jupyter lab` with `base_url=/node/<ip>/<port>/`, writes `~/.jupyter-sessions/<job>.json` once it answers, removes it on exit. Log: `~/.jupyter-sessions/<job>.log` |

`/node` (not `/rnode`, unlike code-server): Jupyter knows its own path (`base_url`) and builds every link with it.

**Why Connect is a `?token=` link, not a posted password like VS Code:** Jupyter's login form also wants an `_xsrf` value from its own page, so a post from OOD's page gets 403. OSC's Jupyter app turns XSRF checks off instead; we keep them on and use Jupyter's standard token link. The token only lives as long as the session.

## Upgrade

JupyterLab: in a scratch venv on the standalone Python, `pip install jupyterlab==<new> ipykernel`, `pip freeze` into `requirements.txt` (keep its two comment lines), rerun `1-install-jupyter.sh`. Python: set `JUPYTER_PYTHON` (a python-build-standalone release `<version>+<date>`), rerun. Each gives a new folder and flips `current`; running sessions keep the old one until they end. Delete old folders when nothing uses them.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `1-install-jupyter.sh`: `Download failed` / pip `Read timed out` | the internet dropped | rerun: the download resumes, pip retries |
| session stays **Waiting** | `viewer` is out of memory, or no free GPU | `squeue -p viewer`; lower `JUPYTER_MEM` / `VSCODE_MEM`, or wait |
| session starts then disappears, `~/.jupyter-sessions/<job>.log`: `jupyter did not start` | wrong `JUPYTER_ROOT`, or Jupyter crashed (the log shows why) | `JUPYTER_ROOT/current/bin/jupyter lab --version` on that node |
| notebook opens but the kernel never connects ("Connecting…") | the browser's address is not `https://OOD_SERVERNAME` (kernels only accept that origin) | open OOD by that name, or set `OOD_SERVERNAME` and rerun `2-install-ood-app.sh` |
| **Connect** shows Jupyter's login page | the token didn't match | relaunch; check `job.sh` exports `JUPYTER_TOKEN` |
| container kernel dies at once | the image has no `ipykernel`, or it was moved during the session | add `ipykernel` to its `.def` and rebuild; start a new session |
| a new image doesn't show | the session started before it was copied, or it's not at `training/<family>/<name>.sif` | start a new session; check the path |
| `torch.cuda.is_available()` is False | a **Notebook only** session (no GPU), or a non-container kernel | launch a **GPU node** session, pick a `(container)` kernel |
| `sbatch` from Jupyter's terminal fails, the same script works from SSH | the session's own `SLURM_*` variables leaked | `job.sh` clears them; rerun `2-install-ood-app.sh`, start a new session |
| GPU choices are wrong after changing GPU nodes | the form is written at install time from `sinfo` | rerun `2-install-ood-app.sh`, then Restart Web Server |

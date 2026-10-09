#!/usr/bin/env bash
# Install JupyterLab ONCE on the shared /home, so every node runs the same copy:
#   $JUPYTER_ROOT/<jupyterlab version>-py<python version>/   and   $JUPYTER_ROOT/current -> it
# It brings its own Python (python-build-standalone): JupyterLab needs Python >= 3.10, AlmaLinux 9 nodes have 3.9.
# Kernels: every training image in $CONTAINERS_ROOT (made by each session's job.sh, see 2-install-ood-app.sh),
# plus whatever each user adds to ~/.local/share/jupyter/kernels. Each user's settings live in their own ~/.jupyter.
# Run on master: sudo bash 1-install-jupyter.sh      Safe to rerun; old versions stay until you delete them.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
# sudo resets PATH to /usr/sbin:/usr/bin (misses a Slurm under /usr/local) and drops SLURM_CONF
# (then the tools look for a config in DNS: "resolve_ctls_from_dns_srv ... Unknown host")
export PATH="$SLURM_BIN:${SLURM_BIN%/bin}/sbin:$PATH" SLURM_CONF
[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes $JUPYTER_ROOT)." >&2; exit 1; }
LAB=$(sed -n 's/^jupyterlab==//p' "$HERE/requirements.txt")
PY=${JUPYTER_PYTHON%%+*}
DIR=$JUPYTER_ROOT/$LAB-py$PY
URL=https://github.com/astral-sh/python-build-standalone/releases/download/${JUPYTER_PYTHON#*+}/cpython-${JUPYTER_PYTHON/+/%2B}-x86_64-unknown-linux-gnu-install_only.tar.gz

echo "== 1. Python $PY -> $DIR/python"
if [ -x "$DIR/python/bin/python3" ]; then
  echo "already there"
else
  mkdir -p "$DIR"
  TGZ=$JUPYTER_ROOT/.python-$JUPYTER_PYTHON.tgz.part
  for try in 1 2 3 4 5; do
    curl -fL --retry 3 -C - -o "$TGZ" "$URL" && gzip -t "$TGZ" 2>/dev/null && break
    echo "download incomplete, resuming ($try/5)"; sleep 5
  done
  gzip -t "$TGZ" || { echo "Download failed. Rerun to resume, or fetch $URL by hand to $TGZ." >&2; exit 1; }
  tar xzf "$TGZ" -C "$DIR"                       # unpacks to $DIR/python
  rm -f "$TGZ"
fi

echo "== 2. JupyterLab $LAB (requirements.txt) -> $DIR"
# A venv, not the bare Python: a venv ignores ~/.local/lib/python3.12, so a user's `pip install --user`
# (from a container kernel, also Python 3.12) can't replace packages under their Jupyter server.
[ -x "$DIR/bin/python" ] || "$DIR/python/bin/python3" -m venv "$DIR"
"$DIR/bin/pip" install -q --disable-pip-version-check --retries 10 --timeout 60 -r "$HERE/requirements.txt"   # no-op when already there

# Container kernels used to be written here; sessions make them now (job.sh). Remove old ones (stale SIF paths).
find "$DIR/share/jupyter/kernels" -mindepth 1 -maxdepth 1 ! -name python3 -exec rm -rf {} +   # python3 = the venv's own
ln -sfn "$(basename "$DIR")" "$JUPYTER_ROOT/current"
chmod -R a+rX "$JUPYTER_ROOT"

echo "== 3. Check (on master, and from the shared /home on each compute node)"
"$JUPYTER_ROOT/current/bin/jupyter" lab --version
"$JUPYTER_ROOT/current/bin/jupyter" kernelspec list
for n in $COMPUTE_NODES; do
  printf '%s: ' "$n"
  timeout 60 srun -w "$n" -t 1 -N1 -n1 "$JUPYTER_ROOT/current/bin/jupyter" lab --version 2>&1 | grep -m1 -E "^[0-9]+\." || echo "(srun failed, check by hand)"
done
echo
echo "Done. Next: sudo bash 2-install-ood-app.sh"

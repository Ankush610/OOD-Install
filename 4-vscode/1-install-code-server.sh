#!/usr/bin/env bash
# Install code-server (VS Code in the browser) ONCE on the shared /home, so every node runs the same copy:
#   $CODE_SERVER_ROOT/<version>/   and   $CODE_SERVER_ROOT/current -> <version>
# Each user's extensions and settings live in their own ~/.local/share/code-server, not here.
# Run on master: sudo bash 1-install-code-server.sh      Safe to rerun; old versions stay until you delete them.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../site.conf"
# sudo resets PATH to /usr/sbin:/usr/bin (misses a Slurm under /usr/local) and drops SLURM_CONF
# (then the tools look for a config in DNS: "resolve_ctls_from_dns_srv ... Unknown host")
export PATH="$SLURM_BIN:${SLURM_BIN%/bin}/sbin:$PATH" SLURM_CONF
[ "$(id -u)" = 0 ] || { echo "Run with sudo (writes $CODE_SERVER_ROOT)." >&2; exit 1; }
V=$CODE_SERVER_VERSION
DIR=$CODE_SERVER_ROOT/$V
URL=https://github.com/coder/code-server/releases/download/v$V/code-server-$V-linux-amd64.tar.gz

echo "== 1. code-server $V -> $DIR"
if [ -x "$DIR/bin/code-server" ]; then
  echo "already there"
else
  # ~220 MB; the download can drop halfway, so resume (-C -) until the archive checks out
  mkdir -p "$CODE_SERVER_ROOT"
  TGZ=$CODE_SERVER_ROOT/.code-server-$V.tgz.part
  for try in 1 2 3 4 5; do
    curl -fL --retry 3 -C - -o "$TGZ" "$URL" && gzip -t "$TGZ" 2>/dev/null && break
    echo "download incomplete, resuming ($try/5)"; sleep 5
  done
  gzip -t "$TGZ" || { echo "Download failed. Rerun to resume, or fetch $URL by hand to $TGZ." >&2; exit 1; }
  mkdir -p "$DIR"
  tar xzf "$TGZ" -C "$DIR" --strip-components=1
  rm -f "$TGZ"
fi
ln -sfn "$V" "$CODE_SERVER_ROOT/current"
chmod -R a+rX "$CODE_SERVER_ROOT"

echo "== 2. Check (on master, and from the shared /home on each compute node)"
"$CODE_SERVER_ROOT/current/bin/code-server" --version 2>&1 | grep -m1 -E "^[0-9]+\."
for n in $COMPUTE_NODES; do
  printf '%s: ' "$n"
  timeout 60 srun -w "$n" -t 1 -N1 -n1 "$CODE_SERVER_ROOT/current/bin/code-server" --version 2>&1 | grep -m1 -E "^[0-9]+\." || echo "(srun failed, check by hand)"
done
echo
echo "Done. Next: sudo bash 2-slurm-viewer.sh"

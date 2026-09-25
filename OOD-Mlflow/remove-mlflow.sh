#!/usr/bin/env bash
# Move everything 2-mlflow-app.sh installs into ~/temp-backup, so the setup can be tested from scratch.
# Users' ~/mlflow data and the Slurm "viewer" partition are NOT touched.
# Run on master: sudo bash remove-mlflow.sh
# New setup works -> sudo rm -rf ~/temp-backup     Broken -> sudo bash remove-mlflow.sh --restore
set -euo pipefail

BACKUP="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)/temp-backup"
ITEMS=(/var/www/ood/apps/sys/mlflow /var/www/ood/apps/sys/mlflow_gc /home/apps/mlflow-venv)

if [ "${1:-}" = "--restore" ]; then
  [ -d "$BACKUP" ] || { echo "No $BACKUP to restore from." >&2; exit 1; }
  for p in "${ITEMS[@]}"; do
    [ -e "$BACKUP/$(basename "$p")" ] || continue
    rm -rf "$p"
    mv "$BACKUP/$(basename "$p")" "$p"
    echo "restored $p"
  done
  rmdir "$BACKUP"
  echo "Done. Restart Web Server in OOD."
  exit 0
fi

[ -e "$BACKUP" ] && { echo "$BACKUP already exists, restore or remove it first." >&2; exit 1; }
if [ -n "$(squeue -h -p viewer 2>/dev/null)" ]; then
  echo "MLflow sessions still running (squeue -p viewer). Delete them in OOD first." >&2
  exit 1
fi

mkdir -p "$BACKUP"
for p in "${ITEMS[@]}"; do
  [ -e "$p" ] || { echo "skip $p (not there)"; continue; }
  mv "$p" "$BACKUP/"
  echo "moved $p -> $BACKUP/"
done

cat <<EOF

Done. Restart Web Server in OOD: MLflow should be gone from Interactive Apps.
Then:   sudo bash 2-mlflow-app.sh
Works:  sudo rm -rf $BACKUP
Broken: sudo bash remove-mlflow.sh --restore
EOF

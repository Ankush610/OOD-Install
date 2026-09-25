# OOD-Install

Open OnDemand 4.2 + a per-user MLflow 3.15.1 app on the dummy cluster.

```
laptop ──ssh──> network-node (10.208.34.138) ──ssh──> master (OOD, MLflow)  +  cn01, cn02 (training)
```

| Folder | What it sets up |
|---|---|
| [OOD-Setup](OOD-Setup/README.md) | OOD web portal on master: packages, test login, SSL, Slurm cluster file |
| [OOD-Mlflow](OOD-Mlflow/README.md) | `viewer` Slurm partition on master, shared MLflow, the MLflow app with Copy + Clean buttons |

## Run order (on master, as root)

```bash
sudo bash OOD-Setup/setup-ood.sh
sudo bash OOD-Mlflow/1-slurm-viewer.sh
sudo bash OOD-Mlflow/2-mlflow-app.sh
```

All scripts are safe to rerun. Check the variables at the top of each one first.

## Open it from the laptop

```bash
sudo ssh -J ankush@10.208.34.138 -L 443:localhost:443 admin@master
```

Then open **https://localhost**. The tunnel must use local port **443**, because OOD redirects every other port away.

**After any config edit:** click **Restart Web Server** in OOD's top-right menu, because OOD caches its config per user.

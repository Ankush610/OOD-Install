# Model Hub — full user flow (all versions)

The whole path once every version is built. Steps marked **(v2+)** are not in v1.
Per-model-type diagrams with the tools v1 actually uses: [versions/version-1/user-flow.md](../versions/version-1/user-flow.md).

```
You ──► OOD login (LDAP: same username + password as SSH, Slurm, MLflow)
          │
          ▼
       Dashboard
          │
 ═════════╪══════ 1. PREPARE ═══════════════════════════════════════════════════
          ├──► Files app: upload data ──► ~/data/        (shared datasets: /home/apps/datasets)
          └──► VS Code / Jupyter app: write train.py + job.sh
          │
 ═════════╪══════ 2. TRAIN (Slurm + Apptainer SIF) ═════════════════════════════
          ▼
   sbatch job.sh ──► Slurm ──► CPU or GPU node ──► apptainer exec [--nv] <training>.sif
          │
          ├──► params / metrics ──► shared MLflow (token from ~/.mlflow/credentials)
          └──► model ──► MLflow artifacts (ML, DL)   or   ~/models/<name>/vN/ (LLMs, big DL)
          │
 ═════════╪══════ 3. REGISTER (MLflow Model Registry = the catalog) ════════════
          ▼
   MLflow UI [Register model] / log_model(registered_model_name=) / model-register DIR NAME
          │
          ├──► private: only you (and whoever you grant in MLflow) see it
          └──► (v2+) model-publish ──► /home/apps/models/published/<you>/<name>/vN  (read-only, everyone)
          │
 ═════════╪══════ 4. DEPLOY (Model Hub OOD app) ════════════════════════════════
          ▼
   Model Hub lists every registered model you may see ──► [Deploy]
   runtime (auto from format) · CPU or GPU type · lifetime 24 h · (v2+) share with …
          │
          ▼
   pod in YOUR namespace u-<you>, as YOUR UID ──► slurm-bridge ──► Slurm job ──► Ready
   (admin, v2+: popular models once in models-public for everyone)
          │
 ═════════╪══════ 5. USE ═══════════════════════════════════════════════════════
          ├──► Playground: chat (LLM) or form (ML / DL)
          ├──► Scripts, notebooks, Slurm jobs:
          │       v1:  endpoint URL from master (+ per-endpoint API key for LLMs)
          │       v2+: gateway http://<master>:30600/<owner>/<endpoint>/… + your token (~/.model-hub/token)
          └──► (v2+) people you shared with call it with their own token
          │
          ▼
   [Delete] · or it ends after 24 h and the GPU is freed · (v2+) [Extend] for another 24 h
```

## Where each step's design lives

| Step | Doc |
|---|---|
| Nodes, `/home` layout, SIF vs OCI | [cluster architecture](https://ankush610.github.io/AI-Factory-Docs/how-it-works/01-cluster-architecture/) |
| Register, runtimes, pods, playground, gateway | [serving.md](serving.md) |
| Your namespace, UID rule, GPU quota, onboarding | [tenancy.md](tenancy.md) |
| Publish, base models, version-drift rule | [publishing.md](publishing.md) |
| What v1 includes | [versions/version-1/README.md](../versions/version-1/README.md) |

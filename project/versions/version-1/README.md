# Model Hub — version 1 (current scope)

What we are building now. The full design (all versions) is in [../../README.md](../../design/README.md); this folder
only says **which parts of it v1 uses** and adds the v1-specific decisions. The code goes in
`OOD-Install/5-model-hub/`.

| File | What's in it |
|---|---|
| [user-flow.md](user-flow.md) | train → register → deploy → use, one diagram each for ML, DL, LLM |
| [runtimes.md](runtimes.md) | which model types v1 serves, with which inference tool and image |
| [build-plan.md](build-plan.md) | phases P0–P2, files to create, "done when" checks |

## v1 in one paragraph

A user logs in to OOD, trains on Slurm with an Apptainer SIF, registers the best run in MLflow, opens the
**Model Hub** OOD app, picks the model and deploys it. It runs as a pod **in their own namespace, as their own
UID**, becoming a Slurm job through slurm-bridge (1 GPU max, 24 h). They try it in the playground and call it
from scripts on master. ML and DL models are served by **MLflow serving**; LLMs by **vLLM**.

## In / out

| In v1 | Later (v2+) | Why it can wait |
|---|---|---|
| Namespace per user + UID policy + 1-GPU quota + per-user kubeconfig + slurm-bridge namespaces ([tenancy](../../design/tenancy.md)) | | Can't cut: pods mount `/home` over NFS; without these any pod can read any home |
| Catalog = MLflow Model Registry + `model-register` for path-based LLMs ([serving](../../design/serving.md) "How models get into the catalog") | `model-publish` / shared `published/` tree ([publishing](../../design/publishing.md)) | v1 is private; sharing needs publish |
| Runtimes: MLflow serving (ML, DL), vLLM (LLM), see [runtimes.md](runtimes.md) | llama.cpp, Triton, TensorFlow, custom images | Three images cover the three model kinds; each extra runtime is another image + template |
| OOD app: models, deploy (GPU/CPU, 24 h), my endpoints (status, logs, countdown, delete), playground (chat / schema form), "how to get your model here" page | Extend button, share dialog, shared/public groups | Delete + redeploy = Extend; sharing needs the gateway |
| Calls from master (a k8s node) to the endpoint's ClusterIP; LLMs get a per-endpoint vLLM `--api-key` | Gateway + per-user tokens, public tier | Flannel lets any pod bypass a gateway anyway (README "Known limits" 2) |
| Admin base models in `/home/apps/models/base/`, registered once | | "Just deploy Qwen" without training |

## v1 limits (tell users)

- **Private only:** you see and deploy your own models plus the admin's base models.
- **1 GPU per user, 24 h per endpoint.** Redeploy to run longer.
- **ML/DL endpoints have no API key in v1**, so any cluster user who finds the address could call them.
- **Serving images are paired with training SIFs.** A model trained in a SIF with no matching serving image
  can't be deployed until the admin builds that pair.

## Production note

v1 calls endpoints at their ClusterIP from master, which works because master is a k8s node on the dummy cluster.
If production's login node is not a k8s node, users there can't reach ClusterIPs, so the gateway (a NodePort,
[serving.md](../../design/serving.md) "Gateway") moves into v1 for production.

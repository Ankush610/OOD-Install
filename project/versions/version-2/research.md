# Model Hub v2 — research (2026-10-06)

What others who serve models on GPU clusters do, and what we took from it.

| Who | Setup | What we took |
|---|---|---|
| **GWDG "Chat AI" / SAIA** (Göttingen, 50 000+ users) — [paper](https://www.researchsquare.com/article/rs-6648693/v1.pdf), [code](https://github.com/gwdg/saia-hpc), [earlier paper](https://arxiv.org/pdf/2407.00110) | vLLM as Slurm jobs, a scheduler keeps jobs running, **Kong API gateway** (keys, rate limits, accounting), SSO via Apache `mod_auth_openidc` | one gateway in front of everything; usage counted at the gateway, not in Slurm; their outages came from Slurm having no free GPUs → show the wait, offer reservations |
| **RAMSES** (Cologne) — [paper](https://arxiv.org/html/2511.21413) | Kubernetes web/API layer + models as Slurm jobs (vLLM in Apptainer); keys in Postgres with a cache; health checks | personal keys checked at the gateway, cached; health checks before marking "ready" |
| **Red Hat OpenShift AI "Models-as-a-Service"** — [intro](https://developers.redhat.com/articles/2025/11/25/introducing-models-service-openshift-ai), [architecture](https://developers.redhat.com/articles/2026/08/18/architecting-the-red-hat-openshift-ai-dashboard-for-models-as-a-service) | Gateway API + Authorino (auth) + Limitador (limits), API keys, tiers, model registry, dashboard | the same split we chose: catalog (registry) → deploy → gateway with keys; too heavy to copy (OpenShift-only pieces) |
| **KServe + llm-d** — [LLMInferenceService](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview), [blog](https://kserve.github.io/website/blog/cloud-native-ai-inference-kserve-llm-d) | the standard Kubernetes way for large LLMs (multi-node, KV-cache routing) | not for v2: built for big multi-node clusters; we have 2 GPU nodes and serve through Slurm. Revisit if a model needs > 1 node |
| **LiteLLM** — [keys](https://docs.litellm.ai/docs/proxy/virtual_keys), [users/budgets](https://docs.litellm.ai/docs/proxy/users), [vs Envoy AI Gateway](https://odock.ai/compare/litellm-vs-envoy-ai-gateway/) | LLM proxy with per-user keys, limits, budgets, usage | candidate for the gateway; but our users also serve non-LLM models (`/invocations`), so it's tested against a plain proxy + our auth (build-plan step 4) |
| **Slinky slurm-bridge** — [docs](https://slinky.schedmd.com/projects/slurm-bridge) | runs k8s pods as Slurm jobs | still young: docs list only the CPU and example GPU DRA drivers; we pin it and test GPUs on every install |

**Main lesson:** production setups put **one gateway** in front of all models (keys, who may call what, limits,
usage), and everything else stays behind it. v1 had no gateway, which is why sharing and access felt messy.

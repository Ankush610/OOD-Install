# vLLM Inference Notes

## KV cache pool (fixed at startup)

- The pool size is set once, at startup.
- It is whatever GPU memory is left after the model weights and working space.
- Mostly `--gpu-memory-utilization` and the model's weight size set it: pool = utilization × GPU memory − weights − peak activations − CUDA graphs.
- `--max-num-seqs` and `--max-model-len` don't reserve KV space, but they shift it a little: the activation peak is measured with a batch of `--max-num-batched-tokens`, whose default depends on them, and CUDA graphs are captured for batch sizes up to `--max-num-seqs`. Always read the real pool size from the startup log (`GPU KV cache size: N tokens`).
- `--kv-cache-dtype fp8` stores each token in half the space of the default bf16/fp16. The pool stays the same size but holds about twice as many tokens.

## `--max-model-len` (the longest single request)

- The most tokens one request can use (prompt + answer).
- **Startup check:** at least one full-length request must fit in the pool. If not, vLLM refuses to start.
- **Worst-case concurrency:** vLLM logs `Maximum concurrency = pool size ÷ max-model-len`.

Example with a pool of 440,000 tokens:

| `max-model-len` | Maximum concurrency |
|---|---|
| 8,192 | about 53 |
| 4,096 | about 107 |

Same pool. The worst-case request is just smaller.

## `--max-num-seqs` (a cap, not a reservation)

- Means "never run more than N requests at once."
- It does **not** reserve KV memory for those N requests.

## Decided at runtime

How many requests actually fit depends on their real length, not on `max-model-len`:

- 50 short chats of 500 tokens each fit easily.
- 50 long requests of 8,000 tokens each may not fit.

When the pool fills up:

- vLLM stops starting new requests. They wait in the queue.
- It may **preempt** a running request (see below). vLLM logs a warning when this happens.

## Preemption (what happens when the pool is full)

1. A running request needs a new block, but the pool is full.
2. vLLM picks a victim, normally the newest request, so the oldest ones keep going.
3. It frees the victim's KV blocks. The request goes back to the waiting queue.
4. When space frees up, vLLM **recomputes** the KV cache: it runs the prompt + every token generated so far through the model in one pass.
5. Generation continues from the next token.

- **Nothing is lost.** The tokens already generated are kept. Only the cache is rebuilt.
- **It costs time.** The GPU does that prompt work twice. The user sees a pause, then the answer carries on.
- **Prefix caching** (`--enable-prefix-caching`, on by default) can save part of the recompute if the freed blocks were not reused yet.

**Where to see the cost in metrics:**

| Metric | What it shows |
|---|---|
| `vllm:num_preemptions_total` | How many preemptions happened. Rising = the pool is too small for the load. |
| TTFT (time to first token) | Goes up. Requests wait in the queue longer, and preempted ones have to be recomputed. |
| Inter-token latency (TPOT) | Streaming answers pause in the middle while a preempted request is recomputed. |

Fix: add pods or lower `--max-num-seqs`.

## Rule of thumb

Set `--max-num-seqs` at or below the "Maximum concurrency" value that vLLM prints at startup. Then N full-length requests always fit and nothing gets preempted.

## Scaling vLLM in Kubernetes

### The problem

- One vLLM pod = one full copy of the model, on one GPU (or several with `--tensor-parallel-size`).
- Inside that GPU, vLLM handles the load by itself: batching, queueing and preemption.
- But it allocates everything **up front, at startup**. The KV pool can never grow. More load only means longer queues and more preemption.
- So to add capacity **dynamically**, we add **more pods** (more GPUs), and remove them when load drops.
- On this cluster each pod goes through slurm-bridge, so it is a Slurm job: a new replica waits in the Slurm queue until a GPU is free, and ends at its Slurm time limit.

### The solution: vLLM → Prometheus → KEDA

```
vLLM /metrics  →  Prometheus  →  KEDA  →  scales the Deployment
(publishes)       (collects)      (decides)   (adds or removes pods)
```

1. **vLLM publishes** `vllm:num_requests_waiting` on `/metrics`. Nothing to configure.
2. **Prometheus collects** it from every vLLM pod every few seconds, using a `ServiceMonitor` or pod annotations.
3. **KEDA decides.** It asks Prometheus how many requests are waiting and sets `replicas` on the Deployment.

Scale on the **queue**, not on GPU or CPU usage. With vLLM the GPU looks busy nearly all the time.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: vllm }
spec:
  scaleTargetRef: { name: vllm }      # your Deployment
  minReplicaCount: 1
  maxReplicaCount: 4
  cooldownPeriod: 600                  # wait 10 min before scaling down
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus-server.monitoring.svc   # Helm chart `prometheus`: service prometheus-server, port 80
      query: sum(vllm:num_requests_waiting)
      threshold: "5"                   # aim for about 5 waiting per pod
```

KEDA sets the pod count to `total waiting ÷ threshold`, rounded up and kept between `minReplicaCount` and `maxReplicaCount` (20 waiting → 4 pods; 21 → still 4, the max).

**Not working yet on this cluster.** Fix these first:
- The KEDA and Prometheus pods are `Pending`: every node has a taint they don't tolerate (control-plane on
  master, `slinky.slurm.net/managed-node` on cn01/cn02). Give them tolerations or a nodeSelector for master
  (Helm values), like the slurm-bridge pods.
- Until KEDA runs, the `v1beta1.external.metrics.k8s.io` APIService is `False (MissingEndpoints)`. That breaks
  API discovery, which is why deleting a namespace hangs in `Terminating`.
- The ScaledObject's Deployment must be in a slurm-bridge managed namespace to get GPUs through Slurm.

**Why KEDA and not a plain HPA?** The HPA (Kubernetes' built-in autoscaler) cannot query Prometheus without the extra Prometheus Adapter, which is fiddly to set up. KEDA creates the HPA for you.

**Tips:**

- A new pod takes minutes to load the model. Scale up early (a low threshold) and scale down slowly (a long cooldown).
- Add a `startupProbe` and a `readinessProbe` on `/health`, so the Service only sends traffic to pods that have finished loading.
- Get the per-pod limit from `vllm bench serve` first, then choose `threshold` and `--max-num-seqs` from it.

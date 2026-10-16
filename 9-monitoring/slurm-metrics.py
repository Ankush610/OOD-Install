#!/usr/bin/env python3
"""Slurm's view of the cluster, for node_exporter's textfile collector. slurm-metrics.timer runs it every 30 s on master.

Per node: state, GPU type, CPUs / memory / GPUs that jobs can get, how many are reserved now and which GPUs. Jobs: running and pending per
partition and user, and running jobs per node and user (who is on which node). Only reads scontrol/squeue (--json):
changes nothing in Slurm, needs no slurm.conf setting. `node` = the machine's hostname (viewer01 -> master), so it
joins with node_exporter's and gpu-metrics' series; `slurm_node` = Slurm's own name for it.
Slurm doesn't answer -> slurm_collector_ok 0 and no other numbers (no stale values).

Usage: slurm-metrics.py [out.prom]   (no argument: print to stdout)      Test: slurm-metrics.py --test
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter

DOWN = {"DOWN", "DRAIN", "FAIL", "NOT_RESPONDING", "POWERED_DOWN", "POWERING_DOWN", "FUTURE", "MAINTENANCE", "REBOOT_ISSUED"}


def slurm(*cmd):
    # 20 s: two calls stay under the unit's 60 s kill, so a hung slurmctld gives collector_ok 0, not a stale file
    return subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=20).stdout


def gpus(gres):
    """'gpu:a30:1(S:0-1),shard:4' -> 1, 'gpu:a30:0(IDX:N/A)' -> 0, 'gpu:2' -> 2, '' -> 0"""
    return sum(int(m.group(1)) for m in re.finditer(r"\bgpu(?::[^:(,]+)?:(\d+)", gres or ""))


def gpu_types(gres):
    """'gpu:a30:1(S:0-1),gpu:h100:2' -> 'a30+h100', 'gpu:2' -> '' (untyped)"""
    return "+".join(sorted({m.group(1) for m in re.finditer(r"\bgpu:([^:(,]+):\d+", gres or "")}))


def gpu_idx(gres_used):
    """Which GPUs are reserved: 'gpu:h100:3(IDX:0-1,4)' -> [0, 1, 4]; 'gpu:a30:0(IDX:N/A)' -> []"""
    out = []
    for m in re.finditer(r"\bgpu(?::[^:(,]+)?:\d+\(IDX:([^)]*)\)", gres_used or ""):
        for part in m.group(1).split(","):
            a, _, b = part.partition("-")
            if a.isdigit():
                out += range(int(a), int(b or a) + 1)
    return sorted(set(out))


def hosts(nodelist):
    """'cn[01-02,7],gpu1' -> ['cn01', 'cn02', 'cn7', 'gpu1']: Slurm's hostlist syntax, expanded here (one
    `scontrol show hostnames` per job each run would load slurmctld as jobs grow). Zero padding kept; several [] ok."""
    out = []
    for name in re.findall(r"(?:[^,\[]|\[[^\]]*\])+", nodelist or ""):
        m = re.search(r"\[([^\]]*)\]", name)
        if not m:
            out.append(name)
            continue
        for part in m.group(1).split(","):
            a, _, b = part.partition("-")
            for i in range(int(a), int(b or a) + 1):
                out += hosts(f"{name[:m.start()]}{i:0{len(a)}d}{name[m.end():]}")
    return out


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def labels(**kw):
    return "{" + ",".join(f'{k}="{esc(v)}"' for k, v in kw.items()) + "}"


def render(nodes, jobs):
    m = {}  # metric -> lines; printed grouped (the text format wants each metric's lines together)

    def add(name, lab, value):
        m.setdefault(name, []).append(f"{name}{lab} {value}")

    host = {}
    for n in nodes:
        host[n["name"]] = n.get("hostname") or n["name"]
        lab = labels(node=host[n["name"]], slurm_node=n["name"])
        state = [s.upper() for s in (n.get("state") or [])]
        add("slurm_node_info", labels(node=host[n["name"]], slurm_node=n["name"], state="+".join(state).lower(),
                                      reason=n.get("reason") or "", partitions=",".join(n.get("partitions") or []),
                                      gpu_type=gpu_types(n.get("gres"))), 1)
        add("slurm_node_available", lab, 0 if DOWN & set(state) else 1)
        # what jobs can get: Slurm keeps specialized cores/memory (CoreSpecCount, MemSpecLimit) for the system
        add("slurm_node_cpus", lab, n.get("cpus", 0) - (n.get("specialized_cores") or 0))
        add("slurm_node_cpus_alloc", lab, n.get("alloc_cpus", 0))
        add("slurm_node_memory_bytes", lab, (n.get("real_memory", 0) - (n.get("specialized_memory") or 0)) * 1048576)
        add("slurm_node_memory_alloc_bytes", lab, (n.get("alloc_memory") or 0) * 1048576)
        add("slurm_node_gpus", lab, gpus(n.get("gres")))
        add("slurm_node_gpus_alloc", lab, gpus(n.get("gres_used")))
        # Slurm's own GPU numbers (0 = the node's first GPU in gres.conf order), one series per reserved GPU
        for i in gpu_idx(n.get("gres_used")):
            add("slurm_node_gpu_reserved", labels(node=host[n["name"]], slurm_node=n["name"], gpu=i), 1)

    per_part, per_node = Counter(), Counter()
    for j in jobs:
        st = j.get("job_state")
        st = (st[0] if isinstance(st, list) and st else st or "").lower()
        if st not in ("running", "pending"):
            continue
        user = j.get("user_name", "")
        per_part[(st, j.get("partition", ""), user)] += 1
        if st == "running":
            for n in hosts(j.get("nodes") or ""):
                per_node[(n, user)] += 1
    for (st, part, user), c in sorted(per_part.items()):
        add("slurm_jobs", labels(state=st, partition=part, user=user), c)
    for (n, user), c in sorted(per_node.items()):
        add("slurm_node_jobs", labels(node=host.get(n, n), slurm_node=n, user=user), c)
    add("slurm_collector_ok", "", 1)
    return "".join(f"# TYPE {k} gauge\n" + "\n".join(v) + "\n" for k, v in m.items())


def main(out):
    try:
        text = render(json.loads(slurm("scontrol", "show", "node", "--json"))["nodes"],
                      json.loads(slurm("squeue", "--json"))["jobs"])
        ok = True
    except Exception as e:  # slurmctld down, timeout, odd JSON: say so in the metrics, not with stale numbers
        print(f"slurm-metrics: {e}", file=sys.stderr)
        text, ok = "# TYPE slurm_collector_ok gauge\nslurm_collector_ok 0\n", False
    if out is None:
        sys.stdout.write(text)
    else:  # write next to the target, then rename: node_exporter never reads a half-written file
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".slurm-")
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, out)
    return 0 if ok else 1


def test():
    nodes = [{"name": "cn01", "hostname": "cn01", "state": ["MIXED"], "partitions": ["a", "b"], "cpus": 48, "alloc_cpus": 8,
              "real_memory": 1000, "alloc_memory": 100, "gres": "gpu:a30:1(S:0-1)", "gres_used": "gpu:a30:1(IDX:0)"},
             {"name": "cn02", "hostname": "cn02", "state": ["DOWN", "NOT_RESPONDING"], "reason": 'Not "responding"',
              "cpus": 48, "real_memory": 1000, "gres": "gpu:a30:1", "gres_used": "gpu:a30:0(IDX:N/A)"},
             {"name": "viewer01", "hostname": "master", "state": ["IDLE", "DRAIN"], "cpus": 48, "specialized_cores": 8,
              "real_memory": 1000, "specialized_memory": 200, "gres": ""}]
    jobs = [{"job_state": ["RUNNING"], "partition": "a", "user_name": "u1", "nodes": "cn01"},
            {"job_state": ["RUNNING"], "partition": "a", "user_name": "u1", "nodes": "cn01"},
            {"job_state": ["PENDING"], "partition": "b", "user_name": "u2", "nodes": ""},
            {"job_state": ["COMPLETED"], "partition": "a", "user_name": "u3", "nodes": "cn01"}]
    t = render(nodes, jobs)
    assert 'slurm_node_available{node="cn01",slurm_node="cn01"} 1' in t
    assert 'slurm_node_available{node="cn02",slurm_node="cn02"} 0' in t
    assert 'slurm_node_available{node="master",slurm_node="viewer01"} 0' in t          # drained
    assert 'reason="Not \\"responding\\""' in t
    assert 'slurm_node_cpus{node="master",slurm_node="viewer01"} 40' in t              # 48 - 8 specialized
    assert 'slurm_node_memory_bytes{node="master",slurm_node="viewer01"} 838860800' in t
    assert 'slurm_node_gpus{node="cn01",slurm_node="cn01"} 1' in t
    assert 'slurm_node_gpus_alloc{node="cn01",slurm_node="cn01"} 1' in t
    assert 'slurm_node_gpus_alloc{node="cn02",slurm_node="cn02"} 0' in t
    assert 'gpu_type="a30"' in t and 'slurm_node_gpu_reserved{node="cn01",slurm_node="cn01",gpu="0"} 1' in t
    assert 'slurm_node_gpu_reserved{node="cn02"' not in t                                # IDX:N/A = none reserved
    assert 'slurm_jobs{state="running",partition="a",user="u1"} 2' in t
    assert 'slurm_jobs{state="pending",partition="b",user="u2"} 1' in t
    assert "u3" not in t                                                                 # finished jobs don't count
    assert 'slurm_node_jobs{node="cn01",slurm_node="cn01",user="u1"} 2' in t
    assert gpus("gpu:2") == 2 and gpus("gpu:a30:1,gpu:h100:2(S:0)") == 3 and gpus(None) == 0
    assert gpu_types("gpu:h100:2(S:0),gpu:a30:1") == "a30+h100" and gpu_types("gpu:2") == "" and gpu_types(None) == ""
    assert gpu_idx("gpu:h100:3(IDX:0-1,4)") == [0, 1, 4] and gpu_idx("gpu:a30:0(IDX:N/A)") == [] and gpu_idx("") == []
    assert gpu_idx("gpu:a30:1(IDX:0),gpu:h100:2(IDX:2-3)") == [0, 2, 3]
    assert hosts("cn[01-03,07],gpu1") == ["cn01", "cn02", "cn03", "cn07", "gpu1"] and hosts("") == []
    assert hosts("r[1-2]n[09-10]") == ["r1n09", "r1n10", "r2n09", "r2n10"] and hosts("cn[8-10]") == ["cn8", "cn9", "cn10"]
    assert t.count("# TYPE slurm_node_cpus gauge") == 1                                  # one header per metric
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
    else:
        sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else None))

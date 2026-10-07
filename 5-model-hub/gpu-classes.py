#!/usr/bin/env python3
"""Print one DRA DeviceClass per Slurm GPU type, so pods can ask for `nvidia.com/gpu` and get the right card.

Slurm names types short (gres gpu:a30:1, gpu:h100:8); the NVIDIA DRA driver names them long ("NVIDIA A30",
"NVIDIA H100 80GB HBM3") and also lists cards Slurm doesn't schedule (a small "NVIDIA RTX A400" display card
here). A class selects the exact product name, so the display card is never handed out.

Usage:  python3 gpu-classes.py <slurm gres strings...>  < product names (one per line, from ResourceSlices)
        python3 gpu-classes.py --quota N  < `kubectl get deviceclass -o json`   -> ResourceQuota `hard:` lines
Test:   python3 gpu-classes.py --test
"""
import re
import sys


def slurm_types(gres_list):
    return sorted({m.group(1).lower() for g in gres_list for m in re.finditer(r"\bgpu:([^:(,]+):\d+", g)})


def classes(types, products):
    out, errors = [], []
    for t in types:
        hits = sorted({p for p in products if re.search(rf"(?<![A-Za-z0-9]){re.escape(t)}(?![A-Za-z0-9])", p, re.I)})
        if len(hits) != 1:
            errors.append(f"Slurm GPU type {t!r} matches {len(hits)} DRA products {hits} (want exactly 1)")
            continue
        out.append((t, hits[0]))
    return out, errors


def yaml(pairs):
    # nvidia.com/gpu can map to one class only; with several types, pods must name the class (ResourceClaim)
    ext = len(pairs) == 1
    docs = []
    for name, product in pairs:
        docs.append(f"""apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata: {{ name: {name} }}
spec:
{"  extendedResourceName: nvidia.com/gpu" + chr(10) if ext else ""}  selectors:
  - cel:
      expression: device.driver == 'gpu.nvidia.com' && device.attributes['gpu.nvidia.com'].type == 'gpu' && device.attributes['gpu.nvidia.com'].productName == '{product}'
""")
    return "---\n".join(docs)


def quota(deviceclasses, n):
    """ResourceQuota `hard` for n GPUs. A pod can get an NVIDIA GPU two ways: `nvidia.com/gpu` (mapped to a typed
    class) or a ResourceClaim naming a class directly. So: typed classes (ours) get n, and every other NVIDIA class
    (the operator's catch-all gpu.nvidia.com, mig, vfio) gets 0, or a claim on it would skip the typed class's cap."""
    hard = {"requests.nvidia.com/gpu": n}
    for d in deviceclasses:
        sel = " ".join(s.get("cel", {}).get("expression", "") for s in d["spec"].get("selectors", []))
        if "gpu.nvidia.com" in sel:
            typed = d["spec"].get("extendedResourceName") or "productName ==" in sel
            hard[f'{d["metadata"]["name"]}.deviceclass.resource.k8s.io/devices'] = n if typed else 0
    return hard


def test():
    here = ["NVIDIA A30", "NVIDIA RTX A400"]
    assert slurm_types(["gpu:a30:1", "gpu:a30:1(S:0)", "(null)"]) == ["a30"]
    assert classes(["a30"], here) == ([("a30", "NVIDIA A30")], [])
    assert classes(["a40"], here)[0] == []                                  # A400 is not an A40
    assert classes(["h100"], ["NVIDIA H100 80GB HBM3"]) == ([("h100", "NVIDIA H100 80GB HBM3")], [])
    assert "extendedResourceName" in yaml([("a30", "NVIDIA A30")])
    assert "extendedResourceName" not in yaml([("a30", "NVIDIA A30"), ("h100", "NVIDIA H100")])
    here_classes = [
        {"metadata": {"name": "a30"}, "spec": {"extendedResourceName": "nvidia.com/gpu", "selectors": [{"cel": {"expression": "device.driver == 'gpu.nvidia.com' && device.attributes['gpu.nvidia.com'].productName == 'NVIDIA A30'"}}]}},
        {"metadata": {"name": "gpu.nvidia.com"}, "spec": {"selectors": [{"cel": {"expression": "device.driver == 'gpu.nvidia.com' && device.attributes['gpu.nvidia.com'].type == 'gpu'"}}]}},
        {"metadata": {"name": "dra.cpu"}, "spec": {"selectors": [{"cel": {"expression": 'device.driver == "dra.cpu"'}}]}},
    ]
    assert quota(here_classes, 1) == {"requests.nvidia.com/gpu": 1,
                                      "a30.deviceclass.resource.k8s.io/devices": 1,
                                      "gpu.nvidia.com.deviceclass.resource.k8s.io/devices": 0}
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test(); sys.exit()
    if sys.argv[1:2] == ["--quota"]:
        import json
        for k, v in quota(json.load(sys.stdin)["items"], int(sys.argv[2])).items():
            print(f'    {k}: "{v}"')
        sys.exit()
    pairs, errors = classes(slurm_types(sys.argv[1:]), [l.strip() for l in sys.stdin if l.strip()])
    for e in errors:
        print("WARNING:", e, file=sys.stderr)
    if len(pairs) > 1:
        print("NOTE: several GPU types: no class gets nvidia.com/gpu; pods must use a ResourceClaim", file=sys.stderr)
    print(yaml(pairs), end="")

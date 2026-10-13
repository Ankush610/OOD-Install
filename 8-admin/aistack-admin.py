#!/usr/bin/env python3
"""The admin page's way to root (build-plan step 8). Installed root-owned as /usr/local/sbin/aistack-admin by
1-install.sh; sudoers lets OOD_ADMIN (and only that account) run it without a password. It does a FIXED list of
things, checks every argument, and calls the same scripts the admin runs by hand, so no logic lives twice:

  read      users                         LDAP people + teams + Model Hub limits
            teams                         teams and their members
            endpoints                     every Model Hub endpoint: owner, state, GPU (node/device), since, until
  people    add-user NAME                 password: one line on stdin (one-time)     1-ldap/add-user.sh
            remove-user NAME [--delete-home] [--delete-mlflow]                       1-ldap/remove-user.sh
            set-password NAME             password: one line on stdin (one-time)     1-ldap/set-password.sh
  teams     team-create TEAM | team-delete TEAM                                      1-ldap/group.sh
            team-add TEAM USER... | team-remove TEAM USER...
  limits    limits USER --gpus N | --max-hours H | --reset                           5-model-hub/2-sync-users.sh
  models    stop-endpoint USER NAME       stops the pod (= its Slurm job, frees the GPU); the endpoint stays, "stopped"

Answer: one JSON object on stdout, {"ok": true|false, "output": "<what the script printed>", "data": ...}.
Every change goes to ADMIN_LOG (who, what, result; never a password). One change at a time (a lock).
  sudo aistack-admin <action> [args]       aistack-admin --test   (self-check, no root)
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

OOD = "@OOD_INSTALL@"                      # 1-install.sh puts the OOD-Install path here
NAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")         # a Linux user name (= add-user.sh)
TEAM = re.compile(r"^[a-z_][a-z0-9_.-]{0,31}$")        # = group.sh
ENDPOINT = re.compile(r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")   # = render.py NAME
LIMITS = {"--gpus": (0, 8), "--max-hours": (1, 24 * 365)}


class Bad(Exception):
    pass


def site():
    """site.conf as a dict (bash does the parsing: it is a bash file)."""
    out = subprocess.run(["bash", "-c", f'set -a; source "{OOD}/site.conf"; env -0'], capture_output=True, check=True).stdout
    return dict(kv.split("=", 1) for kv in out.decode().split("\0") if "=" in kv)


def need(rx, v, what):
    if not isinstance(v, str) or not rx.match(v):
        raise Bad(f"bad {what}: {v!r}")
    return v


def plan(action, args, S):
    """(argv to run, needs stdin password, is a change) for one request; raises Bad on anything unexpected."""
    s = lambda *p: os.path.join(OOD, *p)
    if action == "add-user" and len(args) == 1:
        return ["bash", s("1-ldap/add-user.sh"), need(NAME, args[0], "user"), "--password-stdin"], True, True
    if action == "remove-user" and args:
        u, flags = need(NAME, args[0], "user"), args[1:]
        if u in S.get("KEEP_LOCAL", "").split() + [S.get("OOD_ADMIN", "")]:
            raise Bad(f"{u} is a local admin account: never removed")
        if len(set(flags)) != len(flags) or not set(flags) <= {"--delete-home", "--delete-mlflow"}:
            raise Bad(f"remove-user flags: --delete-home, --delete-mlflow (got {flags})")
        return ["bash", s("1-ldap/remove-user.sh"), u, *flags, "--yes"], False, True
    if action == "set-password" and len(args) == 1:
        return ["bash", s("1-ldap/set-password.sh"), need(NAME, args[0], "user")], True, True
    if action in ("team-create", "team-delete") and len(args) == 1:
        return ["bash", s("1-ldap/group.sh"), action[5:], need(TEAM, args[0], "team")], False, True
    if action in ("team-add", "team-remove") and len(args) >= 2:
        return (["bash", s("1-ldap/group.sh"), action[5:], need(TEAM, args[0], "team")]
                + [need(NAME, u, "user") for u in args[1:]], False, True)
    if action == "limits" and len(args) in (2, 3):
        u, opt = need(NAME, args[0], "user"), args[1:]
        if opt != ["--reset"]:
            if len(opt) != 2 or opt[0] not in LIMITS or not opt[1].isdigit():
                raise Bad("limits USER --gpus N | --max-hours H | --reset")
            lo, hi = LIMITS[opt[0]]
            if not lo <= int(opt[1]) <= hi:
                raise Bad(f"{opt[0]} must be {lo}..{hi}")
        return ["bash", s("5-model-hub/2-sync-users.sh"), u, *opt], False, True
    if action == "stop-endpoint" and len(args) == 2:
        return ["stop-endpoint", need(NAME, args[0], "user"), need(ENDPOINT, args[1], "endpoint")], False, True
    if action in ("users", "teams", "endpoints") and not args:
        return [action], False, False
    raise Bad(f"unknown action or wrong arguments: {action} {args}")


# ---------- reads ----------
def kubectl(*a):
    return subprocess.run(["kubectl", *a], capture_output=True, text=True, check=True,
                          env={**os.environ, "KUBECONFIG": "/etc/kubernetes/admin.conf"}).stdout


def ldap(base, filt, *attrs):
    out = subprocess.run(["ldapsearch", "-x", "-LLL", "-o", "ldif-wrap=no", "-H", "ldap://localhost", "-b", base,
                          filt, *attrs], capture_output=True, text=True, check=True).stdout
    return [dict(l.split(": ", 1) for l in e.splitlines() if ": " in l) | {"_member": [
        l.split(": ", 1)[1] for l in e.splitlines() if l.startswith("member: ")]} for e in out.split("\n\n") if e.strip()]


def teams(S):
    out = {}
    for e in ldap(f"ou=Groups,{S['LDAP_BASE']}", "(&(objectClass=groupOfNames)(!(objectClass=posixGroup)))", "cn", "member"):
        out[e["cn"]] = sorted(re.sub(r"^uid=([^,]+),.*", r"\1", m) for m in e["_member"])
    return out


def users(S):
    t = teams(S)
    ns = {n["metadata"]["labels"].get("aistack/user"): n["metadata"]["labels"]
          for n in json.loads(kubectl("get", "ns", "-l", "aistack/user", "-o", "json"))["items"]}
    out = []
    for e in ldap(f"ou=People,{S['LDAP_BASE']}", "(objectClass=posixAccount)", "uid", "uidNumber"):
        u, lab = e["uid"], ns.get(e["uid"], {})
        out.append({"name": u, "uid": int(e["uidNumber"]), "teams": sorted(k for k, v in t.items() if u in v),
                    "gpus": int(lab.get("aistack/gpus", S["USER_GPU_QUOTA"])),
                    "max_hours": int(lab.get("aistack/max-hours", S["ENDPOINT_HOURS_MAX"])),
                    "custom_limits": lab.get("aistack/custom-limits") == "true", "model_hub": u in ns})
    return sorted(out, key=lambda x: x["name"])


def endpoints_from(svcs, pods, claims):
    """Rows for the admin page from the k8s lists (all namespaces). The GPU = the device its ResourceClaim got."""
    gpus = {}                                          # (ns, pod) -> ["cn01/gpu-0", ...]
    for c in claims:
        res = ((c.get("status") or {}).get("allocation") or {}).get("devices", {}).get("results", [])
        for r in (c.get("status") or {}).get("reservedFor", []):
            if r.get("resource") == "pods":
                gpus.setdefault((c["metadata"]["namespace"], r["name"]), []).extend(f"{d['pool']}/{d['device']}" for d in res)
    pods = {(p["metadata"]["namespace"], p["metadata"]["name"]): p for p in pods}
    out = []
    for s in svcs:
        ns, name, ann = s["metadata"]["namespace"], s["metadata"]["name"], s["metadata"].get("annotations", {})
        p = pods.get((ns, name))
        st = (p or {}).get("status", {})
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in st.get("conditions", []))
        state = ("stopped" if not p else "queued" if not p["spec"].get("nodeName") else "running" if ready
                 else "loading" if st.get("phase") in ("Pending", "Running") else st.get("phase", "?").lower())
        out.append({"owner": ns[2:] if ns.startswith("u-") else ns, "name": name, "state": state,
                    "runtime": s["metadata"].get("labels", {}).get("model-hub/runtime"), "model": ann.get("model-hub/model"),
                    "node": (p or {}).get("spec", {}).get("nodeName"), "gpus": sorted(gpus.get((ns, name), [])),
                    "since": st.get("startTime"), "until": ann.get("model-hub/expires"),
                    "stopped_by": ann.get("model-hub/stopped-by") if state == "stopped" else None})
    return sorted(out, key=lambda e: (e["owner"], e["name"]))


def endpoints():
    get = lambda kind, *sel: json.loads(kubectl("get", kind, "-A", *sel, "-o", "json"))["items"]
    return endpoints_from(get("svc", "-l", "model-hub/runtime"), get("pods", "-l", "model-hub/runtime"), get("resourceclaims"))


def stop_endpoint(user, name):
    ns = f"u-{user}"
    kubectl("-n", ns, "get", "svc", name, "-l", "model-hub/runtime")     # only Model Hub endpoints (fails if none)
    kubectl("-n", ns, "annotate", "svc", name, "--overwrite",
            f"model-hub/stopped-by=admin {time.strftime('%Y-%m-%d %H:%M', time.localtime())}")
    # the Service stays: Model Hub shows it "stopped" and the owner can deploy it again
    return kubectl("-n", ns, "delete", "pod", name, "--ignore-not-found", "--wait=false").strip() or f"{name}: was not running"


# ---------- the request ----------
def log(S, caller, action, args, ok, detail=""):
    line = json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "by": caller, "action": action, "args": args,
                       "ok": ok, "detail": detail[-300:]})
    fd = os.open(S.get("ADMIN_LOG", "/var/log/aistack-admin.log"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(line + "\n")


def main(argv):
    if os.getuid() != 0:
        return {"ok": False, "output": "run with sudo"}
    S = site()
    caller = os.environ.get("SUDO_USER", "root")
    if not argv:
        return {"ok": False, "output": __doc__}
    action, args = argv[0], argv[1:]
    if caller not in ("root", S.get("OOD_ADMIN")):
        log(S, caller, action, args, False, "refused: not the admin")      # who tried what
        return {"ok": False, "output": f"{caller} may not use the admin tool"}
    try:
        cmd, wants_pw, change = plan(action, args, S)
    except Bad as e:
        log(S, caller, action, args, False, f"refused: {e}")
        return {"ok": False, "output": str(e)}
    if not change:
        try:
            data = {"users": users, "teams": teams, "endpoints": lambda S: endpoints()}[action](S)
        except subprocess.CalledProcessError as e:
            return {"ok": False, "output": f"{' '.join(e.cmd[:3])}...: {(e.stderr or '').strip()[-300:]}"}
        return {"ok": True, "output": "", "data": data}
    pw = sys.stdin.readline().rstrip("\n") if wants_pw else None
    with open("/run/aistack-admin.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)               # one change at a time (add-user picks max UID + 1)
        try:
            if cmd[0] == "stop-endpoint":
                out, ok = stop_endpoint(cmd[1], cmd[2]), True
            else:
                r = subprocess.run(cmd, input=(pw + "\n") if wants_pw else "", stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True,      # one stream: warnings where they happened
                                   env={**os.environ, "KUBECONFIG": "/etc/kubernetes/admin.conf"})
                out, ok = r.stdout, r.returncode == 0
        except subprocess.CalledProcessError as e:
            out, ok = (e.stdout or "") + (e.stderr or ""), False
    if pw:
        out = out.replace(pw, "********")              # no script should print it; never log or return it anyway
    log(S, caller, action, args, ok, out)
    return {"ok": ok, "output": out}


def test():
    S = {"KEEP_LOCAL": "admin", "OOD_ADMIN": "admin"}
    good = [("add-user", ["bob"]), ("remove-user", ["bob", "--delete-home"]), ("set-password", ["bob"]),
            ("team-create", ["nlp"]), ("team-add", ["nlp", "bob", "carol"]), ("limits", ["bob", "--gpus", "2"]),
            ("limits", ["bob", "--reset"]), ("stop-endpoint", ["bob", "my-ep"]), ("endpoints", [])]
    for a, args in good:
        plan(a, args, S)
    bad = [("add-user", ["Bob"]), ("add-user", ["bob;rm -rf /"]), ("add-user", ["-rf"]), ("remove-user", ["admin"]),
           ("remove-user", ["bob", "--yes"]), ("remove-user", ["bob", "--delete-home", "--delete-home"]),
           ("team-add", ["nlp"]), ("team-add", ["nlp", "../x"]), ("limits", ["bob", "--gpus", "99"]),
           ("limits", ["bob", "--gpus", "-1"]), ("limits", ["bob", "--cpu", "2"]), ("stop-endpoint", ["bob", "A_B"]),
           ("users", ["x"]), ("rm", ["-rf", "/"]), ("add-user", [])]
    for a, args in bad:
        try:
            plan(a, args, S)
        except Bad:
            continue
        raise AssertionError(f"accepted: {a} {args}")
    cmd, pw, change = plan("remove-user", ["bob", "--delete-mlflow"], S)
    assert cmd[-2:] == ["--delete-mlflow", "--yes"] and not pw and change
    assert plan("add-user", ["bob"], S)[1] is True                       # password from stdin, never in argv
    rows = endpoints_from(
        svcs=[{"metadata": {"namespace": "u-bob", "name": "llm", "labels": {"model-hub/runtime": "vllm"},
                            "annotations": {"model-hub/model": "/models/q", "model-hub/expires": "2026-10-14T10:00:00Z"}}},
              {"metadata": {"namespace": "u-carol", "name": "old", "labels": {"model-hub/runtime": "mlflow"}}}],
        pods=[{"metadata": {"namespace": "u-bob", "name": "llm"}, "spec": {"nodeName": "cn01"},
               "status": {"startTime": "2026-10-13T10:00:00Z", "conditions": [{"type": "Ready", "status": "True"}]}}],
        claims=[{"metadata": {"namespace": "u-bob", "name": "llm-gpu-x"},
                 "status": {"allocation": {"devices": {"results": [{"pool": "cn01", "device": "gpu-0"}]}},
                            "reservedFor": [{"resource": "pods", "name": "llm"}]}}])
    assert rows[0] == {"owner": "bob", "name": "llm", "state": "running", "runtime": "vllm", "model": "/models/q",
                       "node": "cn01", "gpus": ["cn01/gpu-0"], "since": "2026-10-13T10:00:00Z",
                       "until": "2026-10-14T10:00:00Z", "stopped_by": None}, rows[0]
    assert rows[1]["state"] == "stopped" and rows[1]["gpus"] == []
    loading = endpoints_from([{"metadata": {"namespace": "u-x", "name": "e", "annotations": {"model-hub/stopped-by": "admin"}}}],
                             [{"metadata": {"namespace": "u-x", "name": "e"}, "spec": {"nodeName": "cn01"},
                               "status": {"phase": "Running", "conditions": []}}], [])[0]
    assert loading["state"] == "loading" and loading["stopped_by"] is None, loading   # redeployed after an admin stop
    print(f"ok: {len(good)} good requests planned, {len(bad)} bad ones refused, endpoint rows right")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
        sys.exit()
    res = main(sys.argv[1:])
    print(json.dumps(res))
    sys.exit(0 if res["ok"] else 1)

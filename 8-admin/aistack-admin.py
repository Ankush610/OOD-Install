#!/usr/bin/env python3
"""The admin page's way to root (build-plan step 8). Installed root-owned on master as /usr/local/sbin/aistack-admin by
1-install.sh. Two ways in, both for OOD_ADMIN only: sudo on master (the terminal), and the admin page's ssh key
(ADMIN_KEY on LOGIN_HOST), whose line in root's authorized_keys forces `aistack-admin --ssh`: the request is then
SSH_ORIGINAL_COMMAND, split like a shell would (shlex) but never run by one. It does a FIXED list of
things, checks every argument, and calls the same scripts the admin runs by hand, so no logic lives twice:

  read      users                         LDAP people + teams + Model Hub limits
            teams                         teams and their members
            endpoints                     every Model Hub endpoint: owner, state, GPU (node/device), since, until
            log                           the last 200 lines of ADMIN_LOG (newest first)
            jobs                          everything running in Slurm: VS Code / Jupyter sessions, training jobs,
                                          Model Hub endpoints (linked to owner + endpoint), with node + GPU
  people    add-user NAME                 password: one line on stdin (one-time)     1-ldap/add-user.sh
            remove-user NAME [--delete-home] [--delete-mlflow]                       1-ldap/remove-user.sh
            set-password NAME             password: one line on stdin (one-time)     1-ldap/set-password.sh
  teams     team-create TEAM | team-delete TEAM                                      1-ldap/group.sh
            team-add TEAM USER... | team-remove TEAM USER...
  limits    limits USER --gpus N | --max-hours H | --reset                           5-model-hub/2-sync-users.sh
  models    stop-endpoint USER NAME REASON  stops the pod (= its Slurm job, frees the GPU); the endpoint stays, "stopped";
                                          REASON = the message its owner sees (Model Hub, home page)
  jobs      cancel-job JOBID REASON       scancel one Slurm job (a session or a training job; endpoints: stop-endpoint);
                                          REASON = the message its owner sees (home page, VS Code/Jupyter page)

Answer: one JSON object on stdout, {"ok": true|false, "output": "<what the script printed>", "data": ...}.
Every change goes to ADMIN_LOG (who, what, result; never a password). One change at a time (a lock).
  sudo aistack-admin <action> [args]       aistack-admin --test   (self-check, no root)
  ssh -i ADMIN_KEY root@MASTER_HOST '<action> [args]'       (each argument shlex-quoted; passwords still on stdin)
"""
import fcntl
import json
import os
import pwd
import re
import shlex
import subprocess
import sys
import time

OOD = "@OOD_INSTALL@"                      # 1-install.sh puts the OOD-Install path here
NAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")         # a Linux user name (= add-user.sh)
TEAM = re.compile(r"^[a-z_][a-z0-9_.-]{0,31}$")        # = group.sh
ENDPOINT = re.compile(r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$")   # = render.py NAME
LIMITS = {"--gpus": (0, 8), "--max-hours": (1, 24 * 365)}
REASON_MAX = 1000                          # characters; the admin page's textarea has the same maxlength


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


def reason(v):
    """The admin's message to the owner of what they stop: plain text, newlines allowed."""
    why = v.replace("\r\n", "\n").strip()
    if not why or len(why) > REASON_MAX or re.search(r"[\x00-\x08\x0b-\x1f\x7f]", why):
        raise Bad(f"the reason: 1..{REASON_MAX} characters of text (the user reads it)")
    return why


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
    if action == "stop-endpoint" and len(args) == 3:
        return ["stop-endpoint", need(NAME, args[0], "user"), need(ENDPOINT, args[1], "endpoint"), reason(args[2])], False, True
    if action == "cancel-job" and len(args) == 2:
        if not re.fullmatch(r"[0-9]{1,10}", args[0]):
            raise Bad(f"bad job id: {args[0]!r}")
        return ["cancel-job", args[0], reason(args[1])], False, True
    if action in ("users", "teams", "endpoints", "log", "jobs") and not args:
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
                    "stopped_by": ann.get("model-hub/stopped-by") if state == "stopped" else None,
                    "job": (p or {}).get("metadata", {}).get("annotations", {}).get("slurmjob.slinky.slurm.net/job-name")})
    return sorted(out, key=lambda e: (e["owner"], e["name"]))


def endpoints():
    get = lambda kind, *sel: json.loads(kubectl("get", kind, "-A", *sel, "-o", "json"))["items"]
    return endpoints_from(get("svc", "-l", "model-hub/runtime"), get("pods", "-l", "model-hub/runtime"), get("resourceclaims"))


def read_log(S):
    try:
        lines = open(S.get("ADMIN_LOG", "/var/log/aistack-admin.log")).read().splitlines()[-200:]
    except FileNotFoundError:
        return []
    return [json.loads(l) for l in reversed(lines) if l.strip()]


APP = re.compile(r"^/var/www/ood/apps/(?:sys|dev/[^/]+/gateway|usr/[^/]+/gateway)/([^/]+)/")
APP_NAMES = {"vscode": "VS Code", "jupyter": "Jupyter", "bc_desktop": "Desktop"}


def jobs_from(squeue, eps, bridge, hostnames=lambda nodes: [nodes]):
    """Rows for the Running tab: every Slurm job, what it is, whose, where, which GPUs.
    squeue = `squeue -a --json`; eps = endpoint rows (their "job" = the Slurm job name slurm-bridge gave the pod)."""
    by_job = {e["job"]: e for e in eps if e.get("job")}
    t = lambda v: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(v["number"])) if v and v.get("set") and v.get("number") else None
    out = []
    for j in squeue.get("jobs", []):
        state = (j.get("job_state") or ["?"])[0].lower()
        nodes = j.get("nodes") or ""
        gpus = []                                      # gres_detail: one entry per node, e.g. "gpu:a30:2(IDX:0-1)"
        for n, g in zip(hostnames(nodes) if nodes else [], j.get("gres_detail") or []):
            m = re.search(r"\(IDX:([0-9,-]+)\)", g)
            for part in (m.group(1).split(",") if m else []):
                a, _, b = part.partition("-")
                gpus += [f"{n}/gpu-{i}" for i in range(int(a), int(b or a) + 1)]
        row = {"id": j["job_id"], "owner": j.get("user_name"), "name": j.get("name"), "state": state,
               "partition": j.get("partition"), "node": nodes or None, "gpus": gpus,
               "since": t(j.get("start_time")) if state == "running" else None, "until": t(j.get("end_time")),
               "why": j.get("state_reason") if state == "pending" and j.get("state_reason") not in (None, "None") else None}
        app = APP.match(j.get("command") or "")
        if j.get("partition") == bridge or j.get("name") in by_job:
            e = by_job.get(j.get("name"), {})
            row.update(kind="endpoint", owner=e.get("owner", row["owner"]), name=e.get("name", row["name"]), model=e.get("model"))
        elif app:
            row.update(kind="session", app=APP_NAMES.get(app.group(1), app.group(1)))
        else:
            row.update(kind="job")
        out.append(row)
    return sorted(out, key=lambda r: (r["state"] != "running", r["owner"] or "", r["id"]))


def jobs(S):
    slurm = {**os.environ, "SLURM_CONF": S["SLURM_CONF"]}   # sudo drops it; Slurm here has no built-in config path
    sq = json.loads(subprocess.run([os.path.join(S["SLURM_BIN"], "squeue"), "-a", "--json"], capture_output=True,
                                   text=True, check=True, env=slurm).stdout)
    try:
        eps = endpoints()
    except subprocess.CalledProcessError:              # no Model Hub (or k8s down): the jobs are still worth seeing
        eps = []
    hn = lambda nodes: subprocess.run([os.path.join(S["SLURM_BIN"], "scontrol"), "show", "hostnames", nodes],
                                      capture_output=True, text=True, check=True, env=slurm).stdout.split()
    return jobs_from(sq, eps, S.get("BRIDGE_PARTITION", "slurm-bridge"), hn)


def cancel_job(S, jobid, why):
    slurm = {**os.environ, "SLURM_CONF": S["SLURM_CONF"]}
    sq = json.loads(subprocess.run([os.path.join(S["SLURM_BIN"], "squeue"), "-j", jobid, "--json"], capture_output=True,
                                   text=True, env=slurm).stdout or "{}").get("jobs", [])
    if not sq:
        raise Bad(f"no job {jobid} (finished already?)")
    if sq[0].get("partition") == S.get("BRIDGE_PARTITION", "slurm-bridge"):
        raise Bad(f"job {jobid} is a Model Hub endpoint: use stop-endpoint (keeps it listed, the owner can redeploy)")
    subprocess.run([os.path.join(S["SLURM_BIN"], "scancel"), jobid], capture_output=True, text=True, check=True, env=slurm)
    app = sq[0].get("name") if re.fullmatch(r"[a-z_]{1,32}", sq[0].get("name") or "") else "job"   # user-chosen: no paths
    notify(S, sq[0]["user_name"], f"{app}.{jobid}", why)
    return f"cancelled job {jobid} ({sq[0].get('name')}, {sq[0].get('user_name')})"


def notify(S, user, key, why):
    """ADMIN_NOTICES/<key> = "admin <when>" + the reason, for the owner of what was stopped."""
    # the user's pages read this: "admin <when>" + the reason, shown behind a message icon (OOD home page widget,
    # VS Code / Jupyter page) instead of the job just vanishing. <app>.<id>, owned by the user in a
    # sticky dir (like /tmp): only they can remove it (its bin button); 600: the reason is for them only
    # ponytail: notices of removed users stay (tiny files); clean them in remove-user.sh if it ever matters
    uid, d = pwd.getpwnam(user).pw_uid, S["ADMIN_NOTICES"]     # KeyError: no such account (before any file exists)
    os.makedirs(d, exist_ok=True)
    os.chmod(d, 0o1777)
    f = os.path.join(d, key)
    if os.path.lexists(f):
        os.unlink(f)
    fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)   # never through a planted symlink
    os.fchown(fd, uid, -1)
    with os.fdopen(fd, "w") as fh:
        fh.write(f"admin {stamp()}\n{why}\n")


def stamp():
    return time.strftime("%Y-%m-%d %H:%M", time.localtime())


def stop_endpoint(S, user, name, why):
    ns = f"u-{user}"
    svc = json.loads(kubectl("-n", ns, "get", "svc", name, "-o", "json"))     # fails if none (kubectl: no name + -l)
    if "model-hub/runtime" not in svc["metadata"].get("labels", {}):
        raise Bad(f"{name} is not a Model Hub endpoint")
    kubectl("-n", ns, "annotate", "svc", name, "--overwrite", f"model-hub/stopped-by=admin {stamp()}",
            f"model-hub/stop-reason={why}")              # Model Hub shows both behind an envelope; a redeploy removes them
    # the Service stays: Model Hub shows it "stopped" and the owner can deploy it again
    out = kubectl("-n", ns, "delete", "pod", name, "--ignore-not-found", "--wait=false").strip() or f"{name}: was not running"
    try:                                               # home page envelope too; endpoint names repeat across users
        notify(S, user, f"endpoint.{user}.{name}", why)
    except KeyError:                                   # no Linux account for them here: Model Hub still shows it
        out += f"\n(no home page message: {user} has no account on this machine)"
    return out


# ---------- the request ----------
def log(S, caller, action, args, ok, detail=""):
    line = json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "by": caller, "action": action, "args": args,
                       "ok": ok, "detail": detail[-300:]})
    fd = os.open(S.get("ADMIN_LOG", "/var/log/aistack-admin.log"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(line + "\n")


def main(argv, ssh=False):
    if os.getuid() != 0:
        return {"ok": False, "output": "run with sudo"}
    S = site()
    # ssh: only the admin page's key reaches this (forced command in root's authorized_keys, from LOGIN_IP only),
    # and only OOD_ADMIN can read that key, so the key IS the admin. sudo: sudo says who asked.
    caller = S.get("OOD_ADMIN") if ssh else os.environ.get("SUDO_USER", "root")
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
            data = {"users": users, "teams": teams, "endpoints": lambda S: endpoints(), "log": read_log, "jobs": jobs}[action](S)
        except subprocess.CalledProcessError as e:
            return {"ok": False, "output": f"{' '.join(e.cmd[:3])}...: {(e.stderr or '').strip()[-300:]}"}
        return {"ok": True, "output": "", "data": data}
    pw = sys.stdin.readline().rstrip("\n") if wants_pw else None
    with open("/run/aistack-admin.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)               # one change at a time (add-user picks max UID + 1)
        try:
            if cmd[0] == "stop-endpoint":
                out, ok = stop_endpoint(S, cmd[1], cmd[2], cmd[3]), True
            elif cmd[0] == "cancel-job":
                out, ok = cancel_job(S, cmd[1], cmd[2]), True
            else:
                r = subprocess.run(cmd, input=(pw + "\n") if wants_pw else "", stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True,      # one stream: warnings where they happened
                                   env={**os.environ, "KUBECONFIG": "/etc/kubernetes/admin.conf"})
                out, ok = r.stdout, r.returncode == 0
        except subprocess.CalledProcessError as e:
            out, ok = (e.stdout or "") + (e.stderr or ""), False
        except Bad as e:
            out, ok = str(e), False
    if pw:
        out = out.replace(pw, "********")              # no script should print it; never log or return it anyway
    log(S, caller, action, args, ok, out)
    return {"ok": ok, "output": out}


def test():
    S = {"KEEP_LOCAL": "admin", "OOD_ADMIN": "admin"}
    good = [("add-user", ["bob"]), ("remove-user", ["bob", "--delete-home"]), ("set-password", ["bob"]),
            ("team-create", ["nlp"]), ("team-add", ["nlp", "bob", "carol"]), ("limits", ["bob", "--gpus", "2"]),
            ("limits", ["bob", "--reset"]), ("stop-endpoint", ["bob", "my-ep", "Idle for 2 days."]), ("endpoints", []), ("log", []), ("jobs", []),
            ("cancel-job", ["1382", "Idle GPU for 6 hours.\nPlease use sbatch for long runs."])]
    for a, args in good:
        plan(a, args, S)
    bad = [("add-user", ["Bob"]), ("add-user", ["bob;rm -rf /"]), ("add-user", ["-rf"]), ("remove-user", ["admin"]),
           ("remove-user", ["bob", "--yes"]), ("remove-user", ["bob", "--delete-home", "--delete-home"]),
           ("team-add", ["nlp"]), ("team-add", ["nlp", "../x"]), ("limits", ["bob", "--gpus", "99"]),
           ("limits", ["bob", "--gpus", "-1"]), ("limits", ["bob", "--cpu", "2"]), ("stop-endpoint", ["bob", "A_B", "x"]), ("stop-endpoint", ["bob", "my-ep"]), ("stop-endpoint", ["bob", "my-ep", " "]),
           ("users", ["x"]), ("rm", ["-rf", "/"]), ("add-user", []), ("cancel-job", ["1382;id", "x"]), ("cancel-job", ["-1", "x"]),
           ("cancel-job", ["1382"]), ("cancel-job", ["1382", " \n "]), ("cancel-job", ["1382", "x\x1b[2J"]),
           ("cancel-job", ["1382", "x" * 1001]), ("cancel-job", ["1", "a", "b"])]
    for a, args in bad:
        try:
            plan(a, args, S)
        except Bad:
            continue
        raise AssertionError(f"accepted: {a} {args}")
    cmd, pw, change = plan("remove-user", ["bob", "--delete-mlflow"], S)
    assert cmd[-2:] == ["--delete-mlflow", "--yes"] and not pw and change
    assert plan("add-user", ["bob"], S)[1] is True                       # password from stdin, never in argv
    assert plan("cancel-job", ["7", " why\r\nnow "], S)[0] == ["cancel-job", "7", "why\nnow"]
    # the page quotes (shlex.join), --ssh splits: every argument comes back exactly, nothing gets split or run
    for args in (["cancel-job", "7", "it's \"idle\";\n$(rm -rf /) `id` | x & y"], ["team-add", "nlp", "bob carol"], ["log"]):
        assert shlex.split(shlex.join(args)) == args, args
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
                       "until": "2026-10-14T10:00:00Z", "stopped_by": None, "job": None}, rows[0]
    assert rows[1]["state"] == "stopped" and rows[1]["gpus"] == []
    loading = endpoints_from([{"metadata": {"namespace": "u-x", "name": "e", "annotations": {"model-hub/stopped-by": "admin"}}}],
                             [{"metadata": {"namespace": "u-x", "name": "e"}, "spec": {"nodeName": "cn01"},
                               "status": {"phase": "Running", "conditions": []}}], [])[0]
    assert loading["state"] == "loading" and loading["stopped_by"] is None, loading   # redeployed after an admin stop
    T = lambda n: {"set": True, "infinite": False, "number": n}
    sq = {"jobs": [
        {"job_id": 1382, "user_name": "ankush", "partition": "standard", "name": "jupyter", "job_state": ["RUNNING"],
         "nodes": "cn01", "start_time": T(1791876593), "end_time": T(1791890993), "gres_detail": ["gpu:a30:1(IDX:0)"],
         "command": "/var/www/ood/apps/sys/jupyter/job.sh"},
        {"job_id": 1400, "user_name": "slurm", "partition": "slurm-bridge", "name": "mh-bob-llm-x", "job_state": ["RUNNING"],
         "nodes": "cn02", "start_time": T(1791876000), "end_time": T(1791962400), "gres_detail": ["gpu:a30:1(IDX:0)"], "command": "sleep"},
        {"job_id": 1401, "user_name": "carol", "partition": "standard", "name": "train.sh", "job_state": ["RUNNING"],
         "nodes": "cn[01-02]", "start_time": T(1791876000), "end_time": T(1791962400),
         "gres_detail": ["gpu:a30:2(IDX:0-1)", "gpu:a30:1(IDX:3)"], "command": "/home/carol/train.sh"},
        {"job_id": 1402, "user_name": "dave", "partition": "standard", "name": "vscode", "job_state": ["PENDING"],
         "nodes": "", "start_time": T(0), "end_time": T(0), "state_reason": "Resources",
         "command": "/var/www/ood/apps/sys/vscode/job.sh"}]}
    eps = [{"owner": "bob", "name": "llm", "model": "/models/q", "job": "mh-bob-llm-x"}]
    rows = {r["id"]: r for r in jobs_from(sq, eps, "slurm-bridge", lambda n: ["cn01", "cn02"] if n == "cn[01-02]" else [n])}
    assert rows[1382]["kind"] == "session" and rows[1382]["app"] == "Jupyter" and rows[1382]["gpus"] == ["cn01/gpu-0"], rows[1382]
    assert rows[1382]["since"] == "2026-10-13T07:29:53Z", rows[1382]["since"]
    assert (rows[1400]["kind"], rows[1400]["owner"], rows[1400]["name"]) == ("endpoint", "bob", "llm"), rows[1400]
    assert rows[1401]["kind"] == "job" and rows[1401]["gpus"] == ["cn01/gpu-0", "cn01/gpu-1", "cn02/gpu-3"], rows[1401]
    assert rows[1402]["state"] == "pending" and rows[1402]["since"] is None and rows[1402]["why"] == "Resources" \
        and rows[1402]["app"] == "VS Code" and rows[1402]["gpus"] == [], rows[1402]
    print(f"ok: {len(good)} good requests planned, {len(bad)} bad ones refused, endpoint + job rows right")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
        sys.exit()
    if sys.argv[1:] == ["--ssh"]:                     # forced command of the admin page's key (1-install.sh)
        try:
            res = main(shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND", "")), ssh=True)
        except ValueError as e:                      # unbalanced quotes: not something the page sends
            res = {"ok": False, "output": f"bad request: {e}"}
    else:
        res = main(sys.argv[1:])
    print(json.dumps(res))
    sys.exit(0 if res["ok"] else 1)

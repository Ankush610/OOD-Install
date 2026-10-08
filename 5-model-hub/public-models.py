#!/usr/bin/env python3
"""Public models (build-plan step 6b): runs as root every minute (systemd timer from 1-setup.sh), on master.

The owner only sets the MLflow tag public=true|false (Model Hub, "Make public"). This does the privileged part,
as the MLflow admin:
  - every user gets READ on public models (to see and deploy them) and loses it when the model goes private.
  - every version's files are copied where everyone may read them, because MLflow checks a file download by the
    *experiment* it is in: READ on the model isn't enough, and READ on the owner's experiment would show all
    their runs. So:
      ML / DL  MLFLOW_DATA/artifacts/<exp "model-hub-public">/<owner>/<model>/v<N>   (READ on that exp for all)
      LLM      MODELS_ROOT/public/<owner>/<model>/v<N>             (others can't read the owner's ~/models)
    The version gets the tags public_copy (where) and public_status (waiting | copying <done>/<total> bytes, updated
    every 5 s for the owner's progress bar | ready | error: ...). "waiting" is set by Model Hub when the owner clicks.
    Nothing of the owner's changes: their `path` tag and source stay as they are.
  - copies of models that are no longer public (or deleted, or whose owner left) are removed.
Safety: owners = the LDAP users with MANAGE on the model. An LLM folder must belong to an owner and is read AS
that owner (runuser), so nobody can publish files they couldn't read themselves; ML/DL files must be in an
experiment an owner manages. Any MLflow error stops the run before anything is deleted. systemd never starts a
run while one is going, so a big copy only delays the next one.
Usage: public-models.py          (settings from the environment, see the systemd unit 1-setup.sh writes)
       public-models.py --test
"""
import base64
import hashlib
import json
import os
import posixpath
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PUBLIC_EXP = "model-hub-public"
TICK = 5                                               # seconds between progress updates


class MlflowError(Exception):
    def __init__(self, code, text):
        super().__init__(f"HTTP {code}: {text}")
        self.code = code


def slug(name):
    """A model name as one safe folder name (MLflow names may hold '/', spaces, ...); the hash keeps it unique."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name)[:60] + "-" + hashlib.sha1(name.encode()).hexdigest()[:8]


def artifact_dir(uri, owner_exps):
    """'mlflow-artifacts:/<exp>/...' -> the path under the artifact root, if it is in an experiment an owner manages."""
    if not uri.startswith("mlflow-artifacts:/"):
        raise ValueError(f"files are not in MLflow's store ({uri})")
    rel = posixpath.normpath(uri[len("mlflow-artifacts:/"):].lstrip("/"))
    exp = rel.split("/")[0]
    if rel.startswith("..") or not exp.isdigit():
        raise ValueError(f"bad file location {uri}")
    if exp not in owner_exps:
        raise ValueError("the files are in an experiment the owner doesn't manage")
    return rel


def du(path):
    """Bytes in a folder; files may come and go while it's being written."""
    total = 0
    for r, _, fs in os.walk(path):
        for f in fs:
            try:
                total += os.lstat(os.path.join(r, f)).st_size
            except OSError:
                pass
    return total


def copy(src, dest, size, as_reader, as_writer, root, progress):
    """src -> dest.tmp -> dest; reader and writer are separate users, so root itself never picks the files.
    progress(bytes copied) every 5 s while it runs."""
    need, disk = size + 2 * 1024**3, shutil.disk_usage(root)   # 2 GB left over for everyone else
    if disk.free < need or disk.free - size < disk.total * 0.05:
        raise ValueError(f"not enough disk space (needs {size / 1024**3:.1f} GB, {disk.free / 1024**3:.1f} GB free)")
    tmp = dest + ".tmp"
    os.makedirs(os.path.dirname(dest), mode=0o755, exist_ok=True)
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, mode=0o755)
    os.chown(tmp, pwd.getpwnam(as_writer).pw_uid, pwd.getpwnam(as_writer).pw_gid)
    with tempfile.TemporaryFile() as e1, tempfile.TemporaryFile() as e2:   # files, not pipes: can't fill up and hang
        rd = subprocess.Popen(["runuser", "-u", as_reader, "--", "tar", "-C", src, "-chf", "-", "."],
                              stdout=subprocess.PIPE, stderr=e1)
        wr = subprocess.Popen(["runuser", "-u", as_writer, "--", "sh", "-c", "umask 022; tar -C \"$0\" -xf - --no-same-owner",
                               tmp], stdin=rd.stdout, stdout=subprocess.DEVNULL, stderr=e2)
        rd.stdout.close()
        while True:
            try:
                wr.wait(timeout=TICK)
                break
            except subprocess.TimeoutExpired:
                try:
                    progress(du(tmp))
                except MlflowError:                # a missed progress update doesn't stop the copy
                    pass
        if rd.wait() or wr.returncode:
            shutil.rmtree(tmp, ignore_errors=True)
            e1.seek(0); e2.seek(0)
            raise ValueError("copy failed: " + (e1.read() or e2.read()).decode(errors="replace").strip()[-300:])
    os.rename(tmp, dest)


def plan_access(users, perms, public):
    """perms: {(resource_type, id): {user: PERMISSION}}. -> (grants, revokes) as [(user, model)]: READ for everyone
    on public models, and no READ left on the others (owners keep MANAGE; EDIT given by hand is left alone)."""
    grants = [(u, m) for m in sorted(public) for u in users if u not in perms.get(("registered_model", m), {})]
    revokes = [(u, m) for (t, m), who in sorted(perms.items()) if t == "registered_model" and m not in public
               for u, p in sorted(who.items()) if p == "READ"]
    return grants, revokes


def test():
    assert slug("churn") == "churn-" + hashlib.sha1(b"churn").hexdigest()[:8]
    assert "/" not in slug("../a b/c") and slug("a/b") != slug("a_b")
    assert artifact_dir("mlflow-artifacts:/1/models/m-1/artifacts", {"1"}) == "1/models/m-1/artifacts"
    for bad, exps in (("mlflow-artifacts:/1/../../etc", {"1"}), ("mlflow-artifacts:/2/x", {"1"}),
                      ("file:///etc", {"1"}), ("mlflow-artifacts:/../x", {"1"})):
        try:
            artifact_dir(bad, exps); raise AssertionError(f"accepted {bad}")
        except ValueError:
            pass
    perms = {("registered_model", "pub"): {"alice": "MANAGE", "bob": "READ"},
             ("registered_model", "priv"): {"alice": "MANAGE", "bob": "READ", "carol": "EDIT"},
             ("experiment", "1"): {"bob": "READ"}}
    g, r = plan_access(["alice", "bob", "carol"], perms, {"pub"})
    assert g == [("carol", "pub")] and r == [("bob", "priv")], (g, r)
    import tempfile as tf
    with tf.TemporaryDirectory() as d:
        os.makedirs(f"{d}/a/b"); open(f"{d}/a/x", "wb").write(b"1" * 10); open(f"{d}/a/b/y", "wb").write(b"2" * 5)
        assert du(d) == 15 and du(f"{d}/nope") == 0
        # copy() as this user: drop "runuser -u X --", slow the reader down so progress gets reported
        global TICK
        real, seen, TICK = subprocess.Popen, [], 0.05
        def fake(cmd, **kw):
            cmd = cmd[4:]
            return real(["sh", "-c", 'sleep 0.3; exec "$@"', "sh", *cmd] if cmd[0] == "tar" else cmd, **kw)
        subprocess.Popen = fake
        me = pwd.getpwuid(os.getuid()).pw_name
        try:
            copy(f"{d}/a", f"{d}/out/v1", 15, me, me, d, seen.append)
            assert open(f"{d}/out/v1/b/y").read() == "22222" and not os.path.exists(f"{d}/out/v1.tmp") and seen, seen
            try:
                copy(f"{d}/missing", f"{d}/out/v2", 0, me, me, d, seen.append); raise AssertionError("no error")
            except ValueError as e:
                assert "copy failed" in str(e) and not os.path.exists(f"{d}/out/v2.tmp"), e
        finally:
            subprocess.Popen, TICK = real, 5
    print("ok")


# ---------- the real run ----------
def env(k):
    v = os.environ.get(k)
    if not v:
        sys.exit(f"{k} not set (run through the systemd unit 1-setup.sh writes)")
    return v


def run():
    uri, base = env("MLFLOW_URI").rstrip("/"), env("LDAP_BASE")
    models_root, data, hub, mlf = env("MODELS_ROOT"), env("MLFLOW_DATA"), env("MODELHUB_USER"), env("MLFLOW_USER")
    art_root = os.path.join(data, "artifacts")
    auth = "Basic " + base64.b64encode(b"admin:" + open(os.path.join(data, "admin.pass"), "rb").read().strip()).decode()

    def call(method, path, body=None, v="2.0", **params):
        url = f"{uri}/api/{v}/mlflow/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
        req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": auth, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            raise MlflowError(e.code, e.read()[:300].decode(errors="replace"))

    def pages(path, key, **params):
        token = None
        while True:
            r = call("GET", path, max_results=200, **params, **({"page_token": token} if token else {}))
            yield from r.get(key, [])
            token = r.get("next_page_token")
            if not token:
                return

    # who may do what: every LDAP user's MLflow grants (not in MLflow yet = never logged in, nothing to do)
    out = subprocess.run(["ldapsearch", "-x", "-LLL", "-H", "ldap://localhost", "-b", f"ou=People,{base}",
                          "(objectClass=posixAccount)", "uid"], capture_output=True, text=True, check=True).stdout
    users, perms = [], {}
    for u in sorted(l[5:] for l in out.splitlines() if l.startswith("uid: ")):
        try:
            rows = call("GET", "users/permissions/list", v="3.0", username=u)["permissions"]
        except MlflowError as e:
            if e.code == 404:
                continue
            raise
        users.append(u)
        for row in rows:
            perms.setdefault((row["resource_type"], row["resource_pattern"]), {})[u] = row["permission"]
    owners = lambda t, i: sorted(u for u, p in perms.get((t, i), {}).items() if p == "MANAGE")

    try:
        exp = call("GET", "experiments/get-by-name", experiment_name=PUBLIC_EXP)["experiment"]["experiment_id"]
    except MlflowError as e:
        if e.code != 404:
            raise
        exp = call("POST", "experiments/create", {"name": PUBLIC_EXP})["experiment_id"]
    public = {m["name"]: m for m in pages("registered-models/search", "registered_models", filter="tags.public = 'true'")}

    keep = set()                                       # every copy that should exist after this run

    def set_tag(m, v, tags, key, value):
        if tags.get(key) != value:
            call("POST", "model-versions/set-tag", {"name": m, "version": v, "key": key, "value": value})
            tags[key] = value

    for m, model in sorted(public.items()):
        own = owners("registered_model", m)
        owner = own[0] if own else "admin"             # registered by the MLflow admin itself (v1 base models)
        if {t["key"]: t.get("value") for t in model.get("tags", [])}.get("owner") != owner:
            call("POST", "registered-models/set-tag", {"name": m, "key": "owner", "value": owner})
        owner_exps = {i for (t, i), who in perms.items() if t == "experiment" and any(who.get(u) == "MANAGE" for u in own)}
        if "'" in m:
            print(f"skip {m!r}: a quote in the name doesn't fit MLflow's search filter"); continue
        for ver in pages("model-versions/search", "model_versions", filter=f"name = '{m}'"):
            v, tags = ver["version"], {t["key"]: t.get("value") for t in ver.get("tags", [])}
            try:
                if tags.get("path"):                   # LLM folder (model-register)
                    src = os.path.realpath(tags["path"])
                    if src.startswith(models_root + "/") and not src.startswith(models_root + "/public/"):
                        # already readable by every endpoint (/models): no copy, others use the folder itself
                        set_tag(m, v, tags, "public_copy", tags["path"]); set_tag(m, v, tags, "public_status", "ready")
                        continue
                    dest = os.path.join(models_root, "public", owner, slug(m), f"v{v}")
                    keep.add(dest)
                    if os.path.isdir(dest):
                        set_tag(m, v, tags, "public_copy", dest); set_tag(m, v, tags, "public_status", "ready"); continue
                    if not os.path.isdir(src):
                        raise ValueError(f"folder {tags['path']} is gone")
                    reader = pwd.getpwuid(os.stat(src).st_uid).pw_name
                    if reader not in own:
                        raise ValueError(f"the folder belongs to {reader}, not to the model's owner")
                    size = int(subprocess.run(["runuser", "-u", reader, "--", "du", "-sbL", src], capture_output=True,
                                              text=True, check=True).stdout.split()[0])
                    show = lambda done: set_tag(m, v, tags, "public_status", f"copying {done}/{size}")
                    show(0)
                    copy(src, dest, size, reader, hub, models_root, show)
                else:                                  # ML / DL: files in MLflow's own store
                    dl = call("GET", "model-versions/get-download-uri", name=m, version=v)["artifact_uri"]
                    rel = artifact_dir(dl, owner_exps)
                    sub = posixpath.join(owner, slug(m), f"v{v}")
                    dest = os.path.join(art_root, exp, sub)
                    keep.add(dest)
                    if os.path.isdir(dest):
                        set_tag(m, v, tags, "public_copy", f"mlflow-artifacts:/{exp}/{sub}")
                        set_tag(m, v, tags, "public_status", "ready"); continue
                    src = os.path.realpath(os.path.join(art_root, rel))
                    if not src.startswith(art_root + "/") or not os.path.isdir(src):
                        raise ValueError(f"files not found ({dl})")
                    size = int(subprocess.run(["du", "-sb", src], capture_output=True, text=True, check=True).stdout.split()[0])
                    show = lambda done: set_tag(m, v, tags, "public_status", f"copying {done}/{size}")
                    show(0)
                    copy(src, dest, size, mlf, mlf, art_root, show)
                set_tag(m, v, tags, "public_copy", dest if tags.get("path") else f"mlflow-artifacts:/{exp}/{sub}")
                set_tag(m, v, tags, "public_status", "ready")
                print(f"public  {m} v{v} copied ({size / 1024**2:.0f} MB)")
            except (ValueError, OSError, subprocess.CalledProcessError) as e:
                print(f"ERROR   {m} v{v}: {e}")
                set_tag(m, v, tags, "public_status", f"error: {e}"[:250])

    # access after the copies, so nobody sees a public model before its files are there
    grants, revokes = plan_access(users, perms, set(public))
    grants += [(u, None) for u in users if u not in perms.get(("experiment", exp), {})]
    for u, m in grants:
        what = {"resource_type": "registered_model", "resource_id": m} if m else {"resource_type": "experiment", "resource_id": exp}
        call("POST", "users/permissions/grant", {"username": u, "permission": "READ", **what}, v="3.0")
        print(f"grant   {u} READ {m or PUBLIC_EXP}")
    for u, m in revokes:
        try:
            call("POST", "users/permissions/revoke", {"username": u, "resource_type": "registered_model", "resource_id": m}, v="3.0")
            print(f"revoke  {u} READ {m}")
        except MlflowError as e:                       # e.g. the model is deleted already: nothing to lose
            print(f"WARN    revoke {u} {m}: {e}")

    # remove copies nobody should have any more (<root>/<owner>/<model>/v<N>, and .tmp leftovers)
    for root in (os.path.join(models_root, "public"), os.path.join(art_root, exp)):
        for o in os.listdir(root) if os.path.isdir(root) else []:
            for s in os.listdir(os.path.join(root, o)):
                d = os.path.join(root, o, s)
                for v in os.listdir(d):
                    if os.path.join(d, v) not in keep:
                        shutil.rmtree(os.path.join(d, v)); print(f"remove  {os.path.join(d, v)}")
                if not os.listdir(d):
                    os.rmdir(d)
            if not os.listdir(os.path.join(root, o)):
                os.rmdir(os.path.join(root, o))


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test(); sys.exit()
    if os.getuid() != 0:
        sys.exit("Run as root (the systemd timer does).")
    run()

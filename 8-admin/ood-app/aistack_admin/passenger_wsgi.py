"""Admin page backend: an OOD Passenger app that runs AS the logged-in user, which must be OOD_ADMIN.

It does nothing itself: every read and change is one call of the root helper on master (../aistack-admin.py, installed
as ADMIN_HELPER) over ssh with the page's own key (ADMIN_KEY): master's root runs nothing but the helper for that key,
which checks every argument again and logs each change. Each argument is shlex-quoted (ssh sends one command line).
Passwords go to it on stdin. State-changing requests must carry X-Requested-With (a custom header a cross-site form
can't send). site.json (written by 2-install-ood-app.sh): {"admin": OOD_ADMIN, "ssh": [ssh, options..., root@MASTER_HOST]}.
"""
import json
import mimetypes
import os
import pwd
import shlex
import subprocess
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
PUBLIC = os.path.join(HERE, "public")
SITE = json.load(open(os.path.join(HERE, "site.json")))
USER = pwd.getpwuid(os.getuid()).pw_name


class Fail(Exception):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status


def helper(action, *args, password=None):
    """One helper call -> its "data" (reads) or {"output": ...} (changes). Its own refusals become a 400."""
    r = subprocess.run([*SITE["ssh"], shlex.join([action, *args])], capture_output=True, text=True,
                       input=(password + "\n") if password is not None else "", timeout=900)
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        raise Fail(502, f"the admin helper didn't answer: {(r.stderr or r.stdout).strip()[-300:]}")
    if not res.get("ok"):
        raise Fail(400, res.get("output") or "refused")
    return res["data"] if "data" in res else {"output": res.get("output", "")}


def text(body, key):
    v = body.get(key)
    if not isinstance(v, str) or not v:
        raise Fail(400, f"missing {key}")
    return v


def route(method, path, body):
    a = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
    if a[:1] != ["api"]:
        return None
    a = a[1:]
    if method == "GET":
        if a == ["me"]:
            return {"user": USER}
        if a in (["endpoints"], ["users"], ["teams"], ["log"], ["jobs"]):
            return helper(a[0])
    if method == "POST":
        if a == ["users"]:                                           # {name, password}
            return helper("add-user", text(body, "name"), password=text(body, "password"))
        if len(a) == 3 and a[0] == "users" and a[2] == "remove":    # {delete_home, delete_mlflow}
            flags = [f for f, on in (("--delete-home", body.get("delete_home")), ("--delete-mlflow", body.get("delete_mlflow"))) if on]
            return helper("remove-user", a[1], *flags)
        if len(a) == 3 and a[0] == "users" and a[2] == "password":  # {password}
            return helper("set-password", a[1], password=text(body, "password"))
        if len(a) == 3 and a[0] == "users" and a[2] == "limits":    # {gpus, max_hours} | {reset: true}
            if body.get("reset"):
                return helper("limits", a[1], "--reset")
            out = []
            for opt, key in (("--gpus", "gpus"), ("--max-hours", "max_hours")):
                if body.get(key) is not None:
                    out.append(helper("limits", a[1], opt, str(int(body[key])))["output"])
            return {"output": "".join(out)}
        if a == ["teams"]:                                           # {name}
            return helper("team-create", text(body, "name"))
        if len(a) == 3 and a[0] == "teams" and a[2] == "members":   # {add: [...], remove: [...]}
            out = []
            for op in ("add", "remove"):
                names = [n for n in body.get(op) or [] if isinstance(n, str)]
                if names:
                    out.append(helper(f"team-{op}", a[1], *names)["output"])
            return {"output": "".join(out)}
        if len(a) == 4 and a[0] == "endpoints" and a[3] == "stop":  # endpoints/<owner>/<name>/stop {reason}
            return helper("stop-endpoint", a[1], a[2], text(body, "reason"))
        if len(a) == 3 and a[0] == "jobs" and a[2] == "cancel":     # jobs/<id>/cancel {reason} (sessions, training jobs)
            return helper("cancel-job", a[1], text(body, "reason"))
    if method == "DELETE" and len(a) == 2 and a[0] == "teams":
        return helper("team-delete", a[1])
    raise Fail(404, f"no route {method} {path}")


def static(path, script_name):
    # like Model Hub: index.html outside public/, a <base> so relative links work, ?v= so a new install loads at once
    rel = os.path.normpath(path.strip("/"))
    full = os.path.join(PUBLIC, rel)
    if rel and not rel.startswith("..") and os.path.isfile(full):
        return open(full, "rb").read(), mimetypes.guess_type(full)[0] or "application/octet-stream"
    base = (script_name.rstrip("/") + "/").encode()
    data = open(os.path.join(HERE, "index.html"), "rb").read()
    for f in (b"app.js", b"style.css", b"admin.css"):
        v = str(int(os.path.getmtime(os.path.join(PUBLIC, f.decode())))).encode()
        data = data.replace(b'"' + f + b'"', b'"' + f + b"?v=" + v + b'"')
    return data.replace(b"<head>", b'<head>\n  <base href="' + base + b'">', 1), "text/html"


def application(environ, start_response):
    method, path = environ["REQUEST_METHOD"], environ.get("PATH_INFO", "") or "/"
    try:
        if USER != SITE["admin"]:                    # the app folder is readable by the admin only; this is the second lock
            raise Fail(403, f"only {SITE['admin']} may use the admin page")
        if method != "GET" and environ.get("HTTP_X_REQUESTED_WITH") != "XMLHttpRequest":
            raise Fail(403, "missing X-Requested-With")
        n = int(environ.get("CONTENT_LENGTH") or 0)
        body = json.loads(environ["wsgi.input"].read(n) or b"{}") if n else {}
        result = route(method, path, body)
        if result is None:
            data, ctype = static(path, environ.get("SCRIPT_NAME", ""))
            start_response("200 OK", [("Content-Type", ctype), ("Cache-Control", "no-cache")])
            return [data]
        status, payload = "200 OK", result
    except Fail as e:
        status, payload = f"{e.status} Error", {"error": str(e)}
    except (KeyError, ValueError, TypeError, json.JSONDecodeError, subprocess.TimeoutExpired) as e:
        status, payload = "400 Bad Request", {"error": f"bad request: {e}"}
    start_response(status, [("Content-Type", "application/json"), ("Cache-Control", "no-store")])
    return [json.dumps(payload).encode()]

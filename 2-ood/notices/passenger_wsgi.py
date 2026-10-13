"""The bell in OOD's top bar (../branding/_notifications.html.erb) lists the admin's messages; this clears them.
An OOD Passenger app that runs AS the logged-in user, so it can only remove that user's own files: 8-admin writes
ADMIN_NOTICES/<app>.<id> owned by the person whose job or endpoint was stopped, in a sticky dir (like /tmp).
No category in manifest.yml: it is in no menu. site.json (setup-ood.sh step 8): {"notices": ADMIN_NOTICES}.

  POST api/dismiss {"names": ["vscode.1382", "endpoint.bob.my-llm", ...]}  ->  {"removed": [...]}
Must carry X-Requested-With (a custom header a cross-site form can't send).
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
NOTICES = json.load(open(os.path.join(HERE, "site.json")))["notices"]
NAME = re.compile(r"^[a-z_]{1,32}(\.[a-z0-9_-]{1,64}){1,2}$")       # = what 8-admin writes; never a path


def dismiss(names):
    if not isinstance(names, list) or not all(isinstance(n, str) and NAME.match(n) for n in names):
        raise ValueError(f"bad names: {names!r}")
    gone = []
    for n in names:
        f = os.path.join(NOTICES, n)
        try:
            if os.lstat(f).st_uid == os.getuid():   # anyone can drop files there: only ours
                os.remove(f)
                gone.append(n)
        except FileNotFoundError:                   # cleared already (another tab, the VS Code/Jupyter bin button)
            gone.append(n)
    return gone


def application(environ, start_response):
    try:
        if environ["REQUEST_METHOD"] != "POST" or environ.get("PATH_INFO", "").rstrip("/") != "/api/dismiss":
            status, out = "404 Not Found", {"error": "POST api/dismiss only"}
        elif environ.get("HTTP_X_REQUESTED_WITH") != "XMLHttpRequest":
            status, out = "403 Forbidden", {"error": "missing X-Requested-With"}
        else:
            body = json.loads(environ["wsgi.input"].read(int(environ.get("CONTENT_LENGTH") or 0)) or b"{}")
            status, out = "200 OK", {"removed": dismiss(body.get("names"))}
    except (ValueError, OSError) as e:
        status, out = "400 Bad Request", {"error": str(e)}
    start_response(status, [("Content-Type", "application/json"), ("Cache-Control", "no-store")])
    return [json.dumps(out).encode()]

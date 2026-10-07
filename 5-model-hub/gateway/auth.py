#!/usr/bin/env python3
"""The gateway's key check. nginx asks it once per call (auth_request): may this key call this endpoint?

  GET /check   headers from nginx: Authorization (the caller's "Bearer <key>"), X-Original-URI (/<owner>/<endpoint>/...)
               200 + X-Upstream-Authorization (vLLM's own key, nginx passes it on) | 401 no/bad key | 403 not allowed
  GET /healthz 200

Keys: one per person, made in Model Hub ("My API key"): "mh~<user>~<48 hex>". Only a SHA-256 of it is stored, in
Secret model-hub-key of the person's own namespace u-<user> (they can replace or delete it there, nobody else can).
The user name in the key says which namespace to look in; the hash decides.

Who may call: the endpoint's owner (sharing comes later). Unknown endpoint and "not yours" both answer 403, so keys
can't be used to discover other people's endpoints.

Reads the k8s API with this pod's ServiceAccount (2-sync-users.sh lets it read services + secrets in user namespaces
only). Lookups are cached CACHE_S seconds: a revoked or new key takes effect within that.
Stdlib only. Test: python3 auth.py --test
"""
import base64
import hashlib
import hmac
import json
import os
import re
import signal
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USER = r"[a-z_][a-z0-9_.-]{0,31}"                                  # Linux user names (as in LDAP)
KEY = re.compile(rf"^mh~({USER})~([0-9a-f]{{48}})$")
URI = re.compile(rf"^/({USER})/([a-z0-9]([a-z0-9-]{{0,40}}[a-z0-9])?)(/|$|\?)")
CACHE_S = int(os.environ.get("CACHE_SECONDS", "60"))
API = os.environ.get("K8S_API", "https://kubernetes.default.svc")
SA = "/var/run/secrets/kubernetes.io/serviceaccount"


def _token():
    try:
        return open(f"{SA}/token").read().strip()                   # re-read: the kubelet rotates it
    except OSError:
        return ""                                                   # tests: K8S_API is kubectl proxy / a mock


_ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt") if os.path.exists(f"{SA}/ca.crt") else None
_cache, _lock = {}, threading.Lock()


def k8s_get(path):
    """JSON of a k8s object, or None if it doesn't exist (cached, including 'doesn't exist')."""
    now = time.time()
    with _lock:
        hit = _cache.get(path)
        if hit and hit[0] > now:
            return hit[1]
    req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {_token()}"} if _token() else {})
    try:
        with urllib.request.urlopen(req, timeout=5, context=_ctx) as r:
            obj = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code not in (403, 404):                                 # 403: not a user namespace (no RoleBinding)
            raise
        obj = None
    with _lock:
        _cache[path] = (now + CACHE_S, obj)
    return obj


def secret_value(ns, name, key):
    s = k8s_get(f"/api/v1/namespaces/{ns}/secrets/{name}")
    v = (s or {}).get("data", {}).get(key)
    return base64.b64decode(v).decode() if v else None


def endpoint_service(svc, ep):
    """Only Services shaped like render.py makes them. Users can create Services in their own namespace, and an
    ExternalName one (or one without a selector) would make nginx follow it anywhere: another user's model, MLflow."""
    if not svc:
        return False
    spec = svc.get("spec", {})
    return ("model-hub/runtime" in svc["metadata"].get("labels", {}) and spec.get("type", "ClusterIP") == "ClusterIP"
            and spec.get("selector") == {"app": ep})


def check(authorization, uri):
    """-> (status, reason, upstream_authorization or None)"""
    token = authorization[7:].strip() if authorization.lower().startswith("bearer ") else ""
    m = KEY.match(token)
    if not m:
        return 401, "no API key (Authorization: Bearer mh~<user>~...)", None
    caller = m.group(1)
    want = secret_value(f"u-{caller}", "model-hub-key", "sha256")
    if not want or not hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), want):
        return 401, "unknown or revoked API key", None
    u = URI.match(uri or "")
    if not u:
        return 403, "address must be /<owner>/<endpoint>/...", None
    owner, ep = u.group(1), u.group(2)
    svc = k8s_get(f"/api/v1/namespaces/u-{owner}/services/{ep}")
    if caller != owner or not endpoint_service(svc, ep):
        return 403, "no such endpoint, or it isn't yours", None
    if svc["metadata"]["labels"]["model-hub/runtime"] == "vllm":     # vLLM checks its own key; the caller never sees it
        k = secret_value(f"u-{owner}", f"{ep}-key", "api-key")
        return 200, f"{caller} -> {owner}/{ep}", f"Bearer {k}" if k else None
    return 200, f"{caller} -> {owner}/{ep}", None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, "ok")
        if self.path != "/check":
            return self.reply(404, "not found")
        try:
            status, reason, upstream = check(self.headers.get("Authorization", ""), self.headers.get("X-Original-URI", ""))
        except Exception as e:                                       # k8s API down etc.: refuse, never let through
            status, reason, upstream = 503, f"gateway can't check keys: {type(e).__name__}", None
        # one line per call: who called what, allowed or not (usage reports later read this)
        print(json.dumps({"t": int(time.time()), "status": status, "reason": reason,
                          "uri": (self.headers.get("X-Original-URI") or "")[:200]}), flush=True)
        self.reply(status, reason, upstream)

    def reply(self, status, reason, upstream=None):
        self.send_response(status)
        self.send_header("X-Gateway-Reason", reason)
        if upstream:
            self.send_header("X-Upstream-Authorization", upstream)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


def svc(runtime, ep):
    return {"metadata": {"labels": {"model-hub/runtime": runtime}}, "spec": {"type": "ClusterIP", "selector": {"app": ep}}}


def test():
    key = "mh~alice~" + "a" * 48
    db = {"/api/v1/namespaces/u-alice/secrets/model-hub-key": {"data": {"sha256": base64.b64encode(
              hashlib.sha256(key.encode()).hexdigest().encode()).decode()}},
          "/api/v1/namespaces/u-alice/services/qwen": svc("vllm", "qwen"),
          "/api/v1/namespaces/u-alice/secrets/qwen-key": {"data": {"api-key": base64.b64encode(b"vk").decode()}},
          "/api/v1/namespaces/u-alice/services/churn": svc("mlflow", "churn"),
          "/api/v1/namespaces/u-bob/services/x": svc("mlflow", "x"),
          "/api/v1/namespaces/u-alice/services/other": {"metadata": {"labels": {}}, "spec": {"selector": {"app": "other"}}},
          # alice's attempts to point "her" endpoint elsewhere
          "/api/v1/namespaces/u-alice/services/evil": {**svc("mlflow", "evil"), "spec": {
              "type": "ExternalName", "externalName": "x.u-bob.svc.cluster.local"}},
          "/api/v1/namespaces/u-alice/services/nosel": {**svc("mlflow", "nosel"), "spec": {"type": "ClusterIP"}},
          "/api/v1/namespaces/u-alice/services/wrongsel": {**svc("mlflow", "wrongsel"), "spec": {"selector": {"app": "churn"}}}}
    global k8s_get
    k8s_get = db.get
    b = "Bearer " + key
    assert check(b, "/alice/qwen/v1/chat/completions") == (200, "alice -> alice/qwen", "Bearer vk")
    assert check(b, "/alice/churn/invocations")[::2] == (200, None)
    assert check(b, "/alice/churn")[0] == 200 and check(b, "/alice/churn?x=1")[0] == 200
    assert check("", "/alice/qwen/")[0] == 401
    assert check("Bearer mh~alice~" + "b" * 48, "/alice/qwen/")[0] == 401           # wrong key
    assert check("Bearer mh~carol~" + "a" * 48, "/alice/qwen/")[0] == 401           # no key stored for carol
    assert check(b, "/bob/x/invocations")[0] == 403                                 # not hers
    assert check(b, "/alice/nope/")[0] == 403 and check(b, "/alice/other/")[0] == 403
    assert check(b, "/alice/../bob/x")[0] == 403 and check(b, "/")[0] == 403
    for bad in ("evil", "nosel", "wrongsel"):                                       # not shaped like render.py's
        assert check(b, f"/alice/{bad}/invocations")[0] == 403, bad
    assert check("Bearer mh~al ice~" + "a" * 48, "/alice/qwen/")[0] == 401
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test(); sys.exit()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))      # PID 1 in the container: no default SIGTERM handling
    port = int(os.environ.get("PORT", "8081"))
    print(f"gateway auth on 127.0.0.1:{port}, k8s API {API}, cache {CACHE_S}s", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

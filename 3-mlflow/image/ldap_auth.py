"""MLflow login: single sign-on through OOD, LDAP password for people, auth.db for tokens and the local admin.

basic_auth.ini:  authorization_function = ldap_auth:authenticate_request
A request is let in when EITHER
  - it came through OOD's Apache (the browser, logged in with Keycloak): OOD's /node proxy sets
    X-Forwarded-User to the logged-in user, and Apache adds X-MLflow-Proxy-Secret, which only Apache and
    this pod know (MLFLOW_PROXY_SECRET_FILE). Without the secret the header is ignored, so nobody can claim
    a name by calling MLflow's port directly. Or
  - the password matches auth.db (the built-in check): the MLflow admin, and the random job
    token that 3-sync-tokens.sh writes into ~/.mlflow/credentials, or
  - an LDAP bind as uid=<user>,ou=People,<base> works: the person's normal SSH/OOD password.
A person's first login creates their MLflow user, so permissions (owner = creator) work at once.
"""
import hashlib, hmac, os, re, secrets, ssl, time

from ldap3 import Connection, Server, Tls
from mlflow.server.auth import make_basic_auth_response, store
from flask import request
from werkzeug.datastructures import Authorization

# set by ../mlflow.yaml from ../../site.conf; no defaults, so a missing value fails at startup, not at login
URI, BASE, CA = os.environ["LDAP_URI"], os.environ["LDAP_BASE"], os.environ["LDAP_CA"]
NAME = re.compile(r"^[a-z_][a-z0-9_.-]{0,31}$")   # Linux usernames only: nothing can be injected into the DN
# empty or missing = no single sign-on (OOD without Keycloak): only passwords and tokens work
_f = os.environ.get("MLFLOW_PROXY_SECRET_FILE", "")
PROXY_SECRET = open(_f).read().strip() if _f and os.path.isfile(_f) else ""

_server = Server(URI, use_ssl=URI.startswith("ldaps"), connect_timeout=5,
                 tls=Tls(ca_certs_file=CA, validate=ssl.CERT_REQUIRED))
# ponytail: in-process cache of good LDAP logins, 5 min, one worker. The UI fires many requests per page,
# so without it every click is several binds. A password change or LDAP lock takes up to 5 min to bite.
_ok = {}
TTL = 300


def ldap_ok(user, password):
    if not password or not NAME.match(user or ""):   # empty password = anonymous bind, which LDAP accepts
        return False
    key = (user, hashlib.sha256(password.encode()).hexdigest())
    if _ok.get(key, 0) > time.time():
        return True
    try:
        conn = Connection(_server, user=f"uid={user},ou=People,{BASE}", password=password, receive_timeout=5)
        good = conn.bind()
        conn.unbind()
    except Exception:
        good = False   # LDAP down: people can't log in with their password, tokens and admin still work
    if good:
        _ok[key] = time.time() + TTL
    return good


def from_proxy():
    """The user OOD's Apache vouches for, or None."""
    if not PROXY_SECRET:
        return None
    sent, user = request.headers.get("X-MLflow-Proxy-Secret", ""), request.headers.get("X-Forwarded-User", "")
    if sent and hmac.compare_digest(sent.encode(), PROXY_SECRET.encode()) and NAME.match(user):
        return user
    return None


def authenticate_request():
    user = from_proxy()
    if user:
        if not store.has_user(user):
            store.create_user(user, secrets.token_hex(24))
        return Authorization("basic", {"username": user})
    auth = request.authorization
    if auth is None or not auth.username:
        return make_basic_auth_response()
    user, password = auth.username, auth.password or ""
    if store.has_user(user) and store.authenticate_user(user, password):
        return auth
    if ldap_ok(user, password):
        if not store.has_user(user):
            # unknown random password: this account is only ever used through LDAP or a token
            store.create_user(user, secrets.token_hex(24))
        return auth
    return make_basic_auth_response()

#!/usr/bin/env python3
"""Configure Keycloak through its admin REST API (stdlib only). Called by 1-install.sh and 2-realm.sh.

Reads everything from the environment (the scripts export site.conf): KC_URL (http://127.0.0.1:<port><path>),
KEYCLOAK_ADMIN, KEYCLOAK_DATA (admin.pass lives there). Passwords are read from files, never from argv.

  kc.py admin   make KEYCLOAK_ADMIN a permanent admin, then delete the first-start bootstrap admin
  kc.py realm   realm KEYCLOAK_REALM + read-only LDAP users and groups, then a full sync
  kc.py client ID BASE_URL SECRET_FILE
                confidential OIDC client ID for a web app at BASE_URL (login returns to BASE_URL/oidc);
                its secret is written to SECRET_FILE (mode 600)
  kc.py local-user NAME
                a realm user that is NOT in LDAP (the local admin's way in when LDAP is down);
                password from stdin; does nothing if the user already exists
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ["KC_URL"].rstrip("/")
DATA = os.environ["KEYCLOAK_DATA"]


def read(path):
    with open(path) as f:
        return f.read().strip()


def token(user, password):
    body = urllib.parse.urlencode({"grant_type": "password", "client_id": "admin-cli",
                                   "username": user, "password": password}).encode()
    try:
        with urllib.request.urlopen(f"{URL}/realms/master/protocol/openid-connect/token", body) as r:
            return json.load(r)["access_token"]
    except urllib.error.HTTPError as e:
        if e.code in (400, 401):
            return None
        raise


class Admin:
    def __init__(self, tok):
        self.tok = tok

    def call(self, method, path, body=None, ok=(200, 201, 204)):
        req = urllib.request.Request(f"{URL}/admin{path}", method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {self.tok}",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            if e.code in ok:
                return e.code, None
            sys.exit(f"{method} {path}: HTTP {e.code} {e.read().decode()[:300]}")

    def get(self, path, ok=(200,)):
        return self.call("GET", path, ok=ok)[1]


def login():
    tok = token(os.environ["KEYCLOAK_ADMIN"], read(f"{DATA}/admin.pass"))
    if not tok:
        sys.exit(f"Keycloak admin {os.environ['KEYCLOAK_ADMIN']} can't log in: run 1-install.sh first.")
    return Admin(tok)


def cmd_admin():
    """Keycloak's first start makes a *temporary* admin from KC_BOOTSTRAP_ADMIN_*. Replace it with a permanent one."""
    name, pw = os.environ["KEYCLOAK_ADMIN"], read(f"{DATA}/admin.pass")
    if token(name, pw):
        print(f"admin {name}: ok")
        return
    boot = token("kc-bootstrap", read(f"{DATA}/bootstrap.pass"))
    if not boot:
        sys.exit("Neither the admin nor the bootstrap admin can log in (Keycloak data from another install?).")
    a = Admin(boot)
    a.call("POST", "/realms/master/users", {"username": name, "enabled": True,
           "credentials": [{"type": "password", "value": pw, "temporary": False}]}, ok=(201, 409))
    uid = a.get(f"/realms/master/users?exact=true&username={name}")[0]["id"]
    role = a.get("/realms/master/roles/admin")
    a.call("POST", f"/realms/master/users/{uid}/role-mappings/realm", [role])
    a = Admin(token(name, pw))                                 # from here on, as the permanent admin
    boot_id = a.get("/realms/master/users?exact=true&username=kc-bootstrap")[0]["id"]
    a.call("DELETE", f"/realms/master/users/{boot_id}")
    print(f"admin {name}: created; bootstrap admin deleted")


def component(a, realm, parent, provider_type, provider, name, config):
    """Create or update one component (LDAP provider or mapper); returns its id."""
    found = [c for c in a.get(f"/realms/{realm}/components?parent={parent}&type={provider_type}")
             if c["name"] == name]
    body = {"name": name, "providerId": provider, "providerType": provider_type, "parentId": parent,
            "config": {k: [v] for k, v in config.items()}}
    if found:
        body["id"] = found[0]["id"]
        a.call("PUT", f"/realms/{realm}/components/{body['id']}", body)
        return body["id"]
    a.call("POST", f"/realms/{realm}/components", body)
    return [c for c in a.get(f"/realms/{realm}/components?parent={parent}&type={provider_type}")
            if c["name"] == name][0]["id"]


def cmd_realm():
    a, e = login(), os.environ
    realm, base = e["KEYCLOAK_REALM"], e["LDAP_BASE"]
    settings = {
        "realm": realm, "enabled": True, "displayName": e["CLUSTER_TITLE"],
        # LDAP owns users and passwords: no sign-up, no reset, no editing here
        "registrationAllowed": False, "resetPasswordAllowed": False, "editUsernameAllowed": False,
        "loginWithEmailAllowed": False, "duplicateEmailsAllowed": True, "rememberMe": False,
        "bruteForceProtected": True,
    }
    if a.call("GET", f"/realms/{realm}", ok=(200, 404))[0] == 404:
        a.call("POST", "/realms", settings)
        print(f"realm {realm}: created")
    else:
        a.call("PUT", f"/realms/{realm}", settings)
        print(f"realm {realm}: updated")
    # LDAP users may have no e-mail; "verify profile" would ask for one and then fail (read-only LDAP)
    a.call("PUT", f"/realms/{realm}/authentication/required-actions/VERIFY_PROFILE",
           {"alias": "VERIFY_PROFILE", "name": "Verify Profile", "providerId": "VERIFY_PROFILE",
            "enabled": False, "defaultAction": False})

    rid = a.get(f"/realms/{realm}")["id"]
    ldap = component(a, realm, rid, "org.keycloak.storage.UserStorageProvider", "ldap", "ldap", {
        "enabled": "true", "priority": "0", "vendor": "rhds",          # 389 DS = Red Hat Directory Server
        "connectionUrl": e["KC_LDAP_URL"], "authType": "none",         # anonymous search, like OOD and SSSD
        "usersDn": f"ou=People,{base}", "searchScope": "1", "pagination": "true",
        "userObjectClasses": "inetOrgPerson, posixAccount",
        "usernameLDAPAttribute": "uid", "rdnLDAPAttribute": "uid", "uuidLDAPAttribute": "nsuniqueid",
        "editMode": "READ_ONLY", "importEnabled": "true", "syncRegistrations": "false",
        "fullSyncPeriod": "86400", "changedSyncPeriod": "900", "batchSizeForSync": "1000",
        "cachePolicy": "DEFAULT", "connectionPooling": "true", "startTls": "false",
        "trustEmail": "false", "validatePasswordPolicy": "false", "allowKerberosAuthentication": "false",
        "useKerberosForPasswordAuthentication": "false",
    })
    groups = component(a, realm, ldap, "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
                       "group-ldap-mapper", "groups", {
        "groups.dn": f"ou=Groups,{base}", "group.name.ldap.attribute": "cn",
        "group.object.classes": "groupOfNames", "membership.ldap.attribute": "member",
        "membership.attribute.type": "DN", "membership.user.ldap.attribute": "uid",
        "mode": "READ_ONLY", "user.roles.retrieve.strategy": "LOAD_GROUPS_BY_MEMBER_ATTRIBUTE",
        "preserve.group.inheritance": "false", "ignore.missing.groups": "true",
        "drop.non.existing.groups.during.sync": "true", "groups.path": "/",
    })
    print("ldap: users from", f"ou=People,{base}", "and groups from", f"ou=Groups,{base}", "(read-only)")

    _, users = a.call("POST", f"/realms/{realm}/user-storage/{ldap}/sync?action=triggerFullSync")
    _, grp = a.call("POST", f"/realms/{realm}/user-storage/{ldap}/mappers/{groups}/sync?direction=fedToKeycloak")
    print("sync users:", users.get("status") if users else users, "| groups:", grp.get("status") if grp else grp)
    if users and users.get("failed"):
        sys.exit("some LDAP users failed to sync (see Keycloak's log: journalctl -u keycloak)")


def cmd_client(client_id, base, secret_file):
    """Browser login for one web app (OIDC authorization code flow). Safe to rerun: updates it, keeps the secret."""
    a, realm, base = login(), os.environ["KEYCLOAK_REALM"], base.rstrip("/")
    body = {
        "clientId": client_id, "name": client_id, "enabled": True, "protocol": "openid-connect",
        "publicClient": False, "clientAuthenticatorType": "client-secret",
        "standardFlowEnabled": True,                 # browser login only
        "implicitFlowEnabled": False, "directAccessGrantsEnabled": False, "serviceAccountsEnabled": False,
        "redirectUris": [f"{base}/oidc"], "webOrigins": [base], "rootUrl": base, "baseUrl": "/",
        "attributes": {"post.logout.redirect.uris": f"{base}/*", "pkce.code.challenge.method": "S256"},
    }
    found = a.get(f"/realms/{realm}/clients?clientId={urllib.parse.quote(client_id)}")
    if found:
        cid = found[0]["id"]
        a.call("PUT", f"/realms/{realm}/clients/{cid}", {**found[0], **body})
        print(f"client {client_id}: updated ({base}/oidc)")
    else:
        a.call("POST", f"/realms/{realm}/clients", body)
        cid = a.get(f"/realms/{realm}/clients?clientId={urllib.parse.quote(client_id)}")[0]["id"]
        print(f"client {client_id}: created ({base}/oidc)")
    secret = a.get(f"/realms/{realm}/clients/{cid}/client-secret")["value"]
    old = os.umask(0o077)
    try:
        with open(secret_file, "w") as f:
            f.write(secret)
    finally:
        os.umask(old)
    os.chmod(secret_file, 0o600)


def cmd_local_user(name):
    a, realm = login(), os.environ["KEYCLOAK_REALM"]
    if a.get(f"/realms/{realm}/users?exact=true&username={urllib.parse.quote(name)}"):
        print(f"user {name}: exists (change its password in the admin console: Users -> {name} -> Credentials)")
        return
    pw = sys.stdin.read().rstrip("\n")
    if len(pw) < 8:
        sys.exit("password too short (8+ characters)")
    a.call("POST", f"/realms/{realm}/users", {"username": name, "enabled": True, "firstName": name, "lastName": "local",
           "credentials": [{"type": "password", "value": pw, "temporary": False}]})
    print(f"user {name}: created (local to Keycloak, not in LDAP)")


if __name__ == "__main__":
    cmds = {"admin": (cmd_admin, 0), "realm": (cmd_realm, 0), "client": (cmd_client, 3), "local-user": (cmd_local_user, 1)}
    name, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
    if name not in cmds or len(args) != cmds[name][1]:
        sys.exit(__doc__)
    cmds[name][0](*args)

# 6-keycloak

One login for the web tools: OOD, MLflow and Model Hub send the browser to Keycloak, the user logs in once, and
every tool knows who they are (OpenID Connect). **LDAP stays the user list:** Keycloak reads users and groups from
it and LDAP checks the password. SSH, Slurm and file permissions keep using LDAP directly.

**Passwords are the one thing Keycloak writes to LDAP.** A new user's password (`../1-ldap/add-user.sh`, or "Set a new
password" in `../1-ldap/menu.sh`) is one-time: their next web login asks for a new one, and that one goes to LDAP, so
it works for SSH, Slurm, OOD and MLflow at once. Anyone can also change theirs in the account page
(`https://$OOD_SERVERNAME/auth/realms/$KEYCLOAK_REALM/account`). Keycloak binds as `cn=keycloak-passwords,<LDAP_BASE>`,
which an LDAP access rule lets write `userPassword` under `ou=People` and nothing else (`2-realm.sh` checks that).
**Web only:** someone who only ever uses SSH keeps the one-time password until they change it (`passwd`).
Design: `../../AI-Stack/docs/model-hub/versions/version-2/` (build-plan step 2).

## Run (on master, after 0-registry, 1-ldap, 2-ood)

```bash
sudo bash ../2-ood/setup-ood.sh   # once: adds the /auth proxy to OOD's Apache (safe to rerun)
sudo bash 1-install.sh            # Postgres + Keycloak under systemd, images in the registry, permanent admin
sudo bash 2-realm.sh              # realm $KEYCLOAK_REALM with the LDAP users + groups; prints how to test a login
```

This step only installs Keycloak. OOD and MLflow still use their old logins until their own steps switch them
(each keeps the old login as a fallback until the new one is proven).

## Switch OOD's login to Keycloak (after the steps above)

```bash
sed -i 's/^OOD_AUTH=ldap /OOD_AUTH=keycloak /' ../site.conf
sudo bash ../2-ood/setup-ood.sh     # makes Keycloak client "ood"; asks once for a Keycloak password for OOD_ADMIN
```
Then open `https://$OOD_SERVERNAME`: the Keycloak login page comes first, then OOD. **Going back:** set
`OOD_AUTH=ldap` and rerun `setup-ood.sh` (nothing in Keycloak needs undoing).

| What | Where | Why |
|---|---|---|
| client `ood` (confidential, browser login only, PKCE) | Keycloak realm `KEYCLOAK_REALM`; secret in `/etc/ood/oidc-client.secret` (root, 0600) | OOD's Apache (`mod_auth_openidc`) logs users in through it; returns to `https://$OOD_SERVERNAME/oidc` only |
| username = `preferred_username` | `oidc_remote_user_claim` | = the LDAP `uid` = the Linux user the OOD session runs as |
| Apache → Keycloak on `127.0.0.1` | `oidc_provider_metadata_url` | no certificate trouble; Keycloak still gives the browser its public `https://…/auth` address |
| `OOD_ADMIN` = local Keycloak user | `kc.py local-user` | not in LDAP; the way in when LDAP is down (htpasswd isn't used with Keycloak) |
| sessions 8 h | `oidc_session_*` | then Keycloak asks again (silently if its own session is still valid) |
| `/etc/ood/config/ood_portal.yml` mode 0600 | `setup-ood.sh` | it holds the client secret |

## How it runs

```
 browser ──https──► OOD's Apache :443 ── /auth ──► 127.0.0.1:KEYCLOAK_PORT  keycloak     (container, UID 949)
                                                                  │ JDBC
                                                    127.0.0.1:KEYCLOAK_DB_PORT keycloak-db (Postgres, UID 949)
                                                                  │ data: KEYCLOAK_DATA/db (master's local disk)
                    Keycloak ── ldaps://MASTER_HOST:636 ──► 389 DS (users + groups read; writes passwords only)
```

| Piece | Where | Why |
|---|---|---|
| systemd units (quadlets) | `/etc/containers/systemd/keycloak{,-db}.container` | login must work even when k8s has a problem; restarts on crash and at boot |
| both containers run as `KEYCLOAK_USER` (949) | `User=` in the units | the images' own UIDs (1000, 999) are real people/accounts on this cluster |
| 127.0.0.1 only, `Network=host` | `KC_HTTP_HOST`, Postgres `listen_addresses` | nothing reaches Keycloak except through Apache's HTTPS |
| image `keycloak:<ver>-rudra` | `image/Containerfile`, built by `1-install.sh` | pre-built for Postgres + `/auth`: starts in seconds, never rebuilds at runtime |
| passwords | `KEYCLOAK_DATA/{admin,db,bootstrap}.pass`, `/etc/keycloak/*.env` (root, 0600) | never on a command line |
| admin | `KEYCLOAK_ADMIN` in realm `master` | the first-start "temporary" admin is replaced and deleted (`kc.py admin`) |
| `KC_CACHE=local` | runtime env | one server: without it Keycloak opens a cluster port (57800) on every interface |
| sign-outs reach OOD (back-channel logout) | client `ood`: `backchannel.logout.url` = `https://$OOD_SERVERNAME/oidc?logout=backchannel` (`kc.py client`); `OOD_CERT` mounted as trusted | when Keycloak ends a session (`remove-user.sh`, "sign out other devices", admin console) it tells OOD's Apache, which drops its own login (else it lasts up to 8 h): the next page goes to the login, background calls get 401 (Model Hub then reloads) |
| LDAP over ldaps, CA mounted | `Volume=$LDAP_CA:…/truststores/ldap-ca.crt`, `KC_TRUSTSTORE_PATHS` | 389 DS refuses password changes on a plain connection; the name `MASTER_HOST` matches LDAP's certificate |
| LDAP account `cn=keycloak-passwords` | password in `KEYCLOAK_DATA/ldap.pass`; access rule `keycloak sets passwords` on `ou=People` | may write `userPassword`, nothing else: never the Directory Manager |
| LDAP attribute mappers read-only | `kc.py realm` | the provider is writable (for passwords), so name/e-mail edits would otherwise go to LDAP (which refuses them) |

## Files

| File | What it does |
|---|---|
| `1-install.sh` | system user, data dir, passwords, images → registry, units, start, wait for health, permanent admin, check through Apache |
| `2-realm.sh` | LDAP account + access rule for passwords, realm settings (no sign-up, no e-mail reset, brute-force protection), LDAP users + groups (writable for passwords only), full sync; checks the account can't change other attributes |
| `kc.py` | the admin REST calls (stdlib Python; reads passwords from files): `admin`, `realm`, `client` (OIDC client for a web app, secret to a file), `local-user`, `must-change` (one-time password), `logout` + `remove-user` (used by `../1-ldap/remove-user.sh`, in that order around the LDAP delete) |
| `image/Containerfile` | the optimized Keycloak image |
| `theme/ai-factory/login/` | login page look: background `resources/img/bg.jpg`, dark heading (`css/ai-factory.css`); heading text = `PORTAL_TITLE`. `1-install.sh` copies it to `KEYCLOAK_DATA/themes` (mounted read-only) and restarts Keycloak when it changed; `2-realm.sh` turns it on |

## Day to day

| Task | How |
|---|---|
| Status / logs | `systemctl status keycloak keycloak-db`, `journalctl -u keycloak -f` |
| New user | `../1-ldap/add-user.sh`: the password you type is one-time; their first web login asks for their own |
| Forgotten password | `../1-ldap/menu.sh` → Set a new password: one-time again |
| Admin console | `https://$OOD_SERVERNAME/auth/admin`, user `kcadmin`, password `sudo cat $KEYCLOAK_DATA/admin.pass` |
| Upgrade Keycloak | change `KEYCLOAK_VERSION`, rerun `1-install.sh` (new image tag → units change → restart; Keycloak migrates its DB) |
| Upgrade Postgres (major, e.g. 17 → 18) | not by changing the tag alone: dump + restore (`pg_dump` in `keycloak-db`) |
| Backup | `podman exec keycloak-db pg_dump -U keycloak keycloak > keycloak.sql` (as root) + `KEYCLOAK_DATA/*.pass` |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `1-install.sh`: `Port N is taken by another program` | something else listens there (master already runs a Postgres on 5432 and SonarQube on 9000) | pick free ports in `site.conf` (`KEYCLOAK_PORT`, `KEYCLOAK_MGMT_PORT`, `KEYCLOAK_DB_PORT`) |
| `https://<host>/auth/...` gives 503 | Keycloak not running, or `KEYCLOAK_PORT` in Apache's config differs | `systemctl status keycloak`; rerun `../2-ood/setup-ood.sh` after changing ports |
| `/auth` gives 404 from OOD | Apache has no `/auth` proxy yet | rerun `../2-ood/setup-ood.sh` |
| Keycloak page says "HTTPS required" | opened through plain http, or Apache doesn't send `X-Forwarded-Proto` | use `https://`; rerun `../2-ood/setup-ood.sh` |
| links/redirects point to the wrong host | `KC_HOSTNAME` = `https://$OOD_SERVERNAME/auth`; the browser uses another name | set `OOD_SERVERNAME` to the name users type; rerun `../2-ood/setup-ood.sh` and `1-install.sh` |
| an LDAP user gets "Invalid user credentials" | wrong password, or the user isn't under `ou=People` | test the same password with `ssh`; `2-realm.sh` resyncs |
| `keycloak-db` keeps restarting, `Permission denied` on the data dir | `KEYCLOAK_DATA/db` not owned by `KEYCLOAK_UID` | rerun `1-install.sh` (fixes ownership) |
| OOD: Keycloak says `Invalid parameter: redirect_uri` | the browser uses another host name than `OOD_SERVERNAME` | set `OOD_SERVERNAME` to the name users type; rerun `../2-ood/setup-ood.sh` |
| OOD: `Error: user ... does not exist` after logging in | the Keycloak user isn't a Linux user on master (e.g. a local Keycloak user other than `OOD_ADMIN`) | only LDAP users and `OOD_ADMIN` can use OOD |
| OOD: login loop or `state` error | old cookies, or `OIDCCryptoPassphrase` changed | clear the site's cookies; the passphrase lives in `/etc/ood/oidc-crypto.passphrase` (keep it) |
| OOD login broken and you need in now | | `OOD_AUTH=ldap` in `site.conf`, `sudo bash ../2-ood/setup-ood.sh` |
| a removed / signed-out user's OOD tab keeps working | Keycloak can't reach `https://$OOD_SERVERNAME/oidc` (certificate not trusted, or the name doesn't resolve on master) | `journalctl -u keycloak \| grep -i backchannel`; after renewing OOD's certificate rerun `1-install.sh` + restart Keycloak |
| `2-realm.sh`: `Keycloak doesn't trust LDAP's CA yet` | Keycloak was installed before passwords were writable | rerun `1-install.sh` (mounts the CA, restarts Keycloak), then `2-realm.sh` |
| new password refused / "Could not modify attribute" after the first login | Keycloak can't write to LDAP: account, access rule or ldaps | rerun `2-realm.sh` (recreates them and checks); `journalctl -u keycloak \| grep -i ldap` |
| `remove-user.sh` / admin console: deleting a user fails in Keycloak | Keycloak passes a delete on to LDAP, which its account may not do | delete in LDAP first (`remove-user.sh` does it in that order) |
| testing in a rootless podman pod reaches the real LDAP | podman maps the pod hostname to the host's IP | `--add-host <name>:127.0.0.1` (see `testing/keycloak-passwords/run.sh`) |
| `kc.py`: `Neither the admin nor the bootstrap admin can log in` | the database is from an older install with another admin password | put that password in `KEYCLOAK_DATA/admin.pass`, rerun |

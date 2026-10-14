# 2-ood

Installs Open OnDemand 4.2 on the login node `LOGIN_HOST` (AlmaLinux 9; `master` itself on this cluster), with a self-signed certificate. Web login uses the **LDAP password**, the same as SSH. Needs `../1-ldap/1-server.sh` (master) and `2-client.sh` (here) first.
Official guide: https://osc.github.io/ood-documentation/latest/installation/install-software.html

## Run

```bash
sudo bash setup-ood.sh     # on LOGIN_HOST; asks once for OOD_ADMIN's local web password
```
With `OOD_AUTH=keycloak` it needs from master: `../6-keycloak/2-realm.sh` (copies the client secret to `OOD_OIDC_SECRET`)
and, for MLflow single sign-on, `../3-mlflow/2-deploy.sh` (copies `MLFLOW_PROXY_SECRET`). The login node never reads
master's files itself.

It uses these values from `../site.conf`:

| Variable | Meaning |
|---|---|
| `OOD_VERSION` | OnDemand release, part of the repo RPM URL |
| `OOD_SERVERNAME` | the exact host in the browser URL (`localhost` behind an SSH tunnel) |
| `OOD_ADMIN` | a real **local** Linux user with an htpasswd web login, which still works when LDAP is down |
| `CLUSTER_ID` / `CLUSTER_TITLE` | OOD cluster file name, and the name users see |
| `PORTAL_TITLE` / `PORTAL_COLOR` | tab title (also the Keycloak login heading), top bar colour. The look is `ondemand.d/ai-factory.yml` + `branding/` (top bar shows the C-DAC logo `cdac-logo.svg`, made white by CSS; tab icon `favicon.ico`, built from the logo, served via `public_url: /public/ai-factory`; footer = "© 2026 C-DAC India — Government of India" instead of OOD's, no welcome logo, login page background on the home page; home page = our tools as cards in sections (widget `branding/_ai_tools.html.erb` -> `/etc/ood/config/apps/dashboard/views/widgets/`, `dashboard_layout` in the yml; a card shows only if the user can open that app, so Admin only for `OOD_ADMIN`, and `OOD_ADMIN` (not in LDAP) gets no MLflow/Model Hub cards; tool list and texts at the top of the file; icons = the apps' own Bootstrap Icons, white on a colour per tool (`icon-<colour>` in `ai-factory.css`), copied from `5-model-hub` to `/public/ai-factory/bootstrap-icons/`); top bar = Files, Clusters, Interactive Apps with only the "Servers" apps, so no Jobs, My Interactive Sessions, All Apps or Desktop); OOD's own files are not patched. Our own app pages (VS Code, Jupyter, MLflow, Model Hub) get the same bar from `branding/app-bar.css`, written to `/public/ai-factory/app-bar.css` with `PORTAL_COLOR` |
| `SLURM_BIN` / `SLURM_CONF` | folder of `sbatch`, and `slurm.conf` |
| `LDAP_BASE` | where Apache looks users up |

## What it does

1. Repos (CRB, EPEL, Ruby 3.3, Node.js 22, the OOD release RPM), then `ondemand mod_ssl mod_ldap`
2. Self-signed certificate, and the htpasswd login for `OOD_ADMIN`
3. `/etc/ood/config/ood_portal.yml` (the original is kept as `.orig`): HTTPS, login, the `/node` proxy
4. `/etc/ood/config/clusters.d/<CLUSTER_ID>.yml`, so OOD can submit Slurm jobs
5. Starts `httpd`, opens HTTPS if firewalld is running, and checks with `curl`

**Login:**
```yaml
- 'AuthBasicProvider ldap file'
- 'AuthLDAPURL "ldaps://<MASTER_HOST>/ou=People,<LDAP_BASE>?uid?one"'
```
LDAP is asked **first**. Apache stops at the first source that knows the user, so LDAP decides for everyone in it, and only accounts LDAP doesn't know (`OOD_ADMIN`) fall through to htpasswd. **ldaps**, because Apache (login node) and LDAP (master) may be different machines: the password crosses the network encrypted. Apache trusts `LDAP_CA` through `/etc/httpd/conf.d/ood-ldap-ca.conf` (`LDAPTrustedGlobalCert`, a server-wide directive, so not in `ood_portal.yml`).

**Success looks like:** `/` returns **302**, `/pun/sys/dashboard` returns **401** without a login and **200** with an LDAP user's password (`curl -sk -u <user> …`). In the browser, **Clusters -> Shell** and **Jobs -> Active Jobs** load.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `groupadd: GID '76' already exists`, `cyrus-sasl` failed | another group owns GID 76 | the script creates `saslauth` first. By hand: `groupadd -r saslauth; dnf install -y cyrus-sasl` |
| release RPM **404** | wrong version URL | take the current URL from the official guide and set `OOD_VERSION` |
| login refuses the right password | the browser resends an old cached login (Basic auth has no logout), or the user isn't in LDAP | close **all** browser windows; `curl -sk -o /dev/null -w '%{http_code}' -u <user> https://localhost/pun/sys/dashboard`; `LDAPTLS_CACERT=<LDAP_CA> ldapsearch -x -H ldaps://<MASTER_HOST> -b ou=People,<LDAP_BASE> uid=<user>` |
| every LDAP login refused, Apache error log: `LDAP: ... Can't contact LDAP server` / certificate errors | the login node can't reach master's 636, or Apache doesn't trust `LDAP_CA` | `LDAPTLS_CACERT=<LDAP_CA> ldapsearch -x -H ldaps://<MASTER_HOST> -b <LDAP_BASE> -s base`; open 636 on master for `LOGIN_IP`; rerun `setup-ood.sh` (writes `conf.d/ood-ldap-ca.conf`) |
| `setup-ood.sh`: `Run this on <LOGIN_HOST>` | OOD lives on the login node | run it there, or set `LOGIN_HOST` in `site.conf` |
| `setup-ood.sh` (keycloak): `No /etc/ood/oidc-client.secret` or `realm ... doesn't answer at http://<MASTER_IP>:<port>` | `2-realm.sh` not run on master since the split, or master's firewalld doesn't let `LOGIN_IP` in | on master: `sudo bash ../6-keycloak/1-install.sh` (firewall rule) and `2-realm.sh` (copies the secret); `curl http://<MASTER_IP>:<KEYCLOAK_PORT>/auth/realms/master` from here |
| only one user per browser, even in private windows | Basic auth keeps one login per site until the browser fully closes | a second browser or profile. Real fix: single sign-on (Keycloak/OIDC) |
| browser "site can't be reached" | tunnel on a port other than 443 | tunnel with `-L 443:localhost:443`, using `sudo` on the laptop |
| `resolve_ctls_from_dns_srv ... Unknown host` | OOD doesn't see `SLURM_CONF` | set `SLURM_CONF` in `site.conf`, rerun, Restart Web Server |
| `Problem talking to database ... 'cluster' can't be reached` | a `cluster:` line in the cluster file makes OOD use `--clusters`, which needs `slurmdbd` | don't add one (the script doesn't) |
| `sbatch: command not found` | wrong `SLURM_BIN` | `SLURM_BIN` = the folder of `which sbatch` |
| home page still shows the Open OnDemand logo/footer | the user's dashboard was started before the change | **Restart Web Server**; hard-reload the page (Ctrl+Shift+R) |
| a config change has no effect | OOD caches config per user | **Restart Web Server** (top-right menu) |
| home page shows a red "widget error" box instead of the tool cards | a mistake in `_ai_tools.html.erb` (OOD shows the error in place) | fix the file, rerun, **Restart Web Server**. Check first as any user: `cd /var/www/ood/apps/sys/dashboard; source /opt/ood/ondemand/enable; SECRET_KEY_BASE=x RAILS_ENV=production bin/rails runner 'puts ApplicationController.render(partial: "widgets/ai_tools")'` |
| top bar: the bell (admin's messages) is missing, or Develop is gone | the bell is `branding/_notifications.html.erb`, installed as `views/layouts/nav/_develop_dropdown.html.erb` (OOD 4.2 has no setting for a custom top-bar item; that slot sits before Help and is empty without app development). Clearing goes to app `notices/` -> `/var/www/ood/apps/sys/aistack_notices` | rerun `setup-ood.sh`, **Restart Web Server**. Render check: the `rails runner` line above with `partial: "layouts/nav/develop_dropdown"` |
| the bell's x / Clear all: `Could not clear it: HTTP 404` | app `aistack_notices` has no nginx config yet (OOD makes one only on a first browser visit, "Initialize App") | rerun `setup-ood.sh` (stages it with `nginx_stage app` and reloads running PUNs); quick fix: open `https://OOD_SERVERNAME/pun/sys/aistack_notices/` once and press Initialize |
| a tool has no card | its folder name isn't in the list at the top of `_ai_tools.html.erb`, or the user can't open it | add it to the list; `ls -ld /var/www/ood/apps/sys/<app>` |

**Renaming the cluster:** change `CLUSTER_ID`/`CLUSTER_TITLE` in `site.conf`, delete the old `clusters.d/<old>.yml`, rerun, then Restart Web Server.

# 2-ood

Installs Open OnDemand 4.2 on master (AlmaLinux 9), with a self-signed certificate. Web login uses the **LDAP password**, the same as SSH. Needs `../1-ldap/1-server.sh` first.
Official guide: https://osc.github.io/ood-documentation/latest/installation/install-software.html

## Run

```bash
sudo bash setup-ood.sh     # asks once for OOD_ADMIN's local web password
```

It uses these values from `../site.conf`:

| Variable | Meaning |
|---|---|
| `OOD_VERSION` | OnDemand release, part of the repo RPM URL |
| `OOD_SERVERNAME` | the exact host in the browser URL (`localhost` behind an SSH tunnel) |
| `OOD_ADMIN` | a real **local** Linux user with an htpasswd web login, which still works when LDAP is down |
| `CLUSTER_ID` / `CLUSTER_TITLE` | OOD cluster file name, and the name users see |
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
- 'AuthLDAPURL "ldap://localhost/ou=People,<LDAP_BASE>?uid?one"'
```
LDAP is asked **first**. Apache stops at the first source that knows the user, so LDAP decides for everyone in it, and only accounts LDAP doesn't know (`OOD_ADMIN`) fall through to htpasswd. `ldap://localhost` is safe without TLS, because Apache and LDAP are both on master, so the password never leaves the machine.

**Success looks like:** `/` returns **302**, `/pun/sys/dashboard` returns **401** without a login and **200** with an LDAP user's password (`curl -sk -u <user> …`). In the browser, **Clusters -> Shell** and **Jobs -> Active Jobs** load.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `groupadd: GID '76' already exists`, `cyrus-sasl` failed | another group owns GID 76 | the script creates `saslauth` first. By hand: `groupadd -r saslauth; dnf install -y cyrus-sasl` |
| release RPM **404** | wrong version URL | take the current URL from the official guide and set `OOD_VERSION` |
| login refuses the right password | the browser resends an old cached login (Basic auth has no logout), or the user isn't in LDAP | close **all** browser windows; `curl -sk -o /dev/null -w '%{http_code}' -u <user> https://localhost/pun/sys/dashboard`; `ldapsearch -x -H ldap://localhost -b ou=People,<LDAP_BASE> uid=<user>` |
| only one user per browser, even in private windows | Basic auth keeps one login per site until the browser fully closes | a second browser or profile. Real fix: single sign-on (Keycloak/OIDC) |
| browser "site can't be reached" | tunnel on a port other than 443 | tunnel with `-L 443:localhost:443`, using `sudo` on the laptop |
| `resolve_ctls_from_dns_srv ... Unknown host` | OOD doesn't see `SLURM_CONF` | set `SLURM_CONF` in `site.conf`, rerun, Restart Web Server |
| `Problem talking to database ... 'cluster' can't be reached` | a `cluster:` line in the cluster file makes OOD use `--clusters`, which needs `slurmdbd` | don't add one (the script doesn't) |
| `sbatch: command not found` | wrong `SLURM_BIN` | `SLURM_BIN` = the folder of `which sbatch` |
| a config change has no effect | OOD caches config per user | **Restart Web Server** (top-right menu) |

**Renaming the cluster:** change `CLUSTER_ID`/`CLUSTER_TITLE` in `site.conf`, delete the old `clusters.d/<old>.yml`, rerun, then Restart Web Server.

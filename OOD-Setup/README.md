# OOD-Setup

Installs Open OnDemand 4.2 on `master` (AlmaLinux 9). Uses a test login (htpasswd) and a self-signed certificate.
Official guide: https://osc.github.io/ood-documentation/latest/installation/install-software.html

## Run

Edit the variables at the top of `setup-ood.sh`, then:

```bash
sudo bash setup-ood.sh     # asks once for the web password of OOD_USER
```

| Variable | Value here | Where it comes from |
|---|---|---|
| `SERVERNAME` | `localhost` | the exact host in the browser URL |
| `OOD_USER` | `admin` | a real Linux user |
| `CLUSTER_ID` | `dummy` | cluster file name. Apps use it in `form.yml` |
| `SLURM_BIN` | `/usr/local/bin` | `which sbatch` |
| `SLURM_CONF` | `/etc/slurm/slurm.conf` | `echo $SLURM_CONF` |

## What it does

1. Adds the repos (CRB, EPEL, Ruby 3.3, Node.js 22, the OOD release RPM) and installs `ondemand`
2. Makes a self-signed certificate and the htpasswd login
3. Writes `/etc/ood/config/ood_portal.yml` (the original is kept as `.orig`): HTTPS, login, and the `/node` proxy for apps
4. Writes `/etc/ood/config/clusters.d/dummy.yml` so OOD can submit Slurm jobs
5. Starts `httpd`, opens HTTPS in the firewall, and checks with `curl`

**Success looks like this:** `/` returns **302** and `/pun/sys/dashboard` returns **401**. 401 means "log in first".
In the browser, **Clusters -> Shell** and **Jobs -> Active Jobs** load.

Add more web users with `sudo htpasswd /etc/ood/htpasswd <user>`. Leave out `-c`, because it overwrites the file.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `groupadd: GID '76' already exists`, `cyrus-sasl` failed | another group owns GID 76 | the script creates `saslauth` first. By hand: `groupadd -r saslauth; dnf install -y cyrus-sasl` |
| release RPM **404** | wrong version URL | take the current URL from the official guide and set `OOD_VERSION` |
| browser "site can't be reached" | tunnel on a port other than 443 | tunnel with `-L 443:localhost:443`, using `sudo` on the laptop |
| `Could not resolve host: master` from the laptop | master is on the private network | always go through the tunnel |
| `resolve_ctls_from_dns_srv ... Unknown host` | OOD doesn't see `SLURM_CONF` | set `conf:` in the cluster file, then Restart Web Server |
| `Problem talking to database ... 'cluster' can't be reached` | a `cluster:` line makes OOD use `--clusters`, which needs `slurmdbd` | remove the `cluster:` line |
| `sbatch: command not found` | wrong `bin:` | `bin:` = folder of `which sbatch` |
| a config change has no effect | OOD caches config per user | **Restart Web Server** (top-right menu) |

For real users, replace htpasswd with Dex + LDAP, and use a real hostname and certificate.

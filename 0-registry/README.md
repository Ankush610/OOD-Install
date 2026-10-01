# 0-registry

The cluster's own container registry, `REGISTRY` (e.g. `master:5000`): the bridge between podman and Kubernetes.
Kubernetes runs containers with **containerd**, which can't see podman's images, and compute nodes have no internet.
So images go through one registry on master, and every node pulls from it over the LAN:

```
podman build / k8s-image (any user, rootless) ──push──> REGISTRY on master ──pull──> containerd on each k8s node
                                                          (REGISTRY_DATA)            (cached locally after the first pull)
```

Background and the manual steps: `../../AI-Stack/docs/cluster/container-registry.md`.

## Run (on master, first: 3-mlflow and 5-model-hub push their images here)

```bash
sudo bash setup-registry.sh       # needs root ssh to the compute nodes; safe to rerun
```

| Step | Where | What |
|---|---|---|
| 1 | master | `REGISTRY_IMAGE` container `registry`, storage `REGISTRY_DATA`, **deletes allowed** (`REGISTRY_STORAGE_DELETE_ENABLED`), `podman-restart.service` enabled so it comes back after a reboot. Recreated only if image, storage, port or the delete setting differ (the data stays) |
| 2 | every k8s node (`MASTER_HOST` + `COMPUTE_NODES`) | containerd: `config_path = '/etc/containerd/certs.d'` + `certs.d/<REGISTRY>/hosts.toml` (plain HTTP). Backs up `config.toml`, restarts containerd **only if something changed** |
| 3 | master + `LOGIN_NODES` | `/etc/containers/registries.conf.d/010-local-registry.conf` (`insecure = true`: every user's podman, no `--tls-verify=false`) and `/etc/profile.d/apps-bin.sh` (`/home/apps/bin` on PATH) |
| 4 | shared `/home` | `k8s-image` → `/home/apps/bin/k8s-image`, registry name filled in |
| 5 | every k8s node | check: pushes a test image, `crictl pull`s it on each node, deletes it again |

Unreachable nodes are skipped and listed at the end: rerun when they're back.

## Users

```bash
k8s-image build myapp:v1 .            # podman build + push, prints:  image: master:5000/myapp:v1
k8s-image mirror docker.io/library/redis:7
k8s-image ls
```
Rootless podman needs a `/etc/subuid` range: `1-ldap/add-user.sh` gives LDAP users one on `LOGIN_NODES`.
Use fixed tags (`:v1`), never `:latest`: a moved tag means nodes run whatever they cached.

## Deleting images

Delete by digest (removes **every** tag with that digest, so check the ones you keep first), then free the disk:
```bash
d=$(curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      http://$REGISTRY/v2/<name>/manifests/<tag> | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | tr -d '\r')
curl -X DELETE http://$REGISTRY/v2/<name>/manifests/$d                       # 202
sudo podman exec registry registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| pod `ErrImagePull` / `http: server gave HTTP response to HTTPS client` | that node's containerd has no `hosts.toml` for `REGISTRY` | rerun `setup-registry.sh` (the node was down?) |
| `podman push`: `http: server gave HTTP response to HTTPS client` | no `registries.conf.d` drop-in on that node | rerun; or that user is on a node not in `LOGIN_NODES` |
| `podman push` as a user: `cannot find UID/GID ... subuid` | LDAP user without a subuid range | `1-ldap/add-user.sh` gives one; older users: add `user:start:65536` to `/etc/subuid` + `/etc/subgid` |
| everything `ErrImagePull` after master rebooted | registry container not started at boot | `systemctl enable --now podman-restart.service` (step 1 does it) |
| `DELETE` answers `405` | registry started without `REGISTRY_STORAGE_DELETE_ENABLED=true` | rerun `setup-registry.sh` (recreates it, keeps the data) |
| step 2: `no registry config_path in config.toml` | a containerd config without the `config_path` lines | add `config_path = '/etc/containerd/certs.d'` under the CRI images registry section, rerun |

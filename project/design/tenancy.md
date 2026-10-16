# Model Hub — tenancy (namespace per user, UID pinned, quota, onboarding)

Part of the [Model Hub design](README.md). Needed from v1: pods mount `/home` over NFS, so without this
any user's pod could read any home.

Why: in one shared namespace (a) anyone can delete anyone's deployment, and (b) NFS (AUTH_SYS) trusts whatever
UID a pod claims, so `runAsUser: <bob>` plus a `/home` volume reads bob's home.

```
  ns u-alice   labels aistack/uid=<uid> aistack/gid=<gid>, PSA enforce=restricted
  ├── RoleBinding   alice → edit
  ├── ResourceQuota 1 GPU (extended resource AND DRA device classes, see README "Known limits" 7)
  ├── NetworkPolicy same-namespace ingress (not enforced by flannel, see README "Known limits" 2)
  ├── PVC models-ro  → PV (NFS /home/apps/models, ro)
  └── PVC my-models  → PV (NFS /home/alice/models, ro), pre-bound with claimRef
  cluster-wide: ValidatingAdmissionPolicy — every pod in a labeled ns runs as that ns's uid/gid
```
Users can't create PVs or relabel their namespace (`edit` doesn't allow it), and PSA `restricted` blocks inline
`hostPath`/`nfs` volumes. So a pod can only reach the two PVCs, as the owner's UID.
ValidatingAdmissionPolicy is GA since k8s 1.30 (we run 1.36).

## Onboarding (admin: `sudo bash 1-ldap/add-user.sh alice`)
1. (existing) LDAP user, home, `3-sync-tokens.sh` → `~/.mlflow/credentials`.
2. `envsubst < onboarding/user-ns.yaml | kubectl apply` → `u-alice` (labels `aistack/uid`, `aistack/gid`), RoleBinding
   `edit`, ResourceQuota `requests.nvidia.com/gpu: 1`, PVs/PVCs `models-ro` + `my-models`.
3. Client cert: k8s CSR API (`signerName: kubernetes.io/kube-apiserver-client`, CN=`alice`) → approve → write
   `~/.kube/config` (0600, owned by alice, default namespace `u-alice`).
4. (v2, with the gateway) API token: random → `~/.model-hub/token` (0600); `sha256` → Secret `token-alice` in `model-hub`.
5. Add `u-alice` to slurm-bridge's `managedNamespaces`. **This is a helm upgrade per user.** Today it isn't in
   our Helm values at all; the chart default `[slurm-bridge]` is in effect (ConfigMap in namespace `slurm`, where
   the release lives). So the first upgrade must list `slurm-bridge` too, or existing pods stop being managed.
   Check whether slurm-bridge accepts a label selector instead; if yes, use it and skip this step.
   Its admission webhook already intercepts pods in every namespace except `kube-system` and `slurm`, with
   `failurePolicy: Fail`: if the slurm-bridge pods are down, no pod can be created anywhere else.

A `sync` script reruns steps 2–5 for every existing LDAP user. Safe to rerun, the same as `3-sync-tokens.sh`.

## `onboarding/uid-policy.yaml` (once; untested draft — bob's UID in u-alice must be rejected)
```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: { name: pod-runs-as-namespace-owner }
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods", "pods/ephemeralcontainers"]
  variables:
  - name: uid
    expression: "namespaceObject.metadata.labels['aistack/uid']"
  - name: gid
    expression: "namespaceObject.metadata.labels['aistack/gid']"
  validations:
  - expression: >-
      has(object.spec.securityContext) &&
      has(object.spec.securityContext.runAsUser) && string(object.spec.securityContext.runAsUser) == variables.uid &&
      has(object.spec.securityContext.runAsGroup) && string(object.spec.securityContext.runAsGroup) == variables.gid &&
      !has(object.spec.securityContext.supplementalGroups) && !has(object.spec.securityContext.fsGroup)
    message: "pod securityContext must set runAsUser/runAsGroup to your uid/gid, with no supplementalGroups/fsGroup"
  - expression: >-
      object.spec.containers.all(c, !has(c.securityContext) ||
        ((!has(c.securityContext.runAsUser) || string(c.securityContext.runAsUser) == variables.uid) &&
         (!has(c.securityContext.runAsGroup) || string(c.securityContext.runAsGroup) == variables.gid)))
      && (!has(object.spec.initContainers) || object.spec.initContainers.all(c, !has(c.securityContext) ||
        ((!has(c.securityContext.runAsUser) || string(c.securityContext.runAsUser) == variables.uid) &&
         (!has(c.securityContext.runAsGroup) || string(c.securityContext.runAsGroup) == variables.gid))))
      && (!has(object.spec.ephemeralContainers) || object.spec.ephemeralContainers.all(c, !has(c.securityContext) ||
        ((!has(c.securityContext.runAsUser) || string(c.securityContext.runAsUser) == variables.uid) &&
         (!has(c.securityContext.runAsGroup) || string(c.securityContext.runAsGroup) == variables.gid))))
    message: "containers may not override runAsUser/runAsGroup"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: { name: pod-runs-as-namespace-owner }
spec:
  policyName: pod-runs-as-namespace-owner
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchExpressions: [{ key: aistack/uid, operator: Exists }]
```

## `onboarding/user-ns.yaml` (per user: `envsubst < user-ns.yaml | kubectl apply -f -`)
```yaml
# vars: USER OWNER_UID OWNER_GID NFS_SERVER NFS_EXPORT GPU_CLASS   (dummy: NFS_SERVER=192.168.40.102 NFS_EXPORT=/home GPU_CLASS=a30)
apiVersion: v1
kind: Namespace
metadata:
  name: u-${USER}
  labels:
    aistack/uid: "${OWNER_UID}"
    aistack/gid: "${OWNER_GID}"
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: owner, namespace: u-${USER} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: edit }
subjects: [{ apiGroup: rbac.authorization.k8s.io, kind: User, name: ${USER} }]
---
apiVersion: v1
kind: ResourceQuota
metadata: { name: gpus, namespace: u-${USER} }
spec:
  hard:
    requests.nvidia.com/gpu: "1"                                   # pods asking nvidia.com/gpu
    ${GPU_CLASS}.deviceclass.resource.k8s.io/devices: "1"          # direct ResourceClaims (verify in P1)
    gpu.nvidia.com.deviceclass.resource.k8s.io/devices: "1"
    mig.nvidia.com.deviceclass.resource.k8s.io/devices: "0"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: same-namespace-only, namespace: u-${USER} }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress: [{ from: [{ podSelector: {} }, { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: model-hub } } }] }]
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: models-ro-${USER} }
spec:
  capacity: { storage: 1Ti }                       # informational for NFS
  accessModes: [ReadOnlyMany]
  mountOptions: [ro, nconnect=8]
  nfs: { server: ${NFS_SERVER}, path: ${NFS_EXPORT}/apps/models, readOnly: true }
  claimRef: { namespace: u-${USER}, name: models-ro }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: models-ro, namespace: u-${USER} }
spec: { storageClassName: "", volumeName: models-ro-${USER}, accessModes: [ReadOnlyMany], resources: { requests: { storage: 1Ti } } }
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: my-models-${USER} }
spec:
  capacity: { storage: 1Ti }
  accessModes: [ReadOnlyMany]
  mountOptions: [ro, nconnect=8]
  nfs: { server: ${NFS_SERVER}, path: ${NFS_EXPORT}/${USER}/models, readOnly: true }
  claimRef: { namespace: u-${USER}, name: my-models }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: my-models, namespace: u-${USER} }
spec: { storageClassName: "", volumeName: my-models-${USER}, accessModes: [ReadOnlyMany], resources: { requests: { storage: 1Ti } } }
```
A PV binds to exactly one PVC, so each namespace gets its own PV objects pointing at the same NFS path. That's normal.
The NetworkPolicy also lets the gateway (ns `model-hub`) in; it only takes effect once the CNI enforces it.

The serving Deployment that runs inside this namespace: [serving.md](serving.md) "Serving template".

# Migrate `n8n-data` and `paperless-data` off Longhorn RWX

## Why

`n8n-data` and `paperless-data` are Longhorn **ReadWriteMany (RWX)** volumes.
Longhorn implements RWX with an in-cluster **NFS share** (a `share-manager` pod
exposed as a `longhorn-system` ClusterIP on `:2049`). When a node running a pod
that mounts an RWX volume reboots, the NFS mount can hang (server unreachable
during shutdown), Talos cannot unmount it, and the node **wedges mid-reboot**
(`kern: nfs: server ... not responding, timed out`). This stuck nodes 2 and 3
during the control-plane maintenance.

**RWO (ReadWriteOnce) has no NFS layer**, so it does not hang on reboot. RWO
means "one node" — multiple pods on the *same* node can still share it; only
multi-*node* concurrent access needs RWX.

| PVC | NS | Size | Consumers | Plan |
|---|---|---|---|---|
| `n8n-data` | `self-hosted` | 1Gi | single pod (n8n) | → **RWO**, clean |
| `paperless-data` | `self-hosted` | 20Gi | **two**: paperless pod **+** `paperless-backup` CronJob (2 AM), both RW concurrently | see paperless section |
| `paperless-redis-data` | `self-hosted` | 1Gi | — | already RWO, leave it |

> ⚠️ `paperless-data` is RWX **for a reason**: the daily `paperless-backup`
> CronJob (`backup-cronjob.yaml`, `exporter` container) mounts it RW at the same
> time as the running paperless pod. Going to RWO requires making both land on
> the **same node** (see paperless section) — it is not a drop-in like n8n.

General approach: copy-once, new name, keep the source until verified. Longhorn
daily backups on both volumes are the second safety net. Do one app fully,
verify, then the next.

---

## Part A — n8n (straightforward)

Single consumer, so a plain RWO swap.

### 1. Quiesce + stop Flux fighting the migration
```bash
flux suspend kustomization n8n
kubectl -n self-hosted scale deploy/n8n --replicas=0
kubectl -n self-hosted wait --for=delete pod -l app.kubernetes.io/name=n8n --timeout=180s
```

### 2. New RWO PVC
```bash
kubectl -n self-hosted apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data-rwo
  labels:
    recurring-job.longhorn.io/source: enabled
    recurring-job.longhorn.io/daily-backup: enabled
spec:
  storageClassName: longhorn
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 512Mi
EOF
```

### 3. Copy old → new
```bash
kubectl -n self-hosted apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate-n8n-data
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: copy
          image: busybox:1.37
          command: ["sh", "-c", "cp -a /old/. /new/ && sync && echo COPY_DONE && du -sh /old /new"]
          volumeMounts:
            - { name: old, mountPath: /old }
            - { name: new, mountPath: /new }
      volumes:
        - { name: old, persistentVolumeClaim: { claimName: n8n-data } }
        - { name: new, persistentVolumeClaim: { claimName: n8n-data-rwo } }
EOF
kubectl -n self-hosted wait --for=condition=complete job/migrate-n8n-data --timeout=600s
kubectl -n self-hosted logs job/migrate-n8n-data     # COPY_DONE + matching du
kubectl -n self-hosted delete job migrate-n8n-data
```

Don't trust Longhorn's `actualSize` to confirm the copy — the source carries
months of snapshot history, so the two volumes legitimately differ there.
Compare the filesystems instead: mount both read-only in a throwaway pod and
diff `find -type f | md5sum` over each side.

### 4. Repoint the app (git → merge)
- `n8n/app/helmrelease.yaml`: `persistence.data.existingClaim: n8n-data` → `n8n-data-rwo`
- `n8n/app/pvc.yaml`: **add** the `n8n-data-rwo` PVC — keep the old `n8n-data`
  PVC in the file. The Kustomization is `prune: true`, so dropping it from git
  deletes the volume the moment Flux resumes, destroying the rollback source
  before anything has been verified. It goes away in step 6, not here.
- `n8n/app/helmrelease.yaml`: set `strategy: Recreate` on the controller. RWX
  tolerated the default `RollingUpdate` because the new and old pods could
  mount the volume at once; on RWO the new pod blocks forever waiting for the
  old one to release it, wedging every future image bump.

### 5. Merge first, then resume
Flux reconciles from `master`, so **resume only after the change is merged** —
resuming while the change sits on a branch reapplies the old `existingClaim`
and starts n8n back up on the RWX volume.
```bash
flux resume kustomization n8n
flux reconcile kustomization n8n --with-source
```
Verify n8n works (data + workflows). Roll back any time before step 6 by
reverting `existingClaim` to `n8n-data` (still intact).

### 6. Decommission old volume
Remove the old `n8n-data` PVC from `pvc.yaml` (git) → Flux prune deletes it →
Longhorn removes the RWX volume + share-manager.

---

## Part B — paperless (needs backup handling)

Because the backup CronJob also mounts `paperless-data`, pick one:

### Option B1 — RWO + co-locate the backup (removes the hang) — recommended
Migrate `paperless-data` to RWO exactly like n8n (Part A steps, with
`paperless`/`paperless-data`/`paperless-data-rwo`/`20Gi`, and a longer copy
timeout, e.g. `--timeout=1800s`), **plus**:

- **Before migrating**, suspend the backup so it can't fire mid-copy:
  ```bash
  kubectl -n self-hosted patch cronjob paperless-backup -p '{"spec":{"suspend":true}}'
  kubectl -n self-hosted get pods -l app=paperless-backup   # ensure none running
  ```
- **Make the backup share the RWO volume** by pinning it to the paperless node.
  In `backup-cronjob.yaml`, add to the job pod spec (confirm the paperless pod
  label first with `kubectl -n self-hosted get pod -l app.kubernetes.io/name=paperless --show-labels`):
  ```yaml
  spec:            # jobTemplate.spec.template.spec
    affinity:
      podAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/name: paperless
            topologyKey: kubernetes.io/hostname
  ```
  Longhorn RWO allows multiple pods on the **same** node, and RWO has no NFS, so
  no reboot hang. (Trade-off: the backup only runs when it can land on the
  paperless node; with `concurrencyPolicy: Forbid` it just retries next day.)
- Un-suspend the backup once done:
  ```bash
  kubectl -n self-hosted patch cronjob paperless-backup -p '{"spec":{"suspend":false}}'
  ```

### Option B2 — keep `paperless-data` RWX (simplest)
RWX is arguably correct here (two concurrent consumers). Keep it, and just use
the interim mitigation below before any node reboot. No migration, no backup
changes — you accept that paperless is the one thing to scale down before
maintenance.

---

## Interim mitigation (until/if you migrate)
Before rebooting any node, release the RWX mounts so the node can unmount:
```bash
kubectl -n self-hosted patch cronjob paperless-backup -p '{"spec":{"suspend":true}}'
kubectl -n self-hosted scale deploy/n8n paperless --replicas=0
# reboot node, wait Ready
kubectl -n self-hosted scale deploy/n8n paperless --replicas=1
kubectl -n self-hosted patch cronjob paperless-backup -p '{"spec":{"suspend":false}}'
```

## Done when
```bash
kubectl -n longhorn-system get svc | grep 2049   # empty for whatever you migrated
```

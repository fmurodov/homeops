# Migrate `n8n-data` and `paperless-data` from RWX to RWO

## Why

`n8n-data` and `paperless-data` are Longhorn **ReadWriteMany (RWX)** volumes.
Longhorn implements RWX with an in-cluster **NFS share** (a `share-manager` pod
exposed as a `longhorn-system` ClusterIP on `:2049`). When a node running a pod
that mounts an RWX volume reboots, the NFS mount can hang (server unreachable
during the shutdown/networking teardown), Talos cannot unmount it, and the node
**wedges mid-reboot**. This is what stuck nodes 2 and 3 during the control-plane
maintenance (`kern: nfs: server ... not responding, timed out`).

Both apps are **single-replica** and do not need RWX. Moving them to
**ReadWriteOnce (RWO)** removes the NFS share-managers and the reboot hang.

Volumes to migrate:

| PVC | Namespace | Size | Access |
|---|---|---|---|
| `n8n-data` | `self-hosted` | 1Gi | RWX → RWO |
| `paperless-data` | `self-hosted` | 20Gi | RWX → RWO |

`paperless-redis-data` is already RWO — leave it.

## Approach

**Copy-once, new name, keep the source until verified.** For each app: create a
new RWO PVC, copy the data in with a one-off Job, point the app at it, verify,
then delete the old RWX PVC. The old volume is never touched until the very end,
so rollback is trivial. Both volumes also have Longhorn daily backups as a
second safety net.

Do **one app at a time**, fully, before starting the next.

---

## Runbook (per app)

Shown for **n8n**. For **paperless**, substitute: `NS=self-hosted`,
`APP=paperless`, `OLD=paperless-data`, `NEW=paperless-data-rwo`, `SIZE=20Gi`,
and bump the copy Job wait timeout (20Gi takes longer).

### 0. Safety check
- Confirm a recent Longhorn backup exists for the volume (Longhorn UI → Backup).
- Note the controller/pod name: `kubectl -n self-hosted get deploy` (expect `n8n`, `paperless`).

### 1. Quiesce the app and stop Flux from fighting the migration
```bash
flux suspend kustomization n8n
kubectl -n self-hosted scale deploy/n8n --replicas=0
# ensure the old RWX volume is released (no more consumers)
kubectl -n self-hosted wait --for=delete pod -l app.kubernetes.io/name=n8n --timeout=180s
```

### 2. Create the new RWO PVC
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
      storage: 1Gi
EOF
```

### 3. Copy data old → new (one-off Job that mounts both)
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
        - name: old
          persistentVolumeClaim: { claimName: n8n-data }
        - name: new
          persistentVolumeClaim: { claimName: n8n-data-rwo }
EOF

kubectl -n self-hosted wait --for=condition=complete job/migrate-n8n-data --timeout=600s
kubectl -n self-hosted logs job/migrate-n8n-data   # verify COPY_DONE and matching du sizes
kubectl -n self-hosted delete job migrate-n8n-data
```

### 4. Point the app at the new PVC (git)
Edit the app and merge via your normal branch + PR flow:

- `kubernetes/apps/talos1018/self-hosted/n8n/app/helmrelease.yaml`
  `persistence.data.existingClaim: n8n-data` → `n8n-data-rwo`
- `kubernetes/apps/talos1018/self-hosted/n8n/app/pvc.yaml`
  add the `n8n-data-rwo` RWO PVC (same YAML as step 2). **Keep the old
  `n8n-data` PVC in this file for now** — it is removed in step 6.

### 5. Resume Flux and bring the app back on RWO
```bash
flux resume kustomization n8n
flux reconcile kustomization n8n --with-source
kubectl -n self-hosted get pods -l app.kubernetes.io/name=n8n   # Running on the new volume
```
Verify the app end-to-end: data present, workflows/UI work.

### 6. Decommission the old RWX volume (only once you're happy)
Remove the old `n8n-data` PVC from `pvc.yaml` (git) and merge → Flux prune
deletes the PVC → Longhorn deletes the RWX volume **and** its NFS share-manager.

---

## Rollback (any time before step 6)
The old `n8n-data` volume is untouched, so:
```bash
kubectl -n self-hosted scale deploy/n8n --replicas=0
# revert existingClaim back to n8n-data in git, reconcile
flux reconcile kustomization n8n --with-source
```

## Done when
```bash
kubectl -n longhorn-system get svc | grep 2049   # no RWX share-manager services left
```
No node will hang on an NFS unmount during future reboots/upgrades.

## Interim mitigation (until this is done)
Before rebooting any node, release the RWX mounts first:
```bash
kubectl -n self-hosted scale deploy/n8n paperless --replicas=0
# reboot the node, wait Ready
kubectl -n self-hosted scale deploy/n8n paperless --replicas=1
```

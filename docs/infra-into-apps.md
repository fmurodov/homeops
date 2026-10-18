# Fold `infrastructure/` into `apps/` (homeops-project#94)

Decision (refactoring-plan.md §6): drop the separate
`kubernetes/infrastructure/talos1018` tree and keep everything under
`kubernetes/apps/talos1018`, ordered with `dependsOn` only where it matters.
This document is the procedure. Every step is one small PR, merged and verified
before the next one.

## Current structure

Top-level Kustomizations (all applied by `flux-system` from
`kubernetes/clusters/talos1018/`):

| Kustomization    | Path                                      | prune | wait  | dependsOn                  |
|------------------|-------------------------------------------|-------|-------|----------------------------|
| `cluster-config` | `kubernetes/components/common`            | true  | true  | -                          |
| `infra-core`     | `kubernetes/infrastructure/talos1018/core`    | true  | false | cluster-config             |
| `infra-storage`  | `kubernetes/infrastructure/talos1018/storage` | true  | false | infra-core                 |
| `apps`           | `kubernetes/apps/talos1018`               | true  | true  | cluster-config, infra-core |

Children (all `prune: true`, `wait: true`, no `deletionPolicy`, so the default
`MirrorPrune` = delete everything on deletion):

| Child                       | Owner (`kustomize.toolkit.fluxcd.io/name`) | dependsOn                                        | decryption |
|-----------------------------|----------------|--------------------------------------------------------------|-----|
| `infra-cilium-app`          | infra-core     | gateway-api-app                                              | -   |
| `infra-cilium-config`       | infra-core     | infra-cilium-app                                             | -   |
| `infra-cert-manager-app`    | infra-core     | gateway-api-app                                              | -   |
| `infra-cert-manager-config` | infra-core     | infra-cert-manager-app                                       | sops |
| `infra-longhorn-app`        | infra-storage  | infra-cilium-config, infra-cert-manager-config               | -   |
| `infra-longhorn-config`     | infra-storage  | infra-longhorn-app                                           | sops |
| `gateway-api-app`/`-config` | apps           | (CRDs; already in `apps/talos1018/network/gateway-api`)      | -   |

34 app ks.yaml files depend on `infra-longhorn-config`. Nothing in `scripts/`,
`.github/` or `.renovate/` references the `infrastructure/` path.

## The danger

A child Kustomization object is in its parent's inventory. Moving its
definition to another parent makes it *stale* for the old parent, which then
deletes it. Deleting a child with the default `deletionPolicy` and
`prune: true` runs its finalizer, which deletes everything it applied: the
Cilium, cert-manager and Longhorn HelmReleases, and helm-controller then
uninstalls the charts.

## What protects the move (verified against kustomize-controller v1.9.6)

Running versions: Flux v2.9.6, kustomize-controller v1.9.6 (fluxcd/pkg/ssa
v0.76.2).

1. **`kustomize.toolkit.fluxcd.io/prune: disabled` on the child.**
   `deleteObjects()` in `internal/controller/kustomization_controller.go`
   passes `Exclusions{kustomize.toolkit.fluxcd.io/prune: disabled, ...}` to
   `ResourceManager.DeleteAll`; `Delete()` in `fluxcd/pkg/ssa/manager_delete.go`
   reads the **live** object and returns `SkippedAction` when it carries the
   annotation. `pruneSurvivors()` treats `SkippedAction` as settled, so the
   old parent drops it from its inventory and does not retry.
   The same `deleteObjects()` is used by `finalize()`, so the annotation also
   protects the children if a whole parent (`infra-core`) is deleted.
   Docs: https://fluxcd.io/flux/components/kustomize/kustomizations/#prune
2. **Ownership labels.** `deleteObjects()` also sets
   `Inclusions = GetOwnerLabels(parent)` (`kustomize.toolkit.fluxcd.io/name`
   + `/namespace`). If the new parent has already applied the object, those
   labels name the new parent and the old one skips it too. So the race
   between the two parents is safe in either order, but this alone is not
   enough: if the old parent reconciles first, the labels still match.
3. **`spec.deletionPolicy: Orphan` on the child** (second line of defence).
   `finalizerShouldDeleteResources()` returns false for `Orphan`, so even if a
   child object does get deleted its HelmReleases and config stay.
   Docs: https://fluxcd.io/flux/components/kustomize/kustomizations/#deletion-policy
4. **Adoption.** The new parent applies the object with server-side apply as
   the same field manager (`kustomize-controller`), so there is no conflict:
   the owner labels are overwritten and the object is added to the new
   parent's inventory. The object keeps its UID; nothing is recreated.
   `kustomize.toolkit.fluxcd.io/ssa: Merge` is not needed.

Both settings must be **live** before a move (the delete check reads the
in-cluster object), which is why they ship in their own PR first.

Not chosen: `prune: false` on the children. It would stop them pruning their
*own* removed resources during the migration, and `deletionPolicy: Orphan`
already covers the delete-cascade case.

Other checks:
- **Names stay `infra-*`.** Renaming a Kustomization is delete + recreate,
  and 34 app ks.yaml reference `infra-longhorn-config`. Renaming is out of scope.
- **The children's own inventories don't change.** Only the ks.yaml files and
  `spec.path` move; the HelmRepository/HelmRelease/ConfigMap names and
  namespaces are identical, so the children prune nothing. (`cilium-values`
  uses `disableNameSuffixHash`, so its name is stable.)
- **CRD ordering** is per-child `dependsOn` and moves unchanged:
  gateway-api CRDs → cilium-app/cert-manager-app → their config → longhorn.
  cert-manager (`crds.enabled`) and Longhorn CRDs ship in their charts; Cilium's CRDs are
  registered by the operator, which `infra-cilium-config` waits for via
  `infra-cilium-app` `wait: true`.
- **cluster-config / substitution:** `apps` already depends on
  `cluster-config` and substitutes from `cluster-secrets`, exactly like
  `infra-core`/`infra-storage`. No `${...}` appears in the infra ks.yaml.
- **SOPS:** decryption is set per child (`*-config`) and moves with the
  ks.yaml. The parent `apps` also has decryption. Encrypted files can be
  `git mv`'d: the root `.sops.yaml` rule `kubernetes/.*\.sops\.yaml$` covers
  both trees and the MAC does not include the path.
- **`apps` has `wait: true` (5m).** Once the infra children live under it,
  `apps` reports not-Ready while a slow Cilium/Longhorn upgrade runs. This
  is cosmetic; it doesn't block the children.
- **During the move window** the old parent may reconcile first. The child
  then keeps its old `spec.path` until `apps` re-applies it, and fails with
  "path not found". A build failure applies and prunes nothing. Shorten it
  with `flux reconcile ks apps`.

## Target layout

```
kubernetes/apps/talos1018/
├── kube-system/cilium/{ks.yaml,README.md,app/,config/}   # add to kube-system/kustomization.yaml
├── cert-manager/{ks.yaml,app/,config/}                   # app owns its namespace (like cloudflared/)
├── longhorn/{ks.yaml,README.md,app/,config/}             # app owns longhorn-system
└── network/gateway-api/                                  # unchanged
kubernetes/clusters/talos1018/
├── cluster-config.yaml
└── apps.yaml        # dependsOn: cluster-config only
```

`infrastructure.yaml`, `infra-core`, `infra-storage` and
`kubernetes/infrastructure/` are removed. The `dependsOn` graph that remains:

```
cluster-config ─► apps (parent)
gateway-api-app ─► infra-cilium-app ─► infra-cilium-config ─┐
                └► infra-cert-manager-app ─► infra-cert-manager-config ─┴► infra-longhorn-app ─► infra-longhorn-config ─► apps with a PVC
```

## Procedure

Before every step, record the identities you will check afterwards:

```bash
kubectl -n flux-system get ks -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,OWNER:.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name' | grep -E 'infra|NAME'
kubectl get hr -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid' | grep -E 'cilium|cert-manager|longhorn'
helm history -n kube-system cilium --max 1; helm history -n cert-manager cert-manager --max 1; helm history -n longhorn-system longhorn --max 1
```

After every step the pass criteria: same UIDs, no new Helm revision, all
Ready, and no `deleted` event from either parent:

```bash
flux get ks -A | grep -E 'infra|apps'
kubectl -n flux-system get events --field-selector involvedObject.kind=Kustomization | grep -iE 'delet|prun'
```

Rollback for steps 2-4 is `git revert` of that PR. The revert is the same
move in reverse, and the annotation still protects it.

### Step 1: protect the children in place (no moves)

On all six `infra-*` children add
`metadata.annotations.kustomize.toolkit.fluxcd.io/prune: disabled` and
`spec.deletionPolicy: Orphan`.

Pre-merge: `flux diff ks infra-core --path ./kubernetes/infrastructure/talos1018/core`
(and the same for `infra-storage`) shows only the annotation and
`deletionPolicy` on the six objects.

Verify after merge:
```bash
kubectl -n flux-system get ks -o custom-columns='NAME:.metadata.name,PRUNE-ANN:.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune,POLICY:.spec.deletionPolicy' | grep infra-
```
All six show `disabled` / `Orphan`. Nothing else changes.

### Step 2: pilot, move cert-manager

The pilot is cert-manager because it has the smallest blast radius if
something is wrong. Existing certificate Secrets survive a cert-manager
outage. gateway-api is already in `apps/`, so there is nothing to pilot there.

- `git mv kubernetes/infrastructure/talos1018/core/cert-manager kubernetes/apps/talos1018/cert-manager`
- Update both `spec.path` values to `./kubernetes/apps/talos1018/cert-manager/{app,config}`.
- Remove `./cert-manager/ks.yaml` from `infrastructure/talos1018/core/kustomization.yaml`;
  add `./cert-manager/ks.yaml` to `apps/talos1018/kustomization.yaml`.
- Pre-merge: `./scripts/validate.sh flux`; `flux diff ks apps --path ./kubernetes/apps/talos1018`
  shows the two children as drifted (label + path), with nothing deleted.

After merge: `flux reconcile ks apps --with-source`, then:
```bash
kubectl -n flux-system get ks infra-cert-manager-app infra-cert-manager-config \
  -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,OWNER:.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name,PATH:.spec.path'
kubectl -n flux-system get ks apps -o jsonpath='{.status.inventory.entries[*].id}' | tr ' ' '\n' | grep infra-cert
kubectl -n flux-system get ks infra-core -o jsonpath='{.status.inventory.entries[*].id}' | tr ' ' '\n'
kubectl get clusterissuer; kubectl get certificate -A
```
Expected: OWNER=`apps`, same UIDs, in the `apps` inventory and gone from
`infra-core`'s, issuers Ready.

### Step 3: move Cilium

Same as step 2 with `core/cilium` → `apps/talos1018/kube-system/cilium`.
Add `./cilium/ks.yaml` to `kube-system/kustomization.yaml`. Fix the paths in
the Cilium README. Also verify: `cilium status`, the gateway Services still
have their LB IPs, and `kubectl get ciliumloadbalancerippool`.

### Step 4: move Longhorn

`storage/longhorn` → `apps/talos1018/longhorn`, removed from
`storage/kustomization.yaml`. Also verify:
`kubectl -n longhorn-system get volumes.longhorn.io` (all healthy/attached as
before) and `kubectl get recurringjob -n longhorn-system`.

### Step 5: make the empty parents inert

Both parent inventories must be empty first:
```bash
kubectl -n flux-system get ks infra-core infra-storage -o jsonpath='{range .items[*]}{.metadata.name}: {.status.inventory.entries}{"\n"}{end}'
```
- In `infrastructure.yaml` set `deletionPolicy: Orphan` on `infra-core` and `infra-storage`.
- In `apps.yaml` drop `dependsOn: infra-core`. Otherwise `apps` stalls on a
  missing dependency once the parent is gone.

### Step 6: remove the infra parents

Delete `kubernetes/clusters/talos1018/infrastructure.yaml` and
`kubernetes/infrastructure/`. `flux-system` prunes `infra-core` and
`infra-storage`; their finalizers find an empty inventory (and `Orphan`).
Verify: `flux get ks -A` has no `infra-core`/`infra-storage`, all six
`infra-*` children are still Ready with unchanged UIDs, and the HelmReleases
are unchanged.

### Step 7: back to defaults, docs

- Remove the `prune: disabled` annotation and `deletionPolicy: Orphan` from
  the six children, so they use the out-of-the-box behaviour like every other
  app. This is safe because no ownership changes. Optionally keep them on
  the Cilium/Longhorn children as a permanent guard against accidental removal.
- Update CLAUDE.md (directory tree, layering, component structure, key
  files), README.md, kubernetes/README.md, and refactoring-plan.md.

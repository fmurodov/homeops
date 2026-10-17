# Refactoring plan: app-template to raw manifests, and cluster cleanup

Tracks homeops-project#32 (prefer raw manifests over Helm) and #43 (simplify,
make consistent, easy for an outsider to read). Inventory taken 2026-10-17
against `master` and the live cluster (read-only).

Rule of thumb (repo preference): raw `Deployment` + `Service` + `HTTPRoute`
for anything we wrote ourselves; keep a Helm chart only when it is the
upstream-maintained way to ship CRDs, RBAC, webhooks or generated config.

## 1. app-template HelmReleases

14 releases use bjw-s `app-template` 5.3.0. Every one of them uses
`existingClaim` (no chart-owned PVCs) and renders only a ServiceAccount
(unused: `automountServiceAccountToken: false`), Service(s), Deployment /
StatefulSet / DaemonSet, HTTPRoute(s) and at most one ConfigMap or RBAC pair.
Verified with `helm get manifest` for each release.

Chart defaults that a raw manifest must reproduce explicitly:

- `strategy: Recreate` on every Deployment (live: all 19 app-template
  Deployments are Recreate, including the stateless 2-replica paperless
  gotenberg/tika).
- `enableServiceLinks: false` on every pod. Matters for n8n: a Service named
  `n8n` would otherwise inject `N8N_*` variables into the n8n container.
- `automountServiceAccountToken: false`.
- "enabled" probes without `custom: true` are TCP on the primary Service port,
  period 10s, timeout 1s, failureThreshold 3 (startup too, unless overridden).
- Labels `app.kubernetes.io/{name,instance,controller}`; selectors use all
  three. Raw manifests use only `app.kubernetes.io/name`.

| App (ns) | Controllers / containers | Features used | Verdict |
| --- | --- | --- | --- |
| wishlist (self-hosted) | 1 deploy / 1 | PVC (2 subPaths), ConfigMap (Caddyfile), route, default TCP probes, IPv6-only Service | **Converted (pilot)** |
| changedetection (self-hosted) | 1 deploy / 2 (app + browserless) | PVC, route with homepage widget, no probes | **Converted (pilot)** |
| openwebui (ai) | 1 deploy / 1 | PVC, Secret env, route, custom HTTP probes, slow startup | Convert, batch 1 |
| n8n (self-hosted) | 1 deploy / 1 | PVC, Secret env, 2 routes (`n8n-app`, `n8n-webhook`), scrape annotations | Convert, batch 1 (must keep `enableServiceLinks: false`) |
| ollama (ai) | 1 deploy / 1 | PVC, node affinity, custom probes, HR `timeout: 15m` | Convert, batch 2. HR timeout disappears: raise the Flux ks `timeout` to ~15m because `wait: true` now waits on the Deployment |
| pocket-id (security) | 1 deploy / 1 | PVC, emptyDir, Secret env, route on both listeners | Convert, batch 2 (it is the IdP: every SSO login is down during the swap) |
| home-assistant (home-automation) | 1 deploy / 1 | PVC, multus annotation, route on both listeners | Convert, batch 3 |
| music-assistant (media) | 1 sts / 1 | PVC, multus, LoadBalancer Service with fixed LB IP, route | Convert, batch 3. Becomes a Deployment + Recreate. Keep Service names `music-assistant-app` and `music-assistant-streamserver` |
| matter-server (home-automation) | 1 sts / 1 | PVC, multus, NET_RAW, TCP probes, `{{ .Release.Name }}` in env | Convert, batch 3. Becomes a Deployment + Recreate. The env template becomes the literal `matter-server` |
| sure (self-hosted) | 3 deploys (app+worker, postgres, valkey) | 3 PVCs, shared env via YAML anchors | Convert, batch 4. Put the shared env in a ConfigMap + `envFrom` instead of duplicating it |
| netbox (self-hosted) | 3 deploys (init+app+worker, postgres, valkey) | 3 PVCs, shared env anchors, HR timeout 15m | Convert, batch 4. Same `envFrom` approach. Raise the ks timeout for first-run migrations |
| otbr (home-automation) | 2 deploys (`otbr-otbr-1`, `otbr-otbr-3`) pinned per node | privileged, hostPath char devices, multus, exec liveness | Convert, batch 5. Use plain names `otbr-1` / `otbr-3` for the Deployments and keep the Services `otbr-1` / `otbr-3`. Thread network drops during the swap, so do one node at a time if possible |
| paperless (self-hosted) | 4 deploys (app, redis, gotenberg x2, tika x2) | 2 PVCs, PDBs + backup CronJob that select on app-template labels | Convert, batch 5 (last). `pdb.yaml` and the `backup-cronjob.yaml` podAffinity must switch to `app.kubernetes.io/name: paperless-*` in the same PR |
| multus (network) | 1 daemonset | hostPath, ClusterRole/Binding, SA | Convert, batch 5. Mirror upstream's `multus-daemonset-thick`/thin manifest. Existing pods keep their interfaces; only pods created during the gap fail to attach macvlan |

**Count: 14 app-template releases. Convert all 14 (2 done here), keep 0.**
None uses the chart for anything Kubernetes can't express directly. The only
real cost is the env duplication in sure and netbox, which a ConfigMap +
`envFrom` removes. After the last conversion, delete the four app-template
sources: `ai/ocirepository.yaml`, `self-hosted/ocirepository.yaml`,
`security/pocket-id/app/oci-repository.yaml` and
`network/multus/app/ocirepository.yaml`, plus the two `bjw-s`
HelmRepositories (home-assistant, music-assistant).

## 2. Other Helm charts

| Chart | Verdict |
| --- | --- |
| cilium, cert-manager, longhorn | Keep: CRDs, webhooks, upstream-supported install path |
| trivy-operator, tuppr, spegel | Keep: operator/CRDs/RBAC; spegel's chart handles the containerd config |
| victoria-metrics-single, victoria-logs-single, victoria-metrics-alert, grafana, kube-state-metrics, fluent-bit | Keep: large generated config/RBAC, upstream-maintained |
| gitea, gitea-actions | Keep: gitea chart is complex; gitea-actions owns a PVC via volumeClaimTemplate |
| alertmanager | Keep for now: chart-owned PVC (StatefulSet volumeClaimTemplate) makes the swap a data migration for little gain |
| prometheus-node-exporter | Could be a raw DaemonSet (29-line HR), but it's low value. Keep |
| podinfo | Test app. Either drop it or make it a raw Deployment (it already ships a separate `httproute.yaml`) |

## 3. Consistency and simplification findings

Layout and Flux wiring:
- **Three ways to fetch app-template**: HelmRepository `bjw-s`
  (home-assistant, music-assistant), a per-namespace OCIRepository (ai,
  self-hosted) and a per-app OCIRepository (pocket-id, and multus where it is
  named `multus`). Intervals differ: 15m, 12h, 1h. This goes away with
  section 1.
- **Hidden cross-ks dependency**: otbr and matter-server use the `bjw-s`
  HelmRepository declared in `home-automation/home-assistant/app/helmrepository.yaml`,
  but neither ks.yaml has `dependsOn: home-assistant-app`.
- **Layering inversion**: `kubernetes/apps/talos1018/network/gateway-api`
  (the Gateway API CRDs plus the gateways) is applied by the `apps`
  Kustomization, but `infra-cilium-app` and `infra-cert-manager-app` dependsOn
  `gateway-api-app`. It only works because `infra-core` has `wait: false`.
  Move the CRDs to `infrastructure/talos1018/core/`.
- **Doc drift on layering**: CLAUDE.md says apps depend on infra-storage.
  `kubernetes/clusters/talos1018/apps.yaml` depends only on `cluster-config` +
  `infra-core` (README.md is right).
- **ks.yaml naming**: 36 Kustomizations end in `-app` (e.g. `home-assistant-app`,
  `paperless-app`) and the rest don't (`wishlist`, `n8n`, `music-assistant`).
  Pick one. Renaming means delete + recreate, so tie it to the conversion PRs.
- **Missing storage dependency**: 20 ks.yaml with a PVC lack
  `dependsOn: infra-longhorn-config`. Examples: changedetection, pocket-id,
  home-assistant, otbr, matter-server, music-assistant, ntfy, grafana,
  victoria-*, adsb/readsb, homebox, spoolman. 12 have it.
- **Unused decryption**: `decryption:` is set with no `*.sops.yaml` in the
  path in 6 ks.yaml: wishlist, home-assistant, ifconfig, openspeedtest,
  chrony, ripe-atlas.
- `sourceRef.namespace: flux-system` is present in some ks.yaml and absent in
  56. It's harmless, but pick one style.
- Top-level `apps/talos1018/` mixes category folders (ai, self-hosted, media)
  with loose apps (homepage, homebox, bricktracker, spoolman,
  minecraft-bedrock, podinfo).
- Wrong header comment: `media/music-assistant/ks.yaml` says "home-assistant".
- Hardcoded LB IPs in `io.cilium/lb-ipam-ips`: mosquitto, internal-gateway,
  victoria-logs syslog, akvorado flow, music-assistant. Consider a
  cluster-secrets variable, as done for other addresses.
- `healthChecks` correctly appear nowhere. Don't re-add them.

Workloads:
- paperless (`self-hosted/paperless/app/helmrelease.yaml`) has several
  copy-paste problems:
  - the gotenberg and tika containers are named `redis`;
  - the redis Service port is named `http`;
  - a commented-out NFS block is left in;
  - the stateless 2-replica gotenberg/tika run with `Recreate`, so both
    replicas drop at once on every rollout. They should use `RollingUpdate`.
- `enableServiceLinks: false` is set on only 1 of 46 raw workloads
  (skystats). That is the env-collision class of bug; make it a convention.
- No pod `securityContext`: adsbhub, airnavradar, flightradar24,
  opensky-network, piaware, planefinder, radarvirtuel, readsb, skystats,
  ripe-atlas, esphome, homepage, mealie, netbootxyz, openspeedtest,
  spoolman, chrony, minecraft-bedrock.
- No probes: all adsb feeders, mosquitto, esphome, mealie, isponsorblocktv,
  netbootxyz, ripe-atlas, chrony.
- oauth2-proxy is copied 4 times with near-identical specs (akvorado,
  spoolman, matter-server, netbootxyz).
- No dead files: every manifest under `kubernetes/` is reachable from a
  kustomization or a Flux `path`.

Docs:
- `kubernetes/README.md` says to base64-encode into `data:` and pass `--age=`
  by hand. The repo convention is `stringData` plus the `.sops.yaml` creation
  rules (`sops --encrypt --in-place <file>`).
- CLAUDE.md "Adding New Applications" shows `secret.sops.yaml` and omits
  `ks.yaml`/`app/`. The convention is `<app>-secret.sops.yaml` inside `app/`,
  wired by a `ks.yaml`.

Live cluster (not in git):
- About 22 orphaned `*-tls` Secrets from the pre-Gateway ingress era. Examples:
  `self-hosted/wishlist-tls`, `changedetection-tls`, `n8n-tls`,
  `paperless-tls`, `security/pid-tls`, `observability/grafana-tls`, the adsb
  ones and `podinfo-tls`. They have no Certificate. Before deleting, keep
  `gateway-*-tls-v2`, `internal-gateway-tls`, `mosquitto-tls` and
  `longhorn-webhook-tls`.

## 4. Migration procedure (app-template to raw, under Flux)

How this repo wires an app-template app: the Flux Kustomization `<app>`
applies the PVC, the Secret and the HelmRelease. helm-controller renders
everything else. So:

- **PVCs are safe.** They are in the Flux ks inventory (labels
  `kustomize.toolkit.fluxcd.io/name=<app>`), not in the Helm manifest
  (`helm get manifest` lists only SA, ConfigMap, Service, workload and
  HTTPRoute). Removing the HelmRelease never touches them, and the Longhorn
  backup labels stay.
- **Deleting a HelmRelease runs `helm uninstall`**, which deletes every object
  in the release by name. That includes objects that now have the same name in
  the raw manifests. Exception: helm-controller skips the uninstall when the
  HelmRelease is `suspend: true` at deletion time (`reconcileDelete`).
- **The Deployment selector is immutable.** Server-side dry-run against
  wishlist: `spec.selector ... field is immutable`. So a plain merge makes the
  ks fail before anything is pruned: the old app keeps running and the ks goes
  Ready=False. That failure is safe but noisy. The Deployment has to be
  deleted once.
- **The Service selector is an atomic map.** SSA replaces it wholesale
  (dry-run confirmed), so an adopted Service switches cleanly to the new
  labels. The procedure below still recreates it, for a clean ownership state.
- **Service names and ports stay identical**, so in-cluster clients (homepage
  widgets, oauth2-proxy upstreams, `OLLAMA_BASE_URL`, `DB_HOST`, ...) need no
  change. The ClusterIP changes on recreate, which nobody pins.
- **RWO volumes** need `strategy: Recreate` (app-template already used it, so
  behaviour is unchanged).
- **Selectors on chart labels** must change in the same PR: paperless
  `pdb.yaml`, `backup-cronjob.yaml`, and any `app.kubernetes.io/controller`
  topologySpread. Search with
  `grep -rn "app.kubernetes.io/controller\|app.kubernetes.io/instance" kubernetes`.

Procedure per app (or per batch in one namespace):

1. `flux suspend ks <app>`. Optional, but it stops a half-applied state
   between merge and step 3.
2. Merge the PR (HelmRelease removed, raw manifests added).
3. `kubectl -n <ns> delete helmrelease <app>`. This runs `helm uninstall`,
   which removes the SA, Service, ConfigMap, Deployment, HTTPRoute and release
   Secrets. **Downtime starts here.**
4. `flux resume ks <app>`. Flux creates the raw objects, and `wait: true`
   blocks until the Deployment is Ready.
5. Check:
   - `kubectl -n <ns> get deploy,svc,httproute,pvc -l app.kubernetes.io/name=<app>`
   - the endpoint has a pod: `kubectl -n <ns> get endpointslices -l kubernetes.io/service-name=<app>`
   - the homepage tile still appears (it discovers pods by `app.kubernetes.io/name`, which stays the same).

Expected downtime: pod termination + Longhorn detach/attach + app startup.
That is under 2 min for wishlist/changedetection and about 3 min for openwebui
(embeddings load). Ollama is longer (model load); the IdP and Home Assistant
are short but user-visible. If step 1 is skipped, the merge just fails the ks
with the immutable-selector error; run steps 3-4 (`flux reconcile ks <app>`
instead of resume).

Lower-downtime variant (route never flaps; only the pod restarts):

1. `flux suspend hr <app>`.
2. Delete the HR. It is orphaned: no uninstall.
3. `kubectl delete deploy <app>`.
4. Reconcile the ks. Flux adopts the Service, HTTPRoute and ConfigMap in place
   and creates the Deployment.
5. Clean up the leftovers: `kubectl delete sa <app>`,
   `kubectl delete secret -l owner=helm,name=<app>`, and the stale
   `helm.sh/chart` / `meta.helm.sh/*` labels and annotations.

Use this for pocket-id and home-assistant.

## 5. Batches

0. **Pilot (this branch):** wishlist, changedetection (self-hosted). Single
   controller, one PVC, low impact.
1. openwebui, n8n. Single controller.
2. ollama (raise the ks timeout), pocket-id (IdP, use the low-downtime
   variant).
3. home-assistant, music-assistant, matter-server (multus pods; StatefulSet
   to Deployment).
4. sure, netbox (multi-controller with postgres/valkey; shared env via
   ConfigMap). Take a Longhorn backup of the postgres PVCs first.
5. otbr, multus, paperless (hardware/CNI/most coupled). Fix the paperless
   container names and gotenberg/tika `RollingUpdate` while there. Then delete
   the app-template sources.
6. Consistency sweep from section 3: ks naming, longhorn `dependsOn`, unused
   `decryption`, `enableServiceLinks: false`, gateway-api CRDs to infra, and
   README/CLAUDE.md fixes.

## 6. Decisions (2026-10-17)

- **app-template sources:** not fixed in place. otbr and matter-server (and
  the shared bjw-s Helm repo in home-assistant's folder) go away as part of
  their raw-manifest migration (batches 3 and 5).
- **Gateway API CRDs in the apps tree:** fine as is. Longer term the direction
  is to drop the separate `infrastructure/` tree and keep everything under
  `apps/`, ordered with `dependsOn` where it is actually needed — so do not
  move the CRDs into infra.
- **Longhorn `dependsOn`:** add `infra-longhorn-config` to every app with a
  PVC (batch 6, done separately).
- **Ingress-era `*-tls` Secrets:** delete from the cluster (not in git).
- **README / CLAUDE.md drift:** fix (batch 6).
- **paperless converters:** `RollingUpdate` done ahead of batch 5
  (fmurodov/homeops#1015).

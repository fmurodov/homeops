# dev-isolated

The locked-down counterpart to `dev`. Same purpose — developer tooling — split by
trust:

| | `dev` | `dev-isolated` |
|---|---|---|
| Runs | code we wrote (Gitea, its own Actions runner) | code from anywhere |
| PSA | `privileged` (Gitea Actions DinD) | `baseline` |
| Network | full cluster and LAN | public internet only |
| Holds | Gitea's database and secrets | nothing worth stealing |

Any runner whose jobs must **not** touch the LAN or the cluster belongs here,
whatever the vendor — GitLab is the first tenant, GitHub ARC or anything later
drops in beside it and inherits the same isolation without restating it. A runner
that genuinely needs cluster access (deploy jobs, `kubectl` against this cluster)
goes in `dev` instead.

Note what that split means: `dev` is not a security boundary and is not trying to
be one. It is `privileged`, so a job there can take the node — which is precisely
why runners for other people's code do not go in it. `dev-isolated` is the
boundary; keep it that way.

## The boundary

- **`baseline` PSA** — no privileged, hostPath, hostPID or hostNetwork, so a job
  cannot reach the node.
- **`dev-isolated-allow-internet`** selects `{}`, so every pod here — each
  vendor's manager and every job pod they spawn — gets DNS plus the public
  internet and nothing else. RFC1918, ULA and the cluster's own GUA prefix are
  excluded. Selecting on `{}` rather than a job label means a new runner cannot
  opt out and a job cannot escape by dropping a label.
- **Per-runner grants stay per-runner.** A runner needing the API server adds a
  narrow companion policy in its own directory, matched to its own label, so job
  pods never inherit it.

Verified on deploy: a job-pod-equivalent reaches gitlab.com but times out against
both `gitea-http.dev` and `kubernetes.default`. The GitLab manager reaches the
API server and is still blocked from `gitea-http.dev`.

---

# gitlab-runner

Self-hosted runner for gitlab.com, so pipelines aren't capped by shared runner
minutes.

## Isolation specific to this runner

- **Split service accounts**: the manager holds a namespace-scoped `Role` (never
  a ClusterRole); job pods run as `gitlab-runner-jobs`, which has no RBAC bound
  to it and `automountServiceAccountToken: false`.
- **`gitlab-runner-manager-apiserver`** grants the manager `kube-apiserver`
  egress, matched on its label. Job pods never get it.

## Executor

Kubernetes executor — one pod per job, no persistent Docker daemon. Jobs land in
this same namespace and inherit the namespace policy above.

Resource and **ephemeral-storage** limits are set for build, helper and service
containers. The ephemeral caps matter here: job scratch space lands on the node's
`/var`, which containerd and Longhorn also share.

`namespace_overwrite_allowed`, `service_account_overwrite_allowed` and
`pod_labels_overwrite_allowed` are all empty — a `.gitlab-ci.yml` that could pick
its own namespace or service account would step straight out of the sandbox.

## Setup

gitlab.com has no group runners for projects in a **personal namespace**, and no
runner exists at user level — runners are owned by a project, a group, or the
instance. So each runner is created inside a project. That does *not* mean one
runner per project: an unlocked project runner can be assigned to your other
projects from its **Projects** tab, and one pod serves any number of tokens
regardless, because `config.toml` is an array of `[[runners]]`.

1. Project > **Settings > CI/CD > Runners > New project runner**.

   - **Tags** `talos1018`, and leave **Run untagged jobs** checked — existing
     pipelines keep working, and a job can still opt in with `tags: [talos1018]`.
   - Leave **Lock to current projects** unchecked, so the runner can be reused
     for other projects instead of minting a token each time. This does not
     expose it: only a Maintainer of both projects can assign it, fork MRs run
     in the fork rather than here, and the runner polls outbound — nothing
     connects in, and the namespace has no ingress rules at all.
   - Leave the token expiry **unset**. The runner rotates an expiring token into
     its `config.toml`, which lives on an emptyDir and is lost on restart.

2. Ignore the `gitlab-runner register …` command GitLab then shows — there is no
   registration step here. Copy only the `glrt-…` token; it is shown once.

3. Add it to `gitlab-runner-secret.sops.yaml` as `<name>: glrt-…` and encrypt:

   ```
   sops --encrypt --in-place kubernetes/apps/talos1018/dev-isolated/gitlab-runner/app/gitlab-runner-secret.sops.yaml
   ```

   That secret is the only file that changes as projects come and go. The init
   container emits one `[[runners]]` block per key, validates each value looks
   like a `glrt-` token, and fails naming the offending key rather than leaving
   a silent 403 loop.

4. Still in **Settings > CI/CD > Runners**, turn **instance runners off** for the
   project. Creating your own runner does not stop GitLab scheduling on shared
   runners; this is the step that actually stops the quota being consumed.

Tokens never enter the ConfigMap. They are mounted as files under `/secrets` and
substituted into the generated config at startup. The ConfigMap carries
`kustomize.toolkit.fluxcd.io/substitute: disabled` because `render.sh` uses
pod-side shell variables that Flux's envsubst would otherwise blank out.

## Building container images

There is deliberately no Docker-in-Docker, which is why the namespace can stay at
`baseline`. Build rootless instead — buildah with the `vfs` storage driver needs
no extra privileges:

```yaml
build:
  image: quay.io/buildah/stable
  variables:
    STORAGE_DRIVER: vfs
    BUILDAH_FORMAT: docker
  script:
    - buildah bud -t "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA" .
    - buildah login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - buildah push "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA"
```

Kaniko works too. `vfs` trades disk and speed for not needing `/dev/fuse`; if a
build outgrows `ephemeral_storage_limit` the pod is evicted rather than filling
the node, so raise that limit rather than reaching for privileged mode.

If DinD ever becomes unavoidable, it needs `privileged = true` *and* the namespace
moved to `privileged` PSA — which would dissolve the boundary for every other
runner sharing it. That runner belongs in `dev`, which is already `privileged`,
or in a namespace of its own. Not here.

## Caching

`[runners.cache]` is unset: with no S3 endpoint in the cluster, caches are
per-job only. Jobs still work, they just re-download dependencies each run.
Adding a MinIO bucket and an S3 cache block is the fix if that becomes painful.

## Metrics

The manager exposes Prometheus metrics on `[::]:9252` and carries
`prometheus.io/scrape` annotations. VictoriaMetrics needs a pod restart to pick
up scrape-config changes before these appear.

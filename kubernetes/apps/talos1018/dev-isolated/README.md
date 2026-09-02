# dev-isolated

The locked-down counterpart to `dev`, split by trust:

| | `dev` | `dev-isolated` |
|---|---|---|
| Runs | code we wrote (Gitea + its Actions runner) | code from anywhere |
| PSA | `privileged` (DinD) | `baseline` |
| Network | full cluster and LAN | public internet only |

Any runner whose jobs must not touch the LAN or the cluster belongs here,
whatever the vendor. One that genuinely needs cluster access goes in `dev` —
which is `privileged` and therefore not a boundary at all. This namespace is.

`dev-isolated-allow-internet` selects `{}` so nothing here can opt out: not a new
runner, not a job pod that drops a label. A runner needing the API server adds a
narrow policy in its own directory, matched to its own label.

A ResourceQuota caps the namespace as a whole — per-container limits don't bound
the total, and a runner's own `concurrent` setting stops meaning anything once a
second runner shares the namespace.

# gitlab-runner

Kubernetes executor, one pod per job. No DinD — that is what keeps the namespace
at `baseline`. Build images rootless instead: buildah needs `STORAGE_DRIVER: vfs`
to work without `/dev/fuse`. Enabling DinD would mean `privileged` PSA and would
dissolve the boundary for everything else here.

## Tokens

gitlab.com has no runners at user level, and no group runners for projects in a
personal namespace — each is created inside a project. That does not mean one
runner per project: an *unlocked* project runner can be assigned to others from
its **Projects** tab, and `config.toml` is an array of `[[runners]]`, so one pod
serves any number of tokens.

Adding one is a new key in `gitlab-runner-secret` (key = runner name), encrypted
with sops. Nothing else changes — the init container emits a `[[runners]]` block
per key, and fails naming the key if a value is not a `glrt-` token.

Two things that are easy to miss:

- Leave the token expiry **unset**. A rotated token is written back to
  `config.toml`, which is an emptyDir and is lost on restart.
- Turning **instance runners off** per project is what stops shared runner quota
  being consumed. Creating your own runner does not.

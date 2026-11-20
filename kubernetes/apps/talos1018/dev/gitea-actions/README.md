# gitea-actions

act_runner plus a Docker-in-Docker sidecar. Jobs are containers started by
that sidecar's dockerd, so whatever dockerd can do on the node, a workflow can
do too. Hardening history: homeops-project#135.

## Rootless DinD in a user-namespaced pod

Three layers of uids, each unprivileged in the one outside it:

| Where | Job's "root" is |
|---|---|
| job container | uid 0 |
| DinD sidecar (rootlesskit) | uid 1000, the rootless dockerd |
| node | a high uid from the pod's own range (`hostUsers: false`) |

- `hostUsers: false` gives the pod its own user namespace. Kubernetes maps its
  uids 0-65535 to a block of unused uids on the node.
- The sidecar is still `privileged: true`, which the chart hard-codes. Inside a
  user namespace that only grants capabilities over the pod's own namespaces, not
  the node. It is needed anyway: rootless networking (slirp4netns) needs
  `/dev/net/tun`, and a user-namespaced pod gets device nodes only through
  privileged (a hostPath device can't be id-mapped).
- `/etc/subuid` and `/etc/subgid` come from a ConfigMap, because the image's
  default range (100000+) is outside the pod's 65536 uids.
- The Talos sysctl `user.max_user_namespaces` must be above 0 (Talos ships 0);
  it's set in `talos/talos1018/patches/controlplane.yaml`.

What a job can still do:

- `--privileged` job containers see the node's device nodes, owned by `nobody`.
  Block devices are denied; world-writable ones (kvm, fuse, tun, USB serial
  adapters) are usable. A device plugin handing the sidecar only
  `/dev/net/tun` would allow dropping privileged altogether.
- Reach the internet, DNS and Gitea, nothing else (`networkpolicy.yaml`).
- Use up to the sidecar's memory limit: rootless dockerd has no cgroups, so
  there are no per-job limits.

## Workflows that won't run here

kind, and anything that registers binfmt handlers for qemu, need a rootful
privileged daemon. Build multi-arch images on a native runner instead.

# Talos Kubernetes Cluster (talos1018)

This directory contains the Talos configuration for the `talos1018` Kubernetes cluster, managed with plain **talosctl**.

```
talos1018/
├── generate.sh                # versions + talosctl gen config; writes clusterconfig/
├── secrets.sops.yaml          # `talosctl gen secrets` bundle, SOPS-encrypted
├── patches/
│   ├── controlplane.yaml      # shared by all nodes
│   └── talos-1018-N.yaml      # hostname, addresses, NIC alias
└── clusterconfig/             # generated, gitignored (contains secrets)
```

Configs are generated at the `--talos-version v1.14` contract, so most settings are 1.14 documents rather than
v1alpha1 fields. `patches/controlplane.yaml` overrides the new-cluster defaults that don't fit this cluster:
workload isolation stays off (Longhorn v1 needs the host `iscsid`), control-plane nodes carry no `NoSchedule`
taint (all nodes are control planes), anonymous API auth is limited to the health endpoints, there is no Flannel, and the installer
targets `/dev/nvme0n1`.

## Prerequisites

- talosctl
- kubectl
- helm
- sops + age key
- 3 control-plane nodes (fd00:1018:0:5:10:18:6:91-93)
- Control-plane VIP: fd00:1018:0:5:10:18:6:90

## Installation Steps

### Generate Talos configs

```bash
./generate.sh
```

This decrypts `secrets.sops.yaml` and writes `clusterconfig/`.
These files are **generated** and should not be edited manually.

A new cluster needs a secrets bundle first:

```bash
talosctl gen secrets -o secrets.sops.yaml
```

```bash
sops --encrypt --in-place secrets.sops.yaml
```

### Apply Configurations to Nodes

Apply the generated configurations to each control plane node:

```bash
talosctl apply-config --insecure -n 10.18.6.91 --file clusterconfig/talos1018-talos-1018-1.yaml
talosctl apply-config --insecure -n 10.18.6.92 --file clusterconfig/talos1018-talos-1018-2.yaml
talosctl apply-config --insecure -n 10.18.6.93 --file clusterconfig/talos1018-talos-1018-3.yaml
```

### Bootstrap the Cluster

Run this **once**, on a single control-plane node:

```bash
talosctl bootstrap -n fd00:1018:0:5:10:18:6:91
```

### Get kubeconfig

```bash
talosctl kubeconfig --nodes fd00:1018:0:5:10:18:6:90
```

### Network Configuration with Cilium

> **⚠️ IMPORTANT - Bootstrap Preparation**
>
> The Cilium config files use variable substitution (`${IPV6_PREFIX_GUA}`) which only works after Flux is running.
> For the initial bootstrap, you need to temporarily replace these variables with actual values.
>
> Before proceeding, run this command to substitute the variables:
>
> ```bash
> # Decrypt cluster-secrets to get the actual values
> sops -d ../../kubernetes/components/common/cluster-secrets.sops.yaml > /tmp/cluster-secrets.yaml
> 
> # Extract IPv6 prefix
> IPV6_PREFIX_GUA=$(grep IPV6_PREFIX_GUA /tmp/cluster-secrets.yaml | awk '{print $2}')
> 
> # Temporarily replace variables in external-pool.yaml
> sed "s/\${IPV6_PREFIX_GUA}/$IPV6_PREFIX_GUA/g" \
>     ../../kubernetes/apps/talos1018/kube-system/cilium/config/external-pool.yaml > /tmp/external-pool.yaml
> 
> # Clean up
> rm /tmp/cluster-secrets.yaml
> ```
>
> After Flux takes over, these variables will be substituted automatically.

Install Cilium using Helm (required before Flux can operate). Use the same
version pinned in
`../../kubernetes/apps/talos1018/kube-system/cilium/app/helmrelease.yaml`
so the bootstrap matches what Flux will manage:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
    --version 1.19.6 \
    --namespace kube-system \
    -f ../../kubernetes/apps/talos1018/kube-system/cilium/app/values.yaml \
    --create-namespace
```

Apply the Cilium L2 configuration (using the processed external-pool.yaml):

```bash
kubectl create -f ../../kubernetes/apps/talos1018/kube-system/cilium/config/l2-announcement-policy.yaml
kubectl create -f ../../kubernetes/apps/talos1018/kube-system/cilium/config/internal-pool.yaml
kubectl create -f /tmp/external-pool.yaml  # Use the processed file with actual values
```

> **Note**: After Flux is deployed, it will automatically take over management of Cilium without disruption.
> The Cilium values and configs are now located at `kubernetes/apps/talos1018/kube-system/cilium/` and
> are managed by Flux. See `kubernetes/apps/talos1018/kube-system/cilium/README.md` for details.

## Verification

To verify the cluster is running correctly:

```bash
kubectl get nodes
kubectl -n kube-system get pods
```

## Updating Talos configuration

1. Edit the files in `patches/`
2. Regenerate configs:

```bash
./generate.sh
```

3. Check what changes on a node before applying:

```bash
talosctl apply-config -n fd00:1018:0:5:10:18:6:91 --file clusterconfig/talos1018-talos-1018-1.yaml --dry-run
```

4. Apply the generated configurations to each control plane node:

```bash
talosctl apply-config -n fd00:1018:0:5:10:18:6:91 --file clusterconfig/talos1018-talos-1018-1.yaml
talosctl apply-config -n fd00:1018:0:5:10:18:6:92 --file clusterconfig/talos1018-talos-1018-2.yaml
talosctl apply-config -n fd00:1018:0:5:10:18:6:93 --file clusterconfig/talos1018-talos-1018-3.yaml
```

## Talos upgrade
tuppr drives upgrades from `kubernetes/apps/talos1018/system-upgrade/tuppr/config/`. Renovate bumps
`TALOS_VERSION`/`KUBERNETES_VERSION` in `generate.sh` in the same PR, so regenerated configs carry the new
installer image.

**Merging a Talos PR is not a config-only change:** the `TalosUpgrade` is live, so the merge starts a rolling
drain and reboot of every node. Renovate holds Talos minor/major releases for 14 days and patches for 3. During
the run tuppr holds an Alertmanager silence for the alerts a reboot is expected to trip (`spec.silences`).

Before merging:

1. Read the release notes at the tag (`gh release view <version> --repo siderolabs/talos`), not the PR body:
   it can carry pre-release notes.
2. Check the cluster is healthy: all nodes `Ready`, every Longhorn volume `healthy` (or `unknown` when
   detached), Flux has nothing failing, and no other `TalosUpgrade`/`KubernetesUpgrade` is in progress.
3. Take an etcd snapshot (any control-plane node):

   ```bash
   talosctl -n fd00:1018:0:5:10:18:6:92 etcd snapshot ~/talos-etcd-snapshots/etcd-before-$(date +%Y%m%d%H%M).db
   ```

For a Kubernetes minor bump, check the Cilium version supports it first.

Manual upgrade:

```bash
./generate.sh

# renovate: datasource=github-releases depName=siderolabs/talos
set TALOS_VERSION v1.14.3
set TALOS_IMAGE "factory.talos.dev/metal-installer/36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010:$TALOS_VERSION"

talosctl upgrade -n fd00:1018:0:5:10:18:6:91 --image "$TALOS_IMAGE" --wait
talosctl upgrade -n fd00:1018:0:5:10:18:6:92 --image "$TALOS_IMAGE" --wait
talosctl upgrade -n fd00:1018:0:5:10:18:6:93 --image "$TALOS_IMAGE" --wait
```

## etcd backups

`kubernetes/apps/talos1018/system-upgrade/talos-backup/` snapshots etcd daily at 02:30 and uploads it to its
own B2 bucket (`talos1018-etcd`, key restricted to that bucket), encrypted to the SOPS age key.
`EtcdBackupStale` fires when no upload has succeeded in 26h. Retention is a B2 lifecycle rule on the bucket,
not anything in this repo: every snapshot has a unique name, so it needs "days from uploading to hiding" set —
"keep prior versions" alone never expires anything.

To restore after losing etcd quorum (see Talos' disaster recovery guide first):

```bash
age -d -i <age-key-file> -o db.snapshot talos1018-<timestamp>.snap.age
```

```bash
talosctl -n fd00:1018:0:5:10:18:6:91 bootstrap --recover-from=./db.snapshot
```

## System extensions

The installer image in `generate.sh` is an Image Factory schematic with intel-ucode, iscsi-tools and
util-linux-tools. After changing the extensions, create the new schematic at https://factory.talos.dev and
replace the ID in `generate.sh` and in the upgrade command above.

## Cilium upgrade

Once Flux is managing Cilium, upgrades are done by updating the version in
`kubernetes/apps/talos1018/kube-system/cilium/helmrelease.yaml` and committing the change.

For manual upgrades (before Flux takeover), match the version pinned in
`helmrelease.yaml`:

```bash
helm upgrade cilium cilium/cilium \
    --version 1.19.6 \
    --namespace kube-system \
    -f ../../kubernetes/apps/talos1018/kube-system/cilium/app/values.yaml \
    --reuse-values
```

## Maintenance

For cluster maintenance, refer to the [Talos documentation](https://www.talos.dev/latest/introduction/what-is-talos/).

## Notes
- Secrets are stored in `secrets.sops.yaml`
- CNI is set to `none` (installed later via Kubernetes tooling)
- All control-plane nodes are schedulable
- IPv4 + IPv6 dual-stack is enabled

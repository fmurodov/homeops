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

Configs are generated with `--talos-version v1.13` although the nodes run 1.14: the patches still set v1alpha1
fields that the 1.14 documents reject, and the 1.14 new-cluster defaults (`workloadIsolation`, secure EPHEMERAL
mount) break Longhorn v1. Migrating to the 1.14 document kinds is tracked separately.

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
>     ../../kubernetes/infrastructure/talos1018/core/cilium/config/external-pool.yaml > /tmp/external-pool.yaml
> 
> # Clean up
> rm /tmp/cluster-secrets.yaml
> ```
>
> After Flux takes over, these variables will be substituted automatically.

Install Cilium using Helm (required before Flux can operate). Use the same
version pinned in
`../../kubernetes/infrastructure/talos1018/core/cilium/app/helmrelease.yaml`
so the bootstrap matches what Flux will manage:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
    --version 1.19.6 \
    --namespace kube-system \
    -f ../../kubernetes/infrastructure/talos1018/core/cilium/app/values.yaml \
    --create-namespace
```

Apply the Cilium L2 configuration (using the processed external-pool.yaml):

```bash
kubectl create -f ../../kubernetes/infrastructure/talos1018/core/cilium/config/l2-announcement-policy.yaml
kubectl create -f ../../kubernetes/infrastructure/talos1018/core/cilium/config/internal-pool.yaml
kubectl create -f /tmp/external-pool.yaml  # Use the processed file with actual values
```

> **Note**: After Flux is deployed, it will automatically take over management of Cilium without disruption.
> The Cilium values and configs are now located at `kubernetes/infrastructure/talos1018/core/cilium/` and
> are managed by Flux. See `kubernetes/infrastructure/talos1018/core/cilium/README.md` for details.

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

Manual upgrade:

```bash
./generate.sh

# renovate: datasource=github-releases depName=siderolabs/talos
set TALOS_VERSION v1.14.0
set TALOS_IMAGE "factory.talos.dev/metal-installer/36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010:$TALOS_VERSION"

talosctl upgrade -n fd00:1018:0:5:10:18:6:91 --image "$TALOS_IMAGE" --wait
talosctl upgrade -n fd00:1018:0:5:10:18:6:92 --image "$TALOS_IMAGE" --wait
talosctl upgrade -n fd00:1018:0:5:10:18:6:93 --image "$TALOS_IMAGE" --wait
```

## System extensions

The installer image in `generate.sh` is an Image Factory schematic with intel-ucode, iscsi-tools and
util-linux-tools. After changing the extensions, create the new schematic at https://factory.talos.dev and
replace the ID in `generate.sh` and in the upgrade command above.

## Cilium upgrade

Once Flux is managing Cilium, upgrades are done by updating the version in
`kubernetes/infrastructure/talos1018/core/cilium/helmrelease.yaml` and committing the change.

For manual upgrades (before Flux takeover), match the version pinned in
`helmrelease.yaml`:

```bash
helm upgrade cilium cilium/cilium \
    --version 1.19.6 \
    --namespace kube-system \
    -f ../../kubernetes/infrastructure/talos1018/core/cilium/app/values.yaml \
    --reuse-values
```

## Maintenance

For cluster maintenance, refer to the [Talos documentation](https://www.talos.dev/latest/introduction/what-is-talos/).

## Notes
- Secrets are stored in `secrets.sops.yaml`
- CNI is set to `none` (installed later via Kubernetes tooling)
- All control-plane nodes are schedulable
- IPv4 + IPv6 dual-stack is enabled

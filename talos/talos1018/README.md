# Talos Kubernetes Cluster Setup

This guide describes the setup process for a Talos-based Kubernetes cluster with Cilium networking.

## Prerequisites

- talosctl CLI tool installed
- kubectl installed
- Helm installed
- 3 VMs/nodes for control plane (fd00:1018:0:5:10:18:6:91-93)
- Load balancer endpoint at fd00:1018:0:5:10:18:6:90

## Installation Steps

### 1. Generate Talos Configuration

```bash
talosctl gen config talos1018 https://[fd00:1018:0:5:10:18:6:90]:6443
```

### 2. Apply Configurations to Nodes

Apply the generated configurations to each control plane node:

```bash
talosctl apply-config --insecure -n 10.18.6.91 --file controlplane-talos-1018-1.yaml --talosconfig ./talosconfig
talosctl apply-config --insecure -n 10.18.6.92 --file controlplane-talos-1018-2.yaml --talosconfig ./talosconfig
talosctl apply-config --insecure -n 10.18.6.93 --file controlplane-talos-1018-3.yaml --talosconfig ./talosconfig
```

### 3. Bootstrap the Cluster

Initialize the first control plane node:

```bash
talosctl bootstrap -n fd00:1018:0:5:10:18:6:91
```

### 4. Network Configuration with Cilium

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

Install Cilium using Helm (required before Flux can operate):

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
    --version 1.18.2 \
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

## Network Architecture

- Control Plane VIP: fd00:1018:0:5:10:18:6:90
- Control Plane Node 1: fd00:1018:0:5:10:18:6:91
- Control Plane Node 2: fd00:1018:0:5:10:18:6:92
- Control Plane Node 3: fd00:1018:0:5:10:18:6:93


## Talos upgrade

```bash
talosctl apply-config -n <node> --file controlplane-<node>.yaml
# renovate: datasource=github-releases depName=siderolabs/talos
talosctl upgrade -n <node> --image factory.talos.dev/installer/36cd6536eaec8ba802be2d38974108359069cedba8857302f69792b26b87c010:v1.11.6 --wait
```

## Cilium upgrade

Once Flux is managing Cilium, upgrades are done by updating the version in
`kubernetes/infrastructure/talos1018/core/cilium/helmrelease.yaml` and committing the change.

For manual upgrades (before Flux takeover):

```bash
helm upgrade cilium cilium/cilium \
    --version 1.18.2 \
    --namespace kube-system \
    -f ../../kubernetes/infrastructure/talos1018/core/cilium/app/values.yaml \
    --reuse-values
```

## Development

### Git Pre-Commit Hook

To automatically validate configs before committing:

```bash
cp scripts/pre-commit .git/hooks/pre-commit
```

This will run `./scripts/validate.sh` before each commit. To bypass: `git commit --no-verify`

## Maintenance

For cluster maintenance, refer to the [Talos documentation](https://www.talos.dev/latest/introduction/what-is-talos/).

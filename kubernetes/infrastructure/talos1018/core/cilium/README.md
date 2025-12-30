# Cilium CNI Controller

This directory manages Cilium installation via Flux CD.

## Bootstrap Process

Since Cilium is the CNI (Container Network Interface), it must be installed **before** Flux can operate. The bootstrap process is:

1. **Initial Bootstrap**: Install Cilium manually using Helm during cluster setup (see talos/talos1018/README.md)
2. **Flux Takeover**: Once Flux is running, it will take over management of Cilium

## Bootstrap Installation

During initial cluster setup, install Cilium manually.

> **⚠️ IMPORTANT**: The config files use Flux variable substitution (`${IPV6_PREFIX_GUA}`) which doesn't work during bootstrap.
> You need to temporarily replace this variable with actual values from `cluster-secrets.sops.yaml`.
> See `talos/talos1018/README.md` for the complete bootstrap procedure with variable substitution.

Quick bootstrap command (after preparing the external-pool.yaml with actual values):

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
    --version 1.18.2 \
    --namespace kube-system \
    -f kubernetes/infrastructure/talos1018/core/cilium/app/values.yaml
```

## Flux Management

After Flux is deployed, it will:
- Detect the existing Cilium installation
- Take over management without disruption
- Apply updates according to the HelmRelease specification

## Upgrading Cilium

With Flux managing Cilium, upgrades are done by updating the version in `helmrelease.yaml`:

```yaml
spec:
  chart:
    spec:
      version: 1.18.2  # Update this version
```

Commit and push the change, and Flux will perform the upgrade.

## Configuration

Cilium configuration is in `values.yaml`. Key features enabled:
- Dual-stack IPv4/IPv6 support
- L2 announcements for LoadBalancer IPs
- Hubble observability (relay and UI)
- VXLAN tunnel mode
- IPv4/IPv6 masquerading

## Related Resources

L2 announcement policies and IP pools are in the same directory:
- `kubernetes/infrastructure/talos1018/core/cilium/`

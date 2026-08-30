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
    --version 1.20.0 \
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
      version: 1.20.0  # Update this version
```

Commit and push the change, and Flux will perform the upgrade.

## Configuration

Cilium configuration is in `values.yaml`. Key features enabled:
- Dual-stack IPv4/IPv6 support (IPv6-primary)
- L2 announcements for LoadBalancer IPs
- Hubble observability (relay and UI)
- Gateway API access logs (see below)
- Native routing (direct node routes, no tunnel)
- IPv4/IPv6 masquerading

## Gateway API access logs

Every request through the gateway is one JSON line on cilium-envoy's stdout,
collected by fluent-bit into VictoriaLogs:

```
{kubernetes_container_name="cilium-envoy"}
```

The format is in `config/gatewayclassconfig.yaml`, delivered over xDS, so edits
restart nothing. A `postRenderers` patch on the HelmRelease points the
GatewayClass at it, because the chart exposes no `parametersRef` value.

Fields follow Istio's canonical Envoy JSON schema. That buys vocabulary, not a
drop-in dashboard: the popular community board
([14876](https://grafana.com/grafana/dashboards/14876)) is LogQL against Loki,
while this cluster queries VictoriaLogs. The installed VictoriaLogs Explorer
(22759) works on the stream as-is.

Non-obvious bits:

- The GatewayClass stays Helm-owned deliberately — Cilium tears down a
  Gateway's Service and CiliumEnvoyConfig if its GatewayClass disappears.
- The config lives in `config/` because that Kustomization waits on the
  HelmRelease, so Cilium's CRDs exist before it is applied. The cost is a brief
  `Accepted=False` on the GatewayClass during a first apply, which is cosmetic:
  Gateways do not read that condition, and a missing config means "no
  parameters", not an error.
- `spec.service` must stay unset, or it starts rewriting the gateway's
  LoadBalancer service and its pinned IPs.
- Only `%CILIUM_GATEWAY_*%` is Cilium's. Everything else must be a real Envoy
  [command operator](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage).
- `client_ip` prefers Cloudflare's header and falls back to `X-Forwarded-For`
  for clients reaching a listener directly over split DNS; `client_country` is
  null for those. `downstream_remote_address` is the only one a caller cannot
  forge.
- LAN callers keep their source address despite `externalTrafficPolicy:
  Cluster`, because gateway traffic is redirected to the node-local Envoy
  instead of being forwarded to another node.
- `CiliumGatewayClassConfig` is `v2alpha1`; read the release notes when bumping
  the chart.

Bootstrap is unaffected: the manual `helm install` uses only `values.yaml`,
which this does not touch, and without the Gateway API CRDs the chart renders no
GatewayClass, making the post-render a no-op.

## Related Resources

L2 announcement policies and IP pools are in the same directory:
- `kubernetes/infrastructure/talos1018/core/cilium/`

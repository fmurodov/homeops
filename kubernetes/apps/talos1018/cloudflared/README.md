# Cloudflare Tunnel

Terminates all inbound public traffic and forwards it to the Cilium Gateway in
the `network` namespace. Runs in its own `cloudflared` namespace under the
`restricted` Pod Security Standard — `network` is `privileged` because of multus
and chrony, and the tunnel does not need that.

## The tunnel must stay locally-managed

Ingress rules live in `app/configmap.yaml` and nowhere else. That only holds for
a tunnel created with `config_src: local`.

A **remotely-managed** tunnel (the default when you create one in the Zero Trust
dashboard, run with `TUNNEL_TOKEN`) stores its ingress rules on Cloudflare and
pushes them down over the tunnel RPC on every connect. `cloudflared` treats the
mounted `config.yaml` as an initial value only and accepts any pushed
configuration unconditionally — there is no flag to refuse it. The result is a
config file in git that looks authoritative and is entirely inert — which is
what this deployment did from #639 until the migration to a local tunnel.

`config_src` is fixed at creation: the tunnel edit API accepts only `name` and
`tunnel_secret`. Converting means creating a new tunnel and repointing DNS.

## Where the tunnel lives

The tunnel itself is a Terraform resource in the `fmurodov-tf` repo
(`modules/cloudflare/tunnel.tf`), alongside the DNS records that point at it.
It cannot be created from the Zero Trust dashboard — every tunnel the dashboard
creates is remotely-managed.

```hcl
resource "cloudflare_zero_trust_tunnel_cloudflared" "homeops" {
  account_id = cloudflare_account.firdavs.id
  name       = "homeops"
  secret     = var.cloudflared_tunnel_secret
  config_src = "local"
}
```

`cloudflared_tunnel_secret` is a GitLab CI variable, and the same value is half
of the credentials this repo holds. `app/cloudflared-secret.sops.yaml` carries a
`credentials.json` built from three values:

| field          | source                                      |
| -------------- | ------------------------------------------- |
| `AccountTag`   | `cloudflare_account_id` output              |
| `TunnelID`     | `cloudflare_tunnel.id` output               |
| `TunnelSecret` | the `cloudflared_tunnel_secret` CI variable |

The tunnel id is also needed in plain text by `config.yaml`. This repo is
public, and proxied records never expose the `*.cfargotunnel.com` target to
outside resolvers, so it comes from `${CLOUDFLARE_TUNNEL_ID}` in cluster-secrets
rather than being committed — the same treatment `${DOMAIN}` gets. It is an
identifier, not a credential: the connector authenticates with `TunnelSecret`.

Rotating the secret replaces the tunnel (`secret` forces replacement), which
means a new id and a DNS repoint — treat it as a migration, not a rotation.

## Adding a public hostname

The ingress rule is a wildcard on `${DOMAIN}`, so a new external app needs no
change here — just an HTTPRoute on the `https-external` listener and a proxied
CNAME to `<tunnel-id>.cfargotunnel.com`.

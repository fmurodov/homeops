# mosquitto

MQTT broker for the home-automation namespace.

## Listeners

| Port | Transport | Used by |
| ---- | --------- | ------- |
| 1883 | plaintext | Itho ventilation add-on |
| 8883 | TLS       | Home Assistant, any future TLS-capable client |

Both listeners require authentication — `per_listener_settings` is left at its
default of `false`, so `allow_anonymous` and `password_file` are global rather
than per-listener.

Plaintext stays open because the Itho add-on cannot do TLS: its MQTT task is
built on a plain `WiFiClient`, and the firmware's `WiFiClientSecure` is reserved
for firmware update checks. Nothing on the broker side can change that.

There are no topic ACLs — every authenticated client may read and write any
topic. Adding an `acl_file` alongside `password_file` is the way to scope a
client to its own topic tree if that is ever wanted.

## Addressing

The broker sits in Cilium's `internal-pool` (`service.kubernetes.io/topology:
internal`), so it has a ULA and no globally routable address. That pool's IPv4
block is `10.18.6.40-69`, which is why the broker cannot keep an address from
the `external-pool` range while using a `fd00:1018:0:5:3000::` address — the
label selects the pool, and both families must come from it.

## DNS

The TLS certificate is issued for `mqtt.${CLUSTER_DOMAIN}`, but the UniFi
wildcard `*.${CLUSTER_DOMAIN}` points at the gateway, not at this broker's
LoadBalancer IP. A specific host record for `mqtt.${CLUSTER_DOMAIN}` → the
broker's LB IP is required, otherwise TLS clients reach the gateway and fail the
handshake.

## Credentials

Hashed passwords live in `app/mosquitto-secret.sops.yaml`. The secret carries
`kustomize.toolkit.fluxcd.io/substitute: disabled` because the `$7$` PBKDF2
markers in the hashes would otherwise be consumed by Flux's envsubst.

To add or rotate a user:

```bash
sops -d app/mosquitto-secret.sops.yaml | yq -r '.stringData.password_file' > /tmp/pw
docker run --rm -v /tmp:/w eclipse-mosquitto:2.0.22 mosquitto_passwd -b /w/pw <user> <password>
```

Then paste the result back into `stringData.password_file` and re-encrypt with
`sops --encrypt --in-place`. Stakater Reloader restarts the broker when either
the secret or the certificate changes, so no manual rollout is needed.

Mosquitto 2.0.22 warns that the password file is not owned by the `mosquitto`
user and that "future versions will refuse to load" it. Kubernetes always owns
projected secret files as `root:<fsGroup>`, so this cannot be fixed from here —
it is a constraint to watch when the image is bumped.

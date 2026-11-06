# dn42 DNS

DNS for [dn42](https://dn42.dev) (IPv6 only). Tracking: fmurodov/homeops-project#120.

| What | Where | Address |
|---|---|---|
| Recursive resolver (Unbound) | `resolver/` | `fd6d:cefe:ddc3:5:3000::53` (internal-pool) |
| Authoritative (Knot) | `authoritative/` | `fd6d:cefe:ddc3:5:4000::53` (dn42-pool, reachable from dn42) |
| Backup resolver (CoreDNS on rock64) | fmurodov/dn42 `rock64/` | `fd6d:cefe:ddc3:10::53` |

UniFi forwards `dn42` and `d.f.ip6.arpa` to the resolver and the rock64 backup. Cluster CoreDNS
forwards the same zones to the resolver.

## Resolver

- Full recursion from the dn42 delegation servers (`stub-zone` + `stub-prime`), no anycast forwarders.
- Answers only `dn42` and `d.f.ip6.arpa` (`local-zone: "." refuse`), only to `fc00::/7` and our GUA /48.
- Host network, port 1053 (the Service maps 53), so queries to dn42 leave from the node's
  `fd6d:cefe:ddc3:5::` address: rock64 only lets home dn42 prefixes in.
- Our own zones are stubbed straight to Knot.
- **DNSSEC upkeep:** the trust anchors in `resolver/app/configmap.yaml` are the registry `ds-rdata` on
  `data/dns/dn42` and `data/inet6num/fd00::_8` (KSK tags 64441 and 3096 in 2026-11). When the registry
  changes them, update the anchors, or every dn42 lookup fails with SERVFAIL. Check with
  `grep -h ds-rdata data/dns/dn42 'data/inet6num/fd00::_8'` in the registry clone.

## Authoritative

- Zones `fmurodov.dn42` and `3.c.d.d.e.f.e.c.d.6.d.f.ip6.arpa` (`fd6d:cefe:ddc3::/48`) in
  `authoritative/app/zones/`. Edit the files; Knot sets the serial (unixtime), no bump needed.
  Reloader restarts the pod on change.
- The Flux Kustomization has no `postBuild` substitution: it would eat `$ORIGIN` and `$TTL`.
- DNSSEC signed by Knot's default policy (ECDSA P-256, ZSK rolls automatically, KSK never). Keys
  are on the `dn42-authoritative` Longhorn PVC (backed up). Losing it means new KSKs and new
  `ds-rdata` in the registry.
- KSKs: `fmurodov.dn42` tag 64021, reverse zone tag 25631. Their DS are in the registry
  (`data/dns/fmurodov.dn42`, `data/inet6num/fd6d:cefe:ddc3::_48`). Print them with
  `kubectl -n dn42 exec deploy/dn42-authoritative -- keymgr -c /config/knot.conf <zone> ds`.
- No zone transfers, no recursion. One replica (RWO volume).

## Testing

UniFi content filtering on the LAN answers every port-53 query itself, so `dig @<our address>` from a
LAN client tests UniFi, not us. Test from the cluster or rock64:

```fish
kubectl -n dn42 run dnstest --rm -i --restart=Never --image=nicolaka/netshoot -- sh -c 'dig @fd6d:cefe:ddc3:5:3000::53 fmurodov.dn42 SOA +dnssec | grep flags; dig @fd6d:cefe:ddc3:5:4000::53 fmurodov.dn42 SOA +norec +short; dig @fd6d:cefe:ddc3:10::53 wiki.dn42 AAAA +short'
```

The first line should include `ad`. Plain `dig fmurodov.dn42` from the LAN tests the whole chain.

# Akvorado

NetFlow/IPFIX/sFlow collector and analytics console for the home network.

## Layout

Four Flux Kustomizations in the `akvorado` namespace, chained by `dependsOn`:

```
akvorado-kafka-app ─┐
                    ├─→ akvorado-orchestrator-app ─→ akvorado-services-app
akvorado-clickhouse-app ─┘
```

| Component | What it does |
| --- | --- |
| `kafka` | Single-node KRaft broker. Buffers raw datagrams between inlet and outlet. |
| `clickhouse` | Single-node flow store. Holds `flows` plus the 1m/5m/1h rollups. |
| `orchestrator` | Owns the Kafka topic, the ClickHouse schema, and the config the other three fetch over HTTP at startup. |
| `services` | `inlet` (receives UDP), `outlet` (decodes, enriches, writes to ClickHouse), `console` (web UI), `oauth2-proxy`. |

Kafka is not optional — the inlet only ever writes to it, and the outlet only
ever reads from it. Everything else is deliberately single-replica: no Kafka
cluster, no ClickHouse Keeper, no replicated tables, no Redis (the console's
cache backend defaults to in-memory).

All service configuration lives in one place: the `akvorado-config` ConfigMap in
[orchestrator/app/configmap.yaml](orchestrator/app/configmap.yaml). The inlet,
outlet and console have no config of their own.

The SNMP community is the one thing that does not belong in a ConfigMap, so it
lives in `akvorado-snmp-secret` and is pulled in with a YAML `!include`. That
include resolves relative to the config file, which is why the orchestrator
mounts a *projected* volume — it is the only way to surface a ConfigMap key and
a Secret key in the same directory.

## Addresses

- Console: `https://akvorado.${CLUSTER_DOMAIN}` (behind oauth2-proxy / Pocket ID)
- Collector: `10.18.6.41`, UDP 2055 (NetFlow v9), 4739 (IPFIX), 6343 (sFlow)

The Service requests `fd00:1018:0:5:3000::41` as well, but `internal-pool` hands
out no IPv6 today, so in practice the collector is v4-only — same as the
victoria-logs syslog Service. UniFi's collector field takes an IPv4 address
anyway.

Akvorado identifies exporters by source address, so the Service pairs
`externalTrafficPolicy: Cluster` with `service.cilium.io/forwarding-mode: dsr`.
Cilium's L2 announcer does not follow the backend node, so `Local` would
blackhole traffic whenever the lease landed on a node without the inlet pod;
DSR is what preserves the gateway's address instead.

## Enrichment

**Metadata** comes from SNMP against the gateway (`ClassifyExternal` on the
PPPoE and WireGuard interfaces, everything else internal). The gateway's
interfaces are effectively static, so a cached entry is only re-polled once a
day and the cache is persisted across restarts: SNMP has to be down a long time
before any flow is dropped for missing metadata.

The classifier matches the WAN on either `Interface.Name` or
`Interface.Description` being `ppp0`, because UniFi copies interface names into
`ifAlias` and Akvorado only exposes `ifAlias` as the description when it differs
from `ifName`. Whichever way round the gateway reports it, one branch matches.

**Networks** map all seven VLANs to a name and a role, IPv4 and IPv6, so
`SrcNetName`/`DstNetRole` are populated. The IPv6 entries are built from
`${IPV6_PREFIX_GUA}`, which is the site **/48** — `:5` is the SRV VLAN the
cluster nodes live on.

**GeoIP** fills `SrcAS`/`DstAS` and `SrcCountry`/`DstCountry`. A `geoipupdate`
sidecar in the outlet pod pulls GeoLite2-ASN and GeoLite2-Country from MaxMind
into a shared `emptyDir` every 72 hours, and the outlet reloads them through
fsnotify without restarting. Credentials live in `akvorado-geoip-secret`.

It is a plain sidecar rather than an init container on purpose: bad or missing
MaxMind credentials degrade to no geo data instead of stopping the outlet from
consuming flows. The databases are a cache, so they are re-fetched on every pod
restart rather than kept on a volume.

`SrcGeoCity` and `SrcGeoState` stay empty: they need GeoLite2-City, which is a
deliberate trade. Akvorado loads the whole database into a prefix trie, and
measured on this stack that costs **1.85 GiB** resident against **579 MiB** for
Country — 3 GiB during a refresh, when the old and new tries briefly coexist.
Country-only fits in a 2 GiB limit with room to spare. Swapping back means
changing `GEOIPUPDATE_EDITION_IDS`, the `geo-database` path, the memory limit
and `GOMEMLIMIT` together.

`GOMEMLIMIT` is not optional here. Go does not return freed heap to the OS
promptly, so without a ceiling each refresh ratchets RSS up until the pod is
OOMKilled — which is exactly how this was found.

## Retention

All four resolutions are kept for **1 year** (`8760h`). One year of high-fidelity
flows is worth more here than five years of a 1:512 sample, and both cost about
the same volume — so the storage budget goes into [sampling](#capturing-more)
instead of into time.

Akvorado derives the ClickHouse partition interval from the TTL (TTL/50), so this
also widens partitions from 3.4 hours to ~7 days. The rollups no longer earn
their place on retention — they all expire together now — but they still decide
how fast a year-wide query answers, so they stay.

> [!WARNING]
> Changing a resolution's TTL changes the partition key, and Akvorado's migration
> recreates the table rather than rewriting it. Existing flows are lost. That is
> cheap to do early and expensive to do late.

## Before this can reconcile

Point the gateway at the collector: UniFi Network → Settings → CyberSecure →
Traffic Logging → NetFlow (IPFIX), collector `10.18.6.41`, port 4739.

SNMP must stay enabled on the gateway (v2c, community `public`) or the outlet
drops every flow once the metadata cache expires.

Put a MaxMind account id and license key into `akvorado-geoip-secret`
(`sops kubernetes/apps/talos1018/akvorado/services/app/akvorado-geoip-secret.sops.yaml`).
A free GeoLite2 account is enough. Without them the stack still collects flows,
just with no AS or geo columns.

## Sampling

The gateway samples. UniFi Network → Settings → CyberSecure → Traffic Logging:

| Setting | Value |
| --- | --- |
| NetFlow (IPFIX) | enabled on all 7 networks |
| Version | 10 (IPFIX) |
| **Sampling Mode** | **Hash** |
| **Sampling Rate** | **512** |
| Timeout Rate | 5 minutes |
| Refresh Rate | 20 packets |

**The rate is never advertised in the export** — every record arrives with
`SamplingRate = 1`, so Akvorado reports raw counts and understates every byte and
packet figure by roughly 512x. Measured against UniFi's own counters the gap is
~1000x, the right order of magnitude for a 512 rate.

`core.default-sampling-rate: 512` corrects the aggregates. Verify the export is
still not advertising a rate before relying on it:

```bash
kubectl -n akvorado exec deploy/akvorado-clickhouse -- clickhouse-client --query "SELECT DISTINCT SamplingRate FROM flows"
```

If that ever returns something other than 1, UniFi has started advertising and
`default-sampling-rate` is unused.

### Hash mode selects whole flows, not packets

This is the part that bites. In **Hash** mode the selector runs over
flow-invariant header fields, so every packet of a 5-tuple hashes the same way:
a flow is either exported in full or missing entirely. It is not a 1-in-512
sample of each flow's packets.

Measured with four controlled downloads through `ppp0`, varying rate (1.6 to
119 Mbps), duration (7s to 120s), destination AS and protocol:

| Test | Size | Rate | Duration | Records |
| --- | --- | --- | --- | --- |
| A | 100 MiB | 119 Mbps | 7.1s | 0 |
| B | 20 MiB | 12 Mbps | 13.7s | 0 |
| C | 24 MiB | 1.6 Mbps | 120.1s | 0 |
| D | 25 MiB | 25 Mbps | 8.2s | 0 |

168 MiB, ~120k packets, **zero records**. Per-packet sampling at 1:512 would
have produced ~235. Four independent flows each missing is exactly what hash
selection predicts — `(511/512)^4` is 99.2%.

The consequences are worth being explicit about:

- **Aggregate totals are sound** once multiplied by 512, because they average
  over a very large number of flows.
- **Anything scoped to one host, one session or one short window is not.** That
  traffic is present at full weight or absent entirely, on a 1-in-512 coin flip.
- It also explains the **zero inter-VLAN records** despite all 7 networks being
  selected for export. Inter-VLAN traffic covers few distinct 5-tuples here, so
  the expected count at 1:512 rounds to zero. No need to reach for hardware
  offload as an explanation.
- **92% of all records are NTP** — the public [chrony](../network/chrony) service
  on `10.18.6.13`, whose enormous count of distinct 5-tuples means it survives
  sampling far better than anything else on the network does.

### Capturing more

This is a home network. The inlet receives 0.078 packets/s and drops nothing, so
1:512 is buying headroom nobody needs. Two independent knobs:

- **Sampling Mode → Random** makes selection per-packet, so large flows are
  represented proportionally and `default-sampling-rate` becomes valid per-flow
  rather than only in aggregate. Strictly better here, and free.
- **Sampling Rate → lower** trades storage for fidelity, close to linearly. Raw
  flows currently grow at ~1.4 MB/day at 1:512, so for the 1 year of
  [retention](#retention) above, against a 30 GiB volume:

| Rate | Raw growth | 1y raw | Share of volume |
| --- | --- | --- | --- |
| 512 (current) | ~1.4 MB/day | ~0.5 GiB | 2% |
| 64 | ~11 MB/day | ~4 GiB | 13% |
| **16** | **~45 MB/day** | **~16 GiB** | **55%** |
| 4 | ~180 MB/day | ~64 GiB | does not fit |
| 1 | ~717 MB/day | ~256 GiB | does not fit |

**1:16 in Random mode** is the intended setting: it fits a year with room for
rollups and ClickHouse merge headroom, and a 1 MB transfer lands ~45 samples
instead of a coin flip. 1:32 halves the storage if the volume feels tight; full
capture at 1:1 would need ~256 GiB and is not on the table without growing the
PVC by an order of magnitude.

`core.default-sampling-rate` must be changed in step with the UniFi setting —
they are two halves of the same number, and a mismatch silently scales every
byte figure.

## Troubleshooting

Flows arriving but not showing up is almost always the outlet dropping them for
missing metadata, or the schema version having moved on (the Kafka topic is
named `flows-v5`, and the number changes on incompatible schema changes):

```bash
kubectl -n akvorado logs deploy/akvorado-outlet
kubectl -n akvorado exec deploy/akvorado-clickhouse -- clickhouse-client --query "SELECT count() FROM flows"
```

Nothing arriving at all is usually the exporter or the LoadBalancer path. The
akvorado image ships no shell utilities, so reach the metrics endpoint from
outside the container:

```bash
kubectl -n akvorado port-forward deploy/akvorado-inlet 8080:8080
```

```bash
curl -s http://127.0.0.1:8080/api/v0/metrics | grep flow_input_udp
```

To check what SNMP resolved, and confirm the boundary split is right:

```bash
kubectl -n akvorado exec deploy/akvorado-clickhouse -- clickhouse-client --query "SELECT DISTINCT ExporterName, InIfName, InIfDescription, InIfBoundary, InIfConnectivity FROM flows"
```

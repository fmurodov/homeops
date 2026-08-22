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

## Before this can reconcile

Point the gateway at the collector: UniFi Network → Settings → CyberSecure →
Traffic Logging → NetFlow (IPFIX), collector `10.18.6.41`, port 4739.

SNMP must stay enabled on the gateway (v2c, community `public`) or the outlet
drops every flow once the metadata cache expires.

Put a MaxMind account id and license key into `akvorado-geoip-secret`
(`sops kubernetes/apps/talos1018/akvorado/services/app/akvorado-geoip-secret.sops.yaml`).
A free GeoLite2 account is enough. Without them the stack still collects flows,
just with no AS or geo columns.

## Calibrate the sampling rate

`core.default-sampling-rate` is `1`, which reports raw counts. It is only used
when the exporter does not advertise a rate of its own. UniFi describes its
export as *sampled*, so check what actually arrives:

```bash
kubectl -n akvorado exec deploy/akvorado-clickhouse -- clickhouse-client --query "SELECT DISTINCT SamplingRate FROM flows"
```

If that returns something other than 1, UniFi is advertising its rate and the
setting is unused — nothing to do. If it returns 1, compare Akvorado's
throughput against the UniFi dashboard for the same window and set
`default-sampling-rate` to the ratio. Getting this wrong scales every byte and
packet figure by a constant.

## Troubleshooting

Flows arriving but not showing up is almost always the outlet dropping them for
missing metadata, or the schema version having moved on (the Kafka topic is
named `flows-v5`, and the number changes on incompatible schema changes):

```bash
kubectl -n akvorado logs deploy/akvorado-outlet
kubectl -n akvorado exec deploy/akvorado-clickhouse -- clickhouse-client --query "SELECT count() FROM flows"
```

Nothing arriving at all is usually the exporter or the LoadBalancer path:

```bash
kubectl -n akvorado exec deploy/akvorado-inlet -- wget -qO- http://localhost:8080/api/v0/metrics | grep flow_input_udp
```

To check what SNMP resolved, and confirm the boundary split is right:

```bash
kubectl -n akvorado exec deploy/akvorado-clickhouse -- clickhouse-client --query "SELECT DISTINCT ExporterName, InIfName, InIfDescription, InIfBoundary, InIfConnectivity FROM flows"
```

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
outlet and console have no config of their own — they fetch it from the
orchestrator over HTTP **once, at startup**.

That last detail is a trap. Only the orchestrator mounts the ConfigMap, so
`reloader.stakater.com/auto` restarts only the orchestrator when the config
changes, and the other three keep serving the previous settings indefinitely. The
orchestrator visibly restarting is what makes the change look applied. All three
therefore name the ConfigMap explicitly:

```yaml
configmap.reloader.stakater.com/reload: "akvorado-config"
```

Reloader restarts all four at once, so a service can in principle come back
before the new orchestrator does and read the old config again. After changing
anything that shows up in the data, confirm it in the data rather than in the
ConfigMap — see [Sampling](#sampling) for the `SamplingRate` query.

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
the same volume — so the storage budget goes into [sampling](#sampling) instead of
into time. See [what it costs](#what-it-costs) for what that works out to at the
sampling rate actually in use.

Akvorado sizes the ClickHouse partition interval from the TTL (TTL/50), aiming at
~50 partitions per table. The rollups no longer earn their place on retention —
they all expire together now — but they still decide how fast a year-wide query
answers, so they stay.

**Changing a TTL does not lose data.** Akvorado issues `ALTER TABLE ... MODIFY
TTL` and logs `raw flows table already exists, skip migration`; every row
survives. Verified on `2026.8.0` when these four TTLs were raised.

> [!WARNING]
> `ALTER` cannot change `PARTITION BY`, so a TTL change leaves **the partition
> key derived from the old TTL**, and nothing warns you. After the raise to
> `8760h` the tables kept their 3.36h / 14.4h / 43.2h intervals (old TTL / 50)
> against the 7.3 days the new TTL implies — `flows` was heading for ~2,600
> partitions instead of ~50, invisibly, until the year filled.
>
> Check it after any TTL change: `SHOW CREATE TABLE flows`, and compare
> `toIntervalSecond(N)` against the new TTL divided by 50.

All four tables were dropped and rebuilt on 2026-08-22 to pick up the correct
key, so they now partition at 7.3 days and expire at 1 year — 50 partitions each.
The stored history went with them, which was cheap at 20 hours and would not have
been later; it also spanned three sampling regimes, so it was not worth keeping.

Rebuilding is the one operation here that does lose flows, and the order matters.
`flows` is the hub: the three rollup consumers and `exporters_consumer` read from
it, while `flows_<schemahash>_raw_consumer` writes into it from a `Null`-engine
table. **Drop the materialized views before the tables**, keep the five
dictionaries, then restart the orchestrator — its migration is existence-based,
so it recreates whatever is missing.

Scale the outlet to zero first and back up afterwards. Kafka keeps buffering and
the consumer-group offset survives, so no live flows are lost across the window —
only the already-stored history. Expect transient `cannot open geo database`
afterwards: the GeoIP databases sit in an `emptyDir` and are re-fetched on every
pod start. Confirm recovery with `countIf(SrcAS != 0)` rather than by listing the
directory — the outlet image is distroless and has no `ls`.

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
| **Sampling Mode** | **Random** |
| **Sampling Rate** | **16** |
| Timeout Rate | 5 minutes |
| Refresh Rate | 20 packets |

**The rate is never advertised in the export** — every record arrives with
`SamplingRate = 1`, in Random mode exactly as in Hash. Left uncorrected, Akvorado
reports raw counts and understates every byte and packet figure by 16x.

`core.default-sampling-rate: 16` supplies the missing number. It and the UniFi setting
are two halves of the same value: change one without the other and every byte figure
is silently scaled by the ratio. Verify the export still advertises nothing:

```bash
kubectl -n akvorado exec deploy/akvorado-clickhouse -- clickhouse-client --query "SELECT DISTINCT SamplingRate FROM flows"
```

If that ever returns something other than 1, UniFi has started advertising its own
rate and `default-sampling-rate` is unused.

### Why Random, and why 16

The gateway ran **Hash at 1:512** until 2026-08-22. Both halves of that were wrong for
this network.

In **Hash** mode the selector runs over flow-invariant header fields, so every packet
of a 5-tuple hashes the same way: a flow is either exported in full or missing
entirely. It is not a 1-in-512 sample of each flow's packets. Measured with four
controlled downloads through `ppp0`, varying rate (1.6 to 119 Mbps), duration (7s to
120s), destination AS and protocol:

| Test | Size | Rate | Duration | Records |
| --- | --- | --- | --- | --- |
| A | 100 MiB | 119 Mbps | 7.1s | 0 |
| B | 20 MiB | 12 Mbps | 13.7s | 0 |
| C | 24 MiB | 1.6 Mbps | 120.1s | 0 |
| D | 25 MiB | 25 Mbps | 8.2s | 0 |

168 MiB, ~120k packets, **zero records**. Per-packet sampling at 1:512 would have
produced ~235. Four independent flows each missing is exactly what hash selection
predicts — `(511/512)^4` is 99.2%.

That distortion reached every view the console offered. Aggregate totals were sound
once scaled, because they average over very many flows, but anything scoped to one
host, one session or one short window was present at full weight or absent entirely on
a 1-in-512 coin flip. It was also the whole explanation for two long-standing
puzzles: **zero inter-VLAN records** despite all 7 networks being selected for export
(inter-VLAN traffic covers few distinct 5-tuples here, so the expected count rounded to
zero — no hardware offload needed as an explanation), and **92% of all records being
NTP**, the public [chrony](../network/chrony) service on `10.18.6.13`, whose enormous
count of distinct 5-tuples let it survive hash selection far better than anything else.

**Random** fixes the mode: selection becomes per-packet, large flows are represented
proportionally, and `default-sampling-rate` is valid per-flow rather than only in
aggregate. **1:16** then buys back fidelity that was never being spent on anything —
the inlet receives 0.078 packets/s and drops nothing, so 1:512 was reserving headroom
this network has no use for. A 1 MB transfer now lands ~45 samples instead of a coin
flip.

### What it costs

Measured on the live stack across the 2026-08-22 switchover:

| | Hash 1:512 | Random 1:16 |
| --- | --- | --- |
| Flow records | 86/min | 3,284/min |
| `flows` on disk | ~13 bytes/row | ~13 bytes/row |

**38x more records, not the 32x the rate change alone implies** — Random also picks up
the flows Hash was discarding wholesale. Against a **30 GiB** volume, and allowing for
the overnight lull (the Hash-era daily average ran ~11% below its midday rate):

| | Raw | With the three rollups |
| --- | --- | --- |
| Per day | ~55 MB | ~75 MB |
| 1 year of [retention](#retention) | ~19 GiB | **~25 GiB** |

> [!WARNING]
> That is ~84% of the volume, and ClickHouse wants free space to merge into. 1:16 and
> a 1-year TTL on all four resolutions fit, but with little margin for traffic growth.
> If it turns out too tight, the levers are 1:32 (roughly halves it), a shorter TTL on
> the raw table with the rollups kept long, or a larger PVC — and the first two are
> much cheaper decided early, per the TTL warning above.

For reference, raw growth scales close to linearly with the rate: ~1.4 MB/day at
1:512, ~11 MB/day at 1:64, ~55 MB/day at 1:16, and ~717 MB/day at 1:1 — full capture
would need ~256 GiB for a year and is not on the table without growing the PVC by an
order of magnitude.

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

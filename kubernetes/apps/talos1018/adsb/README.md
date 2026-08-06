# ADSB / Flight Tracking

Star-topology ADS-B feeder stack: one external SDR receiver feeds `readsb`,
which re-broadcasts in-cluster to four aggregator feeders plus a local map/API.

```
[External SDR feeder, address in adsb-config secret's EXTERNAL_BEASTHOST]
                │ Beast protocol :30005
                ▼
        readsb (ultrafeeder image)
          - decodes Beast, serves tar1090 map + graphs1090 stats + /metrics on :80
          - serves REAPI JSON on :30152
          - re-broadcasts Beast on :30005 (readsb.adsb.svc.cluster.local)
          - self-feeds adsb.fi / planespotters.net / adsb.lol directly
                │
    ┌───────┬───┴────┬────────────┬──────────────┐
    ▼       ▼         ▼            ▼              ▼
piaware  flightradar24  radarbox  adsbexchange  planefinder
   (all BEASTHOST=readsb.adsb.svc.cluster.local)

 readsb :30152 (REAPI) ──► adsb-api (self-hosted adsblol/api)
                              │ caches via redis:6379
                              ▼
                        exposes /api/0/routeset
                              ▲
 readsb's TAR1090_ROUTEAPIURL─┘ (tar1090 UI route overlay)
```

## Apps

| App | Purpose | Web UI |
|---|---|---|
| `readsb` | Decodes Beast from the external SDR, serves tar1090/graphs1090, re-broadcasts in-cluster | `readsb.${CLUSTER_DOMAIN}` |
| `planefinder` | Feeds Plane Finder | `planefinder.${CLUSTER_DOMAIN}` |
| `piaware` | Feeds FlightAware | `piaware.${CLUSTER_DOMAIN}` |
| `flightradar24` | Feeds FlightRadar24 | `fr24.${CLUSTER_DOMAIN}` |
| `radarbox` | Feeds RadarBox | – |
| `adsbexchange` | Feeds ADSBExchange | – |
| `redis` | Cache for `adsb-api` | – |
| `adsb-api` | Self-hosted `adsblol/api` clone, backs tar1090's route overlay | `adsb-api.${CLUSTER_DOMAIN}` |

## Secrets

`adsb-config-secret.sops.yaml` sits at the category root next to
`namespace.yaml` (same pattern as `ai/ocirepository.yaml` and
`self-hosted/ocirepository.yaml` — a shared resource with no deployment of
its own, applied directly by the top-level `apps` Flux Kustomization rather
than wrapped in its own `ks.yaml`). It holds fields shared by multiple
feeders: `EXTERNAL_BEASTHOST` (the external SDR's address, read only by
`readsb` — deliberately not named `BEASTHOST` to avoid confusion with the
`BEASTHOST` env var every other feeder sets to the in-cluster address),
`FEEDER_SITENAME`, `FEEDER_LAT`, `FEEDER_LONG`, `FEEDER_ALT`, `FEEDER_TZ`,
`FEEDER_UUID`. Apps needing it reference it via `secretKeyRef`, never
`envFrom`.

Per-app credentials that only one feeder needs live in that app's own
secret instead of the shared one: `piaware-config` (`PIAWARE_FEEDER_ID`),
`planefinder-config` (`PLANEFINDER_SHARECODE`), `flightradar24-config`
(`FR24_SHARING_KEY`), `radarbox-config` (`RADARBOX_SHARING_KEY`).
`adsbexchange` has no unique credential.

## Notes

- All five feeders other than `readsb` itself hardcode
  `BEASTHOST=readsb.adsb.svc.cluster.local` as an explicit env var so they
  pull from the in-cluster re-broadcast instead of hammering the external
  SDR directly (env always wins over the same key from a Secret).
- `readsb-data` (globe_history + graphs1090 stats) carries Longhorn
  `recurring-job.longhorn.io` backup labels and is covered by the cluster's
  `daily-backup` RecurringJob. `redis-data` is a disposable cache and isn't
  backed up.

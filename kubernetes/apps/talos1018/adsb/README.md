# ADSB / Flight Tracking

Star-topology ADS-B feeder stack: one external SDR receiver feeds `readsb`,
which re-broadcasts in-cluster to the other feeders plus a local map/API.

```
[External SDR] ─Beast:30005─► readsb ─┬─► piaware / flightradar24 / radarbox / adsbexchange / planefinder
                                       │     (BEASTHOST=readsb)
                                       ├─► adsb-api (REAPI :30152, cached via redis)
                                       │     used by readsb's tar1090 route overlay
                                       └─► skystats (aircraft.json :80 → skystats-db)
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
| `adsb-api` | Self-hosted `adsblol/api` clone; backs tar1090's route overlay and [ESP32-Plane-Radar](https://github.com/fmurodov/ESP32-Plane-Radar) | `adsb-api.${CLUSTER_DOMAIN}` |
| `skystats` | Aircraft stats dashboard ([tomcarman/skystats](https://github.com/tomcarman/skystats)) | `skystats.${CLUSTER_DOMAIN}` |

## Secrets

`adsb-config-secret.sops.yaml` (category root) holds fields shared across
feeders: `EXTERNAL_BEASTHOST`, `FEEDER_SITENAME`, `FEEDER_LAT`,
`FEEDER_LONG`, `FEEDER_ALT`, `FEEDER_TZ`, `FEEDER_UUID`.

Per-app credentials live in that app's own secret: `piaware-config`,
`planefinder-config`, `flightradar24-config`, `radarbox-config`,
`skystats-secret`. `adsbexchange` has none.

## Notes

- Feeders reference `readsb` by short name, not FQDN — everything here
  shares the `adsb` namespace.
- `readsb-data` and `skystats-db-data` carry Longhorn daily-backup labels;
  `redis-data` doesn't (disposable cache).

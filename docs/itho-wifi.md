# Itho Wi-Fi Add-ons

The three NRGwatch non-CVE Wi-Fi add-ons on the Itho Daalderop ventilation, heat pump and
floor heating, and how they reach Home Assistant.

## Table of Contents

- [Modules](#modules)
- [Home Assistant](#home-assistant)
- [Device Parameters Changed from Default](#device-parameters-changed-from-default)
- [Reading and Writing Device Settings](#reading-and-writing-device-settings)

## Modules

All three run add-on firmware 3.2.0 (stable channel) and publish to the cluster broker over
plaintext MQTT on port 1883. The add-on cannot do TLS; see the
[mosquitto README](../kubernetes/apps/talos1018/home-automation/mosquitto/README.md).

| Hostname | Connected to | Device fw | Broker user | Base topic |
| -------- | ------------ | --------- | ----------- | ---------- |
| `itho-hru` | HRU ECO 300 ventilation | — | `ithohru` | `ithohru` |
| `itho-wpu` | WPU 45KC-5G heat pump | 37 | `itho-wpu` | `ithowpu` |
| `itho-autotemp` | Autotemp Spider floor heating controller | 10 | `itho-autotemp` | `ithotemp` |

Home Assistant MQTT Discovery is **off** on every module — the `ithodaalderop` integration
creates the entities instead. API and web authentication are on; turn API auth off
temporarily only when reading device settings over the REST API.

The broker user names must match exactly (`itho-wpu` with the hyphen; `ithowpu` is
refused), and their hashes must be generated with the broker's own mosquitto version.

## Home Assistant

One `ithodaalderop` (haithowifi) config entry per module, all with entity creation mode
**all** — entities outside the integration's default selection are created disabled and
enabled by hand.

### Autotemp rooms

The Autotemp entry names its rooms in the setup and reconfigure flows. Three rooms are in
use, each on its own `Spider <room>` device assigned to the matching area:

| Autotemp room | Name in the entry | Area |
| ------------- | ----------------- | ---- |
| 1 | `living_room` (main thermostat) | Living Room |
| 2 | `kids_room` | Kids room |
| 3 | `bedroom` | Bedroom |

Things the integration does that are easy to trip over:

- Spaces in a room name are replaced with `_`, and a name of exactly `Room_<n>` is treated
  as unset. The flow's own defaults (`Room 1`…`Room 8`) therefore create **no** room
  entities. Use names without spaces.
- Only rooms 1–7 are ever created; room 8 is skipped by an off-by-one in the integration.
- Room entity unique IDs include the room name, so renaming a room creates new entities
  and devices. The integration does not support device removal, so the old devices can
  only be disabled, not deleted.

## Device Parameters Changed from Default

These live in the heat pump and the Autotemp, not in the add-ons, so formatting or
swapping a module does not touch them.

| Device | # | Label | Default | Now | Changed |
| ------ | - | ----- | ------- | --- | ------- |
| Autotemp (fw 10) | 59 | Minimum outdoor temperature enable cooling (°C) | 10 | 16 | 2026-10-27 |
| WPU 45KC (fw 37) | 220 | Minimum outside temp cooling (°C) | 10 | 16 | 2026-10-27 |

### Why

Cooling cannot be switched off on a WPU system — in summer it regenerates the ground
source — and the living room Spider decides heating or cooling for the whole house. With
the defaults, both heating (below 15 °C outside) and cooling (above 10 °C) were allowed
between 10 and 15 °C, so on a 13 °C autumn day with rooms just above their 21 °C setpoint
the system cooled the floors. Raising both cooling limits to 16 °C (the Autotemp's
maximum) means it only heats, or idles, below 16 °C outside, while summer cooling still
works.

A change does not interrupt a cooling run already in progress; it applies the next time
the Autotemp chooses between heating and cooling. Putting the living room Spider on
Stand-by and back to Automatic forces that choice.

Other cooling-related settings that were reviewed and left at default:

| Device | # | Label | Value |
| ------ | - | ----- | ----- |
| WPU | 152 | Blocking time heating to cooling (h) | 24 |
| WPU | 229 | Blocking time cooling to heating (h) | 12 |
| WPU | 217 | Cooling control | 0 |
| Autotemp | 44 | Offset cooling (K) | 1 |
| Autotemp | 62 | Max outdoor temperature enable heating (°C) | 15 |
| Autotemp | 64 | Heating/cooling | 0 |

## Reading and Writing Device Settings

The setting numbers above are positions in the add-on's per-firmware settings table, not
the device's own parameter numbers. They come from the add-on firmware source
([`ithodevice/devices/wpu.h`, `autotemp.h`](https://github.com/arjenhiemstra/ithowifi/tree/master/software/NRG_itho_wifi/main/ithodevice/devices)),
selected by the device firmware version that `/api/v2/deviceinfo` reports — after a
device firmware update, check the mapping again before trusting a number.

With API auth temporarily off, read a setting (label, current value and range):

```bash
curl -s "http://itho-autotemp.local/api/v2/settings?index=59"
```

The live status, including whether the Autotemp is heating or cooling:

```bash
curl -s "http://itho-autotemp.local/api/v2/ithostatus"
```

Write a setting through the add-on's web UI (Itho settings) rather than the API, so the
change is visible and confirmed on the module itself.

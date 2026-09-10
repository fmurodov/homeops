# Thread Dongle (Sonoff Dongle-PMG24)

Recovering and reflashing the Thread radios used by the `otbr` border routers, without
physical access to the node.

## Table of Contents

- [Power Cycling the Dongle Remotely](#power-cycling-the-dongle-remotely)
- [Reflashing the Firmware](#reflashing-the-firmware)
- [Reading the Failure Mode](#reading-the-failure-mode)
- [Is a Device Really Off the Network?](#is-a-device-really-off-the-network)

## Power Cycling the Dongle Remotely

### Problem

The radio MCU is wedged and `otbr-agent` cannot reach it. Restarting the pod does not help,
because reopening the serial port does not reset the MG24.

### Solution

Disabling the USB port drops VBUS, which is equivalent to unplugging the dongle. Any
privileged pod on the node with host `/sys` mounted read-write can do it — on this cluster
the Longhorn CSI plugin qualifies, so no new pod is needed:

```bash
kubectl exec -n longhorn-system <longhorn-csi-plugin-pod> -c longhorn-csi-plugin -- sh -c 'echo 1 > /sys/bus/usb/devices/usb1/1-0:1.0/usb1-port1/disable; sleep 5; echo 0 > /sys/bus/usb/devices/usb1/1-0:1.0/usb1-port1/disable'
```

Confirm the power cycle actually happened — the device number must change, which proves
VBUS dropped rather than the port being disabled logically:

```bash
talosctl -n <node> dmesg | grep -iE "usb 1-1|cp210"
```

`usb 1-1: USB disconnect, device number 2` followed by `new full-speed USB device number 3`
is a real power cycle. A node reboot is **not** a substitute: the default Talos reboot
kexecs and never re-initialises USB, and even `--mode=powercycle` usually leaves VBUS up.

Verify the port path maps to the dongle before writing to it, since the number varies per
machine:

```bash
talosctl -n <node> read /sys/bus/usb/devices/1-1/product
```

## Reflashing the Firmware

Needed when the MG24 stops responding entirely and a power cycle does not recover it.

### Free the device

The flasher needs exclusive access to the serial port, and Flux would otherwise scale the
border router straight back up:

```bash
flux suspend kustomization otbr-app
flux suspend helmrelease otbr -n home-automation
kubectl scale deploy -n home-automation otbr-otbr-3 --replicas=0
```

### Option A — universal-silabs-flasher (CLI)

NabuCasa's flasher, the same tool Home Assistant uses for its own radios. Run a throwaway
`python:3.13` pod, privileged, pinned to the node with `nodeName`, with `/dev/thread0`
mounted from the host at the same path. Inside it:

```bash
pip install universal-silabs-flasher
curl -sL -o /tmp/pmg24-ot-rcp.gbl https://github.com/iHost-Open-Source-Project/hassio-ihost-sonoff-dongle-flasher/raw/main/firmware-build/donglepmg24_mg24_openthread_stable_2.4.4_460800.gbl
universal-silabs-flasher --device /dev/thread0 --bootloader-reset rts_dtr flash --firmware /tmp/pmg24-ot-rcp.gbl
```

`--bootloader-reset rts_dtr` is **required** on this board. Without it the tool probes every
application type at every baud rate, reaches nothing, and reports
`Failed to probe running application type` — which looks exactly like dead hardware. With
it, the Gecko bootloader answers at 115200. `baudrate` also works as a reset method;
`slzb07` does not.

You choose the firmware file here, so provenance is on you.

### Option B — SONOFF Dongle Flasher (official, web UI)

Sonoff ship their flasher as a container as well as a Home Assistant add-on, so it does not
need the dongle plugged into the machine running the browser — it reaches the host's USB
directly. It picks the firmware itself, which is the safer choice when the image matters.

Run `ewelink/sonoff-dongle-flasher` as a pod on the node, privileged, with hostPath mounts
for `/dev` and `/run/udev` (read-only, for automatic dongle detection), then reach the UI:

```bash
kubectl port-forward -n home-automation pod/dongle-flasher 8324:8324
```

Open <http://localhost:8324>, pick the dongle and the OpenThread RCP firmware. Without the
udev mount the port can still be selected by hand.

### Restore

Scale back up explicitly. Resuming Flux does **not** do it: helm-controller skips
releases whose chart and values have not changed, so the HelmRelease goes green
while the deployment stays at zero replicas.

```bash
kubectl delete pod -n home-automation dongle-flasher
kubectl scale deploy -n home-automation otbr-otbr-3 --replicas=1
flux resume helmrelease otbr -n home-automation
flux resume kustomization otbr-app
```

A border router that has just rejoined sits at `state=child` with few neighbours.
That is normal — Thread promotes a REED to router only on demand, and the agent
still routes and publishes `_meshcop._udp` meanwhile. To promote it, ask it
directly rather than restarting another border router to force an election:

```bash
kubectl exec -n home-automation <otbr-pod> -- ot-ctl state router
```

Its RLOC changes when it promotes, and the setting does not survive a restart.

## Reading the Failure Mode

The exit code distinguishes a recoverable wedge from a dead radio:

| Exit | Log line | Meaning |
|------|----------|---------|
| 6 | `HandleRcpTimeout` after running | RCP stopped answering mid-flight. Self-recovers on restart. Baseline is a handful per day. |
| 1 | `Init() at spinel_driver.cpp:87: Failure` at `00:00:00.000` | RCP never answered the initial handshake. Restarts will not fix it. |
| 0 | clean s6 shutdown | The container was killed from outside, e.g. by a liveness probe. |

Count them over time with:

```bash
# LogsQL, against VictoriaLogs
kubernetes_namespace_name:home-automation AND kubernetes_pod_name:otbr* AND _msg:"otbr-agent exited" _time:3d | stats by (_time:3h, _msg) count() n
```

The CP210x USB bridge is a separate chip from the MG24, so the dongle enumerating on USB
and `/dev/thread0` existing say nothing about whether the radio is alive.

## Is a Device Really Off the Network?

Pinging a device's address proves less than it looks: the OMR prefix is elected and
changes when border routers come and go, so a cached address goes stale and fails even
for a healthy device.

Ask SRP instead. Every attached Matter device registers an operational service, which the
border routers republish over mDNS as `<fabric-id>-<16-hex-node-id>._matter._tcp.local`.
Browse from a pod on the LAN — and **bind to the LAN interface explicitly**, because a pod
on `multus-macvlan2` also has `eth0`, and an unbound browse silently returns nothing:

```python
from zeroconf import Zeroconf, ServiceBrowser
zc = Zeroconf(interfaces=["<the pod's net1 global address>"])
ServiceBrowser(zc, "_matter._tcp.local.", listener)
```

No record means the device is not on the Thread network at all, and nothing done on the
controller will recover it — mains devices need a power cycle, battery ones a button press
to force an immediate re-attach. Border routers answer on `_meshcop._udp.local.` as
`OpenThread BorderRouter #XXXX`, where XXXX is the last four hex of `ot-ctl extaddr`.

Devices can also be knocked off by border router churn rather than poor signal: repeated
restarts reshuffle routing, and devices that lose their place during one may never rejoin.
Mains-powered, router-capable devices are not immune, so do not read a cluster of losses as
a coverage problem without checking the restart history first.

# Moving Longhorn to a dedicated partition, one node at a time

Longhorn's data used to live in `/var/lib/longhorn`, a directory on the
`EPHEMERAL` partition that also holds containerd's image store. Each node is
rebuilt so that `EPHEMERAL` is a fixed 100 GiB and Longhorn gets its own
partition (Talos `UserVolumeConfig longhorn`, mounted at `/var/mnt/longhorn`)
on the rest of the disk.

Why a rebuild: Talos only applies `VolumeConfig`/`UserVolumeConfig` when a
volume is provisioned, and Longhorn refuses a second disk on the same
filesystem, so the data can't move in place. Wiping `EPHEMERAL` drops the
partition; on reboot Talos recreates it at 100 GiB and creates the Longhorn
partition in the freed space. STATE (machine config, identity) is untouched.

Longhorn keeps its control files (`engine-binaries`, `metadata`, sockets,
logs) under `/var/lib/longhorn` whatever the data path is; that stays on
`EPHEMERAL` and is expected.

Data safety: one node at a time. While a node is rebuilt every 3-replica
volume keeps its 2 copies on the other nodes; the 2-replica volume is moved by
Longhorn eviction before its copy is removed. Never start a node until every
volume is back to `healthy`.

## Variables

Set these for the node being rebuilt (example: node 1).

```bash
NODE=talos-1018-1
IP=fd00:1018:0:5:10:18:6:91
PEER=fd00:1018:0:5:10:18:6:92        # any other control-plane node
```

## 0. Pre-flight

```bash
# every volume healthy (otbr-data-2 is detached and unused: ignore it)
kubectl -n longhorn-system get volumes.longhorn.io -o json \
  | jq -r '.items[] | select(.status.robustness!="healthy") | "\(.metadata.name) \(.status.state) \(.status.robustness)"'

# etcd: three healthy members
talosctl -n $PEER etcd members
talosctl -n $PEER etcd status

# no Talos/Kubernetes upgrade in flight; don't merge Renovate Talos PRs until done
kubectl get talosupgrades,kubernetesupgrades
```

Silence alerts for the window (Longhorn degraded volumes, node NotReady).

## 1. etcd snapshot

```bash
talosctl -n $PEER etcd snapshot ~/etcd-before-$NODE-$(date +%Y%m%d%H%M).db
```

## 2. Longhorn: stop using the node

```bash
kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
```

Volumes with fewer than 3 replicas move their copy off the node now. Wait
until none of them has a replica left on `$NODE` (3-replica volumes can't
move and stay; that's expected):

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg n $NODE '
  .items[] | select(.spec.nodeID==$n) | .spec.volumeName' | sort -u > /tmp/on-node
kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
  .items[] | select(.spec.numberOfReplicas < 3) | .metadata.name' | grep -xFf /tmp/on-node || echo "none left"
```

## 3. Drain

`kubectl drain` keeps the node cordoned and retries, so Longhorn can drop the
instance-manager's PodDisruptionBudget once the node's volumes are detached.

```bash
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=30m
```

When it finishes, the node's replicas are stopped and the 3-replica volumes
show `degraded` (2 of 3).

## 4. Longhorn: remove the node's replicas and its old disk

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o json \
  | jq -r --arg n $NODE '.items[] | select(.spec.nodeID==$n) | .metadata.name' \
  | xargs -r kubectl -n longhorn-system delete replicas.longhorn.io

kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type merge \
  -p '{"spec":{"evictionRequested":false}}'
DISK=$(kubectl -n longhorn-system get nodes.longhorn.io $NODE -o json | jq -r '.spec.disks | keys[0]')
kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/disks/$DISK/allowScheduling\",\"value\":false}]"
kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type json \
  -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$DISK\"}]"
kubectl -n longhorn-system get nodes.longhorn.io $NODE -o jsonpath='{.spec.disks}{"\n"}'   # expect {}
```

Every volume should now be `degraded` with 2 running replicas, none on `$NODE`.

## 5. Apply the node's Talos config

The node's patch file holds the `VolumeConfig EPHEMERAL` and
`UserVolumeConfig longhorn` documents. They're inert until the reset.

```bash
talos/talos1018/generate.sh
talosctl apply-config -n $IP --file talos/talos1018/clusterconfig/talos1018-$NODE.yaml --dry-run
talosctl apply-config -n $IP --file talos/talos1018/clusterconfig/talos1018-$NODE.yaml
```

The dry-run should show only the two volume documents added.

## 6. Reset EPHEMERAL

Graceful (the default): leaves etcd, then wipes and drops the partition and
reboots.

```bash
talosctl -n $IP reset --system-labels-to-wipe EPHEMERAL --reboot
```

## 7. Check the node came back right, then uncordon

```bash
talosctl -n $IP get volumestatus | grep -E 'EPHEMERAL|u-longhorn'   # both ready; ~100 GiB and ~360 GiB
talosctl -n $IP get mountstatus | grep -E 'EPHEMERAL|u-longhorn'
talosctl -n $PEER etcd members                          # three members again
kubectl get node $NODE                                   # Ready,SchedulingDisabled
```

Uncordon straight away. Longhorn never creates an instance-manager on a
cordoned node, and without one it can't read the new disk. Longhorn's own
`allowScheduling: false` (step 2) still keeps replicas off the node.

```bash
kubectl uncordon $NODE
kubectl -n longhorn-system get pods -o wide --field-selector spec.nodeName=$NODE   # instance-manager Running
```

## 8. Longhorn: check the new disk

The node keeps its `node.longhorn.io/create-default-disk` label, so Longhorn
recreates a default disk by itself at the default data path
(`/var/mnt/longhorn/`) with the default 5% reserve. Wait for it to be ready:

```bash
kubectl -n longhorn-system get nodes.longhorn.io $NODE -o json | jq -r '.status.diskStatus | to_entries[] |
  "\(.key) max=\(.value.storageMaximum/1073741824|floor)GiB uuid=\(.value.diskUUID)",
  (.value.conditions[] | "  \(.type)=\(.status) \(.reason)")'
talosctl -n $IP read /var/mnt/longhorn/longhorn-disk.cfg            # same diskUUID
```

Expect ~363 GiB, `Ready=True`, `Schedulable=True`.

If it shows `Ready=False DiskFilesystemChanged` ("record diskUUID doesn't
match the one on the disk"), the disk was created before the
instance-manager was up. On node 1 this happened because the node was still
cordoned. The partition is new and empty, so reset it: remove the disk entry,
delete the stray config file through the instance-manager, and let Longhorn
recreate it.

```bash
talosctl -n $IP usage /var/mnt/longhorn --depth 0 -H                # a few hundred bytes = empty
DISK=$(kubectl -n longhorn-system get nodes.longhorn.io $NODE -o json | jq -r '.spec.disks | keys[0]')
kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/disks/$DISK/allowScheduling\",\"value\":false}]"
kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type json \
  -p "[{\"op\":\"remove\",\"path\":\"/spec/disks/$DISK\"}]"
IM=$(kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager \
  --field-selector spec.nodeName=$NODE -o name)
kubectl -n longhorn-system exec $IM -- rm -f /host/var/mnt/longhorn/longhorn-disk.cfg
```

Longhorn re-adds the default disk within a few seconds; check again.

## 9. Enable scheduling and wait for the rebuild

```bash
kubectl -n longhorn-system patch nodes.longhorn.io $NODE --type merge -p '{"spec":{"allowScheduling":true}}'
watch -n 30 "kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '[.items[].status.robustness] | group_by(.) | map(\"\\(.[0])=\\(length)\") | join(\" \")'"
```

Done when every volume except the unused detached one is `healthy`. Then
check the node:

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o json \
  | jq -r --arg n $NODE '[.items[] | select(.spec.nodeID==$n)] | length'   # ~40
talosctl -n $IP usage /var/lib/containerd --depth 0 -H
```

Only then move on to the next node.

Node 1 (2026-10-16): drain 1.5 min, reset to node Ready ~10 min, partition
363.4 GiB.

## After all three nodes

- Move the two volume documents from the node patch files into
  `patches/controlplane.yaml`.
- Remove the kubelet `extraMounts` for `/var/lib/longhorn`, verify a volume
  attach, detach and replica rebuild, then move `machine.kubelet` to
  `KubeletConfig`.
- Revisit the kubelet image GC thresholds (they were lowered because
  containerd shared a filesystem with Longhorn).

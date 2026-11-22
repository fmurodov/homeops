# Disaster recovery runbook

Start with the row that matches what happened. Every procedure here only
**reads** backups: nothing writes to B2, and the drills never touch the
production volumes.

| What happened | Go to | Time it took in the last drill |
|---|---|---|
| One app lost or broke its data, the cluster is fine | [1. Restore a volume in the cluster](#1-restore-a-volume-in-the-cluster) | ~20 min per 7 GiB volume, then under 2 min to boot |
| The cluster is gone, I need the files | [2. Restore a volume without the cluster](#2-restore-a-volume-without-the-cluster) | ~7-8 min per 7 GiB volume on the Mac |
| etcd lost quorum, the control plane won't come back | [3. Restore etcd from a snapshot](#3-restore-etcd-from-a-snapshot) | ~25 s to download, decrypt and check the snapshot |
| Nothing is broken, it's drill time | [4. Quarterly drill](#4-quarterly-drill) | about 1 hour |

## What you need

- **age key**: Apple Passwords, entry with the `AGE-SECRET-KEY-...` for
  recipient `age1kesma5f5...`. It decrypts every `*.sops.yaml` in this repo
  (including the B2 keys) and the etcd snapshots.
- **etcd read key** `talos1018-etcd-ro`: Apple Passwords, next to the age key.
- **Backblaze account**: login in Apple Passwords, if a key was revoked.
- A Mac with `brew install sops age rclone jq lz4 e2fsprogs` and, for etcd,
  `brew install etcd` (for `etcdutl`). Docker Desktop to boot an app outside
  the cluster.
- For section 1, a working `kubectl` against the cluster.

Backups run every night at 00:00 UTC (Longhorn, PVCs labelled
`recurring-job.longhorn.io/daily-backup`, 10 kept) and 02:30 UTC (etcd).

## 1. Restore a volume in the cluster

Longhorn restores a backup into a **new** volume. The drill below does that in
a scratch namespace `dr-drill`, with all traffic blocked, so a restored Home
Assistant can't switch lights or send notifications. The manifests are in
[`dr-drill/`](dr-drill/).

1. Note the production pods so you can prove later they were not touched:
   `kubectl get pods -n home-automation; kubectl get pods -n self-hosted`.
2. Check Longhorn has room for the restore (one replica of the volume size):
   `kubectl -n longhorn-system get nodes.longhorn.io -o yaml | grep -A3 storageAvailable`.
3. Find the backup. The PVC's Longhorn volume is in `kubectl get pvc -n <ns> <pvc>`
   (`VOLUME` column); its newest backup URL is:

   ```bash
   kubectl -n longhorn-system get backups.longhorn.io -l backup-volume=<pvc-volume> \
     --sort-by=.status.backupCreatedAt -o jsonpath='{.items[-1].status.url}'
   ```

4. Put the URLs in `docs/dr-drill/10-restore-volumes.yaml` (local edit, don't
   commit it), then:

   ```bash
   kubectl apply -f docs/dr-drill/00-namespace.yaml
   kubectl apply -f docs/dr-drill/10-restore-volumes.yaml
   ```

   The PVC is Bound within seconds, but the restore runs on. It's done when
   this prints `false` (progress in percent is on the engine,
   `kubectl -n longhorn-system get engines.longhorn.io -l longhornvolume=<vol> -o yaml | grep progress`):

   ```bash
   kubectl -n longhorn-system get volumes.longhorn.io <restored-vol> -o jsonpath='{.status.restoreRequired}'
   ```

5. Boot the apps: `kubectl apply -f docs/dr-drill/20-apps.yaml`, then check
   they answer:

   ```bash
   # Home Assistant: 401 means it is up (it logs at warn, so there's no "initialized" line)
   kubectl -n dr-drill exec deploy/ha -- python3 -c \
     "import urllib.request as u;u.urlopen('http://localhost:8123/api/')" 2>&1 | grep -o 'HTTP Error 401'
   # Paperless: checks every document file against its checksum in the DB
   kubectl -n dr-drill exec deploy/paperless -c paperless -- sh -c \
     'cd /usr/src/paperless/src && s6-setuidgid paperless python3 manage.py document_sanity_checker --no-progress-bar'
   ```

   Expect Home Assistant to log network errors (MQTT, DNS, UniFi, weather,
   custom integrations reinstalling from PyPI): that is the blocked network,
   not damage. The recorder warns the database "was not shut down cleanly";
   that is normal for a backup of a running volume.

6. Clean up, the same day:

   ```bash
   kubectl delete -f docs/dr-drill/
   kubectl -n longhorn-system get volumes.longhorn.io   # the restored volumes must be gone
   ```

   Don't leave restored volumes around and never back one up: Longhorn labels
   them with the **production** volume's `backup-volume`, so a backup of a
   restored volume would land in production's backup chain.

**For a real restore** (the production volume is lost or corrupt), the
restore is the same; only the last step differs. Suspend the app's Flux
Kustomization (`flux suspend kustomization <app>`), scale the app to 0, then
in the Longhorn UI restore the backup and use *Create PV/PVC* with the
original PVC name once the broken PVC is deleted. Resume Flux after the app is
up. This variant has not been drilled; prefer copying files out of a
`dr-drill` restore when only some data is missing.

## 2. Restore a volume without the cluster

Use this when the cluster is gone and all that is left is the B2 bucket,
the age key and a Mac (or any Linux box). It rebuilds a Longhorn backup as a
raw ext4 image and pulls the files out of it. Nothing here writes to B2 or to
a cluster. It was about three times faster than Longhorn's own restore in the
2026-11-20 drill.

### What a Longhorn backup looks like in the bucket

```
talos1018-longhorn/1018/backupstore/volumes/<xx>/<yy>/<pvc-volume>/
├── volume.cfg                  # Size, LastBackupName, Labels.KubernetesStatus (ns + PVC name)
├── backups/backup_<name>.cfg   # Blocks: [{Offset, BlockChecksum}], CompressionMethod
└── blocks/<c[0:2]>/<c[2:4]>/<c>.blk
```

- Every backup's `.cfg` lists the **complete** block map of the volume at that
  snapshot, incremental or not, so one `.cfg` is enough to rebuild it. Blocks
  are deduplicated and shared between backups.
- A block is 2 MiB of volume data at `Offset`, compressed with lz4 (frame
  format, so the `lz4` CLI reads it).
- `BlockChecksum` is the first 64 hex characters of **SHA-512** of the
  *uncompressed* block (not SHA-256), and also its file name.
- Ranges with no block were never written or were trimmed: they are zeros.
- The image is a crash-consistent ext4 filesystem ("needs journal recovery"),
  because Longhorn snapshots a mounted volume.

### Prerequisites

1. **age key**: Apple Passwords, entry with the `AGE-SECRET-KEY-...` for
   recipient `age1kesma5f5...`. Put it where sops looks on macOS:
   `~/Library/Application Support/sops/age/keys.txt` (or `export SOPS_AGE_KEY=...`).
2. **B2 credentials**: decrypted from
   `kubernetes/apps/talos1018/longhorn/config/backup-b2-secret.sops.yaml` by the
   script. If that key was revoked, log in to Backblaze (account password in
   Apple Passwords), create a **read-only** application key for
   `talos1018-longhorn`, and export `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY` and `AWS_ENDPOINTS` (the bucket's S3 endpoint URL)
   instead. Read-only is enough and is the safer choice for a restore.
3. Tools: `brew install sops rclone jq lz4 e2fsprogs` (e2fsprogs is keg-only:
   its binaries are in `$(brew --prefix e2fsprogs)/sbin`). No Docker needed.
4. Free disk: the image is sparse, so roughly the volume's used size twice
   (downloaded blocks + image), plus the extracted files.

### Restore

```bash
# Which volumes have backups (namespace/pvc, volume, last backup, size)
./scripts/restore-longhorn-backup.sh list

# Latest backup of a PVC into a scratch directory
./scripts/restore-longhorn-backup.sh self-hosted/wishlist-data ~/dr/wishlist

# A specific backup (names are in backups/ next to volume.cfg)
./scripts/restore-longhorn-backup.sh self-hosted/wishlist-data backup-fd2162120128472a ~/dr/wishlist
```

The script verifies every block's checksum while assembling and stops on a
mismatch. It ends with `OK: <dir>/<pvc-volume>.img`.

### Read the files

```bash
E=$(brew --prefix e2fsprogs)/sbin
cd ~/dr/wishlist
$E/e2fsck -fy pvc-*.img          # replays the journal; fixes free-count noise
$E/e2fsck -fn pvc-*.img          # must now come back clean
mkdir files && $E/debugfs -R "rdump / files" pvc-*.img
```

`rdump` run as a normal user prints "Operation not permitted while changing
ownership" for every file. That is only chown failing; the contents are
written. Run it with `sudo` if the original UIDs matter (for example before
handing a Postgres data directory to a container).

Always run `e2fsck -fy` before extracting: without the journal replay,
`debugfs` can return files as they were before the last writes.

On Linux, `sudo mount -o loop,ro pvc-*.img /mnt` after the `e2fsck` works too.

### Check what came back

- SQLite apps: copy the `.db`, `-wal` and `-shm` together, then
  `sqlite3 copy.db "pragma integrity_check"` (open a copy, since opening
  checkpoints the WAL into the file).
- Postgres volumes (netbox, sure, skystats): start a matching `postgres` image
  on the extracted data directory and let it run crash recovery.

### Boot Home Assistant from the files

```bash
docker run --rm -d --name ha-dr --network none -v ~/dr/ha/files:/config \
  ghcr.io/home-assistant/home-assistant:<same tag as the deployment>
docker exec ha-dr python3 -c "import urllib.request as u;u.urlopen('http://localhost:8123/api/')"  # HTTP Error 401 = up
```

`--network none` keeps it away from real devices; drop it only when this copy
is meant to take over. Then it also needs internet once, because custom
integrations reinstall their Python packages on a fresh container.

Paperless needs internet at start-up with the production settings:
`PAPERLESS_OCR_LANGUAGES` makes it `apt-get install` the extra Tesseract
languages on every start, and without network it hangs before the web server
comes up. For an offline start leave that variable out and set
`PAPERLESS_OCR_LANGUAGE=eng`, as in `dr-drill/20-apps.yaml`.

## 3. Restore etcd from a snapshot

`talos-backup` uploads an age-encrypted snapshot to the B2 bucket
`talos1018-etcd` every night at 02:30 UTC
(`talos1018/talos1018-<UTC time>.snap.age`, about 165-200 MB). Its own key can
only **write** (reads get 403 "not entitled"), so restoring uses a separate
read-only key.

1. Get the read-only key `talos1018-etcd-ro` from Apple Passwords (it is
   limited to this bucket, no expiry). If it is gone, create a new one in
   Backblaze: *Application Keys*, bucket `talos1018-etcd`, *Read Only*.
2. Download the newest snapshot, decrypt and check it (about 25 s):

   ```bash
   export RCLONE_CONFIG_E_TYPE=s3 RCLONE_CONFIG_E_PROVIDER=Other
   export RCLONE_CONFIG_E_ACCESS_KEY_ID=<read-only keyID>
   export RCLONE_CONFIG_E_SECRET_ACCESS_KEY=<read-only applicationKey>
   # The bucket's S3 endpoint; without the repo, copy it from the bucket page in Backblaze
   export RCLONE_CONFIG_E_ENDPOINT=$(sops -d --extract '["stringData"]["CUSTOM_S3_ENDPOINT"]' \
     kubernetes/apps/talos1018/system-upgrade/talos-backup/app/b2-secret.sops.yaml)
   rclone lsl e:talos1018-etcd | sort -k2,3 | tail -3   # newest last
   rclone copyto e:talos1018-etcd/talos1018/talos1018-<time>.snap.age snap.age
   age -d -i ~/Library/Application\ Support/sops/age/keys.txt -o db.snapshot snap.age
   etcdutl snapshot status db.snapshot -w table          # hash, revision, keys, size
   ```

3. Follow the Talos disaster recovery guide, then
   `talosctl -n <first control plane> bootstrap --recover-from=./db.snapshot`
   (see `talos/talos1018/README.md`).
4. `rm -f db.snapshot snap.age` afterwards: the snapshot holds every Secret in
   the cluster.

## 4. Quarterly drill

Takes about an hour, most of it waiting. Do it in January, April, July and
October.

- [ ] Section 1 for `home-automation/home-assistant-config` and
      `self-hosted/paperless-data-rwo`: both boot, Paperless sanity check has 0 errors.
- [ ] Section 2 for one small volume (e.g. `self-hosted/wishlist-data`).
- [ ] Section 3 steps 1-2 (download, decrypt, `snapshot status`), then delete the files.
- [ ] Cleanup: `dr-drill` gone, no restored volumes left, `~/dr` deleted,
      production pods unchanged.
- [ ] Add a row per volume to the drill log below.

## Drill log

| Date | Volume | Path | Backup size | Restore | Boot / check | Result |
|---|---|---|---|---|---|---|
| 2026-11-15 | `self-hosted/wishlist-data` (1 GiB) | no cluster | 43 blocks | 40 s | - | `e2fsck` clean after journal replay; `prod.db` + all 20 uploads byte-identical to live |
| 2026-11-15 | `self-hosted/mealie-data` (500 MiB) | no cluster | 67 blocks | 45 s | - | `mealie.db` integrity ok, 8 recipes |
| 2026-11-20 | `home-automation/home-assistant-config` (8 GiB) | cluster (`dr-drill`) | 3,531 blocks, ~7 GiB | ~19 min | API up 26 s after pod start; DB `integrity_check` 455 s | ok: 2,998 entities, 322 devices, 14.0M states; only network errors |
| 2026-11-20 | `self-hosted/paperless-data-rwo` (20 GiB) | cluster (`dr-drill`) | 3,495 blocks, ~7 GiB | ~24 min | API up 75 s after apply; sanity checker 88 s | ok: 1,403 documents, 0 errors, 0 warnings |
| 2026-11-20 | `home-automation/home-assistant-config` | no cluster | 4.6 GB downloaded | 407 s + 12 s extract | Docker `--network none`: up ~13 s after start | `e2fsck` clean; DB `integrity_check` ok in 83 s |
| 2026-11-20 | `self-hosted/paperless-data-rwo` | no cluster | 7.2 GB downloaded | 481 s + 21 s extract | not booted | `e2fsck` clean; `db.sqlite3` integrity ok, 1,403 documents |
| 2026-11-22 | etcd snapshot | B2 read-only key | 165 MB | 21 s download, 1 s `age -d` | `etcdutl snapshot status` < 1 s | ok: 5,725 keys, revision 345720484; bucket holds 13 daily snapshots (11-10 to 11-22), so retention works |

On 2026-11-20 both cluster restores and both Mac restores ran at the same time
and shared the uplink, so one restore on its own is faster. A first boot
pulls the image (HA took 81 s on the Mac).

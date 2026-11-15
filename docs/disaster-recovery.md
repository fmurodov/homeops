# Disaster recovery: Longhorn volumes from B2 without Kubernetes

Use this when the cluster is gone and all that is left is the B2 bucket,
the age key and a Mac (or any Linux box). It rebuilds a Longhorn backup as a
raw ext4 image and pulls the files out of it. Nothing here writes to B2 or to
a cluster.

## What a Longhorn backup looks like in the bucket

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

## Prerequisites

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

## Restore

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

## Read the files

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

## Check what came back

- SQLite apps: copy the `.db`, `-wal` and `-shm` together, then
  `sqlite3 copy.db "pragma integrity_check"` (open a copy, since opening
  checkpoints the WAL into the file).
- Postgres volumes (netbox, sure, skystats): start a matching `postgres` image
  on the extracted data directory and let it run crash recovery.

## Drill log

| Date | Volume | Backup | Blocks (unique) | Restore time | Result |
|---|---|---|---|---|---|
| 2026-11-15 | `self-hosted/wishlist-data` (1 GiB) | `backup-fd2162120128472a` | 43 (33) | 40 s | `e2fsck` clean after journal replay; `prod.db` integrity ok; `prod.db` + all 20 uploads byte-identical to the live volume (SHA-256) |
| 2026-11-15 | `self-hosted/mealie-data` (500 MiB) | `backup-79ff47e8bcef4a2f` | 67 (56) | 45 s | `e2fsck` clean; `mealie.db` integrity ok, 8 recipes |

Most of those ~40 s is the lookup, which reads every `volume.cfg` in the
bucket (45 today); the downloads themselves are a few seconds. Expect the
large volumes (paperless ~4,600 blocks, home-assistant ~22,000 blocks, up to
2 MiB each before compression) to be bound by download bandwidth.

## Not covered yet (homeops-project#6)

- Booting Home Assistant and Paperless on a Docker host from extracted data.
- Decrypting an etcd snapshot from the `talos-backup` bucket with the age key.
- A quarterly repeat of this drill.

Backups go to Backblaze B2 only (set in `app/helmrelease.yaml`):

Backup Target: s3://talos1018-longhorn@auto/1018/
Backup Target Credential Secret: longhorn-b2-backups

`longhorn-r2-backups` (Cloudflare R2, `s3://longhorn-backup@auto/1018`) is still
deployed but no backup target uses it.

Restoring a backup without the cluster: `docs/disaster-recovery.md`.

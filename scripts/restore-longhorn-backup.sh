#!/usr/bin/env bash
# Rebuild a Longhorn volume from the B2 backupstore as a raw disk image,
# without Kubernetes or the Longhorn engine. Only reads from the bucket.
# Runbook: docs/disaster-recovery.md
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 list
       $0 <namespace/pvc | pvc-volume-name> [backup-name|latest] <out-dir>

Credentials: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINTS from the
environment, else decrypted with sops from the longhorn-b2-backups secret.
BACKUP_TARGET overrides the bucket/prefix (default: $BACKUP_TARGET_DEFAULT).
EOF
  exit 1
}

BACKUP_TARGET_DEFAULT="talos1018-longhorn/1018"
BACKUP_TARGET="${BACKUP_TARGET:-$BACKUP_TARGET_DEFAULT}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="$REPO_ROOT/kubernetes/apps/talos1018/longhorn/config/backup-b2-secret.sops.yaml"

for bin in rclone jq lz4 shasum; do
  command -v "$bin" >/dev/null || { echo "missing: $bin (brew install $bin)" >&2; exit 1; }
done

if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  command -v sops >/dev/null || { echo "set AWS_* or install sops" >&2; exit 1; }
  creds=$(sops -d --output-type json "$SECRET")
  AWS_ACCESS_KEY_ID=$(jq -r .stringData.AWS_ACCESS_KEY_ID <<<"$creds")
  AWS_SECRET_ACCESS_KEY=$(jq -r .stringData.AWS_SECRET_ACCESS_KEY <<<"$creds")
  AWS_ENDPOINTS=$(jq -r .stringData.AWS_ENDPOINTS <<<"$creds")
  unset creds
fi
export RCLONE_CONFIG_LHB_TYPE=s3 RCLONE_CONFIG_LHB_PROVIDER=Other
export RCLONE_CONFIG_LHB_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export RCLONE_CONFIG_LHB_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_LHB_ENDPOINT="$AWS_ENDPOINTS"
VOLUMES="lhb:$BACKUP_TARGET/backupstore/volumes"

# volume.cfg lives at volumes/<xx>/<yy>/<volume>/; print "<path>\t<ns/pvc>\t<volume>\t<last backup>\t<size>"
list_volumes() {
  rclone lsf -R --files-only --include volume.cfg "$VOLUMES/" | while read -r cfg; do
    rclone cat "$VOLUMES/$cfg" | jq -r --arg p "${cfg%volume.cfg}" '
      [$p,
       ((.Labels.KubernetesStatus // "{}") | fromjson | "\(.namespace // "")/\(.pvcName // "")"),
       .Name, (.LastBackupAt // "-"), "\((.Size | tonumber) / 1048576)Mi"] | @tsv'
  done
}

[[ $# -ge 1 ]] || usage
if [[ $1 == list ]]; then
  list_volumes | cut -f2- | sort | column -t
  exit 0
fi
[[ $# -ge 2 ]] || usage
TARGET=$1
if [[ $# -eq 2 ]]; then BACKUP=latest; OUT=$2; else BACKUP=$2; OUT=$3; fi

echo "Looking up $TARGET ..."
row=$(list_volumes | awk -F'\t' -v t="$TARGET" '$2 == t || $3 == t' | head -1)
[[ -n "$row" ]] || { echo "no backed-up volume matches $TARGET" >&2; exit 1; }
VOLPATH=$(cut -f1 <<<"$row")
VOLUME=$(cut -f3 <<<"$row")

mkdir -p "$OUT/blocks"
rclone cat "$VOLUMES/${VOLPATH}volume.cfg" >"$OUT/volume.cfg"
[[ $BACKUP == latest ]] && BACKUP=$(jq -r .LastBackupName "$OUT/volume.cfg")
rclone cat "$VOLUMES/${VOLPATH}backups/backup_${BACKUP}.cfg" >"$OUT/backup.cfg"

SIZE=$(jq -r .Size "$OUT/volume.cfg")
METHOD=$(jq -r .CompressionMethod "$OUT/backup.cfg")
NBLOCKS=$(jq '.Blocks | length' "$OUT/backup.cfg")
echo "$VOLUME ($(cut -f2 <<<"$row")): backup $BACKUP from $(jq -r .SnapshotCreatedAt "$OUT/backup.cfg"), $NBLOCKS blocks, $METHOD, volume $((SIZE / 1048576)) MiB"
case "$METHOD" in lz4 | none) ;; *) echo "unsupported compression: $METHOD (gzip needs a gunzip branch)" >&2; exit 1 ;; esac

# Blocks are content-addressed: blocks/<c[0:2]>/<c[2:4]>/<c>.blk, shared across backups.
jq -r '.Blocks[].BlockChecksum | "\(.[0:2])/\(.[2:4])/\(.).blk"' "$OUT/backup.cfg" | sort -u >"$OUT/blocks.txt"
echo "Downloading $(wc -l <"$OUT/blocks.txt" | tr -d ' ') unique blocks ..."
rclone copy --files-from "$OUT/blocks.txt" --transfers 16 "$VOLUMES/${VOLPATH}blocks" "$OUT/blocks"

# Each block is 2 MiB of volume data at .Offset. Unlisted ranges were never
# written (or were trimmed), so they stay as sparse zeros.
IMG="$OUT/$VOLUME.img"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1 count=0 seek="$SIZE" status=none
echo "Assembling $IMG ..."
jq -r '.Blocks[] | "\(.Offset) \(.BlockChecksum)"' "$OUT/backup.cfg" | while read -r offset sum; do
  blk="$OUT/blocks/${sum:0:2}/${sum:2:2}/$sum.blk"
  if [[ $METHOD == lz4 ]]; then lz4 -dcq "$blk" >"$OUT/block.raw"; else cp "$blk" "$OUT/block.raw"; fi
  # Longhorn's checksum is the first 64 hex chars of SHA-512 over the uncompressed block.
  got=$(shasum -a 512 "$OUT/block.raw" | cut -c1-64)
  [[ $got == "$sum" ]] || { echo "checksum mismatch at offset $offset" >&2; exit 1; }
  dd if="$OUT/block.raw" of="$IMG" bs=2097152 seek=$((offset / 2097152)) conv=notrunc status=none
done
rm -f "$OUT/block.raw"
echo "OK: $IMG ($NBLOCKS blocks verified)"
echo "Next: docs/disaster-recovery.md, 'Read the files'"

#!/usr/bin/env bash
set -e

INPUT=$1
BACKUP_NAME=$2
OUTPUT_NAME=$3

source .env.local 2>/dev/null || { echo "Error: .env.local not found"; exit 1; }

# Show usage and list volumes if no input
if [ -z "$INPUT" ]; then
  echo "Usage: $0 <pvc-name-or-id> [backup-name] [output-name]"
  echo ""
  echo "Examples:"
  echo "  $0 paperless-data                    # restore latest backup"
  echo "  $0 paperless-data backup-abc123     # restore specific backup"
  echo "  $0 paperless-data latest my-data    # restore latest with custom name"
  echo ""
  echo "Fetching available volumes..."

  # Inline volume listing
  docker run --rm \
    -e RCLONE_CONFIG_S3_TYPE=s3 \
    -e RCLONE_CONFIG_S3_PROVIDER=Other \
    -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
    -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
    -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
    rclone/rclone lsf \
    "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/" \
    --files-only --recursive 2>/dev/null | grep "volume.cfg$" | while read cfg_path; do

    pvc_id=$(echo "$cfg_path" | grep -o "pvc-[a-f0-9-]*")

    temp_file=$(mktemp)
    docker run --rm \
      -e RCLONE_CONFIG_S3_TYPE=s3 \
      -e RCLONE_CONFIG_S3_PROVIDER=Other \
      -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
      -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
      -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
      rclone/rclone cat \
      "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/${cfg_path}" \
      > "$temp_file" 2>/dev/null

    if command -v jq &> /dev/null && [ -s "$temp_file" ]; then
      pvc_name=$(jq -r '.Labels.KubernetesStatus | fromjson | .pvcName // "N/A"' "$temp_file" 2>/dev/null)
      namespace=$(jq -r '.Labels.KubernetesStatus | fromjson | .namespace // "N/A"' "$temp_file" 2>/dev/null)
      printf "%-45s %-30s %s\n" "$pvc_id" "$pvc_name" "$namespace"
    fi
    rm -f "$temp_file"
  done | sort -k3,3 -k2,2

  exit 0
fi

# Check dependencies
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install with: brew install jq"; exit 1; }
python3 -c "import lz4.frame" 2>/dev/null || { echo "Error: Install lz4 with: pip3 install lz4 --break-system-packages"; exit 1; }

# Lookup PVC ID if needed
if [[ ! $INPUT =~ ^pvc-[a-f0-9-]+$ ]]; then
  echo "Looking up PVC ID for: $INPUT"

  # Find PVC by name
  TEMP_LIST=$(mktemp)
  docker run --rm \
    -e RCLONE_CONFIG_S3_TYPE=s3 \
    -e RCLONE_CONFIG_S3_PROVIDER=Other \
    -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
    -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
    -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
    rclone/rclone lsf \
    "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/" \
    --files-only --recursive 2>/dev/null | grep "volume.cfg$" > "$TEMP_LIST"

  while read cfg_path; do
    temp_file=$(mktemp)
    docker run --rm \
      -e RCLONE_CONFIG_S3_TYPE=s3 \
      -e RCLONE_CONFIG_S3_PROVIDER=Other \
      -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
      -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
      -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
      rclone/rclone cat \
      "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/${cfg_path}" \
      > "$temp_file" 2>/dev/null

    pvc_name=$(jq -r '.Labels.KubernetesStatus | fromjson | .pvcName // ""' "$temp_file" 2>/dev/null)

    if [ "$pvc_name" = "$INPUT" ]; then
      PVC_ID=$(echo "$cfg_path" | grep -o "pvc-[a-f0-9-]*")
      rm -f "$temp_file"
      break
    fi
    rm -f "$temp_file"
  done < "$TEMP_LIST"

  rm -f "$TEMP_LIST"

  if [ -z "$PVC_ID" ]; then
    echo "Error: PVC not found: $INPUT"
    exit 1
  fi

  echo "Found PVC ID: $PVC_ID"
else
  PVC_ID=$INPUT
fi

[ -z "$OUTPUT_NAME" ] && OUTPUT_NAME=$INPUT

echo ""
echo "=== Finding Backups ==="

# Find backup directory
BACKUP_DIR=$(docker run --rm \
  -e RCLONE_CONFIG_S3_TYPE=s3 \
  -e RCLONE_CONFIG_S3_PROVIDER=Other \
  -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
  -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
  -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
  rclone/rclone lsf \
  "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/" \
  --dirs-only --recursive 2>/dev/null | grep "$PVC_ID" | head -1)

[ -z "$BACKUP_DIR" ] && { echo "Error: No backups found for $PVC_ID"; exit 1; }

# List backups
BACKUPS=$(docker run --rm \
  -e RCLONE_CONFIG_S3_TYPE=s3 \
  -e RCLONE_CONFIG_S3_PROVIDER=Other \
  -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
  -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
  -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
  rclone/rclone lsf \
  "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/${BACKUP_DIR}backups/" \
  --files-only 2>/dev/null | grep "backup_backup-.*\.cfg$" | sort)

[ -z "$BACKUPS" ] && { echo "Error: No backups found"; exit 1; }

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Available backups for $PVC_ID:"
echo ""
printf "%-30s %-20s\n" "Backup Name" "Created"
echo "=================================================="

echo "$BACKUPS" | while read backup_file; do
  backup_name=$(echo "$backup_file" | sed 's/backup_\(backup-[a-f0-9]*\)\.cfg/\1/')

  docker run --rm \
    -e RCLONE_CONFIG_S3_TYPE=s3 \
    -e RCLONE_CONFIG_S3_PROVIDER=Other \
    -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
    -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
    -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
    rclone/rclone cat \
    "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/${BACKUP_DIR}backups/${backup_file}" \
    > "$TEMP_DIR/$backup_name.json" 2>/dev/null || continue

  created=$(jq -r '.CreatedTime // "N/A"' "$TEMP_DIR/$backup_name.json" 2>/dev/null | cut -d'T' -f1)
  printf "%-30s %s\n" "$backup_name" "$created"
done

# Select backup
if [ -z "$BACKUP_NAME" ] || [ "$BACKUP_NAME" = "latest" ]; then
  SELECTED_BACKUP=$(echo "$BACKUPS" | tail -1 | sed 's/backup_\(backup-[a-f0-9]*\)\.cfg/\1/')
  echo ""
  echo "Using latest: $SELECTED_BACKUP"
else
  SELECTED_BACKUP=$BACKUP_NAME
  echo ""
  echo "Using: $SELECTED_BACKUP"
fi

echo "$BACKUPS" | grep -q "backup_${SELECTED_BACKUP}\.cfg" || { echo "Error: Backup not found"; exit 1; }

echo ""
echo "=== Restoring ==="
echo "Volume:  $OUTPUT_NAME"
echo "Backup:  $SELECTED_BACKUP"
echo ""

TEMP_BACKUP=$(mktemp -d)
trap "rm -rf $TEMP_BACKUP $TEMP_DIR" EXIT

# Download backup
echo "[1/4] Downloading from S3..."
docker run --rm \
  -v "$TEMP_BACKUP:/data" \
  -e RCLONE_CONFIG_S3_TYPE=s3 \
  -e RCLONE_CONFIG_S3_PROVIDER=Other \
  -e RCLONE_CONFIG_S3_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
  -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
  -e RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT} \
  rclone/rclone copy \
  "s3:${LONGHORN_S3_BUCKET}/${LONGHORN_S3_PREFIX}/backupstore/volumes/${BACKUP_DIR}" \
  /data \
  --progress 2>&1 | grep -v "NOTICE"

echo "✓ Downloaded"

# Reconstruct volume
echo ""
echo "[2/4] Reconstructing volume..."

python3 - <<'PYTHON' "$TEMP_BACKUP" "$PWD/restored-volumes/volume.img" "$SELECTED_BACKUP"
import sys, os, json, lz4.frame

backup_dir, output_file, selected_backup = sys.argv[1:4]

# Read volume metadata
with open(os.path.join(backup_dir, 'volume.cfg')) as f:
    volume_size = int(json.load(f).get('Size', '0'))

if volume_size == 0:
    sys.exit("Error: Invalid volume size")

# Read backup metadata
with open(os.path.join(backup_dir, 'backups', f'backup_{selected_backup}.cfg')) as f:
    backup_meta = json.load(f)

blocks = backup_meta.get('Blocks', [])
compression = backup_meta.get('CompressionMethod', 'lz4')

print(f"Volume: {volume_size / (1024**3):.2f} GB, Blocks: {len(blocks)}, Compression: {compression}")

os.makedirs(os.path.dirname(output_file), exist_ok=True)

with open(output_file, 'wb') as out:
    out.truncate(volume_size)

    for i, block in enumerate(blocks):
        offset = block.get('Offset', 0)
        checksum = block.get('BlockChecksum', '')

        if len(checksum) < 4:
            continue

        block_path = os.path.join(backup_dir, 'blocks', checksum[:2], checksum[2:4], f"{checksum}.blk")

        if not os.path.exists(block_path):
            continue

        try:
            with open(block_path, 'rb') as blk:
                data = lz4.frame.decompress(blk.read())
            out.seek(offset)
            out.write(data)

            if (i + 1) % 10 == 0:
                print(f"  {i + 1}/{len(blocks)} blocks")
        except Exception as e:
            print(f"Warning: Block {checksum[:8]} failed: {e}")

print(f"✓ Reconstructed")
PYTHON

[ $? -ne 0 ] && exit 1
echo "✓ Volume image created"

# Extract files
echo ""
echo "[3/4] Extracting files..."

mkdir -p "./volumes/$OUTPUT_NAME"

if [[ "$OSTYPE" == "darwin"* ]]; then
  docker run --rm --privileged --cap-add SYS_ADMIN \
    -v "$PWD/restored-volumes:/input" \
    -v "$PWD/volumes/$OUTPUT_NAME:/output" \
    alpine:latest sh -c '
      apk add --no-cache e2fsprogs rsync >/dev/null 2>&1
      mkdir -p /mnt/volume
      mount -t ext4 -o loop /input/volume.img /mnt/volume
      rsync -a /mnt/volume/ /output/
      umount /mnt/volume
    ' || exit 1

  sudo chown -R $USER:staff "./volumes/$OUTPUT_NAME"
else
  LOOP_DEV=$(sudo losetup -f)
  sudo losetup "$LOOP_DEV" "./restored-volumes/volume.img"
  sudo mkdir -p /mnt/restore
  sudo mount "$LOOP_DEV" /mnt/restore
  sudo rsync -a /mnt/restore/ "./volumes/$OUTPUT_NAME/"
  sudo chown -R $USER:$USER "./volumes/$OUTPUT_NAME"
  sudo umount /mnt/restore
  sudo losetup -d "$LOOP_DEV"
  sudo rmdir /mnt/restore
fi

SIZE=$(du -sh "./volumes/$OUTPUT_NAME" | cut -f1)
echo "✓ Extracted ($SIZE)"

# Cleanup
echo ""
echo "[4/4] Cleaning up..."
rm -rf "./restored-volumes"
echo "✓ Done"

echo ""
echo "✓ Restored to: ./volumes/$OUTPUT_NAME"

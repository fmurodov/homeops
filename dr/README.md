# Disaster Recovery

Simple tools for restoring Longhorn volumes and running apps locally when the cluster is down.

## Quick Start

### 1. Restore a Volume from Longhorn Backup

```bash
# List available volumes
./scripts/restore-volume.sh

# Restore specific volume
./scripts/restore-volume.sh esphome-data
```

Volume will be restored to `volumes/esphome-data/`

### 2. Run App with Docker

See `examples/` for docker-compose files you can use as templates.

```bash
cd examples/esphome
docker-compose up -d
```

## Prerequisites

**For volume restore:**
- Docker or Podman
- `jq` and `lz4`: `brew install jq` and `pip3 install lz4 --break-system-packages`
- S3 credentials (copy `.env.local.example` to repo root):
  ```bash
  cp .env.local.example ../.env.local
  # Edit ../.env.local with your S3 credentials
  ```

**For running apps:**
- Docker or Podman with docker-compose

## How to Use

### Restore and Run ESPHome (Example)

```bash
# 1. Restore volume
cd dr
./scripts/restore-volume.sh esphome-data

# 2. Start ESPHome
cd examples/esphome
docker-compose up -d

# Access at http://localhost:6052
```

### Create Your Own App

1. Copy `examples/esphome/docker-compose.yml`
2. Modify image, ports, volumes for your app
3. Restore the volume you need
4. Update volume path in docker-compose.yml
5. Run `docker-compose up -d`

## Examples

- **esphome**: Full example with volume mount, secrets, and network

Add more examples as needed for other critical apps.

## Notes

- Docker compose examples are simplified versions of K8s deployments
- Some features (ingress, TLS, OIDC) won't work outside the cluster
- Use this for emergency access to data and basic app functionality

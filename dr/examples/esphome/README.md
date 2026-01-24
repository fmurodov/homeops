# ESPHome Docker Compose Example

Simple docker-compose to run ESPHome locally using restored Longhorn volume.

## Usage

```bash
# 1. Restore ESPHome volume from backup
cd ../..
./scripts/restore-volume.sh esphome-data

# 2. Start ESPHome
cd examples/esphome
docker-compose up -d

# 3. Access dashboard
open http://localhost:6052
```

## Notes

- Port 6052 exposed for web interface
- Uncomment `network_mode: host` on Linux for mDNS device discovery (not supported on macOS)
- Credentials are optional (remove if not needed)
- Restored volume must be at `../../volumes/esphome-data`
- Build cache is ephemeral (recreated on each start)

## Stop

```bash
docker-compose down
```

## Logs

```bash
docker-compose logs -f
```

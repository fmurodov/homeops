#!/bin/bash
# RIPE Database NRTMv3 availability probe.
#
# Reads the RIPE NRTM mirror feed, validates the response framing, and pushes
# nrtm_check_* metrics to VictoriaMetrics. Runs as the nrtm-check CronJob, and is
# runnable from a local shell for testing — every setting is env-overridable:
#
#   DEBUG=1 ./nrtm_check.sh     # print the raw NRTM responses
#   VM_URL= ./nrtm_check.sh     # run the check but skip the metric push
set -euo pipefail

HOST="${HOST:-whois.ripe.net}"
PORT="${PORT:-4444}"
SOURCE="${SOURCE:-RIPE}"
TIMEOUT="${TIMEOUT:-10}"
RANGE_SIZE="${RANGE_SIZE:-10}"
VM_URL="${VM_URL-http://victoria-metrics-victoria-metrics-single-server.observability.svc.cluster.local:8428/api/v1/import/prometheus}"
DEBUG="${DEBUG:-0}"

LABELS='department="db",environment="homelab",instance="whois.ripe.net",job="whois_nrtm_check",monitoring="internal-homelab",service="whois",visibility="internal"'

SUCCESS=1
END_SERIAL=0
ENTRY_COUNT=0

debug() { [[ "$DEBUG" == "1" ]] && echo "DEBUG: $1" >&2 || true; }

fail() {
    echo "FAIL: $1" >&2
    SUCCESS=0
    push_metrics
    exit 1
}

push_metrics() {
    [[ -n "$VM_URL" ]] || { echo "(VM_URL empty — skipping metric push)" >&2; return 0; }
    cat <<EOF | curl -s --data-binary @- "$VM_URL"
nrtm_check_success{$LABELS,source="$SOURCE"} $SUCCESS
nrtm_check_entries{$LABELS,source="$SOURCE"} $ENTRY_COUNT
nrtm_check_end_serial{$LABELS,source="$SOURCE"} $END_SERIAL
nrtm_check_timestamp{$LABELS,source="$SOURCE"} $(date +%s)
EOF
}

nrtm_query() {
    local host="$1" port="$2" payload="$3" terminator="$4" timeout="$5"
    python3 - "$host" "$port" "$payload" "$terminator" "$timeout" <<'PYEOF'
import socket, sys, time
host, port, payload, terminator, timeout = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], float(sys.argv[5])
sock = socket.create_connection((host, port), timeout=timeout)
sock.sendall((payload + "\n").encode())
sock.settimeout(timeout)
data = b""
start = time.time()
while True:
    try:
        chunk = sock.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    data += chunk
    if terminator.encode() in data:
        break
    if time.time() - start > timeout * 3:
        break
sock.close()
sys.stdout.write(data.decode(errors="replace"))
PYEOF
}

RAW_SOURCES_RESPONSE=$(nrtm_query "$HOST" "$PORT" "-q sources" "$SOURCE:3:" "$TIMEOUT")
debug "$RAW_SOURCES_RESPONSE"
SOURCE_QUERY_RESPONSE=$(echo "$RAW_SOURCES_RESPONSE" | grep "^$SOURCE:3:" || true)
[[ -z "$SOURCE_QUERY_RESPONSE" ]] && fail "no sources response for $SOURCE"

MIRROR_FLAG=$(echo "$SOURCE_QUERY_RESPONSE" | awk -F: '{print $3}')
[[ "$MIRROR_FLAG" != "Y" && "$MIRROR_FLAG" != "X" ]] && fail "mirroring not allowed (flag=$MIRROR_FLAG)"

END_SERIAL=$(echo "$SOURCE_QUERY_RESPONSE" | awk -F: '{print $4}' | cut -d- -f2)
BEGIN_SERIAL=$((END_SERIAL - RANGE_SIZE))

RANGE_QUERY_RESPONSE=$(nrtm_query "$HOST" "$PORT" "-g $SOURCE:3:$BEGIN_SERIAL-$END_SERIAL" "%END" "$TIMEOUT")
debug "$RANGE_QUERY_RESPONSE"

grep -q "^%START Version: 3 $SOURCE" <<< "$RANGE_QUERY_RESPONSE" || fail "no %START marker"
grep -q "^%END $SOURCE" <<< "$RANGE_QUERY_RESPONSE" || fail "no %END marker"

ENTRY_COUNT=$(grep -cE "^(ADD|DEL) [0-9]+" <<< "$RANGE_QUERY_RESPONSE" || true)
echo "OK: $SOURCE serial $BEGIN_SERIAL-$END_SERIAL, $ENTRY_COUNT entries"
push_metrics

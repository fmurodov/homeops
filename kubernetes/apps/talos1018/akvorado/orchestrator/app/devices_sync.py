#!/usr/bin/env python3
"""Write the UniFi client list as an Akvorado custom dictionary.

Akvorado serves dictionary CSVs to ClickHouse over HTTP rather than having
ClickHouse read them off disk, so this file has to land on the orchestrator.
"""
import csv
import json
import os
import ssl
import sys
import time
import urllib.request

BASE = os.environ.get("UNIFI_URL", "https://10.18.6.1")
OUT = os.environ.get("OUTPUT", "/run/akvorado-dict/devices.csv")
INTERVAL = int(os.environ.get("INTERVAL", "900"))
PAGE = 200

# The gateway presents its own certificate and there is no CA to pin it to.
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def get(path):
    req = urllib.request.Request(
        BASE + "/proxy/network/integration/v1" + path,
        headers={"X-API-KEY": os.environ["UNIFI_API_KEY"], "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15, context=CTX) as resp:
        return json.load(resp)


def clients():
    site = get("/sites")["data"][0]["id"]
    offset = 0
    while True:
        page = get("/sites/%s/clients?limit=%d&offset=%d" % (site, PAGE, offset))
        for client in page["data"]:
            yield client
        offset += PAGE
        if offset >= page["totalCount"]:
            return


def build():
    rows = []
    for client in clients():
        ip = client.get("ipAddress")
        name = client.get("name")
        # Clients report only currently-connected devices, some without an
        # address at all, and unnamed ones come back with their MAC as the
        # name — which tells us nothing the flow record does not already have.
        if not ip or not name or name == client.get("macAddress"):
            continue
        rows.append(["::ffff:" + ip if ":" not in ip else ip, name])
    return sorted(set(map(tuple, rows)))


def write(rows):
    tmp = OUT + ".tmp"
    with open(tmp, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["addr", "name"])
        writer.writerows(rows)
    os.replace(tmp, OUT)


def main():
    once = "--once" in sys.argv
    while True:
        try:
            rows = build()
            write(rows)
            print("wrote %d devices" % len(rows), flush=True)
        except Exception as err:
            print("sync failed: %s" % err, flush=True)
            # A missing CSV would leave the dictionary with no source, so seed
            # an empty one rather than let UniFi being unreachable block start.
            if not os.path.exists(OUT):
                write([])
        if once:
            return
        time.sleep(INTERVAL)


main()

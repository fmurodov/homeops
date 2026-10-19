#!/usr/bin/env python3
"""Prometheus exporter for a MeshCore repeater on USB serial.

Repeater firmware only speaks its text CLI over USB, not the companion
protocol that meshcore_py and friends need, so this polls the stats commands
directly on every scrape.
"""
import json
import os
import re
import select
import socket
import termios
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

DEVICE = os.environ.get("MESHCORE_DEVICE", "/dev/meshcore")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9842"))
TIMEOUT = float(os.environ.get("COMMAND_TIMEOUT", "3"))

# (json key, metric name, type, help, scale)
STATS = {
    "stats-core": [
        ("battery_mv", "meshcore_battery_volts", "gauge", "Supply voltage", 0.001),
        ("uptime_secs", "meshcore_uptime_seconds", "gauge", "Seconds since boot", 1),
        ("errors", "meshcore_error_flags", "gauge", "Error flag bitmask", 1),
        ("queue_len", "meshcore_queue_length", "gauge", "Outbound queue length", 1),
    ],
    "stats-radio": [
        ("noise_floor", "meshcore_noise_floor_dbm", "gauge", "Radio noise floor", 1),
        ("last_rssi", "meshcore_last_rssi_dbm", "gauge", "RSSI of the last received packet", 1),
        ("last_snr", "meshcore_last_snr_db", "gauge", "SNR of the last received packet", 1),
        ("tx_air_secs", "meshcore_tx_airtime_seconds_total", "counter", "Transmit airtime since boot", 1),
        ("rx_air_secs", "meshcore_rx_airtime_seconds_total", "counter", "Receive airtime since boot", 1),
    ],
    "stats-packets": [
        ("recv", "meshcore_packets_received_total", "counter", "Packets received since boot", 1),
        ("sent", "meshcore_packets_sent_total", "counter", "Packets sent since boot", 1),
        ("flood_tx", "meshcore_packets_flood_sent_total", "counter", "Flood packets sent since boot", 1),
        ("direct_tx", "meshcore_packets_direct_sent_total", "counter", "Direct packets sent since boot", 1),
        ("flood_rx", "meshcore_packets_flood_received_total", "counter", "Flood packets received since boot", 1),
        ("direct_rx", "meshcore_packets_direct_received_total", "counter", "Direct packets received since boot", 1),
        ("recv_errors", "meshcore_receive_errors_total", "counter", "Receive errors since boot", 1),
    ],
}

# "<4-byte pubkey hex>:<seconds since heard>:<snr * 4>", one per line
NEIGHBOR = re.compile(r"\b([0-9a-fA-F]{8}):(\d+):(-?\d+)\b")


def open_port():
    fd = os.open(DEVICE, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] |= termios.CLOCAL | termios.CREAD
    a[4] = a[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def command(fd, cmd):
    """Send a CLI command and return the text after its "-> " reply marker."""
    os.write(fd, (cmd + "\r").encode())
    buf = b""
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            buf += os.read(fd, 4096)
        elif b"-> " in buf and buf.endswith(b"\n"):
            break
    text = buf.decode(errors="replace")
    _, _, reply = text.partition("-> ")
    if not reply:
        raise TimeoutError(f"no reply to {cmd!r}")
    return reply.strip()


def collect():
    lines = []

    def metric(name, mtype, help_, samples):
        lines.append(f"# HELP {name} {help_}")
        lines.append(f"# TYPE {name} {mtype}")
        for labels, value in samples:
            lines.append(f"{name}{labels} {value}")

    start = time.monotonic()
    try:
        fd = open_port()
        try:
            ver = command(fd, "ver")
            stats = {c: json.loads(command(fd, c)) for c in STATS}
            neighbors = NEIGHBOR.findall(command(fd, "neighbors"))
        finally:
            os.close(fd)
    except (OSError, ValueError) as e:
        print(f"scrape failed: {e}", flush=True)
        metric("meshcore_up", "gauge", "Whether the repeater answered", [("", 0)])
        return "\n".join(lines) + "\n"

    metric("meshcore_up", "gauge", "Whether the repeater answered", [("", 1)])
    version = ver.split()[0].replace("\\", "").replace('"', "")
    metric("meshcore_info", "gauge", "Firmware version", [(f'{{version="{version}"}}', 1)])
    for cmd, fields in STATS.items():
        for key, name, mtype, help_, scale in fields:
            if key in stats[cmd]:
                metric(name, mtype, help_, [("", stats[cmd][key] * scale)])
    metric(
        "meshcore_neighbor_last_heard_seconds", "gauge", "Seconds since a neighbor's last advert",
        [(f'{{neighbor="{k.lower()}"}}', int(s)) for k, s, _ in neighbors],
    )
    metric(
        "meshcore_neighbor_snr_db", "gauge", "SNR of a neighbor's last advert",
        [(f'{{neighbor="{k.lower()}"}}', int(q) / 4) for k, _, q in neighbors],
    )
    metric("meshcore_scrape_duration_seconds", "gauge", "Time spent talking to the repeater",
           [("", round(time.monotonic() - start, 3))])
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = collect().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(HTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        # Linux binds "::" dual-stack by default.
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


if __name__ == "__main__":
    # Single-threaded on purpose: the serial port takes one conversation at a time.
    Server(("::", LISTEN_PORT), Handler).serve_forever()

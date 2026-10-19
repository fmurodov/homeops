#!/usr/bin/env python3
"""Set a MeshCore companion radio's clock over USB serial before the ingestor starts.

The radio has no battery-backed clock, so after a power loss it stamps adverts
with stale times until something sets it, and the ingestor never does.
Best-effort: a radio that does not answer must not keep the ingestor down.
"""
import os
import select
import struct
import sys
import termios
import time

DEVICE = os.environ.get("MESHCORE_DEVICE", "/dev/meshcore")
TIMEOUT = 3
MAX_FRAME = 172

CMD_GET_DEVICE_TIME = 5
CMD_SET_DEVICE_TIME = 6
RESP_OK = 0
RESP_ERR = 1
RESP_CURR_TIME = 9


def open_port():
    fd = os.open(DEVICE, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] |= termios.CLOCAL | termios.CREAD
    a[4] = a[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def request(fd, payload, codes):
    """Send a frame and return the first reply frame whose code is in codes."""
    os.write(fd, b"<" + struct.pack("<H", len(payload)) + payload)
    buf = b""
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            buf += os.read(fd, 4096)
        # Skip debug output and unsolicited push frames.
        while True:
            start = buf.find(b">")
            if start < 0 or len(buf) < start + 3:
                break
            (length,) = struct.unpack_from("<H", buf, start + 1)
            if length > MAX_FRAME:
                buf = buf[start + 1:]
                continue
            frame = buf[start + 3:start + 3 + length]
            if len(frame) < length:
                break
            buf = buf[start + 3 + length:]
            if frame and frame[0] in codes:
                return frame
    raise TimeoutError(f"no reply to command {payload[0]}")


def device_time(fd):
    frame = request(fd, bytes([CMD_GET_DEVICE_TIME]), {RESP_CURR_TIME})
    return struct.unpack_from("<I", frame, 1)[0]


def main():
    fd = open_port()
    try:
        offset = device_time(fd) - time.time()
        print(f"companion clock offset {offset:.0f}s", flush=True)
        # The firmware refuses to move the clock backwards.
        if offset < -60:
            now = int(time.time())
            frame = request(fd, bytes([CMD_SET_DEVICE_TIME]) + struct.pack("<I", now), {RESP_OK, RESP_ERR})
            if frame[0] != RESP_OK:
                raise RuntimeError("radio rejected the new time")
            print(f"companion clock set, offset now {device_time(fd) - time.time():.0f}s", flush=True)
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"could not set companion clock: {e}", file=sys.stderr, flush=True)

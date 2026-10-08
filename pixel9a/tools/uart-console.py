#!/usr/bin/env python3
"""Read from, and send commands to, the Pixel 9a console over the RP2040 bridge.

The wire is not plain ASCII: every byte arrives followed by a NUL, which is why
the stream decodes cleanly as UTF-16LE but looks like interleaved garbage as
ASCII. Stripping NUL bytes recovers the text for both the bootloader (BL2/ABL)
and the kernel console, so that is what this tool displays.

Because that NUL-interleaving may also apply to the *input* direction, sending is
supported in both `ascii` and `utf16` encodings so we can discover which one the
device's console actually accepts.

Examples:
    uart-console.py --read 35
    uart-console.py --cmd "ls -la /dev" --wait 4
    uart-console.py --cmd reboot --encoding utf16 --wait 3
"""

from __future__ import annotations

import argparse
import errno
import os
import select
import sys
import termios
import time

DEFAULT_DEV = "/dev/serial/by-id/usb-Seeed_XIAO_RP2040_PIO_UART_bridge_415032383337300B-if00"


def open_port(dev: str, baud: int) -> int:
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0
    a[1] = 0
    a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    speed = getattr(termios, f"B{baud}", None)
    if speed is None:
        raise SystemExit(f"unsupported baud {baud}")
    a[4] = speed
    a[5] = speed
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def read_for(fd: int, seconds: float) -> bytes:
    end = time.time() + seconds
    buf = bytearray()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                continue
            raise
        if chunk:
            buf += chunk
    return bytes(buf)


def printable(raw: bytes) -> str:
    """Drop NULs (wire artefact) and normalise line endings."""
    txt = raw.replace(b"\x00", b"").decode("utf-8", "replace")
    return txt.replace("\r\n", "\n").replace("\r", "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default=DEFAULT_DEV)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--read", type=float, default=0.0, help="read this many seconds")
    ap.add_argument("--cmd", action="append", default=[], help="command to send (repeatable)")
    ap.add_argument("--wait", type=float, default=3.0, help="seconds to read after each send")
    ap.add_argument("--encoding", choices=["ascii", "utf16"], default="ascii")
    ap.add_argument("--flush", action="store_true", help="drop buffered data before starting")
    args = ap.parse_args()

    fd = open_port(args.dev, args.baud)
    if args.flush:
        termios.tcflush(fd, termios.TCIOFLUSH)

    if args.read and not args.cmd:
        out = read_for(fd, args.read)
        sys.stdout.write(printable(out))
        return 0

    for cmd in args.cmd:
        payload = cmd + "\r\n"
        if args.encoding == "utf16":
            data = payload.encode("utf-16-le")
        else:
            data = payload.encode("ascii", "replace")
        print(f"$ {cmd}")
        os.write(fd, data)
        sys.stdout.write(printable(read_for(fd, args.wait)))

    if args.wait and not args.cmd:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

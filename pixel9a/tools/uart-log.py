#!/usr/bin/env python3
"""Continuously log the Pixel 9a debug UART (via RP2040 CDC-ACM bridge).

The Tensor/Pixel boot chain and the Android kernel both mirror their console to
this UART, but as UTF-16LE (EDK2/ABL and the Exynos-derived serial driver emit
CHAR16). We therefore keep the raw byte stream AND a decoded text stream.

Usage:
    python3 uart-log.py [--dev /dev/ttyACM0] [--baud 115200] [--out DIR]

Notes:
  * The RP2040 "PIO UART bridge" occasionally mis-locks its PIO divider after a
    host baud change; if the decoded text turns to garbage, reopen the port.
  * There is no getty/shell on this UART. Writing bytes is harmless but nothing
    consumes them except (in bootloader mode) the bootloader console.
"""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import os
import select
import sys
import termios
import time


def open_port(dev: str, baud: int) -> int:
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0  # iflag
    a[1] = 0  # oflag
    a[3] = 0  # lflag
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    speed = getattr(termios, f"B{baud}", None)
    if speed is None:
        raise SystemExit(f"unsupported baud {baud}")
    a[4] = speed
    a[5] = speed
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def main() -> int:
    ap = argparse.ArgumentParser()
    # The RP2040's ttyACM index climbs on every replug (0 -> 1 -> 3 -> 4 ...), so
    # default to the stable by-id symlink rather than a hardcoded index.
    ap.add_argument("--dev", default=(
        "/dev/serial/by-id/usb-Seeed_XIAO_RP2040_PIO_UART_bridge_"
        "415032383337300B-if00"))
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out", default="/tmp/pixel9a-captures")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    raw_path = os.path.join(args.out, f"uart-{stamp}.bin")
    txt_path = os.path.join(args.out, f"uart-{stamp}.txt")

    raw = open(raw_path, "ab", buffering=0)
    txt = open(txt_path, "a", buffering=1)
    # The kernel console emits UTF-16LE but the bootloader (BL2/ABL) emits plain
    # ASCII, so a NUL-stripped mirror is the easiest way to read boot-time output.
    ascii_path = os.path.join(args.out, f"uart-{stamp}.ascii.txt")
    asc = open(ascii_path, "a", buffering=1)
    print(f"[uart-log] {args.dev} @ {args.baud} -> {raw_path}", flush=True)
    print(f"[uart-log]   decoded: {txt_path}", flush=True)
    print(f"[uart-log]   ascii  : {ascii_path}", flush=True)

    fd = None
    pending = bytearray()
    last_flush = time.time()

    while True:
        if fd is None:
            try:
                fd = open_port(args.dev, args.baud)
                print(f"[uart-log] {dt.datetime.now():%H:%M:%S} port opened", flush=True)
            except OSError as exc:
                print(f"[uart-log] open failed: {exc}; retry in 2s", flush=True)
                time.sleep(2)
                continue

        try:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                chunk = os.read(fd, 65536)
                if chunk:
                    raw.write(chunk)
                    asc.write(chunk.replace(b"\x00", b"").decode("utf-8", "replace"))
                    pending += chunk
        except OSError as exc:
            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                print(f"[uart-log] read error {exc}; reopening", flush=True)
                try:
                    os.close(fd)
                except OSError:
                    pass
                fd = None
                continue

        # Emit complete decoded lines. UTF-16LE: a line ends CR LF 00 00.
        while b"\r\x00\n\x00" in pending or b"\n\x00" in pending:
            sep = b"\r\x00\n\x00" if b"\r\x00\n\x00" in pending else b"\n\x00"
            line, _, rest = pending.partition(sep)
            pending = bytearray(rest)
            if len(line) % 2:
                line += b"\x00"
            text = line.decode("utf-16-le", "replace").rstrip("\x00")
            if text.strip():
                ts = dt.datetime.now().strftime("%H:%M:%S.%f")[:-3]
                txt.write(f"{ts} {text}\n")

        if time.time() - last_flush > 30:
            txt.flush()
            last_flush = time.time()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)

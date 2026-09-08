#!/usr/bin/env python3
"""Capture a serial port to a log file, reconnecting if it drops."""
import os
import sys
import time
import select
import termios

port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyACM0"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
logpath = sys.argv[3] if len(sys.argv) > 3 else "/tmp/tegu-work/uart.log"

BAUD = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
    230400: termios.B230400,
}
if baud not in BAUD:
    sys.exit(f"unsupported baud {baud}")


def configure(fd: int) -> None:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = BAUD[baud]
    attrs[5] = BAUD[baud]
    cc = list(attrs[6])
    cc[termios.VMIN] = 1
    cc[termios.VTIME] = 0
    attrs[6] = cc
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIFLUSH)


def stamp(msg: str) -> bytes:
    return f"\n=== {time.strftime('%F %T')} {msg} ===\n".encode()


os.makedirs(os.path.dirname(logpath) or ".", exist_ok=True)
# line-buffered text is wrong for mixed \r\n UART; write bytes unbuffered
with open(logpath, "ab", buffering=0) as log:
    log.write(stamp(f"capture start pid={os.getpid()} {port} {baud}"))
    while True:
        fd = None
        try:
            fd = os.open(port, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
            configure(fd)
            log.write(stamp(f"opened {port}"))
            while True:
                r, _, _ = select.select([fd], [], [], 1.0)
                if not r:
                    continue
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    # select() on a CDC-ACM port wakes spuriously and the
                    # read then returns EAGAIN. That is not a disconnect.
                    # Letting it fall through to the reopen below cost a
                    # whole boot: the port was torn down and rebuilt about
                    # once a second and 7 KB of a 120 KB boot survived.
                    continue
                if not data:
                    break
                log.write(data)
        except FileNotFoundError:
            log.write(stamp(f"{port} missing, retry"))
            time.sleep(0.4)
        except OSError as e:
            log.write(stamp(f"oserror {e}, retry"))
            time.sleep(0.4)
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
                log.write(stamp("port closed"))
                time.sleep(0.2)

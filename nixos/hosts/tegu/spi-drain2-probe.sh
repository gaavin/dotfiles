#!/bin/sh
# Drain until the part is actually quiet, then command. The drain has been
# wrong all along.
#
# Last boot caught it. A command went out while the part was mid-message and
# the drain loop had run zero times, because it was gated on ATTN:
#
#	d1 drained=0 w=38 47 41 ... attn=0x00000000
#
# 38 47 41 is ASCII "8GA", out of the middle of the identify string
# S3908GA1B0-15.0. A read before it had taken the first eight bytes and
# stopped, and ATTN read 0 for the whole of the rest of that message.
#
# So ATTN means "a message is waiting", not "a message is unfinished". It
# drops as soon as a read starts consuming one, while the remainder is still
# queued. Every drain this port has written -- in every probe, and in the
# driver -- stops there, which means every command it has ever sent may have
# landed in the middle of a message. That is the one thing already known to
# destroy the exchange, so no previous command result is trustworthy.
#
# The fix is to drain on what the part actually says rather than on the line:
# keep reading until a read comes back starting with 0x5a, which is TouchComm
# padding and the part's way of saying it has nothing. A read starting a5 is a
# fresh message; anything else is the middle of one.
#
# Then re-run the commands that have been failing, on a part that is quiet for
# the first time:
#
#	c1  02 00 00   CMD_IDENTIFY
#	c2  20 00 00   CMD_GET_APPLICATION_INFO
#	c3  04 00 00   CMD_RESET, unmistakable if it lands -- the part reboots
#	               and announces itself with an identify
#
# Every byte is 0x00, 0x02, 0x04 or 0x20, all harmless if the framing slips
# and one is read as a command. No report types: they collide with flash
# commands (REPORT_TOUCH 0x11 is CMD_ERASE_FLASH).
set -u

L() { echo "tegu-dr: $*" > /dev/kmsg; }
A=0x15060004
AT() { devmem $A 32; }

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

# Read until the part answers with padding. 40 bytes covers the longest
# message it sends -- the identify is 29 -- so one read consumes one message.
D() {
	d=0
	o=""
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		o=$(cut -c1-11 < "$X")
		case "$o" in 5a*) break ;; esac
		d=$((d + 1))
	done
	L "$1 drain=$d last=$o attn=$(AT)"
}

# $1 label, $2 bytes. Drain properly, command, poll for the reply.
C() {
	D "$1-pre"
	echo "t $2" > "$X"
	w=$(cut -c1-11 < "$X")
	r=""
	k=0
	while [ $k -lt 10 ]; do
		echo 'r 32' > "$X"
		r=$(cut -c1-17 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 w=$w tries=$k attn=$(AT) r=$r"
	Z="$Z $1:t=$k,$(printf %s "$r" | cut -c1-8)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

C c1 "02 00 00"
C c2 "20 00 00"
C c3 "04 00 00"
D final

# One short line at the end, twice: the UART drops characters and this is what
# survives when the per-step lines do not.
L "R:$Z"
L "R:$Z"
L END

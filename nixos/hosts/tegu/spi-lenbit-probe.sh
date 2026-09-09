#!/bin/sh
# Does the part read our length field? One bit, decided in one boot.
#
# The drain fix worked and did not help. c1-pre found one queued message that
# ATTN never reported -- so the old drain really was leaving the part
# mid-message -- but with the part genuinely quiet, w=5a proving it, all three
# commands still produced nothing:
#
#	c1 02 00 00  CMD_IDENTIFY              tries=10 attn=0 r=5a 5a 5a
#	c2 20 00 00  CMD_GET_APPLICATION_INFO  tries=10 attn=0 r=5a 5a 5a
#	c3 04 00 00  CMD_RESET                 tries=10 attn=0 r=5a 5a 5a
#
# CMD_RESET is unmistakable if it lands and it did not land.
#
# Chip select has since been eliminated too (spi-cs-probe.sh). The same command
# driven by hand, with chip select held in software and asserted a millisecond
# before the first clock rather than mainline's ~200 ns, transmitted perfectly
# -- TX FIFO 3 -> 0, TX_DONE, three bytes back, no error bits -- and the part
# said nothing, ATTN never rising. So the fault is not the controller, not the
# framing, not the drain and not chip select.
#
# So the open question is no longer which command or when to send it. It is
# whether the bytes arrive at all. Two stories still fit everything:
#
#	A. the part receives our bytes exactly and declines to answer
#	B. the part receives activity but not our data, and everything that
#	   ever looked like decoding was chance
#
# The length field decides it, because a length is the one field whose
# misreading has a visible consequence. TouchComm framing is command, length
# low, length high; a command declaring 0xffff leaves the part waiting for
# 65535 payload bytes that will never come, and it stops answering. A command
# declaring 0 completes and it stays healthy -- established over many boots.
#
#	t1  02 00 00   CMD_IDENTIFY, length 0        control, must stay alive
#	t2  02 ff ff   CMD_IDENTIFY, length 0xffff   must kill it, under A
#	t3  02 00 00   only reached if t2 did nothing
#
#	t2 kills it   -> A. The part parses our length, so it receives our
#	                 bytes accurately, and the fault is that a correctly
#	                 received command is not acted on.
#	t2 harmless   -> B. The part is not parsing what we send, and the
#	                 fault is below the protocol: signal, not software.
#
# The test is robust to the one thing not yet settled, which is whether the
# bytes arrive bit-exact. Shifted by a bit either way, 02 ff ff still declares
# a length near 0xffff and 02 00 00 still declares zero, so the discriminator
# survives a misalignment that would scramble a command code.
#
# One death per boot -- a reset pulse does not revive this part, only a full
# boot does -- so t2 is the whole budget and the controls bracket it. The
# drain is the corrected one: read until the part answers 0x5a padding, never
# trusting ATTN, which drops mid-message.
set -u

L() { echo "tegu-lb: $*" > /dev/kmsg; }
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

D() {
	d=0
	o=""
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		o=$(cut -c1-11 < "$X")
		case "$o" in 5a*) break ;; esac
		d=$((d + 1))
	done
}

# Alive if it answers a marker or padding, dead if 0x00 or 0xff.
H() {
	h=0
	v=""
	while [ $h -lt 8 ]; do
		echo 'r 8' > "$X"
		v=$(cut -c1-11 < "$X")
		case "$v" in a5*|5a*) break ;; esac
		sleep 0.02
		h=$((h + 1))
	done
	L "$1 alive=$h attn=$(AT) $v"
	Z="$Z $1=$h"
}

T() {
	D
	echo "t $2" > "$X"
	w=$(cut -c1-11 < "$X")
	L "$1 drain=$d w=$w attn=$(AT)"
	Z="$Z $1(d=$d)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

H h0
T t1 "02 00 00"
H h1
T t2 "02 ff ff"
H h2
T t3 "02 00 00"
H h3

L "R:$Z"
L "R:$Z"
L END

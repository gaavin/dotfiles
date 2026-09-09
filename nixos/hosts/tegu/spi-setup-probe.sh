#!/bin/sh
# Was it the mode, or was it spi_setup()? One variable, mode 0 throughout.
#
# The mode sweep produced the first command responses this port has ever seen,
# and it is not yet clear what caused them.
#
#	m0 ch=0x00000000 bits=0 r=a5 10 18 00
#	m1 ch=0x00000004 bits=1 r=a5 03 38 47
#	m2 ch=0x00000008 bits=2 r=a5 03 ff ff
#	m3 ch=0x0000000C bits=3 r=4a 1d ff ff
#	R0 tries=12 attn=1 r=00 00 00 00
#	R1 tries=0  attn=1 r=a5 00 00 00
#	R2 tries=0  attn=0 r=a5 01 18 00
#	R3 tries=0  attn=0 r=a5 01 18 00
#
# Two things are settled by that. **The mode control is real** -- CH_CFG bits
# [3:2] track the requested mode exactly, so the old sweep it was doubted for
# can be trusted to have changed something. And mode 3 reads are bit-shifted:
# 0x4a is 0xa5 shifted left one, which is what a wrong sampling edge looks
# like.
#
# The rest is not settled. STATUS_OK is 0x01 and the identify payload is 24
# bytes, so `a5 01 18 00` is the exact shape of a successful command response
# -- but R0 may have reset the part, and every arm after it ran on a part in a
# changed state with a drain that gives up silently after twelve tries. The
# responses could be leftovers.
#
# And there is a second candidate that has nothing to do with the mode.
# `echo mode N` calls `spi_setup()` unconditionally, even for the mode it is
# already in, and mainline's `s3c64xx_spi_setup()` calls
# `pm_runtime_get_sync()`, which forces a resume and therefore
# `s3c64xx_spi_hwinit()`: INT_EN, MODE_CFG, PACKET_CNT and SWAP_CFG rewritten,
# pending interrupts cleared, `cur_speed = 0` so the next transfer
# reconfigures the clock, and `s3c64xx_flush_fifo()` -- a SW_RST of both
# FIFOs. So the previous boot ran a full controller re-init immediately before
# every command, which it had never done before. That, not the mode, may be
# the whole story.
#
# This separates them. Mode 0 throughout, never changed, so the only variable
# is whether spi_setup() runs first:
#
#	A  drain, command                 the historical shape, which fails
#	B  drain, mode 0, command         same mode, but hwinit first
#	C  drain, command                 A again, after B, to catch a part
#	                                  that simply warmed up
#
# CMD_IDENTIFY rather than CMD_RESET on purpose: it does not reset the part,
# so there is no 400 ms window of 0x00 to confuse the next arm, and its reply
# is self-verifying -- STATUS_OK, 24 bytes, then 01 01 and the ASCII part
# number. Reading `53 33 39 30 38` back is proof and not inference.
set -u

L() { echo "tegu-su: $*" > /dev/kmsg; }
A=0x15060004

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

# Drain until the part answers padding, and say so when it never does -- the
# previous probe's drain gave up silently and that is why its later arms are
# uninterpretable.
D() {
	d=0
	q=no
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		case "$(cut -c1-11 < "$X")" in 5a*) q=yes; break ;; esac
		d=$((d + 1))
	done
}

H() {
	h=0
	v=""
	while [ $h -lt 8 ]; do
		echo 'r 8' > "$X"
		v=$(cut -c1-11 < "$X")
		case "$v" in a5*|5a*) break ;; esac
		h=$((h + 1))
	done
	L "$1 alive=$h attn=$(devmem $A 32) $v"
}

# $1 label, $2 "setup" to run spi_setup() first. Enough bytes to see the
# ASCII part number in the payload, which is what makes a reply undeniable.
C() {
	D
	[ "$2" = setup ] && echo 'mode 0' > "$X"
	echo 't 02 00 00' > "$X"
	r=""
	k=0
	while [ $k -lt 12 ]; do
		echo 'r 32' > "$X"
		r=$(cut -c1-44 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 drain=$d quiet=$q tries=$k attn=$(devmem $A 32)"
	L "$1 r=$r"
	Z="$Z $1:d=$d$q,t=$k,$(printf %s "$r" | cut -c1-11)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

H h0
C A plain
H h1
C B setup
H h2
C C plain
H h3

L "Z:$Z"
L "Z:$Z"
L END

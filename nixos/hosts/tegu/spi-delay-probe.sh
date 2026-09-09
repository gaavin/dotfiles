#!/bin/sh
# Sleep before the first read, the way the vendor does. That may be all of it.
#
# Six identical CMD_IDENTIFY in mode 0 got nothing:
#
#	1n:yes,t=12,5a  2n:yes,t=12,5a  3s:yes,t=12,ff
#	4s:no,t=12,ff   5n:no,t=12,ff   6n:no,t=12,ff
#
# Arms 1 and 2 ran on a provably quiet part with no reply, so the command path
# is not reliable and the one boot that worked needs explaining rather than
# celebrating. spi_setup() before the command is dead again as the cause: arm 3
# had it, quiet=yes, and not only failed but took the part to 0xff.
#
# The difference is *when the first read happens*, and the vendor says so
# outright. syna_tcm_v1_write_message() in polling mode does:
#
#	syna_pal_sleep_ms(polling_ms);
#	retval = syna_tcm_v1_read_message(tcm_dev, NULL);
#
# with polling_ms = RESP_IN_POLLING = CMD_RESPONSE_POLLING_DELAY_MS = 2. It
# **sleeps before reading at all.** Every probe this port has written reads
# immediately after the command.
#
# And the boot that worked had a delay in it by accident -- the `mode 0` call
# sat between the transmit and the poll:
#
#	P1  t -> read  1.5 ms   a5 0e 00 00   replied
#	P2  t -> read   11 ms   a5 0e 00 00   replied
#	P0  t -> read    5 ms   a5 01 18 00   full identify
#	1-6 t -> read  immediate              nothing, six times
#
# Note what rules out "the part is merely slow": the later polls in that boot
# were 20 ms apart and still found only padding. So an immediate first read
# does not just miss the response, it appears to **destroy** it -- the exact
# mirror of "commanding on a pending message wedges the part", which this port
# established long ago and then only ever applied in one direction.
#
#	A  command, sleep 20 ms, then poll     expect a reply
#	B  identical to A                      one reply is an anecdote
#	C  command, poll immediately           the control, expect nothing
#
# The control goes last because it is the arm expected to hurt the part, and
# because it is what every previous boot already did.
set -u

L() { echo "tegu-dl: $*" > /dev/kmsg; }
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
	L "$1 alive=$h $v"
}

# $1 label, $2 "w" to wait before the first read.
C() {
	D
	echo 't 02 00 00' > "$X"
	[ "$2" = w ] && sleep 0.02
	r=""
	k=0
	while [ $k -lt 12 ]; do
		echo 'r 40' > "$X"
		r=$(cut -c1-89 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 wait=$2 drain=$d quiet=$q tries=$k attn=$(devmem $A 32)"
	L "$1 r=$(printf %s "$r" | cut -c1-35)"
	Z="$Z $1$2:$q,t=$k,$(printf %s "$r" | cut -c4-5)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

C A w
H h1
C B w
H h2
C C n
H h3

L "Z:$Z"
L "Z:$Z"
L END

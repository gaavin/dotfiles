#!/bin/sh
# The command path works. Is it reliable, and what does it need?
#
# CMD_IDENTIFY was sent in mode 0 and answered in full:
#
#	P0 r=a5 01 18 00 01 01 53 33 39 30 38 47 41 31 42 30 2d 31 35
#	      2e 30 00 62 2f 44 00 00 04 5a
#
# marker, STATUS_OK, 24 bytes, version 1, mode 1, "S3908GA1B0-15.0", build
# 4468578, max_write_size 1024, end of message. On a part that had reached
# padding first, answered on the first poll. That is the whole thing working.
#
# Two corrections fall out of the same boot. **Mode 0 is right**, matching
# Google, and the CPOL gradient built from the previous boot was an artifact:
# mode 2 here returns `a5 0e 00 00`, STATUS_NOT_IMPLEMENTED, so it reaches the
# part but mangles the command byte into something it declines. And the
# earlier `a5 01 18 00` from modes 2 and 3 were leftovers of the reset R0
# caused, exactly the confound that boot was flagged for.
#
# What is not understood is why the same operation failed a boot earlier. Arms
# A and B of spi-setup-probe.sh were both mode 0 on a provably quiet part, one
# with spi_setup() and one without, and neither answered. Here it answers. The
# only visible difference is that P0 followed two commands the part had
# already replied to, which suggests something has to happen first -- but that
# is one boot and a guess, and this port has paid for those.
#
# So: six identical CMD_IDENTIFY in mode 0, from the first moment after boot,
# alternating whether spi_setup() runs first. No mode changes, nothing else
# touched. That answers three things at once -- whether the first command of a
# boot lands, whether they keep landing, and whether spi_setup() matters --
# and it is the measurement the driver needs before it can rely on any of it.
#
# The status byte is what to read in the digest: 01 is STATUS_OK, 0e is
# NOT_IMPLEMENTED, 00 is IDLE, and 5a means it never answered at all.
set -u

L() { echo "tegu-rp: $*" > /dev/kmsg; }
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

# $1 label, $2 "s" to run spi_setup() first.
C() {
	D
	[ "$2" = s ] && echo 'mode 0' > "$X"
	echo 't 02 00 00' > "$X"
	r=""
	k=0
	while [ $k -lt 12 ]; do
		echo 'r 40' > "$X"
		r=$(cut -c1-89 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 setup=$2 drain=$d quiet=$q tries=$k attn=$(devmem $A 32)"
	L "$1 r=$(printf %s "$r" | cut -c1-35)"
	Z="$Z $1$2:$q,t=$k,$(printf %s "$r" | cut -c4-5)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

C 1 n
C 2 n
C 3 s
C 4 s
C 5 n
C 6 n

L "Z:$Z"
L "Z:$Z"
L END

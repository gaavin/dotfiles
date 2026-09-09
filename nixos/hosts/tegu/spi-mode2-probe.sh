#!/bin/sh
# Send CMD_IDENTIFY in mode 2 and read the answer back in full. If the part
# number comes back in ASCII, the command path works and the mode is the fix.
#
# spi_setup() is out. It was the other candidate for the responses the mode
# sweep produced, and this boot separated them with mode 0 fixed throughout:
#
#	h0 alive=0            a5 10 18 00   part alive, identify queued
#	A  d=1 quiet=yes t=12 5a 5a 5a 5a   quiet part, plain command, nothing
#	h1 alive=0            5a 5a 5a      still alive
#	B  d=0 quiet=yes t=12 ff ff ff ff   quiet part, spi_setup, nothing
#	h2 alive=8            ff ff ff ff   part no longer driving MISO
#
# Both arms ran on a part that had provably reached padding, so **mode 0
# fails cleanly**, and hwinit before the command changes nothing. What is left
# is the mode, and across two boots it lines up:
#
#	mode 0   nothing                  three clean attempts
#	mode 1   a5 00 00 00              STATUS_IDLE
#	mode 2   a5 01 18 00              STATUS_OK, 24 bytes
#	mode 3   a5 01 18 00              STATUS_OK, 24 bytes
#
# Both answering modes have CPOL = 1, and mode 2 is the one that also reads
# cleanly -- mode 3 reads come back shifted a bit (0x4a for 0xa5).
#
# The previous boot cannot carry this on its own: R0 may have reset the part
# and its drain gave up silently, so those replies could be leftovers. This
# probe removes that. The drain reports whether it truly reached padding, and
# the reply is read back far enough to contain the ASCII part number. A reply
# of
#
#	a5 01 18 00 01 01 53 33 39 30 38 ...
#
# is marker, STATUS_OK, 24 bytes, version 1, mode 1, then "S3908" -- proof
# rather than inference, and impossible to produce as a leftover of anything
# this probe did not ask for.
#
# Two identical mode-2 arms, because one reply is an anecdote. The mode 0
# control goes last: it is already established, and the part has a limited
# number of commands in it -- two mode-0 commands ended the previous boot.
#
# Commands go out in the mode under test and every read is taken in mode 0,
# where reads are known good, which is the shape that produced the replies.
set -u

L() { echo "tegu-m2: $*" > /dev/kmsg; }
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
	L "$1 alive=$h attn=$(devmem $A 32) $v"
}

# $1 label, $2 mode to transmit in.
C() {
	D
	echo "mode $2" > "$X"
	echo 't 02 00 00' > "$X"
	echo 'mode 0' > "$X"
	r=""
	k=0
	while [ $k -lt 12 ]; do
		echo 'r 40' > "$X"
		r=$(cut -c1-89 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 m=$2 drain=$d quiet=$q tries=$k attn=$(devmem $A 32)"
	L "$1 r=$r"
	Z="$Z $1/$2:$q,t=$k,$(printf %s "$r" | cut -c1-11)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

H h0
C P1 2
H h1
C P2 2
H h2
C P0 0
H h3

L "Z:$Z"
L "Z:$Z"
L END

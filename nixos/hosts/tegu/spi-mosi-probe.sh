#!/bin/sh
# Is MOSI connected to the part at all? Second attempt; the first was void.
#
# CMD_RESET did nothing -- the command that cannot be ignored, on a healthy
# drained part, at two clock rates. Nor did IDENTIFY, at four SPI modes, bare
# or padded. Nothing on MOSI has ever had an effect, while reads stay
# byte-perfect, and reads need only CLK, CS and MISO. The pads cannot be
# inspected: there is no gpb bank in Google's zumapro pinctrl tables or the
# stock DTS, and no pinctrl controller covers HSI0 at all. So the part has to
# be the instrument.
#
# The first run of this probe read 00 00 00 00 00 00 00 00 for every variant
# *including the undriven one*, which is the path that has always worked. That
# is not a result, it is a broken measurement: the part was still booting. It
# was waiting on ATTN, and ATTN is not meaningful right after a reset -- it
# was already high at 0 ms every time while the part was not yet answering.
#
# The fix is the vendor's own, and it is written in this driver's comments
# already: syna_tcm_v1_read() reads, checks byte 0 for the marker, and on
# anything else sleeps and reads the whole packet again, up to ten times. The
# device re-presents its message from the marker on the next read. A single
# read is not a measurement; a read that never finds a marker is.
#
# So each variant retries until it sees 0xa5, and reports how many tries it
# took. Changing only what sits on MOSI:
#
#	v0  undriven (tx_buf NULL)   the path that has always worked
#	v1  all zeros
#	v2  all ones
#	v3  undriven again           proves the part still answers, so any
#	                             difference above was the data and not wear
#
#	all four resynchronise    -> MOSI does nothing to the part. The pad is
#	                             not driving it, and the a5 XX ff readings
#	                             were an artefact of having TXCH on.
#	v1/v2 never resynchronise -> the wire is live and destructive, so the
#	                             part hears us and the fault is decoding.
#
# Each variant gets its own pending message from a reset pulse, since reading
# one consumes it and writing one destroys it, with a fixed settle afterwards
# rather than a wait on ATTN.
set -u

L() { echo "tegu-mosi: $*" > /dev/kmsg; }
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

# Reset and settle. Google's timing is 2 ms of reset and 50 ms after, which
# this driver already found is not always enough, so wait four times that and
# let the retry loop cover the rest.
RS() {
	echo 'reset' > "$X"
	sleep 0.2
}

# $1 label, $2 the tcm_xfer command. Retry until the marker shows up.
TRY() {
	t=0
	o=""
	while [ $t -lt 12 ]; do
		echo "$2" > "$X"
		o=$(cut -c1-23 < "$X")
		case "$o" in a5*) break ;; esac
		sleep 0.02
		t=$((t + 1))
	done
	L "$1 tries=$t attn=$(AT) $o"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null

RS ; TRY v0 'r 8'
RS ; TRY v1 't 00 00 00 00 00 00 00 00'
RS ; TRY v2 't ff ff ff ff ff ff ff ff'
RS ; TRY v3 'r 8'

L END

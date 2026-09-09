#!/bin/sh
# Is MOSI connected to the part at all?
#
# CMD_RESET did nothing. That is the command that cannot be ignored -- if it
# lands, the part reboots and announces itself -- and it did nothing at 10 MHz
# and at the slower clock, drained first, on a healthy part. Nothing put on
# MOSI has ever had an effect: not IDENTIFY, not RESET, at four SPI modes, two
# clock rates, padded or bare.
#
# Everything else works. Reads are byte-perfect, and reads need only CLK, CS
# and MISO. So the question is no longer which command or which timing, it is
# whether the fourth wire is there.
#
# The one piece of evidence that says it is: twice, writing while a message
# was pending returned two header bytes and then 0xff -- a5 10 ff, a5 c2 ff --
# where writing to a quiet part returns clean 5a padding. That was read as the
# part detecting a write and abandoning its message. But it rests on two
# samples taken by hand, and an older experiment in the handover disagrees
# with it outright: Q2 and Q3 drove MOSI with zeros and with 0xff and got back
# 00 00 00, not a truncated header.
#
# So test it directly. A part with a message ready is the detector: read the
# first eight bytes three ways, changing only what sits on MOSI.
#
#	v0  MOSI undriven   tx_buf NULL, the path that has always worked
#	v1  MOSI all zeros
#	v2  MOSI all ones
#
#	all three identical    -> MOSI does nothing to the part. The pad is
#	                          not driving it, and the a5 XX ff readings
#	                          were an artefact of having TXCH on.
#	v1/v2 differ from v0   -> the part is reacting to MOSI, the wire is
#	                          live, and the fault is in what it decodes.
#
# Each variant needs its own pending message, because reading one consumes it
# and writing one destroys it. The reset pad supplies them on demand: a pulse
# reboots the part and it queues a REPORT_IDENTIFY, which is also a second
# check on whether the reset line still works.
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

# Reset, then wait for the part to announce itself. Bounded at ~2 s; Google's
# own timing is 2 ms of reset and 50 ms of settling, and the driver already
# found 50 ms is not always enough.
W8() {
	echo 'reset' > "$X"
	w=0
	while [ $w -lt 40 ]; do
		sleep 0.05
		a=$(AT)
		[ $((a & 1)) -eq 1 ] && break
		w=$((w + 1))
	done
	L "$1 attn=$a after $((w * 50))ms"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null

W8 v0
echo 'mosi 0' > "$X"
echo 'r 8' > "$X"
L "v0 undriven $(cat "$X") attn=$(AT)"

W8 v1
echo 't 00 00 00 00 00 00 00 00' > "$X"
L "v1 zeros    $(cat "$X") attn=$(AT)"

W8 v2
echo 't ff ff ff ff ff ff ff ff' > "$X"
L "v2 ones     $(cat "$X") attn=$(AT)"

# And once more undriven, to prove the part still answers after both writes
# and that any difference above was the MOSI data rather than wear.
W8 v3
echo 'r 8' > "$X"
L "v3 undriven $(cat "$X") attn=$(AT)"

L END

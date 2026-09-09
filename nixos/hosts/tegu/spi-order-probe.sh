#!/bin/sh
# The same sequence that worked by hand, but through the driver's transfers.
#
# spi-drain-cmd-probe.sh got a whole conversation out of the part -- identify,
# two fw-status reports, then STATUS_IDLE -- by draining while ATTN was high,
# commanding only once it went low, and then polling. Every byte parsed and
# the part stayed healthy.
#
# That run was entirely hand-driven, though, and hand-driven means slow: every
# devmem is a process, so each step was milliseconds from the last where the
# driver would be microseconds. So two explanations still fit:
#
#	the ordering was wrong   -> the driver just needs to drain and poll,
#	                            which is a small, safe change
#	the timing was wrong     -> the part needs more time than spi_sync
#	                            gives it, and the driver needs delays too
#
# This separates them. Identical order, identical bytes, but every transfer
# goes through tcm_xfer, so the SPI core, chip-select handling, FIFO flushing
# and runtime PM are all back in play. If the conversation still works, the
# fix is ordering alone.
#
# "t 02 00 00" rather than "w": both transmit, but t keeps what arrives on
# MISO during the command, and that capture is what showed the part aborting
# its message two bytes in.
#
# Reads are 32 bytes: enough for the 29-byte identify and any short report,
# and short enough that a line survives a UART that drops characters.
set -u

L() { echo "tegu-ord: $*" > /dev/kmsg; }

# gpn0[0], active high: high means the part has a message waiting.
A=0x15060004
AT() { devmem $A 32; }

# tcm_xfer appears only after probe() returns -- the driver core adds
# dev_groups afterwards -- so wait rather than assume.
X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null

# Drain. A write destroys whatever the part is presenting, so the command must
# not go out until ATTN is low.
i=0
while [ $i -lt 6 ]; do
	a=$(AT)
	[ $((a & 1)) -eq 0 ] && break
	echo 'r 32' > "$X"
	L "D$i a=$a $(cat "$X")"
	i=$((i + 1))
done

L "CW attn=$(AT) (want 0)"
echo 't 02 00 00' > "$X"
L "CW got $(cat "$X")"

# Poll. The reply did not arrive on the first read by hand either.
i=0
while [ $i -lt 6 ]; do
	echo 'r 32' > "$X"
	L "R$i $(cat "$X")"
	i=$((i + 1))
done

L "END attn=$(AT)"
L END

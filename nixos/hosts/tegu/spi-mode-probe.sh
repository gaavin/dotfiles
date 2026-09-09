#!/bin/sh
# Sweep the SPI mode for the command direction, properly this time.
#
# Where this stands: the bus works, the part is healthy, draining before
# commanding stops it wedging -- and the command is still ignored. Last boot,
# through the driver, the identify was drained (D0), the part went quiet, the
# command went out, and six reads returned nothing but 5a padding with ATTN
# never rising.
#
# That also retires the idea that the earlier hand-driven identify was a reply
# to CMD_IDENTIFY. It was the queued message that S0 failed to drain: when the
# drain succeeds, the command produces nothing.
#
# But the part does notice a write. Writing while a message is pending gives
# a5 10 ff and a5 c2 ff -- two header bytes and then the line released -- while
# writing to a quiet part gives a clean 5a 5a 5a. If that third byte were a
# capture artefact of having TXCH on, padding would break at byte three too,
# and it does not. So MOSI reaches the part, the part sees a write starting,
# and it abandons its outbound message -- and then does nothing with what it
# received. Bits arriving but not decoding is a timing question.
#
# Which has never been tested. Mainline's s3c64xx only applies CPOL and CPHA
# from inside
#
#	if (bpw != sdd->cur_bpw || speed != sdd->cur_speed) {
#		...
#		sdd->cur_mode = spi->mode;
#		status = s3c64xx_spi_config(sdd);
#
# so setting spi->mode alone never reaches CH_CFG. Google's driver assigns
# cur_mode outside that check; mainline does not. The driver's "mode N"
# command therefore does nothing, and every mode result in the handover was
# measured against a bus that never changed mode.
#
# So set CPOL and CPHA in CH_CFG directly. Nothing puts them back: only
# s3c64xx_spi_config() writes those bits and it will not run, while
# enable_datapath(), flush_fifo() and hwinit() all read-modify-write CH_CFG
# and preserve them.
#
# Per mode: drain in mode 0, switch, command, switch back, read the reply.
# Splitting it that way matters -- if the part wants a different edge for MOSI
# than for MISO, a sweep that changes both at once would hide it.
set -u

L() { echo "tegu-md: $*" > /dev/kmsg; }

CH=0x111d0000
A=0x15060004
AT() { devmem $A 32; }

# CPOL is CH_CFG bit 3, CPHA bit 2, so SPI mode n is simply n << 2.
M() {
	c=$(devmem $CH 32)
	devmem $CH 32 $(( (c & ~0xc) | ($1 << 2) ))
}

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
L "ch at rest $(devmem $CH 32)"

for m in 0 1 2 3; do
	# Drain in the mode that is known to read correctly. A write destroys
	# whatever the part is presenting, so the part must be quiet first.
	M 0
	# d, not j: the read loop below reuses j, and logging j after it would
	# report the read count as the drain count.
	d=0
	while [ $d -lt 4 ]; do
		a=$(AT)
		[ $((a & 1)) -eq 0 ] && break
		echo 'r 32' > "$X"
		d=$((d + 1))
	done

	M $m
	echo 't 02 00 00' > "$X"
	w=$(cat "$X")
	an=$(AT)

	M 0
	r=""
	j=0
	while [ $j -lt 3 ]; do
		echo 'r 32' > "$X"
		r="$r|$(cut -c1-23 < "$X")"
		j=$((j + 1))
	done
	L "m$m drained=$d w=$w attn=$an r=$r"
done

M 0
L "ch restored $(devmem $CH 32)"
L END

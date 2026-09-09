#!/bin/sh
# Does "mode N" actually reach the hardware? And does CMD_RESET land in any
# mode? One boot, and the first half validates the instrument for the second.
#
# The length test came back harmless:
#
#	h0=0 t1(d=1) h1=0 t2(d=0) h2=0 t3(d=0) h3=0
#
# t2 was 02 ff ff, CMD_IDENTIFY declaring 65535 payload bytes, and the part
# stayed healthy through it and everything after. That was written up in
# advance as proving the part does not parse our length. **It does not prove
# that.** max_write_size from the identify is 1024, so 65535 is not merely
# large, it is invalid, and a firmware that validates the field would reject
# the command and stay healthy -- which is exactly what was seen. Parsing and
# rejecting, and not parsing at all, predict the same observation. The
# discriminator was not one.
#
# So the question is still whether the part receives our bytes as sent, and
# the live mechanism for "it does not" is that it samples MOSI on the wrong
# clock edge. That would explain every result at once: reads fine, commands
# ignored as garbage, and the only two byte patterns that ever changed the
# part's behaviour being 0x00 and 0xff, the two that survive a bit shift
# unchanged.
#
# The handover says modes 0-3 were already swept, that 0 and 1 both read
# correctly and none accepted a command. Both halves of that are doubtful.
# Every command result from that era was taken with the broken drain. And
# "CPHA does not affect reads" is not how SPI works -- with CPHA wrong the
# master samples MISO on the edge the part is changing it -- so a sweep where
# two adjacent modes read identically is more likely a sweep that never
# changed anything.
#
# Part 1 settles that directly, because CH_CFG carries the mode:
#
#	S3C64XX_SPI_CPOL_L	(1 << 3)
#	S3C64XX_SPI_CPHA_B	(1 << 2)
#
# so CH_CFG bits [3:2] must read back equal to the mode that was asked for.
# s3c64xx_spi_config() rewrites them from spi->mode on every transfer, so the
# read is taken after a transfer, not straight after the store.
#
# Part 2 then sends CMD_RESET in each mode. CMD_RESET is the one command that
# announces itself -- the part reboots and queues an identify -- and **ATTN is
# a devmem read of gpn0, so it is a witness that owes nothing to the SPI
# controller and works in the modes where reads do not.** Drain and poll are
# done in mode 0, where reads are known good; only the command byte goes out
# in the mode under test.
#
# Mode 0 goes first: it is what Google sets (synaptics,spi-mode = <0>) and
# what this port already uses, so it is the least likely to wedge the part,
# and one death ends the boot.
set -u

L() { echo "tegu-mv: $*" > /dev/kmsg; }
A=0x15060004
C=0x111d0000

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

# Drain on what the part says, never on ATTN, which drops mid-message.
D() {
	d=0
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		case "$(cut -c1-11 < "$X")" in 5a*) break ;; esac
		d=$((d + 1))
	done
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Y=""
Z=""

# Part 1. Set each mode, force a transfer so s3c64xx_spi_config() applies it,
# then read CH_CFG back. bits must equal m or the control does nothing.
for m in 0 1 2 3; do
	echo "mode $m" > "$X"
	echo 'r 8' > "$X"
	v=$(cut -c1-11 < "$X")
	c=$(devmem $((C + 0)) 32)
	b=$(( (c >> 2) & 3 ))
	L "m$m ch=$c bits=$b r=$v"
	Y="$Y $m:b=$b,$(printf %s "$v" | cut -c1-5)"
done

echo 'mode 0' > "$X"

# Part 2. CMD_RESET in each mode, ATTN as the witness.
for m in 0 1 2 3; do
	echo 'mode 0' > "$X"
	D
	echo "mode $m" > "$X"
	echo 't 04 00 00' > "$X"
	echo 'mode 0' > "$X"
	r=""
	k=0
	while [ $k -lt 12 ]; do
		a=$(devmem $A 32)
		echo 'r 32' > "$X"
		r=$(cut -c1-11 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "R$m tries=$k attn=$a r=$r"
	Z="$Z $m:t=$k,$(printf %s "$r" | cut -c1-5)"
done

L "Y:$Y"
L "Y:$Y"
L "Z:$Z"
L "Z:$Z"
L END

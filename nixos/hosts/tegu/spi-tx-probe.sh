#!/bin/sh
# Does the touch SPI controller transmit? A hand-driven transfer says so
# directly, with no SPI core and no touchscreen in the way.
#
# The handover's L4/L5 said internal loopback echoed nothing and concluded the
# transmit datapath is dead. That contradicts an earlier, equally direct
# result -- loopback echoing a5 5a 0f f0 byte for byte -- and the two cannot
# both stand. spi-modecfg-probe.sh asks which of them is measuring what it
# thinks; this one goes around the argument entirely.
#
# Drive a four-byte transfer by hand, reading the FIFO levels at each step. In
# internal loopback the block feeds its own transmit data back to its own
# receive path, so pads, muxing and the part are all out of the picture and
# there is exactly one thing left that can fail.
#
# The driver is never asked to transfer, and that is what makes this
# trustworthy. s3c64xx_spi_hwinit() rewrites MODE_CFG from scratch --
#
#	writel(0, regs + S3C64XX_SPI_MODE_CFG);
#	val |= (S3C64XX_SPI_MAX_TRAILCNT << S3C64XX_SPI_TRAILCNT_OFF);
#	writel(val, regs + S3C64XX_SPI_MODE_CFG);
#
# 0x3ff << 19 is 0x1FF80000, this port's MODE_CFG at rest -- but it runs only
# from s3c64xx_spi_runtime_resume(), and only a transfer triggers a resume. So
# with the driver left alone nothing rewrites the register behind us.
#
# Leaving the controller runtime-suspended is safe: ipclk and pclk are
# fixed-clock stubs and every gate on the CMU_HSI0 USI2 path is open with
# MANUAL clear, so clk_disable_unprepare() does not stop this block. The
# registers stay live, which is how touch-probe.sh has been reading them all
# along.
#
# Chip select is ours to drive: spi-manual-cs.py removes
# S3C64XX_SPI_QUIRK_CS_AUTO from the gs101 port config in this build, so
# CS_REG = 0 asserts and 1 releases, exactly as s3c64xx_spi_set_cs() does.
#
# Three readings, each falsifying a different claim:
#
#	filled   tx=4          the FIFO took the bytes. If this reads 0 the
#	                       writes never landed and nothing downstream
#	                       matters.
#	enabled  tx=0          the shifter consumed them. If it stays at 4 the
#	                       transmit datapath really is dead.
#	rx       a5 5a 0f f0   the bits went round.
#
# Four bytes at ~10 MHz take 3.2 us, far less than one devmem invocation, so
# "enabled" already shows the finished state rather than the transfer in
# flight. That is fine: the question is whether it moved, not when.
#
# No kernel build needed, which is the point -- a kernel change costs a
# rebuild and an 11 GB rootfs reflash, and this answers the same question with
# the registers this port has been reading all along.
#
# Code is terse because it has to be: tegu-cmd has about 1.4 KB of kernel
# command line to carry it, and it strips these comments before sending.
set -u

L() { echo "tegu-spi: $*" > /dev/kmsg; }

# spi_20 @ 0x111d0000. Offsets, not names, to stay inside the budget:
#   0x00 CH_CFG   0x04 CLK_CFG  0x08 MODE_CFG  0x0c CS_REG   0x10 INT_EN
#   0x14 STATUS   0x18 TX_DATA  0x1c RX_DATA   0x20 PKT_CNT  0x24 PEND_CLR
#   0x28 SWAP_CFG 0x2c FB_CLK
B=0x111d0000
R() { devmem $((B + $1)) 32; }
W() { devmem $((B + $1)) 32 $2; }

# The touch interrupt, gpn0[0], active high on this board: high means a
# message is waiting. Read only -- the pull is not touched, because a probe
# that leaves a resistor here makes every later reading a reading of the
# resistor.
A=0x15060004

# gs101's STATUS: TX level [14:6], RX level [23:15], TX_DONE at 25. The FIFO
# levels are the whole point -- "the datapath does not shift" and "the FIFO
# never took the data" are different faults with the same symptom.
S() {
	s=$(R 0x14)
	printf '%s tx=%d rx=%d d=%d' "$s" \
		$(((s >> 6) & 0x1ff)) $(((s >> 15) & 0x1ff)) $(((s >> 25) & 1))
}

D() { L "$1 ch=$(R 0) mode=$(R 8) cs=$(R 0xc) pkt=$(R 0x20) $(S)"; }

L BEGIN

# Is the part alive this boot? Every later reading is uninterpretable without
# it, and a read is the one operation known to work: tx_buf is NULL, so the
# transmit channel is never enabled and MOSI is never driven.
#
# tcm_xfer appears only after probe() returns -- the driver core adds
# dev_groups afterwards -- so wait for it rather than assume it.
X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done

if [ -z "$X" ]; then
	L "P0 no tcm_xfer"
else
	echo 'poll 0' > "$X" 2>/dev/null
	echo 'r 29' > "$X"
	L "P0 identify = $(cat "$X")"
fi
D "P1 at rest"

# INT_EN is masked for the duration below. The four error interrupts are
# enabled at rest (s3c64xx_spi_runtime_resume writes 0x3c), and their handler
# prints an unrate-limited dev_err; a storm out of a hand-driven transfer
# would take the log with it, and the log is the result. Nothing is lost --
# the same four error flags are bits 5:2 of STATUS, which every reading below
# prints raw.
C=$(R 0)
I=$(R 0x10)
Z=""
# If devmem is not answering, stop before writing anything: an empty $C would
# drop an argument from the restore at the end and leave the channel enabled.
[ -n "$C" ] || { L "no devmem"; exit 1; }
M() {
	W 0x10 0
	# $1 label, $2 MODE_CFG. Quiesce and clear both FIFOs the way the
	# driver does -- channels off, pulse SW_RST, channels still off. HS_EN
	# stays clear; it is only for >= 30 MHz.
	W 0x20 0
	W 0 $((C & ~0x43))
	W 0 $(((C & ~0x43) | 0x20))
	W 0 $((C & ~0x63))
	W 0x24 0x1e ; W 0x24 0
	W 0x28 0 ; W 0x2c 0
	W 8 $2
	W 0xc 0
	W 0x20 $((0x10000 | 4))
	L "$1 armed mode=$(R 8) pkt=$(R 0x20) cs=$(R 0xc)"
	# Fill with the channel still off, the order the driver uses:
	# s3c64xx_enable_datapath() writes the FIFO before it writes CH_CFG.
	W 0x18 0xa5 ; W 0x18 0x5a ; W 0x18 0x0f ; W 0x18 0xf0
	f=$(S)
	W 0 $(((C & ~0x60) | 0x3))
	e=$(S)
	L "$1 fill[$f] en[$e]"
	# Pop only what the FIFO says it holds. Reading an empty RX FIFO is
	# not worth finding out about on this SoC.
	s=$(R 0x14)
	n=$(((s >> 15) & 0x1ff))
	o=""
	i=0
	while [ $i -lt $n ] && [ $i -lt 8 ]; do
		o="$o$(printf %02x $(R 0x1c)),"
		i=$((i + 1))
	done
	L "$1 rx_lvl=$n rx=$o"
	# Stash a one-line digest. The last capture was truncated exactly here,
	# so the answer gets repeated at the end where a short line has the
	# best chance of surviving a UART that is visibly dropping characters.
	Z="$Z $1 f[${f#* }] e[${e#* }] rx=$o"
}

L "P2 loopback: nothing leaves the block"
M P2 0x1FF80008

# Same transfer, loopback off, aimed at the part. This splits the question the
# handover has been unable to split: "MOSI never reaches the pad" from "the
# part ignores what it is told".
#
# MISO floats to its pull-up at 0xff when nothing drives it, and this part
# drives it low when it objects. Bytes back that are neither 0xff nor the
# part's own message mean the part heard something -- so MOSI is muxed and
# driving, and the fault is above the wire. All 0xff and it heard nothing.
#
# Last, because it talks at the part, and three unanswered requests take it
# from talking to silent.
L "P3 attn=$(devmem $A 32)"
M P3 0x1FF80000
L "P3 attn=$(devmem $A 32)"

# Put it back. A probe that leaves the block configured poisons every later
# reading -- this port has paid for that once already, with a pull-up left on
# the interrupt line. The driver re-runs hwinit on its next transfer anyway,
# but that is its business, not an excuse.
W 0 $((C & ~0x63))
W 0x20 0
W 0xc 1
W 8 0x1FF80000
W 0 $C
W 0x10 $I
D "P4 restored"

L "R:$Z"
L "R:$Z"
L END

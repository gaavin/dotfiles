#!/bin/sh
# Send a real TouchComm command by hand and see whether the part answers.
#
# The physical layer is now proven (spi-tx-probe.sh, 2026-09-09): the
# controller transmits, and with loopback off the part answered 5a 5a 5a 5a,
# TouchComm padding, so it is powered, selected, listening and driving MISO.
# Reads return whole messages. What has never worked is a command.
#
# The packet shape is not in doubt. syna_tcm_v1_write() builds
#
#	out.buf[0] = command
#	out.buf[1] = payload_len & 0xff
#	out.buf[2] = (payload_len >> 8) & 0xff
#	out.buf[3...] = payload
#
# so CMD_IDENTIFY (0x02) with no payload is exactly "02 00 00", which is what
# this port's driver already sends. CRC is not appended either: the vendor
# assumes has_crc, then clears it when the two bytes past the message read
# 0x5a5a, and this part's identify ends in a bare 5a EOM with 5a padding
# after it. So the bytes are right and something about the *transfer* is not.
#
# Driving it by hand removes, in one move, everything the driver does that a
# command might not survive: chip-select timing, the flush_fifo() SW_RST after
# every transfer, transfer splitting, and runtime PM re-initialising the block
# between steps. It also gives the part far more time than the driver does --
# each devmem is a process, so CS-to-clock and command-to-read are
# milliseconds rather than microseconds.
#
# Two attempts and no more. Three unanswered requests take this part from
# talking to 0x5a padding to 0x00 to not driving MISO, so C1 and C2 are the
# whole budget and the baseline read has to come first.
#
#	C1  write and read under separate chip selects, the vendor's shape
#	C2  both under one chip select
#
# Read the answer off C1r/C2r: a marker byte a5 means the part accepted the
# command and is replying. All 5a means it heard clocks and had nothing to
# say, so the command was not understood as one. All ff means it stopped
# driving, and all 00 means it is wedged and the boot is spent.
set -u

L() { echo "tegu-cmd: $*" > /dev/kmsg; }

# spi_20 @ 0x111d0000: 0x00 CH_CFG, 0x08 MODE_CFG, 0x0c CS_REG, 0x10 INT_EN,
# 0x14 STATUS, 0x18 TX_DATA, 0x1c RX_DATA, 0x20 PKT_CNT, 0x24 PEND_CLR.
B=0x111d0000
R() { devmem $((B + $1)) 32; }
W() { devmem $((B + $1)) 32 $2; }
A=0x15060004

S() {
	s=$(R 0x14)
	printf '%s tx=%d rx=%d d=%d' "$s" \
		$(((s >> 6) & 0x1ff)) $(((s >> 15) & 0x1ff)) $(((s >> 25) & 1))
}

# Channels off, SW_RST pulse to empty both FIFOs, pending cleared. The same
# order s3c64xx_flush_fifo() uses, minus the parts that need the driver.
Q() {
	W 0x20 0
	W 0 $((C & ~0x43))
	W 0 $(((C & ~0x43) | 0x20))
	W 0 $((C & ~0x63))
	W 0x24 0x1e ; W 0x24 0
}

# Drain the RX FIFO into a hex string. Bounded, because a runaway level would
# otherwise spin here.
P() {
	s=$(R 0x14)
	n=$(((s >> 15) & 0x1ff))
	o=""
	i=0
	while [ $i -lt $n ] && [ $i -lt 40 ]; do
		o="$o$(printf %02x $(( $(R 0x1c) & 0xff )))"
		i=$((i + 1))
	done
	L "$1 rx_lvl=$n rx=$o"
	# Stash for the repeat at the end: the last two boots both lost their
	# tail to a UART that drops characters, and one short line carrying the
	# whole answer has the best chance of getting through.
	Z="$Z $1=$o"
}

# Transmit the given bytes. RXCH is enabled alongside TXCH because that is how
# the driver does it -- PACKET_CNT then generates exactly the right number of
# clocks -- and it means MISO is captured while the command goes out, which a
# plain write would throw away.
WR() {
	l=$1 ; shift ; c=$#
	Q
	W 0xc 0
	W 0x20 $((0x10000 | c))
	for b in "$@"; do W 0x18 $b; done
	L "$l fill $(S)"
	W 0 $(((C & ~0x60) | 0x3))
	L "$l sent $(S)"
	P "$l"
}

# Clock without transmitting: RXCH only, TXCH off. This is the one path that
# has always worked, and it is what leaves MOSI undriven -- syna_spi_read()
# passes tx_buf = NULL for exactly this reason.
RD() {
	Q
	W 0xc 0
	W 0x20 $((0x10000 | $2))
	W 0 $(((C & ~0x61) | 0x2))
	L "$1 clk $(S)"
	P "$1"
}

L BEGIN

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] && { echo 'poll 0' > "$X" 2>/dev/null; echo 'r 29' > "$X"; L "P0 id=$(cat "$X")"; }

C=$(R 0)
I=$(R 0x10)
Z=""
[ -n "$C" ] || { L "no devmem"; exit 1; }
W 0x10 0
W 8 0x1FF80000

# C1: the vendor's shape. Command under one chip select, released, then the
# reply read under another.
L "C1 attn=$(devmem $A 32)"
WR C1w 0x02 0x00 0x00
W 0xc 1
RD C1r 16
W 0xc 1
L "C1 attn=$(devmem $A 32)"

# C2: both halves inside one chip select, which is what a controller with
# CS_AUTO removed is supposed to give a multi-transfer message.
L "C2 attn=$(devmem $A 32)"
WR C2w 0x02 0x00 0x00
RD C2r 16
W 0xc 1
L "C2 attn=$(devmem $A 32)"

W 0 $((C & ~0x63))
W 0x20 0
W 0xc 1
W 0x10 $I
L "R:$Z"
L "R:$Z"
L END

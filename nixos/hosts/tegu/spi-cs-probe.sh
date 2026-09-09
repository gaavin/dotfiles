#!/bin/sh
# Is chip select the reason no command has ever been understood?
#
# Google runs this touchscreen in MANUAL chip-select mode, and mainline cannot.
# From zuma-tegu-common-touch.dtsi:
#
#	controller-data {
#		samsung,spi-feedback-delay = <0>;
#		samsung,spi-chip-select-mode = <0>;
#		cs-clock-delay = <2>;
#	};
#
# In soc-gs drivers/spi/spi-s3c64xx.c, mode 0 is MANUAL_CS_MODE and the
# default when the property is absent is AUTO_CS_MODE. So this is a deliberate
# per-slave override, and only two devices in the whole tegu tree take it:
# this touchscreen (delay 2) and the eSE (delay 18).
#
# What MANUAL_CS_MODE with a delay does, in Google's driver:
#
#	enable_cs()        SLAVE_SEL = 0            chip select asserted
#	enable_datapath()  CH_CFG |= TXCH_ON
#	                   udelay(cs->cs_delay)     <-- 2 us before any clock
#	                   fill the FIFO, start
#	disable_cs()       SLAVE_SEL = SIG_INACT    released, in software
#
# Mainline's gs101 port config hardcodes S3C64XX_SPI_QUIRK_CS_AUTO, so
# s3c64xx_spi_set_cs() writes CS_AUTO | NSC_CNT_2 and the hardware drives nSS
# off the packet counter, giving two SCLK cycles -- about 200 ns at 10 MHz --
# where Google arranges at least 2 us. set_cs(false) is a no-op entirely.
#
# This is the only difference between the two drivers on the touch bus that
# this port has not already refuted. fifosize, dma-mode and swap-mode were all
# checked and none can matter; feedback-delay is 0 on both.
#
# The A/B, in one boot, same command, same part:
#
#	A  02 00 00 through the driver          CS_AUTO, ~200 ns setup
#	B  02 00 00 driven by hand              CS held in software throughout,
#	                                        milliseconds of setup, because
#	                                        every devmem is its own process
#
# B is the generous bracket on purpose: if 2 us is what the part needs, then
# milliseconds certainly is, and if B still says nothing then CS timing is
# dead as a suspect and the fault is above the wire.
#
# The hand-driven half is spi-tx-probe.sh's proven sequence -- it already
# echoed a5 5a 0f f0 in loopback and drew 5a 5a 5a 5a out of the part -- with
# one change: the bytes are a real TouchComm command instead of a test
# pattern. No command has ever been sent this way. Every command this port has
# tried went through spi_sync(), so all of them share whatever the driver
# does, and none of them isolate it.
#
# CMD_IDENTIFY with length 0 is the safest command there is: established over
# many boots to leave the part healthy, and unmistakable if it lands, because
# the part answers with its identify report.
set -u

L() { echo "tegu-cs: $*" > /dev/kmsg; }
A=0x15060004
B=0x111d0000
R() { devmem $((B + $1)) 32; }
W() { devmem $((B + $1)) 32 $2; }

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

# Drain on what the part says, never on ATTN: ATTN drops as soon as a read
# starts consuming a message, while the rest is still queued, so a drain that
# trusts it stops mid-message and the next command lands inside one.
D() {
	d=0
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		case "$(cut -c1-11 < "$X")" in 5a*) break ;; esac
		d=$((d + 1))
	done
}

# Alive if it answers a marker or padding; dead if 0x00 or 0xff.
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
	Z="$Z $1=$h"
}

# Poll for a reply. 10 reads at 20 ms is 200 ms; the vendor polls far less.
P() {
	r=""
	k=0
	while [ $k -lt 10 ]; do
		echo 'r 32' > "$X"
		r=$(cut -c1-17 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 tries=$k attn=$(devmem $A 32) r=$r"
	Z="$Z $1:t=$k,$(printf %s "$r" | cut -c1-8)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

H h0

# A: the driver's own path, CS_AUTO. The control.
D
echo 't 02 00 00' > "$X"
L "A drain=$d w=$(cut -c1-11 < "$X")"
P A
H h1

# B: the same three bytes, chip select ours from before the first clock to
# after the last. INT_EN is masked first -- the four error interrupts print an
# unrate-limited dev_err and a storm would destroy the log that is the result.
D
C=$(R 0)
I=$(R 0x10)
Q=$(R 0xc)
[ -n "$C" ] || { L "no devmem"; exit 1; }
W 0x10 0
W 0x20 0
W 0 $((C & ~0x43))
W 0 $(((C & ~0x43) | 0x20))
W 0 $((C & ~0x63))
W 0x24 0x1e ; W 0x24 0
W 8 0x1FF80000
W 0x20 $((0x10000 | 3))
# Fill with the channel still off, the order the driver uses: no clock runs
# until CH_CFG is written, so nothing is on the wire yet.
W 0x18 0x02 ; W 0x18 0x00 ; W 0x18 0x00
f=$(R 0x14)
# Chip select asserted here and the clock started on the very next write, so
# the part gets one devmem -- about a millisecond -- of chip select before the
# first edge, where mainline's NSC_CNT_2 gives it two SCLK cycles, about
# 200 ns. Deliberately only one: holding chip select down for the four writes
# this used to take is its own way to confuse a part, and would have made a
# null result unreadable.
W 0xc 0
W 0 $(((C & ~0x60) | 0x3))
# Released immediately. Three bytes at 10 MHz take 2.4 us and a devmem is a
# thousand times that, so the transfer is long finished.
W 0xc 1
s=$(R 0x14)
n=$(((s >> 15) & 0x1ff))
o=""
i=0
while [ $i -lt $n ] && [ $i -lt 4 ]; do
	o="$o$(printf %02x $(( $(R 0x1c) & 0xff )))"
	i=$((i + 1))
done
L "B drain=$d f=$f s=$s done=$(((s >> 25) & 1)) rx=$o"
Z="$Z B[$f>$s,$o]"

# Put the block back. A probe that leaves it configured poisons every later
# reading; this port has paid for that once with a pull-up left on ATTN.
W 0 $C
W 0x10 $I
W 0xc $Q

P B
H h2

L "R:$Z"
L "R:$Z"
L END

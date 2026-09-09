#!/bin/sh
# Did the loopback bit survive to the transfer that was supposed to use it?
#
# The handover's L4/L5 set MODE_CFG bit 3 (SELF_LOOPBACK) with devmem, ran a
# transfer, saw nothing echoed, and concluded the transmit datapath is dead.
# The bit was never read back, and there is a concrete mechanism in mainline
# that would have removed it first:
#
#	s3c64xx_spi_runtime_resume()  ->  s3c64xx_spi_hwinit()
#	    writel(0, regs + S3C64XX_SPI_MODE_CFG);
#	    ...
#	    val |= (S3C64XX_SPI_MAX_TRAILCNT << S3C64XX_SPI_TRAILCNT_OFF);
#	    writel(val, regs + S3C64XX_SPI_MODE_CFG);
#
# 0x3ff << 19 is 0x1FF80000 -- exactly the MODE_CFG this port reads at rest,
# and exactly what L1 and L6 reported either side of the attempt. The
# controller sets auto_runtime_pm with AUTOSUSPEND_TIMEOUT 2000, so it
# suspends two seconds after a transfer and re-runs hwinit on the next one.
# Every line of a shell script is far more than two seconds apart, so a bit
# poked in with devmem cannot be expected to reach the next transfer.
#
# If that is what happened, L4/L5 measured an ordinary external transfer
# against a part that answers 0xff, and say nothing about transmit. The whole
# claim rests on one register read that was never taken.
#
# Companion to spi-tx-probe.sh, which answers the transmit question outright
# by driving a transfer by hand. Run that one first if only one boot is going
# spare: this explains why an earlier result was wrong, that one says what is
# actually true. They are two scripts because tegu-cmd has about 1.4 KB of
# kernel command line to carry a payload and both together do not fit.
set -u

L() { echo "tegu-spi: $*" > /dev/kmsg; }

# spi_20 @ 0x111d0000: 0x00 CH_CFG, 0x08 MODE_CFG, 0x0c CS_REG, 0x14 STATUS,
# 0x20 PKT_CNT, 0x28 SWAP_CFG, 0x2c FB_CLK.
B=0x111d0000
R() { devmem $((B + $1)) 32; }
W() { devmem $((B + $1)) 32 $2; }

# gs101's STATUS: TX level [14:6], RX level [23:15], TX_DONE at 25.
S() {
	s=$(R 0x14)
	printf '%s tx=%d rx=%d done=%d' "$s" \
		$(((s >> 6) & 0x1ff)) $(((s >> 15) & 0x1ff)) $(((s >> 25) & 1))
}

D() { L "$1 ch=$(R 0) mode=$(R 8) cs=$(R 0xc) pkt=$(R 0x20) swap=$(R 0x28) fb=$(R 0x2c) $(S)"; }

L BEGIN

# Is the part alive this boot? A read is the one operation known to work:
# tx_buf is NULL, so the transmit channel is never enabled and MOSI is never
# driven. tcm_xfer appears only after probe() returns -- the driver core adds
# dev_groups afterwards -- so wait for it rather than assume it.
X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "P0 no tcm_xfer -- the touch driver did not probe"; L END; exit 0; }

echo 'poll 0' > "$X" 2>/dev/null
echo 'r 29' > "$X"
L "P0 identify = $(cat "$X")"
D "P1 at rest"

# The caveat, closed. Set SELF_LOOPBACK, run a transfer that actually
# transmits, and read MODE_CFG back before anything else can touch it.
# Nothing on this path clears bit 3: s3c64xx_spi_config() would, but it runs
# only when bits-per-word or speed change and neither does here, and
# s3c64xx_enable_datapath() and s3c64xx_flush_fifo() both read-modify-write
# MODE_CFG and preserve it. So the value read back is the value the transfer
# ran with.
#
#	mode=0x1FF80008 after  ->  loopback really was on. L4/L5 stand and the
#	                           transmit datapath is dead.
#	mode=0x1FF80000 after  ->  the bit was gone before the transfer. L4/L5
#	                           measured a normal external transfer and say
#	                           nothing about transmit.
#
# "t a5 5a 0f f0" is deliberately a transmitting transfer: tx_buf is
# non-NULL, which is what sets CH_TXCH_ON. If the bit survived, the reply is
# the echo; if it did not, those four bytes went at the touchscreen as a
# command and may wedge it -- which is why P0 reads the part first and why
# nothing after this depends on the part being well.
W 8 0x1FF80008
L "P2 armed mode=$(R 8) (want 0x1FF80008)"
echo 't a5 5a 0f f0' > "$X"
L "P2 mode immediately after tx = $(R 8)"
D "P2 after tx"
L "P2 echoed = $(cat "$X") (want a5 5a 0f f0 if loopback held)"

# Which write cleared it. The controller autosuspends two seconds after a
# transfer and hwinit runs on resume, so a second transfer issued immediately
# -- while it is still awake -- has no resume to run. Same two commands, no
# gap between them:
#
#	survives here but not above  ->  runtime-PM resume, i.e. hwinit
#	cleared both times           ->  something on the transfer path
W 8 0x1FF80008 ; echo 't a5 5a 0f f0' > "$X" ; P=$(R 8)
L "P3 mode after a back-to-back tx = $P"
L "P3 echoed = $(cat "$X")"

# And the same question for the feedback tap, which the driver's "fb" command
# pokes the same way. s3c64xx_spi_prepare_message() writes FB_CLK from the
# slave's controller-data on every message, so that one is rewritten per
# transfer rather than per resume -- worth having the reading rather than the
# reasoning.
W 0x2c 3
L "P4 fb set to $(R 0x2c)"
echo 'r 4' > "$X"
L "P4 fb after a transfer = $(R 0x2c) (0 means prepare_message rewrote it)"

W 8 0x1FF80000
W 0x2c 0
D "P5 restored"
L END

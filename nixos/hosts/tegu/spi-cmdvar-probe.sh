#!/bin/sh
# Four command variants against a part that is now kept healthy by draining.
#
# Where this stands. The bus is proven, MOSI reaches the part -- it abandons
# its outbound message when a write starts -- and draining before commanding
# stops it wedging, so several attempts now fit in one boot where three used
# to kill it. What still does not happen is any response: ATTN never rises.
#
# Ruled out since the last boot, each properly rather than by assumption:
#
#   SPI mode.   Writing CPOL/CPHA into CH_CFG directly finally moved the
#               hardware -- padding read back as 5a, b4, 69, which is one
#               0x5a stream sampled 0, 1 and 2 bits late -- and no mode
#               produced a reply. The driver's "mode N" had never worked:
#               mainline applies cur_mode only inside its bpw/speed check.
#   Poll time.  The vendor polls every 2 ms for up to CMD_RESPONSE_TIMEOUT_MS
#               = 3000, but ATTN stayed low the whole time here, so the part
#               had nothing to give rather than something we missed.
#   swap-mode.  For 8-bit words Google writes SWAP_CFG = 0, same as mainline.
#
# So stop narrowing and widen. Four variants, each drained first, each
# followed by ATTN and three reads:
#
#   c1  02 00 00 at 10 MHz          the control, known to do nothing
#   c2  02 00 00 at 6.25 MHz        the slowest this clock tree reaches;
#                                   tests whether the part can sample MOSI at
#                                   10 MHz even though it drives MISO fine
#   c3  02 00 00 + five 00 bytes    tests whether the packet needs trailing
#                                   clocks before the part acts on it
#   c4  04 00 00                    CMD_RESET, and the one that cannot be
#                                   mistaken: if it lands the part reboots
#                                   and announces itself with an identify
#
# c4 is last because it changes the part's state. The CMU divider is logged
# either side of the speed change, because "the driver accepted hz" is not
# evidence the clock moved -- this port has been burned by exactly that.
set -u

L() { echo "tegu-var: $*" > /dev/kmsg; }

A=0x15060004
AT() { devmem $A 32; }
# DIV_CLK_HSI0_USI2, CMU_HSI0 + 0x181c. Ratio is the low bits, rate is
# 400 MHz / (ratio + 1), and the controller divides by a further 4.
DIV=0x1100181c

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

# $1 label, $2 the bytes. Drain first: a write destroys whatever the part is
# presenting, and commanding on a pending message is what used to wedge it.
T() {
	d=0
	while [ $d -lt 4 ]; do
		a=$(AT)
		[ $((a & 1)) -eq 0 ] && break
		echo 'r 32' > "$X"
		d=$((d + 1))
	done
	echo "t $2" > "$X"
	w=$(cat "$X")
	an=$(AT)
	r=""
	j=0
	while [ $j -lt 3 ]; do
		echo 'r 32' > "$X"
		r="$r|$(cut -c1-17 < "$X")"
		j=$((j + 1))
	done
	L "$1 drained=$d w=$w attn=$an r=$r"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
L "div=$(devmem $DIV 32)"

T c1 "02 00 00"

echo 'hz 6250000' > "$X"
L "slow div=$(devmem $DIV 32) (want ratio 15)"
T c2 "02 00 00"

echo 'hz 10000000' > "$X"
L "fast div=$(devmem $DIV 32) (want ratio 9)"
T c3 "02 00 00 00 00 00 00 00"

T c4 "04 00 00"
L "post-reset attn=$(AT)"
T c5 "02 00 00"

L END

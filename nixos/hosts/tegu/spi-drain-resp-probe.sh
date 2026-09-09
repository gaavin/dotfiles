#!/bin/sh
# Read past STATUS_IDLE. The response may have been one message further on
# every time.
#
# Releasing chip select after the command is established. Pulsing CS_REG and
# nothing else made the part answer on the first read where the control got
# nothing in twelve:
#
#	A  after=spi_setup  t=0   a5 00 00 00
#	B  after=spi_setup  t=0   a5 c2 02 00 20 00
#	R  after=CS pulse   t=0   a5 00 00 00      attn=1
#	C  after=nothing    t=12  5a 5a 5a ...     <- control
#
# R is the clean one: it touches CS_REG and no other register, so this is chip
# select and not hwinit's FIFO flush or its cur_speed reset.
#
# It also reported **cs=0x00000000**. This build already removes
# S3C64XX_SPI_QUIRK_CS_AUTO (kernel/spi-manual-cs.py, applied by apply.sh), so
# set_cs() writes 0 to assert and 1 to release -- and reading 0 after a
# transfer means chip select is being left **asserted**. That is the fault, and
# it is why Google's disable_cs() writes SIG_INACT explicitly.
#
# But none of those replies is a command response. 0x00 is STATUS_IDLE and
# 0xc2 is REPORT_FW_STATUS, routine telemetry. **The poll loop breaks on the
# first `a5`**, so it stops at whatever message happens to be at the head of
# the queue. In the one boot that produced the identify, the first framed
# message simply was the identify. The response to CMD_IDENTIFY may have been
# one message further along every other time, and this port would not have
# seen it.
#
# So: read on. Break only on STATUS_OK (a5 01), log every message seen on the
# way, and print the whole payload when it arrives. Chip select is pulsed
# after the command and again between reads, because each read is its own
# spi_sync() and each leaves it asserted the same way.
#
# Three identical arms. If STATUS_OK arrives second or third behind an IDLE,
# that is the command path working and the driver simply has to keep reading --
# which is what syna_tcm_v1_read_message() does anyway.
set -u

L() { echo "tegu-dr2: $*" > /dev/kmsg; }
A=0x15060004
S=0x111d000c

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

# Release chip select the way disable_cs() would, then put the register back
# to whatever the driver left: under this build set_cs() owns bit 0, and a
# probe that leaves SIG_INACT set holds the bus inactive for the whole boot.
P() {
	Q=$(devmem $S 32)
	devmem $S 32 1
	devmem $S 32 $Q
}

D() {
	d=0
	q=no
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		case "$(cut -c1-11 < "$X")" in 5a*) q=yes; break ;; esac
		d=$((d + 1))
	done
}

C() {
	D
	echo 't 02 00 00' > "$X"
	P
	M=""
	f=""
	k=0
	while [ $k -lt 8 ]; do
		echo 'r 40' > "$X"
		r=$(cut -c1-89 < "$X")
		M="$M $(printf %s "$r" | cut -c1-5)"
		case "$r" in "a5 01"*) f=$r ;; esac
		[ -n "$f" ] && break
		P
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 quiet=$q cs=$Q msgs=$M"
	[ -n "$f" ] && L "$1 OK $(printf %s "$f" | cut -c1-35)"
	Z="$Z $1:$(printf %s "$M" | cut -c1-24)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

C A
C B
C D

L "Z:$Z"
L "Z:$Z"
L END

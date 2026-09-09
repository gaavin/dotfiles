#!/bin/sh
# Replicate the one sequence that ever worked, exactly, before ablating it.
#
# This port has spent four boots removing pieces from a result it never
# reproduced. That is backwards, and the cell table shows why:
#
#	                    mode BEFORE  mode AFTER  result
#	mode2 P0            yes          yes         a5 01 18 00 + identify
#	mode2 P1/P2 (m=2)   yes          yes         a5 0e NOT_IMPLEMENTED
#	repeat 3,4          yes          no          padding
#	release A,B,R       no           yes         a5 00 IDLE
#	drain-resp A,B,D    no           yes         a5 00 IDLE x8
#	release C, delay    no           no          padding
#
# **The both-cell has been occupied exactly once**, and that one boot answered
# three commands coherently -- mode 0 gave STATUS_OK with the full identify,
# mode 2 gave NOT_IMPLEMENTED, which is the correct reply to a mangled command
# byte. Everything since has tested one side or the other and produced IDLE or
# padding, and each was treated as evidence about that side alone.
#
# There is a mechanism for the BEFORE half, in s3c64xx_spi_transfer_one():
#
#	if (bpw != sdd->cur_bpw || speed != sdd->cur_speed) {
#		sdd->cur_speed = speed;
#		status = s3c64xx_spi_config(sdd);
#	}
#
# s3c64xx_spi_config() is **skipped when speed and bpw are unchanged**, and it
# is what writes CH_CFG -- CPOL, CPHA -- and calls clk_set_rate(). hwinit()
# sets cur_speed = 0, so a spi_setup() before the command forces the command's
# own transfer to reconfigure the controller from scratch. Without it the
# transfer runs on whatever state was left behind.
#
#	1  mode 0, command, mode 0     exact replica of P0
#	2  identical to 1              reproducibility
#	3  command, mode 0             ablate BEFORE
#	4  mode 0, command             ablate AFTER
#
# No chip-select pulsing anywhere: P0 did not have it, and it is the stimulus
# under test, not an improvement to bolt on. The only change from P0 is that
# the read loop breaks on STATUS_OK rather than the first marker and logs every
# message on the way -- reading more is safe and it is what showed the IDLEs
# were hiding the answer.
#
# If 1 and 2 both return the identify, the baseline is real and 3 and 4 say
# which half is load-bearing. If they do not, the one success was never about
# the mode calls and this whole line of attack is dead -- which is worth
# knowing in one boot rather than four more.
set -u

L() { echo "tegu-rr: $*" > /dev/kmsg; }
A=0x15060004

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

D() {
	d=0
	q=no
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		case "$(cut -c1-11 < "$X")" in 5a*) q=yes; break ;; esac
		d=$((d + 1))
	done
}

# $1 label, $2 spi_setup before, $3 spi_setup after.
C() {
	D
	[ "$2" = y ] && echo 'mode 0' > "$X"
	echo 't 02 00 00' > "$X"
	[ "$3" = y ] && echo 'mode 0' > "$X"
	M=""
	f=""
	k=0
	while [ $k -lt 8 ]; do
		echo 'r 40' > "$X"
		r=$(cut -c1-89 < "$X")
		M="$M $(printf %s "$r" | cut -c1-5)"
		case "$r" in "a5 01"*) f=$r ;; esac
		[ -n "$f" ] && break
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 b=$2 a=$3 quiet=$q attn=$(devmem $A 32) msgs=$M"
	[ -n "$f" ] && L "$1 OK $(printf %s "$f" | cut -c1-35)"
	Z="$Z $1:$(printf %s "$M" | cut -c1-17)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

C 1 y y
C 2 y y
C 3 n y
C 4 y n

L "Z:$Z"
L "Z:$Z"
L END

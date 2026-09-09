#!/bin/sh
# The real bring-up: app info, report config, enable reports, then look for
# touch data. Using the sequence that now works reproducibly.
#
# CMD_IDENTIFY answered on the first message, twice, with the full payload:
#
#	1 b=y a=y quiet=yes msgs= a5 01
#	1 OK a5 01 18 00 01 01 53 33 39 30 38 47      <- STATUS_OK, "S3908G"
#	3 b=n a=y            msgs= a5 c2 5a 5a ...    <- no OK, BEFORE required
#	4 b=y a=n            msgs= ff ff ff ...       <- part stops, AFTER required
#
# So the working shape is spi_setup(), command, spi_setup(), read -- and both
# halves are load-bearing. The one action they share is that hwinit() rewrites
# CS_REG, which in this build (S3C64XX_SPI_QUIRK_CS_AUTO stripped by
# spi-manual-cs.py, and no-cs-readback absent so no_cs is false) means:
#
#	writel(S3C64XX_SPI_CS_SIG_INACT, CS_REG);
#
# Chip select released. Measured, CS_REG reads 0 after an ordinary transfer --
# asserted -- so the driver is not deasserting it between messages and the
# part never sees a transaction boundary. Reads never needed one, because a
# queued message streams out on any clock; a command does.
#
# That explanation is not finished -- spi_set_cs() passes the driver a pin
# level rather than an activate flag, so the polarity wants instrumenting
# before any driver fix is written -- but the sequence is reproducible now, so
# use it rather than wait for the theory.
#
#	A  20 00 00      CMD_GET_APPLICATION_INFO
#	B  25 00 00      CMD_GET_TOUCH_REPORT_CONFIG
#	E  05 01 00 11   CMD_ENABLE_REPORT, payload REPORT_TOUCH
#
# then read for about ten seconds looking for a5 11, REPORT_TOUCH. **Touch the
# screen as soon as the phone boots** -- the window opens roughly eighteen
# seconds in and anything the panel sees should turn into messages.
#
# Report headers are logged as they arrive, at most a few, plus a count. A
# touch report is a5 11 with a non-zero length; a5 00 is idle and a5 c2 is the
# routine firmware-status telemetry this part emits on its own.
set -u

L() { echo "tegu-bu: $*" > /dev/kmsg; }

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
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		case "$(cut -c1-11 < "$X")" in 5a*) break ;; esac
		d=$((d + 1))
	done
}

# $1 label, $2 command bytes. The working shape, unchanged.
C() {
	D
	echo 'mode 0' > "$X"
	echo "t $2" > "$X"
	echo 'mode 0' > "$X"
	r=""
	k=0
	while [ $k -lt 8 ]; do
		echo 'r 40' > "$X"
		r=$(cut -c1-89 < "$X")
		case "$r" in "a5 01"*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 t=$k $(printf %s "$r" | cut -c1-44)"
	Z="$Z $1:$(printf %s "$r" | cut -c1-5)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

C A "20 00 00"
C B "25 00 00"
C E "05 01 00 11"

L "TOUCH THE SCREEN NOW"
n=0
t=0
j=0
while [ $j -lt 400 ]; do
	echo 'r 40' > "$X"
	v=$(cut -c1-44 < "$X")
	case "$v" in
	"a5 11"*) t=$((t + 1)); [ $t -lt 4 ] && L "RPT $v" ;;
	a5*) n=$((n + 1)) ;;
	esac
	j=$((j + 1))
done
L "Z:$Z msgs=$n touch=$t"
L "Z:$Z msgs=$n touch=$t"
L END

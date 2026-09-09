#!/bin/sh
# Reporting is enabled. Now actually listen for touch data, with a window long
# enough to touch the screen in and reads that can see a message.
#
# The bring-up worked:
#
#	B 25 00 00      a5 01 80 00 10 08 1b 38 1e 08 ...   STATUS_OK, 128 bytes
#	E 05 01 00 11   a5 01 00 00                         STATUS_OK, length 0
#
# CMD_GET_TOUCH_REPORT_CONFIG returned the report format and CMD_ENABLE_REPORT
# accepted REPORT_TOUCH. **Touch reporting is on.**
#
# The listening half failed for two reasons, both mistakes in this script
# rather than anything the hardware did:
#
#	1. It ran 18.430 -> 20.320, **1.9 seconds**, not the ten it was
#	   advertised as. 400 reads at ~4.75 ms is two seconds, so there was
#	   no window to touch the screen in at all.
#	2. It read with plain `r 40` and nothing between the reads. This port
#	   had already measured that after a command, reads return padding
#	   unless chip select is released first -- with a pulse between reads
#	   every read framed a message, without it every read returned 5a.
#	   The loop was built without the one thing known to be necessary.
#
# So: `mode 0` before every read, the same release that makes commands land,
# and 1500 iterations at roughly 10 ms -- about fifteen seconds. Progress
# markers every 500 so the real window length is measurable rather than
# claimed.
#
# CMD_GET_APPLICATION_INFO is retried behind a CMD_IDENTIFY warm-up. It failed
# as the first command of its boot, which is now the third time the first
# command after boot has gone unanswered while later identical ones worked.
# That is worth a note of its own: whatever the driver ends up doing, it should
# not trust its first command.
#
# Anything with a marker is logged, not just a5 11 -- if reports arrive under
# a different code this should show it rather than filter it out.
set -u

L() { echo "tegu-tr: $*" > /dev/kmsg; }

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
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null

C W "02 00 00"
C A "20 00 00"
C E "05 01 00 11"

L "TOUCH THE SCREEN NOW -- about 15 seconds"
n=0
t=0
j=0
while [ $j -lt 1500 ]; do
	echo 'mode 0' > "$X"
	echo 'r 40' > "$X"
	v=$(cut -c1-44 < "$X")
	case "$v" in
	"a5 11"*) t=$((t + 1)); [ $t -lt 5 ] && L "RPT $v" ;;
	a5*) n=$((n + 1)); [ $n -lt 5 ] && L "MSG $v" ;;
	esac
	j=$((j + 1))
	case $j in 500|1000) L "mark $j n=$n t=$t" ;; esac
done
L "Z: msgs=$n touch=$t"
L "Z: msgs=$n touch=$t"
L END

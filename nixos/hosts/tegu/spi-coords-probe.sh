#!/bin/sh
# Capture a touch report that differs from idle, in full. The coordinates are
# in the bytes the last probe truncated.
#
# The touchscreen is reporting:
#
#	RPT a5 11 17 00 00 00 00 00 00 00 00 00 00 01 01
#	Z: msgs=414 touch=1086
#
# a5 marker, 0x11 REPORT_TOUCH, length 0x0017 = 23 payload bytes, and 1086 of
# them in a sixteen-second window. The bring-up worked and the part is
# streaming.
#
# CMD_GET_TOUCH_REPORT_CONFIG said what is in those 23 bytes:
#
#	10 08   GESTURE_ID              1 byte
#	1b 38   GESTURE_DATA            7 bytes
#	1e 08   SENSING_MODE            1 byte
#	17 08   NSM_STATE               1 byte
#	18 08   NUM_OF_ACTIVE_OBJECTS   1 byte
#	04      PAD_TO_NEXT_BYTE
#
# That is 11 bytes, and the remaining 12 are the per-object records the
# foreach emits -- index, classification, X, Y. **The log was cut at 44
# characters, which stopped exactly before them.** The reports were logged, the
# coordinates were in them, and the probe threw them away.
#
# So: log the whole thing, 83 characters, and rather than logging the first
# few reports -- which arrive before anyone can reach the screen -- keep the
# first report as a baseline and log only reports that **differ** from it.
# Idle frames are identical to each other, so anything that differs is the
# panel responding to something.
#
# CMD_GET_APPLICATION_INFO is dropped. It has now failed three times, warm-up
# or not, and it is not needed to receive reports -- it carries sensor
# dimensions, which matter for scaling coordinates later, not for proving they
# arrive. One question per boot.
#
# **Touch the screen, and keep moving.** A stationary finger still reports, but
# a moving one makes consecutive frames differ from each other as well as from
# idle, which is the clearest possible signal that these are real coordinates.
set -u

L() { echo "tegu-xy: $*" > /dev/kmsg; }

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
C E "05 01 00 11"

L "TOUCH AND MOVE -- about 15 seconds"
b=""
c=0
t=0
j=0
while [ $j -lt 1500 ]; do
	echo 'mode 0' > "$X"
	echo 'r 40' > "$X"
	v=$(cut -c1-83 < "$X")
	case "$v" in
	"a5 11"*)
		t=$((t + 1))
		if [ -z "$b" ]; then
			b=$v
			L "IDLE $v"
		elif [ "$v" != "$b" ] && [ $c -lt 8 ]; then
			c=$((c + 1))
			L "XY$c $v"
		fi
		;;
	esac
	j=$((j + 1))
	case $j in 750) L "mark n=$t diff=$c" ;; esac
done
L "Z: touch=$t diff=$c"
L "Z: touch=$t diff=$c"
L END

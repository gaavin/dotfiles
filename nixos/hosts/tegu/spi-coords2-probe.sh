#!/bin/sh
# Same capture, but with the console quietened so the answer survives.
#
# Last boot found the touches and lost the evidence:
#
#	tegu-xy: BEGIN
#	tegu-xy: mark n=384 diff=8
#
# **diff=8** -- the cap -- so eight reports differing from idle were captured
# while the screen was being touched. Not one of the lines carrying them
# reached the UART.
#
# The cause is this script's own doing. Putting `mode 0` before every read
# makes the driver emit two lines per iteration:
#
#	zumapro-touch spi0.0: feedback delay set to default (0)
#	zumapro-touch spi0.0: r: 80 us, ret 0
#
# At 1500 iterations that is over three thousand lines. At 115200 baud a
# 60-character line takes about 5 ms, so the loop was not merely noisy, it was
# **rate-limited by the console** -- which is also why each iteration took
# 11 ms. The handover's own rule, "rate-limit anything the poll loop can
# print", was written after this exact failure and then walked into again.
#
# The fix is not to quieten the console. That was tried and it silenced the
# UART completely -- writing 1 to /proc/sys/kernel/printk stopped even our own
# lines, prefixed <0>, from arriving, and the boot produced no output at all.
# It was also unnecessary. The previous boot's "mark" line came through the
# same flood intact, so a line printed **after** the loop, when nothing is
# competing with it, gets through.
#
# So the reports are held in variables and printed at the end, each twice,
# and the console is left alone. The console also paces the loop at about
# 11 ms an iteration, which is where the fifteen-second window comes from.
#
# **Touch the screen and keep moving.**
set -u

L() { echo "tegu-c2: $*" > /dev/kmsg; }

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
x1=""
x2=""
x3=""
x4=""
c=0
t=0
j=0
while [ $j -lt 1200 ]; do
	echo 'mode 0' > "$X"
	echo 'r 40' > "$X"
	v=$(cut -c1-83 < "$X")
	case "$v" in
	"a5 11"*)
		t=$((t + 1))
		if [ -z "$b" ]; then
			b=$v
		elif [ "$v" != "$b" ]; then
			c=$((c + 1))
			case $c in
			1) x1=$v ;;
			40) x2=$v ;;
			80) x3=$v ;;
			120) x4=$v ;;
			esac
		fi
		;;
	esac
	j=$((j + 1))
done
L "IDLE $b"
L "XY1 $x1"
L "XY1 $x1"
L "XY2 $x2"
L "XY2 $x2"
L "XY3 $x3"
L "XY3 $x3"
L "XY4 $x4"
L "Z: touch=$t diff=$c"
L "Z: touch=$t diff=$c"
L END

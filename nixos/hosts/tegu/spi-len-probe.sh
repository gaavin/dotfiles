#!/bin/sh
# Does the part parse the length field, and which write is the one that kills?
#
# Established: MOSI is connected and decoded. Driving it stops the part
# answering where an undriven read on the same part finds the identify on the
# first try, and content matters -- an eight-byte write beginning 0x02 is
# harmless, eight bytes of 0x00 or 0xff are not. So the part reads the first
# byte, tells 0x02 from 0x00, and still never answers a valid command,
# CMD_RESET included.
#
# A misread length field fits that shape exactly. syna_tcm_v1_write() builds
# command, length low, length high; if the length arrives wrong the part
# accepts a valid command, waits for payload that never comes, answers
# nothing, reports no error, and breaks when the next write lands as
# unexpected payload.
#
# The hard constraint is that a reset pulse does not revive a broken part --
# only a full boot does -- so a boot gets one breakage and no more. That makes
# the health check between writes the real instrument: it says exactly which
# write killed it, and everything after a death is void.
#
#	h0  baseline
#	d1  02 00 00       correct, zero length. The control.
#	d2  02 01 00 02    claims one payload byte and supplies it
#	d3  20 00 00       a different command entirely
#
# Every byte here is 0x00, 0x01, 0x02 or 0x20 -- CMD_NONE, CMD_CONTINUE_WRITE,
# CMD_IDENTIFY, CMD_GET_APPLICATION_INFO -- all harmless if the framing slips
# and one of them is read as a command. That rules out the obvious experiment:
# CMD_ENABLE_REPORT wants a report type, and every report type collides with a
# flash command (REPORT_TOUCH 0x11 is CMD_ERASE_FLASH, REPORT_DELTA 0x12 is
# CMD_WRITE_FLASH). On a bus whose framing is the thing under test, those
# bytes are not worth putting on the wire.
set -u

L() { echo "tegu-len: $*" > /dev/kmsg; }
A=0x15060004
AT() { devmem $A 32; }

X=""
i=0
while [ $i -lt 100 ]; do
	X=$(ls /sys/bus/spi/devices/*/tcm_xfer 2>/dev/null | head -1)
	[ -n "$X" ] && break
	sleep 0.1
	i=$((i + 1))
done
[ -n "$X" ] || { L "no tcm_xfer"; exit 1; }

# Alive if it answers a marker or padding; dead if 0x00 or 0xff. Retries,
# because the device re-presents its message from the marker on the next read
# and one read is not a measurement.
H() {
	t=0
	o=""
	while [ $t -lt 6 ]; do
		echo 'r 8' > "$X"
		o=$(cut -c1-11 < "$X")
		case "$o" in a5*|5a*) break ;; esac
		sleep 0.02
		t=$((t + 1))
	done
	L "$1 alive=$t attn=$(AT) $o"
}

# Drain, command, then poll for a reply. A write destroys whatever the part is
# presenting, so it has to be quiet first.
C() {
	d=0
	while [ $d -lt 4 ]; do
		a=$(AT)
		[ $((a & 1)) -eq 0 ] && break
		echo 'r 32' > "$X"
		d=$((d + 1))
	done
	echo "t $2" > "$X"
	w=$(cut -c1-11 < "$X")
	r=""
	t=0
	while [ $t -lt 8 ]; do
		echo 'r 16' > "$X"
		r=$(cut -c1-17 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		t=$((t + 1))
	done
	L "$1 drained=$d w=$w tries=$t attn=$(AT) r=$r"
}

L BEGIN

# Is the AOC even running? The touch SPI bus is shared with it -- Google's
# node has goog,tbn-enabled and tbn,mode = <2>, TBN_MODE_AOC_CHANNEL, and the
# owner enum is AP or AOC -- so a second master on this bus would matter a
# great deal. If it is held off, it cannot be interfering and the negotiator
# is moot; only if it is running is any of that stack worth writing.
#
# Read only what the stock DTS names, and only in the always-on alive domain:
# pd-aoc@15462280 is the power-domain status and aoc_req is at 0x154b0000.
# The AOC block itself is at 0x17000000 and is NOT touched -- it sits behind
# an S2MPU and this SoC raises a fatal SError on a read of an unbacked or
# protected address, which has already cost this port a boot once.
L "aoc pd=$(devmem 0x15462280 32) $(devmem 0x15462284 32) $(devmem 0x15462288 32)"
L "aoc req=$(devmem 0x154b0000 32)"

echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null

H h0
C d1 "02 00 00"
H h1
C d2 "02 01 00 02"
H h2
C d3 "20 00 00"
H h3

L END

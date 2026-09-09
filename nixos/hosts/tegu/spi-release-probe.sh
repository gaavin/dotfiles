#!/bin/sh
# Does the command only land once chip select is released? Every arm this port
# has run says the deciding step happens *after* the transmit.
#
# The delay theory died: 20 ms of sleep before the first read changed nothing,
# and the immediate-read control behaved identically. Tabulating every command
# arm across four boots separates them perfectly on one thing, and it is not
# the delay, the mode, or spi_setup() before the command:
#
#	arm         mode BEFORE   mode AFTER      result
#	mode2 P1    yes (2)       yes (0)         a5 0e 00 00
#	mode2 P2    yes (2)       yes (0)         a5 0e 00 00
#	mode2 P0    yes (0)       yes (0)         a5 01 18 00 + identify
#	setup A     no            no              nothing
#	setup B     yes (0)       no              nothing
#	repeat 1-6  mixed         no              nothing
#	delay A,B   no            no (20ms sleep) nothing
#	delay C     no            no              nothing
#
# Three for three with a `mode` call between the transmit and the first read;
# nothing without, ten times. "Before" is excluded -- setup B and repeat 3/4
# had it and failed -- and a plain sleep is excluded, so it is not time.
#
# The mechanism candidate, and it is the same register this port cleared
# earlier from the other end. Mainline's `s3c64xx_spi_set_cs(spi, false)` is a
# **no-op under S3C64XX_SPI_QUIRK_CS_AUTO** -- read it, it only writes on the
# !CS_AUTO path -- so nothing ever deasserts chip select after a transfer.
# Google's MANUAL_CS_MODE disable_cs() writes SLAVE_SIG_INACT explicitly.
# `spi_setup()` reaches hwinit() and so `s3c64xx_flush_fifo()`, a SW_RST of the
# channel, which would drop chip select as a side effect.
#
# If the part needs the transaction *closed* before it acts on a command, that
# fits everything -- including why reads never cared, since a queued message
# streams out on any clock while a command needs a boundary to be acted on.
# spi-cs-probe.sh tested chip-select *setup* before the first clock and
# correctly refuted it. It never tested the *release*.
#
#	A  command, spi_setup, poll      the shape that has always replied
#	B  identical to A                one reply is an anecdote
#	R  command, pulse CS_REG, poll   release chip select and nothing else
#	C  command, poll                 the control
#
# R is the arm that separates "chip select release" from "hwinit in general".
# It writes SIG_INACT and puts the register straight back to the value the
# driver left, because under CS_AUTO set_cs() only ORs bits in and never
# clears that one -- leaving it set holds chip select inactive for the rest of
# the boot and every later read times out at -5.
set -u

L() { echo "tegu-rl: $*" > /dev/kmsg; }
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

D() {
	d=0
	q=no
	while [ $d -lt 12 ]; do
		echo 'r 40' > "$X"
		case "$(cut -c1-11 < "$X")" in 5a*) q=yes; break ;; esac
		d=$((d + 1))
	done
}

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
}

# $1 label, $2 what to do after the transmit: s spi_setup, r pulse CS, n none.
C() {
	D
	echo 't 02 00 00' > "$X"
	case "$2" in
	s) echo 'mode 0' > "$X" ;;
	r) Q=$(devmem $S 32); devmem $S 32 1; devmem $S 32 $Q ;;
	esac
	r=""
	k=0
	while [ $k -lt 12 ]; do
		echo 'r 40' > "$X"
		r=$(cut -c1-89 < "$X")
		case "$r" in a5*) break ;; esac
		sleep 0.02
		k=$((k + 1))
	done
	L "$1 after=$2 drain=$d quiet=$q tries=$k cs=${Q:-na} attn=$(devmem $A 32)"
	L "$1 r=$(printf %s "$r" | cut -c1-35)"
	Z="$Z $1$2:$q,t=$k,$(printf %s "$r" | cut -c4-5)"
}

L BEGIN
echo 'poll 0' > "$X" 2>/dev/null
echo 'mosi 0' > "$X" 2>/dev/null
Z=""

C A s
H h1
C B s
H h2
C R r
H h3
C C n
H h4

L "Z:$Z"
L "Z:$Z"
L END

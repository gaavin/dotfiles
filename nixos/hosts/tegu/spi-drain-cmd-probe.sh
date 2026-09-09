#!/bin/sh
# Drain first, then command, then poll -- the order the vendor driver uses.
#
# spi-cmd-probe.sh (2026-09-09) showed the part is healthy and reporting: a
# hand-driven "02 00 00" left it talking, and a read got a whole
# REPORT_FW_STATUS message out of it. It also showed what breaks it. ATTN was
# high going into the second attempt -- a message was pending -- and writing a
# command anyway caught the part mid-message and left it driving nothing:
#
#	C2w rx=a5c2ff          the a5 c2 header, then the line released
#	C2r rx=ffffffff...     nothing driving
#
# One command at the wrong moment, from talking to silent. That is very likely
# the whole of "three failing commands wedge this part", and it is what this
# port's driver has always done: it commands whenever it likes.
#
# syna_tcm_v1_write_message() does not. It takes cmd_mutex and rw_mutex, and
# the IRQ thread drains reports, so a command never lands while the part has
# something to say. This is that sequence by hand:
#
#	S0   one read, unconditionally -- proves the part is driving
#	D0.. read while ATTN is high, until it goes low
#	CW   write 02 00 00 only once the part is quiet
#	CR0..poll for the reply
#
# Read the result off the CR lines. A code below 0x10 is a command *status*
# and is the thing that has never been seen -- STATUS_OK is 0x01. 0x10 and
# above is an asynchronous report, which is what C1r turned out to be, so a
# second REPORT_FW_STATUS proves nothing on its own.
#
# The driver is not used at all here, not even for the baseline read: its
# probe stops at identify and never starts the poll work, so nothing else
# touches this bus and no runtime-PM resume can re-init the block underneath.
set -u

L() { echo "tegu-cmd: $*" > /dev/kmsg; }

B=0x111d0000
R() { devmem $((B + $1)) 32; }
W() { devmem $((B + $1)) 32 $2; }

# gpn0[0], active high on this board: high means a message is waiting.
A=0x15060004
AT() { devmem $A 32; }

# Channels off, SW_RST to empty both FIFOs, pending cleared.
Q() {
	W 0x20 0
	W 0 $((C & ~0x43))
	W 0 $(((C & ~0x43) | 0x20))
	W 0 $((C & ~0x63))
	W 0x24 0x1e ; W 0x24 0
}

# Drain the RX FIFO to hex. 40 bytes covers a header, a small payload and the
# EOM in one go, which matters: a message read in two transfers loses bytes.
P() {
	s=$(R 0x14)
	n=$(((s >> 15) & 0x1ff))
	o=""
	# k, not i: shell functions share globals, and the drain and poll loops
	# outside use i. Reusing it here reset their counter on every call and
	# neither loop could ever terminate.
	k=0
	while [ $k -lt $n ] && [ $k -lt 40 ]; do
		o="$o$(printf %02x $(( $(R 0x1c) & 0xff )))"
		k=$((k + 1))
	done
	L "$1 n=$n $o"
}

# Clock without transmitting: RXCH on, TXCH off, which is what leaves MOSI
# undriven and is the only read shape that has ever worked here.
RD() {
	Q
	W 0xc 0
	W 0x20 $((0x10000 | $2))
	W 0 $(((C & ~0x61) | 0x2))
	P "$1"
	W 0xc 1
}

# Transmit, with RXCH on alongside so PACKET_CNT generates the clocks and MISO
# is captured while the command goes out.
WR() {
	l=$1 ; shift ; c=$#
	Q
	W 0xc 0
	W 0x20 $((0x10000 | c))
	for b in "$@"; do W 0x18 $b; done
	W 0 $(((C & ~0x60) | 0x3))
	P "$l"
	W 0xc 1
}

L BEGIN
C=$(R 0)
I=$(R 0x10)
[ -n "$C" ] || { L "no devmem"; exit 1; }
W 0x10 0
W 8 0x1FF80000

# One read no matter what ATTN says. Padding proves it is driving; a message
# means the boot handed us one already.
L "S0 attn=$(AT)"
RD S0 40

# Now drain until it has nothing left. Bounded, because a part that answers
# every read with a message would otherwise spin here forever.
i=0
while [ $i -lt 6 ]; do
	a=$(AT)
	[ $((a & 1)) -eq 0 ] && break
	L "D$i attn=$a"
	RD "D$i" 40
	i=$((i + 1))
done

# Only now, with the part quiet, send the command.
L "CW attn=$(AT) (want 0)"
WR CW 0x02 0x00 0x00

i=0
while [ $i -lt 6 ]; do
	RD "CR$i" 40
	i=$((i + 1))
done
L "END attn=$(AT)"

W 0 $((C & ~0x63))
W 0x20 0
W 0xc 1
W 0x10 $I
L END

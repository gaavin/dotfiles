#!/bin/sh
# Dump the registers the touchscreen stack depends on, to the kernel log, so
# they reach the UART console. There is no ssh on this phone; a boot-time dump
# is the only way to read hardware from userspace and get the result off it.
#
# Ordered least-risky first, with a marker printed BEFORE each region. Not all
# of these blocks are known to be alive, and on this SoC a read of an unclocked
# block does not return garbage -- it raises an SError and panics. That already
# happened once here, sweeping sysreg_ufs at 0x13020000, so the markers are the
# point: whatever the log ends on is the block that was not safe to touch.
set -u

log() { echo "$*" > /dev/kmsg; }

dump() {
	name=$1 base=$2 words=$3
	log "tegu-probe: --- $name @ $base, $words words ---"
	dd if=/dev/mem bs=4 count="$words" skip=$(( base / 4 )) 2>/dev/null \
		| od -An -tx4 -w16 \
		| awk -v b="$base" '{ printf "tegu-probe: +0x%03x  %s %s %s %s\n", \
				      (NR-1)*16, $1, $2, $3, $4 }' \
		| while read -r line; do echo "$line" > /dev/kmsg; done
}

log "tegu-probe: BEGIN"

# Always-on, and this port already writes it at arch_initcall for the UFS VCC
# rail, so it is known good. gpp1[1] is the touch reset line.
dump "pinctrl peric0 (gpp*, touch reset gpp1-1)" $((0x10840000)) 64

# The ALIVE domain, by definition powered whenever the phone is. gpn0[0] is
# the touch interrupt; Google's board tree calls this bank GPIO_CUSTOM_ALIVE.
dump "pinctrl alive (gpn0, touch irq)" $((0x15060000)) 64

# Less certain. The SPI pins GPB10[4..7] are in a PERIC bank, and this is the
# second pinctrl controller; whether its domain is on is exactly the question.
dump "pinctrl peric1 (gpb*, touch spi pins)" $((0x10C40000)) 64

# The prize, and the one worth losing the boot for: bit field at
# sysreg + 0x101c selects what this USI is -- SPI, I2C or UART. If the
# bootloader already put it in SPI mode, a large piece of the touch bring-up
# is already done. Deliberately last, so everything above is on the wire
# before this is attempted.
log "tegu-probe: --- USI mode for touch spi_20: 0x1102101c (LAST, may fault) ---"
dd if=/dev/mem bs=4 count=1 skip=$(( 0x1102101c / 4 )) 2>/dev/null \
	| od -An -tx4 | while read -r v; do echo "tegu-probe: usi_mode =$v" > /dev/kmsg; done

log "tegu-probe: END (all regions survived)"

#!/bin/sh
# Dump the registers the touchscreen stack depends on, to the kernel log, so
# they reach the UART console. There is no ssh on this phone; a boot-time dump
# is the only way to read hardware from userspace and get the result off it.
#
# Use devmem, not dd. On arm64 valid_phys_addr_range() limits /dev/mem read()
# to real memory:
#
#	return memblock_is_region_memory(addr, size) &&
#	       memblock_is_map_memory(addr);
#
# so dd on MMIO returns EFAULT regardless of STRICT_DEVMEM, which is why the
# first version of this script printed its headers and not one register.
# devmem goes through mmap() instead, and that path does reach MMIO.
#
# Ordered least-risky first, with a marker printed BEFORE each region. Not all
# of these blocks are known to be alive, and on this SoC a read of an unclocked
# block does not return garbage -- it raises an SError and panics. That already
# happened here once, sweeping sysreg_ufs at 0x13020000, so the markers are the
# point: whatever the log ends on is the block that was not safe to touch.
set -u

log() { echo "$*" > /dev/kmsg; }

# Four registers per line, so 64 words is 16 lines rather than 64.
dump() {
	name=$1 base=$2 words=$3
	log "$(printf 'tegu-probe: --- %s @ 0x%08x ---' "$name" "$base")"
	i=0
	while [ "$i" -lt "$words" ]; do
		line=$(printf '+0x%03x ' $((i * 4)))
		j=0
		while [ "$j" -lt 4 ] && [ "$i" -lt "$words" ]; do
			line="$line $(devmem $((base + i * 4)) 32)"
			i=$((i + 1))
			j=$((j + 1))
		done
		log "tegu-probe: $line"
	done
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

# The prize, and the one worth losing the boot for: the field at sysreg +
# 0x101c selects what this USI is -- SPI, I2C or UART. If the bootloader has
# already put it in SPI mode, a large piece of the touch bring-up is done.
# Deliberately last, so everything above is on the wire before this is tried.
log "tegu-probe: --- USI mode for touch spi_20: 0x1102101c (LAST, may fault) ---"
log "tegu-probe: usi_mode = $(devmem 0x1102101c 32)"

log "tegu-probe: END (all regions survived)"

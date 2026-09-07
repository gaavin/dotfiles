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

# The clock path for USI11, which is the SPI the touchscreen hangs off. Named
# offsets only, from Google's cal-if tables for this SoC:
#
#	SFR_BLOCK(CMU_TOP,    0x26040000, 0x8000)
#	SFR_BLOCK(CMU_PERIC1, 0x10c00000, 0x8000)
#	SFR(PLL_CON0_MUX_CLKCMU_PERIC1_NOC_USER,       0x0610, CMU_PERIC1)
#	SFR(PLL_CON0_MUX_CLKCMU_PERIC1_USI11_USI_USER, 0x0640, CMU_PERIC1)
#	SFR(CLK_CON_DIV_DIV_CLK_PERIC1_USI11_USI,      0x1810, CMU_PERIC1)
#	SFR(..._USI11_USI_IPCLKPORT_IPCLK,             0x2048, CMU_PERIC1)
#	SFR(..._USI11_USI_IPCLKPORT_PCLK,              0x204c, CMU_PERIC1)
#	SFR(CLK_CON_GAT_GATE_CLKCMU_PERIC1_NOC,        0x211c, CMU_TOP)
#
# This is the same question the HSI2 clocks turned out to answer for UFS: the
# bootloader had left that whole path running and the driver's writes were
# no-ops. If PERIC1 is the same, the SPI needs a provider to satisfy the DT
# and nothing more. Bit 21 is CG_VAL, bit 28 ENABLE_AUTOMATIC_CLKGATING.
one() { log "$(printf 'tegu-probe: %-28s %s = %s' "$1" "$2" "$(devmem "$2" 32)")"; }

log "tegu-probe: --- CMU: the USI11/SPI clock path ---"
one "TOP gate PERIC1_NOC"   0x2604211c
one "PERIC1 NOC user mux"   0x10c00610
one "PERIC1 USI11 user mux" 0x10c00640
one "PERIC1 USI11 div"      0x10c01810
one "PERIC1 USI11 ipclk"    0x10c02048
one "PERIC1 USI11 pclk"     0x10c0204c

# Where that clock comes from, so its rate can be computed rather than
# guessed. CMU_TOP feeds PERIC1 two clocks, NOC (bus) and IP (the one the USI
# runs on). SELECT picks from cmucal_mux_clkcmu_peric1_ip_parents[]:
#
#	0 = PLL_SHARED0_D4, 1 = PLL_SHARED2_D2, 2 = PLL_SHARED3_D2
#
# and DIVRATIO is bits [3:0], dividing by ratio+1. UFS's clock was worked out
# the same way; getting this wrong once already hard-locked the phone, so it
# is read before anything states a frequency.
log "tegu-probe: --- CMU_TOP: where PERIC1_IP comes from ---"
one "TOP PERIC1_IP mux"     0x260410f4
one "TOP PERIC1_IP div"     0x260418ec
one "TOP PERIC1_IP gate"    0x26042118
one "TOP PERIC1_NOC mux"    0x260410f8
one "TOP PERIC1_NOC div"    0x260418f0

# The SPI controller itself. Its clock path reads as fully running above, so
# this block is powered and clocked and these reads are safe -- which was not
# something to assume before the CMU said so. A live CH_CFG here proves the
# bus is reachable before any driver is written for it.
log "tegu-probe: --- SPI controller for touch, spi_20 @ 0x111d0000 ---"
one "spi CH_CFG"           0x111d0000
one "spi MODE_CFG"         0x111d0008
one "spi CS_REG"           0x111d000c
one "spi SPI_INT_EN"       0x111d0010
one "spi SPI_STATUS"       0x111d0014
one "spi PACKET_CNT"       0x111d0020
one "spi FB_CLK_SEL"       0x111d002c

log "tegu-probe: END (all regions survived)"

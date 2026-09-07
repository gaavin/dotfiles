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

# The decisive experiment, and it needs no kernel code at all.
#
# Every SPI register above reads 0x00000000. That is not a dead block: with
# USI SW_CONF = NONE the USI holds whichever IP it fronts in reset, so the SPI
# registers reading zero is exactly what an unconfigured USI looks like. If
# that reading is right, writing SW_CONF = SPI should bring the block out of
# reset and its registers should stop being uniformly zero.
#
# USI_V2_SW_CONF_SPI is BIT(1), from mainline drivers/soc/samsung/exynos-usi.c.
# The pins are not muxed to the SPI function, so nothing outside the SoC can
# be driven by this; the write only decides which IP the USI presents. A
# reboot puts it back.
log "tegu-probe: --- experiment: USI11 SW_CONF = SPI ---"
before=$(devmem 0x1102101c 32)
devmem 0x1102101c 32 0x2
after=$(devmem 0x1102101c 32)
log "tegu-probe: usi_mode $before -> $after (wanted 0x00000002)"

log "tegu-probe: --- SPI controller again, after SW_CONF=SPI ---"
one "spi CH_CFG"           0x111d0000
one "spi MODE_CFG"         0x111d0008
one "spi CS_REG"           0x111d000c
one "spi SPI_INT_EN"       0x111d0010
one "spi SPI_STATUS"       0x111d0014
one "spi PACKET_CNT"       0x111d0020
one "spi FB_CLK_SEL"       0x111d002c

# Release the touchscreen from reset and watch its interrupt line.
#
# The SPI pins need no muxing. Google's tree calls them GPB10[4..7], which is
# a datasheet pad name -- Linux's banks on this SoC are gpa*, gph*, gpn*,
# gpp*, gps* and there is no gpb anywhere. None of the five USIs sharing the
# sysreg at 0x11020000 declare pinctrl in the stock tree either, and touch
# works on Android regardless, so those pads are fixed-function and SW_CONF
# alone decides what the block is. That matches the controller initialising
# correctly here with nothing having muxed a pin.
#
# What is not configured is the reset line. gpp1 is peric0 bank 1, confirmed
# by the stock tree listing its banks in order (gpp0, gpp1, ...) and by gpp0's
# own registers matching what this port's UFS shim prints. TS1_RESET_L is
# gpp1[1], active low, and it currently reads as function 0 -- an input, not
# driven -- so the touch controller is held in reset by nothing at all.
#
# Driving it high is the same move that brought the UFS VCC rail up, and it
# answers the one question that could invalidate the whole touch effort. The
# interrupt line gpn0[0] is active low and idle high. If the part is powered,
# releasing reset should let it drive that line; if the S2MPG14 rails are off,
# nothing will move and we know ACPM has to come first. Its pull-down is
# cleared beforehand so the reading reflects the part and not the SoC.
GPP1_CON=0x10840020 ; GPP1_DAT=0x10840024
GPN0_CON=0x15060000 ; GPN0_DAT=0x15060004 ; GPN0_PUD=0x15060008

log "tegu-probe: --- experiment: release touch reset, watch its irq ---"
log "tegu-probe: gpp1 CON=$(devmem $GPP1_CON 32) DAT=$(devmem $GPP1_DAT 32)"
log "tegu-probe: gpn0 CON=$(devmem $GPN0_CON 32) DAT=$(devmem $GPN0_DAT 32) PUD=$(devmem $GPN0_PUD 32)"

# Let the interrupt line float, so what it reads is what the part drives.
pud=$(devmem $GPN0_PUD 32)
devmem $GPN0_PUD 32 $(( pud & ~0x3 ))
log "tegu-probe: gpn0 pull cleared, PUD now $(devmem $GPN0_PUD 32)"
log "tegu-probe: irq line before reset release: DAT=$(devmem $GPN0_DAT 32)"

# gpp1[1] to output, then high. Read-modify-write: the other pins in this
# bank belong to other peripherals and must not be disturbed.
con=$(devmem $GPP1_CON 32)
devmem $GPP1_CON 32 $(( (con & ~0xf0) | 0x10 ))
dat=$(devmem $GPP1_DAT 32)
devmem $GPP1_DAT 32 $(( dat | 0x2 ))
log "tegu-probe: gpp1 now CON=$(devmem $GPP1_CON 32) DAT=$(devmem $GPP1_DAT 32)"

sleep 1
log "tegu-probe: irq line 1s after reset release: DAT=$(devmem $GPN0_DAT 32)"

# The reading above cannot distinguish the two cases that matter. An
# unpowered part leaves the line floating, and a floating CMOS input reads
# low; a *powered* TouchComm part asserts this same active-low line after
# reset to announce its identify report. Both give DAT bit 0 = 0.
#
# A pull-up separates them. A weak pull-up wins against a high-Z line and
# loses against a transistor actively holding it down:
#
#	reads 1  ->  nothing is driving.  The part is not powered, and the
#	             S2MPG14 rails have to come first, via ACPM.
#	reads 0  ->  something is pulling it down against the pull-up. The
#	             part is powered and asserting its interrupt, and the
#	             rails are already on.
log "tegu-probe: --- discriminator: pull the irq line up ---"
pud=$(devmem $GPN0_PUD 32)
devmem $GPN0_PUD 32 $(( (pud & ~0x3) | 0x3 ))
log "tegu-probe: gpn0 PUD now $(devmem $GPN0_PUD 32) (3 = pull-up on pin 0)"
sleep 1
log "tegu-probe: irq with pull-up, reset released: DAT=$(devmem $GPN0_DAT 32)"

# And a reset pulse to Google's own timing -- synaptics,reset-active-ms = 2,
# synaptics,reset-delay-ms = 50 -- in case the part needs a real edge rather
# than the level it has been sitting at since boot. Sampled repeatedly,
# because the interrupt is a pulse if the part is talking.
log "tegu-probe: --- proper reset pulse, 2ms low, then sample ---"
dat=$(devmem $GPP1_DAT 32)
devmem $GPP1_DAT 32 $(( dat & ~0x2 ))
sleep 0.01
devmem $GPP1_DAT 32 $(( dat | 0x2 ))
i=0
while [ "$i" -lt 10 ]; do
	sleep 0.05
	log "tegu-probe: irq sample $i: DAT=$(devmem $GPN0_DAT 32)"
	i=$((i + 1))
done

# Now ask the part directly. The interrupt has been held low since the reset
# pulse, which is what a TouchComm device does when it has a message waiting
# and is what the pull-up test says is happening -- but a line held low by an
# unpowered pad and a line held low by a live part still look the same from a
# GPIO register. Clocking the bus does not.
#
# If the part is there, the first byte of a TouchComm v1 message is the marker
# 0xA5, followed by a status code and a 16-bit length. Anything that is not
# uniformly 0x00 or 0xff is already proof the rails are on and the bus is
# wired correctly; 0xA5 would be proof it is a TouchComm part talking.
log "tegu-probe: --- talk to the touch part over SPI ---"
dev=$(ls /dev/spidev* 2>/dev/null | head -1)
if [ -z "$dev" ]; then
	log "tegu-probe: no /dev/spidev* -- spidev did not bind"
else
	log "tegu-probe: using $dev"
	log "tegu-probe: irq before transfer: DAT=$(devmem $GPN0_DAT 32)"
	# Keep stderr out of the hex. Last time spi-pipe was missing from the
	# unit's PATH and its "command not found" got dumped as if it were the
	# touchscreen's reply -- readable only because it happened to be ASCII.
	if err=$(head -c 16 /dev/zero | spi-pipe -d "$dev" -s 1000000 2>&1 >/tmp/spi.bin); then
		log "tegu-probe: spi read 16 bytes:$(od -An -tx1 < /tmp/spi.bin | tr -s " \n" " ")"
	else
		log "tegu-probe: spi-pipe failed: $err"
	fi
	log "tegu-probe: irq after transfer:  DAT=$(devmem $GPN0_DAT 32)"
fi

log "tegu-probe: END (all regions survived)"

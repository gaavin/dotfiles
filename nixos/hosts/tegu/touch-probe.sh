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

# The clock path for USI2 in CMU_HSI0, which is the SPI the touchscreen hangs
# off. This used to read CMU_PERIC1, which was simply the wrong block: the
# stock DTB gives spi@111D0000 clocks that resolve through Google's zuma.h to
# VDOUT_CLK_HSI0_USI2_USI and GATE_HSI0_USI2_USI. Named offsets only, from
# Google's cal-if tables for this SoC:
#
#	SFR_BLOCK(CMU_TOP,  0x26040000, 0x8000)
#	SFR_BLOCK(CMU_HSI0, 0x11000000, 0x8000)
#	SFR(PLL_CON0_MUX_CLKCMU_HSI0_PERI_USER,   0x0680, CMU_HSI0)
#	SFR(CLK_CON_MUX_MUX_CLK_HSI0_USI2,        0x101c, CMU_HSI0)
#	SFR(CLK_CON_DIV_DIV_CLK_HSI0_USI2,        0x181c, CMU_HSI0)
#	SFR(CLK_CON_GAT_GATE_CLK_HSI0_USI2,       0x2120, CMU_HSI0)
#	SFR(..._USI2_HSI0_IPCLKPORT_IPCLK,        0x20fc, CMU_HSI0)
#	SFR(..._USI2_HSI0_IPCLKPORT_PCLK,         0x2100, CMU_HSI0)
#	SFR(QCH_CON_USI2_HSI0_QCH,                0x30cc, CMU_HSI0)
#
# Every one of these was read on hardware and is already open; none of it was
# the reason transfers failed. Bit 21 is CG_VAL, bit 20 MANUAL, bit 28
# ENABLE_AUTOMATIC_CLKGATING -- and per Google's ra_get_gate(), with MANUAL
# clear it is bit 28 that decides, not CG_VAL.
one() { log "$(printf 'tegu-probe: %-28s %s = %s' "$1" "$2" "$(devmem "$2" 32)")"; }

log "tegu-probe: --- CMU_HSI0: the USI2/SPI clock path ---"
one "HSI0 PERI_USER mux"    0x11000680
one "HSI0 MUX_CLK_USI2"     0x1100101c
one "HSI0 DIV_CLK_USI2"     0x1100181c
one "HSI0 GATE_CLK_USI2"    0x11002120
one "HSI0 USI2 ipclk"       0x110020fc
one "HSI0 USI2 pclk"        0x11002100
one "HSI0 USI2 QCH"         0x110030cc

# Where that clock comes from, so its rate can be computed rather than
# guessed. SELECT picks from cmucal_mux_clkcmu_hsi0_peri_parents[]:
#
#	0 = PLL_SHARED0_D4, 1 = PLL_SHARED2_D2, 2 = PLL_SHARED3_D2,
#	3 = PLL_SPARE_D1
#
# and DIVRATIO is bits [3:0], dividing by ratio+1. PLL_CON3 carries ENABLE at
# bit 31, STABLE at 29 and M/P/S at [25:16]/[13:8]/[2:0], so the PLL's own
# rate is checkable instead of taken on faith -- which is how the 400 MHz the
# device tree used to claim turned out to be 399.36 MHz.
log "tegu-probe: --- CMU_TOP: where HSI0_PERI comes from ---"
one "TOP HSI0_PERI mux"     0x26041098
one "TOP HSI0_PERI div"     0x26041890
one "TOP HSI0_PERI gate"    0x260420c0
one "TOP PLL_CON3_SHARED2"  0x260401cc

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
log "tegu-probe: --- experiment: USI2 SW_CONF = SPI ---"
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

# Put the line back. This pull-up used to be left on for the rest of the boot,
# which pinned ATTN high from here onwards -- and since the line is read as
# active high, that is indistinguishable from a message the part never stops
# offering. Every ATTN measurement after this point was a measurement of a
# resistor.
devmem $GPN0_PUD 32 $(( pud & ~0x3 ))
log "tegu-probe: gpn0 pull restored, PUD now $(devmem $GPN0_PUD 32)"


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
	# 10 MHz, not 1. The controller has no prescaler (gs101's port config
	# sets clk_from_cmu), so the bit rate comes from the CMU divider alone:
	# 400 MHz through a 4-bit DIVRATIO and the controller's fixed /4 reaches
	# 6.25 MHz to 100 MHz, and lands exactly on 10 MHz -- the touch part's
	# own maximum from Google's board file -- at ratio 9. 1 MHz is not
	# reachable, which is why the last attempt ran the bus at 100 MHz and
	# failed with -EIO.
	log "tegu-probe: using $dev"
	log "tegu-probe: irq before transfer: DAT=$(devmem $GPN0_DAT 32)"
	# Keep stderr out of the hex. Last time spi-pipe was missing from the
	# unit's PATH and its "command not found" got dumped as if it were the
	# touchscreen's reply -- readable only because it happened to be ASCII.
	# Report the exit status, never branch on it. spi-pipe returns 1 for a
	# partial block -- 16 bytes against its 32-byte default -- so a perfectly
	# good transfer looks like a failure, and this script threw the data away
	# and printed "spi-pipe failed:" with an empty error for the first boot on
	# which the bus actually worked. What distinguishes them is the output:
	# bytes read means the transfer ran, nothing means it did not.
	err=$(head -c 16 /dev/zero | spi-pipe -d "$dev" -s 10000000 2>&1 >/tmp/spi.bin)
	rc=$?
	log "tegu-probe: spi rc=$rc err=[$err]"
	log "tegu-probe: spi read $(wc -c < /tmp/spi.bin) bytes:$(od -An -tx1 < /tmp/spi.bin | tr -s " \n" " ")"
	log "tegu-probe: irq after transfer:  DAT=$(devmem $GPN0_DAT 32)"
fi

log "tegu-probe: END (all regions survived)"

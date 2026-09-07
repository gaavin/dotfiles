#!/usr/bin/env python3
"""Let Linux own the cluster watchdogs that the bootloader arms.

BL2 arms a 60-second watchdog on every boot and says so:

	[BL2]
	WD: enabled(60s, 1/3)

Nothing in this port ever petted it, so a working system died on a timer.
The reset reason ABL records is unambiguous:

	[PRE] reset message: APC Watchdog Early
	[PRE] RST_STAT: 0x1 - CLUSTER0_NONCPU_WDTRESET
	[PRE] Reboot reason: 0xcbea - APC Watchdog Early

Mainline's s3c2410_wdt drives this block already, as google,gs101-wdt. What
it cannot safely reuse here is gs101's *PMU* data. That variant reaches into
the PMU for four things -- the reset mask, RST_STAT, the counter enable, and
automatic disable -- at fixed offsets:

	#define GS_CLUSTER0_NONCPU_OUT		0x1220
	#define GS_CLUSTER0_NONCPU_INT_EN	0x1244
	#define GS_RST_STAT_REG_OFFSET		0x3B44

Nothing establishes those are right on zumapro, and this port has already
been bitten once by exactly that assumption: gs101's PHY isolation control is
at PMU 0x3ec8 and Tensor G4's is at 0x3ec0, which left the PHY isolated and
raised an SError on first touch. Writing four unverified PMU offsets to stop
a watchdog would be the same mistake with a bigger blast radius.

So this variant carries no PMU quirks at all. The syscon lookup in
s3c2410wdt_probe() is gated behind QUIRKS_HAVE_PMUREG, so with none of them
set the driver never maps the PMU and never writes it. It touches only the
watchdog's own WTCON/WTDAT/WTCNT/WTCLRINT at 0x10060000, which are part of
the IP and not SoC-integration guesswork -- and those are all that petting or
stopping it requires.

What is given up is the PMU-side reset reporting and mask handling. ABL
already reports the reset reason on the next boot, which is how this was
diagnosed in the first place, so nothing that mattered is lost.
"""
import sys

p = "drivers/watchdog/s3c2410_wdt.c"
s = open(p).read()

anchor = """static const struct s3c2410_wdt_variant drv_data_gs101_cl1 = {"""
if s.count(anchor) != 1:
    sys.exit("add-zumapro-wdt: gs101 variants moved upstream")

variant = """/*
 * Tensor G4. Same watchdog IP as gs101, but with no PMU access: this port has
 * not established zumapro's PMU register offsets, and gs101's are known to
 * differ elsewhere in that block. Without QUIRKS_HAVE_PMUREG the driver never
 * maps the PMU, and the watchdog's own registers are enough to pet it.
 */
static const struct s3c2410_wdt_variant drv_data_zumapro = {
	.quirks = QUIRK_HAS_WTCLRINT_REG | QUIRK_HAS_DBGACK_BIT,
};

"""
s = s.replace(anchor, variant + anchor, 1)

match = """	{ .compatible = "google,gs101-wdt",
	  .data = &drv_data_gs101_cl0 },"""
if s.count(match) != 1:
    sys.exit("add-zumapro-wdt: watchdog match table moved upstream")
s = s.replace(match,
              match + """
	{ .compatible = "google,zumapro-wdt",
	  .data = &drv_data_zumapro },""", 1)

open(p, "w").write(s)
print("add-zumapro-wdt: added google,zumapro-wdt (no PMU access)")

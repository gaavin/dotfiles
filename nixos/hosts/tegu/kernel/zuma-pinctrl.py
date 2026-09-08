#!/usr/bin/env python3
"""Add zumapro pin-controller data to mainline's Samsung pinctrl driver.

Without this the SoC has no GPIO at all, and this port drives the two pins it
needs -- the touch reset (gpp1-1, PERIC0) and the touch ATTN interrupt
(gpn0-0, CUSTOM_ALIVE) -- by writing the GPIO blocks directly through ioremap.
Those shims cannot supply an interrupt, which is also why sec-acpm could not
probe: platform_get_irq() is mandatory in it and gs101 sources that irq from a
GPIO.

The bank tables are taken from the zumapro-mainline tree
(github.com/zumapro-mainline/linux, commit 9f1a38f7 "zuma: Write new pinctrl
driver data"). Two entries are independently confirmed against Google's own
tables in google-modules/soc/gs, drivers/pinctrl/gs/pinctrl-gs.c: gpn0 is bank
0 of GPIO_CUSTOM_ALIVE at 0x15060000, one pin, and gpp1 is bank 1 of
GPIO_PERIC0 at 0x10840000 with four pins and a 0x20 stride. Both agree with
what this port measured on hardware before either source was consulted.

The GS101_PIN_BANK_EINT{W,G} macros the data uses already exist upstream in
pinctrl-exynos.h, so only the tables, the of_match_data and two lines of
plumbing are new.
"""
import sys

data = open(sys.argv[1] if len(sys.argv) > 1 else "zuma-pinctrl-data.c").read()

p = "drivers/pinctrl/samsung/pinctrl-exynos-arm64.c"
s = open(p).read()

if "zuma_of_data" in s:
    sys.exit("zuma-pinctrl: upstream now carries zuma data; drop this patch")

anchor = """const struct samsung_pinctrl_of_match_data gs101_of_data __initconst = {
	.ctrl		= gs101_pin_ctrl,
	.num_ctrl	= ARRAY_SIZE(gs101_pin_ctrl),
};
"""
if anchor not in s:
    sys.exit("zuma-pinctrl: gs101_of_data anchor moved in %s" % p)

s = s.replace(anchor, anchor + "\n" + data)
open(p, "w").write(s)

# The driver has to be reachable by compatible, and the data by name.
p = "drivers/pinctrl/samsung/pinctrl-samsung.h"
s = open(p).read()
anchor = "extern const struct samsung_pinctrl_of_match_data gs101_of_data;\n"
if anchor not in s:
    sys.exit("zuma-pinctrl: gs101 extern anchor moved in %s" % p)
s = s.replace(anchor, anchor +
              "extern const struct samsung_pinctrl_of_match_data zuma_of_data;\n")
open(p, "w").write(s)

p = "drivers/pinctrl/samsung/pinctrl-samsung.c"
s = open(p).read()
anchor = """	{ .compatible = "google,gs101-pinctrl",
		.data = &gs101_of_data },
"""
if anchor not in s:
    sys.exit("zuma-pinctrl: gs101 match anchor moved in %s" % p)
s = s.replace(anchor, anchor +
              """	{ .compatible = "google,zuma-pinctrl",
		.data = &zuma_of_data },
""")
open(p, "w").write(s)

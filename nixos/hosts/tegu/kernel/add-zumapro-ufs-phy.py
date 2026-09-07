#!/usr/bin/env python3
"""Add a Tensor G4 (zumapro) UFS PHY variant to the Samsung UFS PHY driver.

The Tensor G4 PHY is the Tensor G1 PHY with one difference that matters: the
register that lifts PHY isolation sits at a different offset in the power
management unit. Mainline's gs101 data uses 0x3ec8; Google's own zumapro
description says 0x3ec0. Writing the wrong one leaves the PHY isolated, and
the first access to it raises an asynchronous SError that panics the kernel
inside samsung_ufs_phy_power_on. That was observed on hardware over UART.

A variant is added rather than changing the gs101 value, which would break the
Pixel 6. This is the shape an upstream submission would take.
"""
import sys

VARIANT = '''
/* Tensor G4 (zumapro): as gs101, but PHY isolation control sits at 0x3ec0. */
#define TENSOR_ZUMAPRO_PHY_CTRL		0x3ec0

const struct samsung_ufs_phy_drvdata tensor_zumapro_ufs_phy = {
	.cfgs = tensor_gs101_ufs_phy_cfgs,
	.cfgs_hibern8 = tensor_gs101_hibern8_cfgs,
	.isol = {
		.offset = TENSOR_ZUMAPRO_PHY_CTRL,
		.mask = TENSOR_GS101_PHY_CTRL_MASK,
		.en = TENSOR_GS101_PHY_CTRL_EN,
	},
	.clk_list = tensor_gs101_ufs_phy_clks,
	.num_clks = ARRAY_SIZE(tensor_gs101_ufs_phy_clks),
	/*
	 * Keep .wait_for_cal. It was tried without, on the theory that zumapro
	 * reports calibration completion elsewhere. It does not: skipping the
	 * wait let the driver proceed to write PHY registers that are not
	 * ready, and the kernel panicked with an SError in phy_power_off.
	 * With the wait in place the driver gives up cleanly and the system
	 * boots. The timeout is the honest signal, not a quirk to route around.
	 */
	.wait_for_cal = gs101_phy_wait_for_calibration,
	.wait_for_cdr = gs101_phy_wait_for_cdr_lock,
};
'''

def fail(msg):
    sys.exit("add-zumapro-ufs-phy: %s" % msg)

# 1. the drvdata itself
p = "drivers/phy/samsung/phy-gs101-ufs.c"
s = open(p).read()
if "tensor_gs101_ufs_phy = {" not in s:
    fail("gs101 UFS PHY drvdata moved upstream")
if "0x3ec8" not in s:
    fail("gs101 PHY_CTRL offset changed upstream; re-derive 0x3ec0")
if "tensor_zumapro_ufs_phy" in s:
    fail("upstream now carries a zumapro PHY; drop this")
open(p, "w").write(s + VARIANT)

# 2. declare it
p = "drivers/phy/samsung/phy-samsung-ufs.h"
s = open(p).read()
anchor = "extern const struct samsung_ufs_phy_drvdata tensor_gs101_ufs_phy;"
if anchor not in s:
    fail("PHY drvdata declarations moved upstream")
s = s.replace(anchor,
              anchor + "\nextern const struct samsung_ufs_phy_drvdata tensor_zumapro_ufs_phy;", 1)
open(p, "w").write(s)

# 3. bind it to a compatible
p = "drivers/phy/samsung/phy-samsung-ufs.c"
s = open(p).read()
anchor = '\t\t.compatible = "google,gs101-ufs-phy",\n\t\t.data = &tensor_gs101_ufs_phy,\n\t}, {'
if anchor not in s:
    fail("PHY match table moved upstream")
s = s.replace(anchor,
              '\t\t.compatible = "google,gs101-ufs-phy",\n'
              '\t\t.data = &tensor_gs101_ufs_phy,\n'
              '\t}, {\n'
              '\t\t.compatible = "google,zumapro-ufs-phy",\n'
              '\t\t.data = &tensor_zumapro_ufs_phy,\n'
              '\t}, {', 1)
open(p, "w").write(s)
print("add-zumapro-ufs-phy: added google,zumapro-ufs-phy (isolation at 0x3ec0)")

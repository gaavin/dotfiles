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
/*
 * Tensor G4 reports PHY calibration completion in a different place from
 * Tensor G1, which is why mainline's gs101 wait always times out here:
 *
 *	                 register (byte)   bit
 *	gs101            0xce0             3     TRSV_REG338, LN0_MON_RX_CAL_DONE
 *	zumapro          0xc74             0
 *
 * From Google's own calibration table for this SoC (google-modules/soc/gs,
 * drivers/ufs/zuma/ufs-cal.h), whose PHY_EMB_CAL_WAIT entry reads
 *
 *	{0x0000, 0xC74, 0x01, PMD_ALL, PHY_EMB_CAL_WAIT, BRD_ALL}
 *
 * i.e. poll address 0xc74 for mask 0x01. Google's tables address the PMA in
 * bytes with a 0x800 lane stride; mainline addresses it in registers and
 * shifts by two, with a 0x200 lane stride, which is the same thing. 0xc74 in
 * bytes is register 0x31d.
 *
 * Skipping the wait instead is not an option: that was tried on hardware and
 * the driver went on to program a PHY that was not ready, panicking the
 * kernel with an SError in phy_power_off.
 */
#define TENSOR_ZUMAPRO_CAL_DONE_REG	0x31d	/* byte offset 0xc74 */
#define TENSOR_ZUMAPRO_CAL_DONE		BIT(0)

static int zumapro_phy_wait_for_calibration(struct phy *phy, u8 lane)
{
	struct samsung_ufs_phy *ufs_phy = get_samsung_ufs_phy(phy);
	const unsigned int timeout_us = 40000;
	const unsigned int sleep_us = 40;
	u32 val;
	u32 off;
	int err;

	off = PHY_PMA_TRSV_ADDR(TENSOR_ZUMAPRO_CAL_DONE_REG, lane);

	err = readl_poll_timeout(ufs_phy->reg_pma + off, val,
				 (val & TENSOR_ZUMAPRO_CAL_DONE),
				 sleep_us, timeout_us);
	if (err)
		dev_err(ufs_phy->dev,
			"zumapro: failed to get phy cal done %d\\n", err);

	return err;
}
/* Tensor G4 (zumapro): as gs101, but PHY isolation control sits at 0x3ec0. */
#define TENSOR_ZUMAPRO_PHY_CTRL		0x3ec0


/*
 * Tensor G4 analogue PHY configuration.
 *
 * Transcribed mechanically from Google's calibration table for this SoC
 * (google-modules/soc/gs, drivers/ufs/zuma/ufs-cal.h, init_cfg_evt1), taking
 * the PHY_PMA_COMN and PHY_PMA_TRSV entries in order. Google addresses the
 * PMA in bytes; mainline addresses it in registers and shifts by two, so each
 * offset here is Google's divided by four. The lane stride agrees too:
 * Google's 0x800 bytes is mainline's 0x200 registers, so gs101's TRSV macro
 * applies unchanged.
 *
 * The last two entries are the calibration trigger: writing 0x0c then 0x00 to
 * COMN register 0x50 is what starts it, and the wait that follows is what was
 * timing out with gs101's (different) sequence loaded.
 *
 * Only the PMA entries belong here. Google's table also carries PCS and
 * UNIPRO writes, which in mainline are the host controller driver's job
 * (exynos-ufs pre_link/post_link), not the PHY's.
 */
static const struct samsung_ufs_phy_cfg tensor_zumapro_pre_init_cfg[] = {
	PHY_COMN_REG_CFG(0x50, 0x08, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x05, 0x19, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x0b, 0x44, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x0c, 0xc4, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x0d, 0xc3, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x0f, 0x88, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x16, 0x1a, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x19, 0x04, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x54, 0x88, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x67, 0x4c, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x68, 0x4c, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x201, 0x44, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x202, 0x44, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x203, 0x00, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x204, 0x18, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x205, 0xc0, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x207, 0x1c, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x2ec, 0x8c, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x27c, 0xd0, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x288, 0xfa, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x289, 0x60, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x234, 0x30, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x239, 0x05, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x23d, 0x05, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x24d, 0x1a, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x24e, 0x12, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x24f, 0x5e, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x259, 0x2a, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x260, 0x54, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x266, 0x54, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x273, 0x00, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x274, 0x00, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x2ab, 0x00, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x2ac, 0x02, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x50, 0x0c, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x50, 0x00, PWR_MODE_ANY),
	END_UFS_PHY_CFG,
};

static const struct samsung_ufs_phy_cfg *tensor_zumapro_ufs_phy_cfgs[CFG_TAG_MAX] = {
	[CFG_PRE_INIT]		= tensor_zumapro_pre_init_cfg,
	/*
	 * The high-speed power-mode tables are gs101's for now. They are only
	 * reached once the link is up, so they cannot be tested until
	 * calibration succeeds; revisit with zuma's pwr_change tables then.
	 */
	[CFG_PRE_PWR_HS]	= tensor_gs101_pre_pwr_hs_config,
	[CFG_POST_PWR_HS]	= tensor_gs101_post_pwr_hs_config,
};

const struct samsung_ufs_phy_drvdata tensor_zumapro_ufs_phy = {
	.cfgs = tensor_zumapro_ufs_phy_cfgs,
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
	.wait_for_cal = zumapro_phy_wait_for_calibration,
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

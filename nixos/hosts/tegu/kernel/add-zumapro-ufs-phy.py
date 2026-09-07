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

/*
 * Diagnostics for the calibration timeout.
 *
 * The table is now this SoC's and the wait polls the register this SoC
 * reports in, and it still times out. That leaves two possibilities worth
 * separating before changing any more code: either our register writes are
 * not reaching the PHY at all (wrong clock or the block held in reset), or
 * they are landing and the PHY genuinely will not calibrate.
 *
 * Read the values back to find out. This has to happen here, at the point of
 * failure, rather than from userspace: by the time the rescue shell runs, the
 * probe has failed and phy_power_off has re-isolated the PHY, so touching the
 * PMA from /dev/mem would raise an SError instead of an answer.
 */
static void zumapro_phy_report_cal_failure(struct samsung_ufs_phy *ufs_phy,
					   u8 lane)
{
	static const struct {
		const char *name;
		u32 reg;
		u32 wrote;
		bool trsv;
	} readback[] = {
		{ "COMN 0x05",  0x05,  0x19, false },
		{ "COMN 0x0b",  0x0b,  0x44, false },
		{ "COMN 0x0c",  0x0c,  0xc4, false },
		{ "TRSV 0x201", 0x201, 0x44, true  },
		{ "TRSV 0x2ac", 0x2ac, 0x02, true  },
	};
	u32 off, val;
	int i;

	/*
	 * Deliberately not reporting COMN 0x1e as a PLL lock status any more.
	 *
	 * This used to print it as "pll_lock_status", read 0x0c every boot, and
	 * that number was carried for several rounds as the one unexplained
	 * reading. It explains nothing, because nothing uses the register:
	 *
	 *   - mainline defines PHY_PLL_LOCK_STATUS 0x1e and
	 *     samsung_ufs_phy_wait_for_lock_acq(), but no SoC variant assigns
	 *     that function to .wait_for_cdr or anything else. It is dead code;
	 *   - Google's tables for this SoC never read or write COMN byte 0x78,
	 *     which is what register 0x1e is;
	 *   - their PHY_PLL_WAIT operation exists only as an enum member and
	 *     appears in no table entry, so nothing waits on a PMA PLL here at
	 *     all;
	 *   - gs101's real lock check is CDR, on TRSV 0x339 bit 3, and it runs
	 *     after the link is up, not during calibration.
	 *
	 * So 0x0c was a read of a register this SoC does not use, printed under
	 * a borrowed name. Reporting it invited exactly the reading it got.
	 */
	dev_err(ufs_phy->dev, "zumapro: lane %u of %u\\n",
		lane, ufs_phy->lane_cnt);

	/*
	 * Is the PHY actually out of isolation? The registers answering at all
	 * says the digital domain is alive, but isolation is what gates the
	 * analogue side, and that is where calibration runs.
	 */
	if (!regmap_read(ufs_phy->reg_pmu, ufs_phy->isol.offset, &val))
		dev_err(ufs_phy->dev,
			"zumapro: pmu isol reg 0x%04x reads 0x%08x (mask 0x%x en 0x%x)\\n",
			ufs_phy->isol.offset, val, ufs_phy->isol.mask,
			ufs_phy->isol.en);

	off = PHY_PMA_TRSV_ADDR(TENSOR_ZUMAPRO_CAL_DONE_REG, lane);
	dev_err(ufs_phy->dev, "zumapro: cal_done reg (0x%03x) reads 0x%02x\\n",
		TENSOR_ZUMAPRO_CAL_DONE_REG,
		readl(ufs_phy->reg_pma + off));

	/*
	 * If these read back what we wrote, the register path is fine and the
	 * fault is in the analogue domain. If they read 0x00 or 0xff, the
	 * writes are being swallowed and no calibration table can ever work.
	 */
	for (i = 0; i < ARRAY_SIZE(readback); i++) {
		off = readback[i].trsv
			? PHY_PMA_TRSV_ADDR(readback[i].reg, lane)
			: PHY_APB_ADDR(readback[i].reg);
		val = readl(ufs_phy->reg_pma + off);
		dev_err(ufs_phy->dev,
			"zumapro: %s wrote 0x%02x reads 0x%02x %s\\n",
			readback[i].name, readback[i].wrote, val,
			val == readback[i].wrote ? "ok" : "MISMATCH");
	}
}

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
	if (err) {
		dev_err(ufs_phy->dev,
			"zumapro: cal done never set (%d), continuing anyway\\n",
			err);
		zumapro_phy_report_cal_failure(ufs_phy, lane);

		/*
		 * Deliberately not fatal, because Google's own kernel does not
		 * treat it as fatal either. In
		 * google-modules/soc/gs/drivers/ufs/zuma/ufs-cal-if.c,
		 * ufs30_cal_done_wait() -- the handler for the
		 * PHY_EMB_CAL_WAIT entry that ends this SoC's pre-link table,
		 * {0x0000, 0xC74, 0x01, PMD_ALL, PHY_EMB_CAL_WAIT, BRD_ALL} --
		 * polls TRSV 0xC74 bit 0 a hundred times and then does this:
		 *
		 *	#if defined(__UFS_CAL_FW__)
		 *		if (i >= 100)
		 *			return UFS_CAL_ERROR;
		 *	#endif
		 *		return UFS_CAL_NO_ERROR;
		 *
		 * __UFS_CAL_FW__ is defined only for the firmware build. In
		 * the kernel build the timeout returns success, so on this
		 * hardware the vendor driver never blocks on this bit.
		 *
		 * Treating it as fatal here made phy_power_on() fail, which
		 * made exynos_ufs_phy_init() run phy_exit() on a PHY that had
		 * in fact been programmed. The register dump says calibration
		 * does run: within the same window the PHY writes TRSV 0xC3C,
		 * 0xC78 and 0xC7C -- registers no table of ours touches -- and
		 * moves 0xC74 itself. What never happens is bit 0 setting.
		 */
		err = 0;
	}

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

/*
 * Nothing to do to the PMA at a power-mode change on this SoC.
 *
 * That is not an omission, it is what Google's tables say. ufs_cal_pre_pmc()
 * selects calib_of_hs_rate_a or calib_of_hs_rate_b, and for Tensor G4 both
 * hold only UNIPRO_STD_MIB and UNIPRO_DBG_APB entries -- the L2 timer and
 * PA_PWRMODEUSERDATA values that exynos-ufs already writes from
 * gs101_ufs_pre_pwr_change(). Not one PHY_PMA_COMN or PHY_PMA_TRSV entry
 * between them. ufs_cal_post_pmc() picks post_calib_of_hs_rate_a or _b, and
 * on this SoC both are empty:
 *
 *	static struct ufs_cal_phy_cfg post_calib_of_hs_rate_a[] = {
 *		{0, 0, 0, 0, PHY_CFG_NONE, BRD_ALL}
 *	};
 *
 * These slots used to carry gs101's tables, which do write the PMA. That put
 * Tensor G1's analogue values into a Tensor G4 PHY at the moment of the gear
 * switch, and the switch came back PWR_FATAL_ERROR:
 *
 *	pwr ctrl cmd 0x2 with (MIBattribute 0x1571, mode 0x11) failed,
 *		host upmcrs:0x5
 *	ufshcd_dme_change_power_mode: power mode change failed 5
 */
static const struct samsung_ufs_phy_cfg tensor_zumapro_pwr_hs_cfg[] = {
	END_UFS_PHY_CFG,
};

/*
 * Hibern8, from Google's post_h8_enter and pre_h8_exit for this SoC. Their
 * offsets are bytes and mainline's are registers, so each is theirs over four:
 * 0x9F4 -> 0x27d, 0xA00 -> 0x280, 0xB64 -> 0x2d9.
 *
 * Their PHY_PMA_TRSV_SQ and PHY_PMA_TRSV entries reach the same register file
 * by the same address arithmetic -- __config_uic() handles both with
 * pma_writel(..., PHY_PMA_TRSV_ADDR(addr, lane)) -- so both become
 * PHY_TRSV_REG_CFG_GS101 here.
 *
 * These slots held gs101's tables until now, which is why the link died the
 * moment anything let it idle: clock gating put it into hibern8, and coming
 * back out ran Tensor G1's analogue values through a Tensor G4 PHY.
 *
 *	samsung-ufs-phy: failed to get cdr lock
 *	pwr ctrl cmd 0x18 with (MIBattribute 0x0, mode 0x0) failed,
 *		host upmcrs:0x5
 *	ufshcd_uic_hibern8_exit: hibern8 exit failed. ret = 5
 *	ufshcd_ungate_work: hibern8 exit failed 5
 *
 * UIC command 0x18 is DME_HIBERN8_EXIT and upmcrs 5 is PWR_FATAL_ERROR.
 */
static const struct samsung_ufs_phy_cfg tensor_zumapro_post_h8_enter[] = {
	PHY_TRSV_REG_CFG_GS101(0x27d, 0x08, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x280, 0x3a, PWR_MODE_ANY),
	PHY_COMN_REG_CFG(0x000, 0x51, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x2d9, 0x30, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x2d9, 0x33, PWR_MODE_ANY),
	END_UFS_PHY_CFG,
};

static const struct samsung_ufs_phy_cfg tensor_zumapro_pre_h8_exit[] = {
	PHY_COMN_REG_CFG(0x000, 0x11, PWR_MODE_ANY),
	/*
	 * Google's {0x0000, 0x000, 0x0A, PMD_ALL, COMMON_WAIT, BRD_ALL}. The
	 * PHY needs settling time after that write before the squelch
	 * registers are touched, and mainline's table format had no way to say
	 * so, so PHY_DELAY_CFG adds one rather than leaving the wait out and
	 * hoping bus latency covers it.
	 */
	PHY_DELAY_CFG(10, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x27d, 0x00, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x280, 0x30, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x2d9, 0x32, PWR_MODE_ANY),
	PHY_TRSV_REG_CFG_GS101(0x2d9, 0x22, PWR_MODE_ANY),
	END_UFS_PHY_CFG,
};

static const struct samsung_ufs_phy_cfg *tensor_zumapro_hibern8_cfgs[] = {
	[CFG_POST_HIBERN8_ENTER]	= tensor_zumapro_post_h8_enter,
	[CFG_PRE_HIBERN8_EXIT]		= tensor_zumapro_pre_h8_exit,
};

static const struct samsung_ufs_phy_cfg *tensor_zumapro_ufs_phy_cfgs[CFG_TAG_MAX] = {
	[CFG_PRE_INIT]		= tensor_zumapro_pre_init_cfg,
	[CFG_PRE_PWR_HS]	= tensor_zumapro_pwr_hs_cfg,
	[CFG_POST_PWR_HS]	= tensor_zumapro_pwr_hs_cfg,
};

const struct samsung_ufs_phy_drvdata tensor_zumapro_ufs_phy = {
	.cfgs = tensor_zumapro_ufs_phy_cfgs,
	.cfgs_hibern8 = tensor_zumapro_hibern8_cfgs,
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
	/*
	 * No .wait_for_cdr. gs101's polls TRSV 0x338 bit 3, a register that
	 * appears nowhere in Google's tables for this SoC, and it duly failed
	 * every time it ran -- once after the gear change and again on every
	 * hibern8 exit:
	 *
	 *	samsung-ufs-phy 13204000.phy: failed to get cdr lock
	 *
	 * Google waits for no CDR lock here at all: post_calib_of_hs_rate_a
	 * and _b are empty, and pre_h8_exit ends with register writes, not a
	 * PHY_CDR_WAIT entry. A poll of the wrong register can only ever
	 * report failure, so it is removed rather than pointed somewhere.
	 */
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

# A table entry that waits instead of writing.
#
# Google's tables have COMMON_WAIT for this and __config_uic() answers it with
# handle->udelay(cfg->val); mainline's table format has no equivalent, so the
# Tensor G4 hibern8-exit sequence could not be expressed faithfully without
# one. PHY_DELAY_BLK reuses the existing id field, so nothing else changes.
blk = "#define PHY_TRSV_BLK\t2"
if blk not in s:
    fail("PHY block ids moved upstream")
s = s.replace(blk, blk + "\n#define PHY_DELAY_BLK\t3", 1)

comn = "#define PHY_COMN_REG_CFG(o, v, d) {\t\\"
if comn not in s:
    fail("PHY_COMN_REG_CFG moved upstream")
s = s.replace(comn,
              "#define PHY_DELAY_CFG(us, d) {\t\\\n"
              "\t.off_0 = 0,\t\t\\\n"
              "\t.off_1 = 0,\t\t\\\n"
              "\t.val = (us),\t\t\\\n"
              "\t.desc = (d),\t\t\\\n"
              "\t.id = PHY_DELAY_BLK,\t\\\n"
              "}\n\n" + comn, 1)
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

cfgfn = """	enum {LANE_0, LANE_1}; /* lane index */

	switch (lane) {"""
if s.count(cfgfn) != 1:
    fail("samsung_ufs_phy_config() body moved upstream")
s = s.replace(cfgfn, """	enum {LANE_0, LANE_1}; /* lane index */

	/*
	 * A wait, not a write. Google's tables spell this COMMON_WAIT and
	 * __config_uic() answers it with handle->udelay(cfg->val); Tensor G4's
	 * hibern8-exit sequence needs 10us after the first common-block write
	 * before the squelch registers are touched. Once per entry, not once
	 * per lane.
	 */
	if (cfg->id == PHY_DELAY_BLK) {
		if (lane == LANE_0)
			udelay(cfg->val);
		return;
	}

	switch (lane) {""", 1)

if "#include <linux/delay.h>" not in s:
    inc = "#include <linux/io.h>"
    if inc not in s:
        fail("phy-samsung-ufs.c includes moved upstream")
    s = s.replace(inc, "#include <linux/delay.h>\n" + inc, 1)

open(p, "w").write(s)
print("add-zumapro-ufs-phy: added google,zumapro-ufs-phy (isolation at 0x3ec0)")

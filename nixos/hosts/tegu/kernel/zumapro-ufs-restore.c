// SPDX-License-Identifier: GPL-2.0-only
/*
 * Bring-up shim: put the UFS pins and reference clock where the stock
 * firmware puts them, before the UFS driver probes.
 *
 * The bootloader tears UFS down on its way out, in two ways measured on
 * hardware:
 *
 *   - the device's VCC rail is switched off. The stock device tree
 *     (zumapro-a1-ipop.dtb) describes it as
 *         fixedregulator@0 { regulator-name = "ufs-vcc";
 *                            gpio = <&gpp0 1 0>; enable-active-high; };
 *     and gpp0 DAT bit 1 reads 0 at hand-over.
 *   - the reference clock output to the device is parked. The stock tree
 *     wants gph5-0 at samsung,pin-function = <2> with no pull; it is left as
 *     a plain GPIO output driven low, with a pull enabled.
 *
 * Nothing in this kernel restores either, so the device is unpowered and
 * unclocked and never answers link startup (device_present stays 0).
 *
 * This belongs in a pinctrl driver plus a regulator, the way mainline does it
 * for gs101. That needs zumapro pin-bank tables which are not published --
 * gs101's do not match, 20 banks in peric0 against zumapro's 12 -- so writing
 * one now would mean inventing them. Until then, set the four fields
 * directly, from the stock device tree's own values, and say so plainly.
 *
 * Doing it here rather than from userspace matters: the UFS driver must see
 * the pins already correct on its *first* probe. A re-bind cannot substitute,
 * because phy_init() only calls ops->init when init_count is zero, and a
 * failed probe never calls phy_exit -- so a re-bound driver silently skips
 * PHY calibration rather than redoing it.
 *
 * Samsung bank layout, shared with gs101: CON at +0x00, four bits per pin
 * (1 = output, 2 = function 2); DAT at +0x04, one bit per pin; PUD at +0x08,
 * two bits per pin.
 */

#include <linux/init.h>
#include <linux/delay.h>
#include <linux/moduleparam.h>
#include <linux/io.h>

/*
 * The M-PHY reference clock.
 *
 * CLKCMU_HSI2_UFS_EMBD is the parent of MUX_CLKCMU_HSI2_UFS_EMBD_USER, which
 * is the parent of GOUT_BLK_HSI2_UID_UFS_EMBD_IPCLKPORT_I_CLK_UNIPRO -- the
 * M-PHY/UniPro clock the PMA calibrates against. On this SoC it is a VDD_INT
 * DVFS clock, set through ACPM firmware that mainline does not have, so
 * nothing here ever programs it and it keeps whatever the bootloader left.
 *
 * RETRACTED. This file previously claimed the bootloader left this clock on
 * the wrong PLL and the wrong divider, comparing against Google's VDD_INT
 * normal-level table (cal-if/zuma, cmucal_vclk_vdd_int[] with
 * vdd_int_nm_lut_params[]), which reads MUX SELECT 3 and DIV DIVRATIO 1
 * where the hardware has 1 and 2. Working the frequencies out afterwards
 * says that reading is wrong:
 *
 *	PLL_SHARED0 = 2133.00 MHz, PLL_SPARE = 2400.00 MHz
 *
 *	as the bootloader left it : SHARED0_D4 / 3 = 177.75 MHz
 *	that table read literally : SPARE_D1  / 2 = 1200.00 MHz
 *
 * 177.75 MHz is a plausible UniPro clock and is close to the 166.67 MHz
 * stub both this port and gs101 mainline put in the device tree for it.
 * 1200 MHz is not, and there is no further divider in CMU_HSI2 for UFS --
 * only NOC dividers -- so nothing downstream would bring it back.
 *
 * So the clock the bootloader leaves is most likely correct, the LUT was
 * misread, and setting it to "Google's values" replaced a working clock
 * with a dead one. That is the whole explanation for the hard lockup
 * below; there is no evidence left that this clock was ever the problem.
 *
 * Field positions are from cmucal-sfr.c, not guessed:
 *	CLK_CON_MUX_MUX_CLKCMU_HSI2_UFS_EMBD  0x10b8  SELECT [1:0], BUSY bit 16
 *	CLK_CON_DIV_CLKCMU_HSI2_UFS_EMBD      0x18b0  DIVRATIO [3:0], BUSY bit 16
 */
#define ZUMAPRO_CMU_TOP_BASE	0x26040000
#define CLKCMU_HSI2_UFS_EMBD_MUX	0x10b8
#define CLKCMU_HSI2_UFS_EMBD_DIV	0x18b0
#define CMU_MUX_SELECT_MASK		0x3
#define CMU_DIV_RATIO_MASK		0xf
#define CMU_BUSY			BIT(16)
#define UFS_EMBD_MUX_PLL_SPARE_D1	3	/* Google's VDD_INT nm value */
#define UFS_EMBD_DIV_BY_2		1	/* Google's VDD_INT nm value */

#define ZUMAPRO_PERIC0_BASE	0x10840000	/* pinctrl@10840000, gpp0 at +0 */
#define ZUMAPRO_HSI2_PINS_BASE	0x13060000	/* pinctrl@13060000, gph5 at +0 */
#define BANK_CON		0x00
#define BANK_DAT		0x04
#define BANK_PUD		0x08

/*
 * Re-pointing the M-PHY reference clock is OFF by default, because doing it
 * hard-locked the phone.
 *
 * Setting mux=3 (PLL_SPARE_D1) and div=1 succeeded by every check available
 * -- both fields read back the requested values and both BUSY bits cleared
 * -- and then the UFS driver's first register access hung the interconnect:
 *
 *     zumapro-ufs-pins: UFS_EMBD mux 0x00000003 (settled) div 0x00000001 (settled)
 *     ...
 *     watchdog: CPU5: Watchdog detected hard LOCKUP on cpu 6
 *
 * PLL_SPARE_D1 is a member of cmucal_vclk_blk_cmu[], which ACPM owns, so on
 * a mainline kernel that PLL is never started. Selecting a dead source gives
 * the block no clock at all, and the first access to it never returns.
 *
 * Two things worth keeping from that:
 *   - a CMU mux BUSY bit clearing means the switch completed, NOT that the
 *     selected source is running. It is not a liveness check.
 *   - the experiment still proves the lever is real: changing this mux
 *     visibly changed the UFS block's behaviour, which no other register in
 *     this port has done.
 *
 * Pass zumapro_ufs_restore.set_clock=1 to try it again once PLL_SPARE is
 * actually running, or when targeting a source that is.
 */
static bool set_clock;
module_param(set_clock, bool, 0444);
MODULE_PARM_DESC(set_clock, "re-point the UFS M-PHY reference clock (hangs unless PLL_SPARE runs)");

static void __init zumapro_rmw(void __iomem *reg, u32 clear, u32 set)
{
	writel((readl(reg) & ~clear) | set, reg);
}

/*
 * Wait for a CMU mux or divider to finish switching. Bounded and
 * non-fatal: if the selected source is not running the block stays busy,
 * and a stuck mux must be reported rather than hang the boot.
 */
static bool __init zumapro_cmu_settle(void __iomem *reg)
{
	int i;

	for (i = 0; i < 1000; i++) {
		if (!(readl(reg) & CMU_BUSY))
			return true;
		udelay(10);
	}
	return false;
}

static int __init zumapro_ufs_pins_init(void)
{
	void __iomem *peric0, *hsi2, *cmu_top;
	bool mux_ok, div_ok;

	peric0 = ioremap(ZUMAPRO_PERIC0_BASE, 0x1000);
	if (!peric0)
		return -ENOMEM;

	hsi2 = ioremap(ZUMAPRO_HSI2_PINS_BASE, 0x1000);
	if (!hsi2) {
		iounmap(peric0);
		return -ENOMEM;
	}

	/* ufs-vcc: gpp0[1] output, driven high. */
	zumapro_rmw(peric0 + BANK_CON, 0xf0, 0x10);
	zumapro_rmw(peric0 + BANK_DAT, 0, BIT(1));

	/* ufs-refclk-out: gph5[0] to function 2, no pull. */
	zumapro_rmw(hsi2 + BANK_CON, 0xf, 0x2);
	zumapro_rmw(hsi2 + BANK_PUD, 0x3, 0);

	/* M-PHY reference clock: Google's VDD_INT normal-level settings. */
	cmu_top = set_clock ? ioremap(ZUMAPRO_CMU_TOP_BASE, 0x8000) : NULL;
	if (cmu_top) {
		zumapro_rmw(cmu_top + CLKCMU_HSI2_UFS_EMBD_DIV,
			    CMU_DIV_RATIO_MASK, UFS_EMBD_DIV_BY_2);
		div_ok = zumapro_cmu_settle(cmu_top + CLKCMU_HSI2_UFS_EMBD_DIV);

		zumapro_rmw(cmu_top + CLKCMU_HSI2_UFS_EMBD_MUX,
			    CMU_MUX_SELECT_MASK, UFS_EMBD_MUX_PLL_SPARE_D1);
		mux_ok = zumapro_cmu_settle(cmu_top + CLKCMU_HSI2_UFS_EMBD_MUX);

		pr_info("zumapro-ufs-pins: UFS_EMBD mux %#010x (%s) div %#010x (%s)\n",
			readl(cmu_top + CLKCMU_HSI2_UFS_EMBD_MUX),
			mux_ok ? "settled" : "STILL BUSY",
			readl(cmu_top + CLKCMU_HSI2_UFS_EMBD_DIV),
			div_ok ? "settled" : "STILL BUSY");
		iounmap(cmu_top);
	} else if (set_clock) {
		pr_warn("zumapro-ufs-pins: could not map CMU_TOP\n");
	}

	pr_info("zumapro-ufs-pins: gpp0 CON %#010x DAT %#010x, gph5 CON %#010x PUD %#010x\n",
		readl(peric0 + BANK_CON), readl(peric0 + BANK_DAT),
		readl(hsi2 + BANK_CON), readl(hsi2 + BANK_PUD));

	iounmap(hsi2);
	iounmap(peric0);
	return 0;
}
/*
 * arch_initcall: before device_initcall, so this runs ahead of the UFS
 * platform driver's probe. The device then has power and a reference clock
 * for its very first link startup, and the stock PHY path -- calibration
 * included -- runs against hardware that is actually alive.
 */
arch_initcall(zumapro_ufs_pins_init);

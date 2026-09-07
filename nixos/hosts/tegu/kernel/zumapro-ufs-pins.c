// SPDX-License-Identifier: GPL-2.0-only
/*
 * Bring-up shim: put the UFS pins where the stock firmware puts them, before
 * the UFS driver probes.
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
#include <linux/io.h>

#define ZUMAPRO_PERIC0_BASE	0x10840000	/* pinctrl@10840000, gpp0 at +0 */
#define ZUMAPRO_HSI2_PINS_BASE	0x13060000	/* pinctrl@13060000, gph5 at +0 */
#define BANK_CON		0x00
#define BANK_DAT		0x04
#define BANK_PUD		0x08

static void __init zumapro_rmw(void __iomem *reg, u32 clear, u32 set)
{
	writel((readl(reg) & ~clear) | set, reg);
}

static int __init zumapro_ufs_pins_init(void)
{
	void __iomem *peric0, *hsi2;

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

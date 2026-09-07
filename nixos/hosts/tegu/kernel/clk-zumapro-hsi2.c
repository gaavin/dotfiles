// SPDX-License-Identifier: GPL-2.0-only
/*
 * Clock gates for the HSI2 block of the Google Tensor G4 (zumapro).
 *
 * This is the minimum needed to bring up UFS storage. Tensor G4 has no
 * mainline clock driver at all, and without one the storage PHY never
 * calibrates: the kernel is handed fixed-clock stubs, believes the clocks are
 * running, and drives a block the bootloader has gated. On hardware that
 * shows up as
 *
 *	samsung-ufs-phy 13204000.phy: failed to get phy cal done -110
 *	exynos-ufshc 13200000.ufs: link startup failed 1
 *
 * Scope is deliberately narrow. A full port of clk-gs101.c to this SoC is a
 * large job; this covers one block and the six gates UFS actually asks for,
 * so storage can be brought up and tested independently of that work.
 *
 * Register data comes from Google's own CAL tables for this SoC
 * (google-modules/soc/gs, drivers/soc/google/cal-if/zuma/cmucal-sfr.c):
 *
 *	SFR_BLOCK(CMU_HSI2, 0x13000000, 0x8000)
 *
 * The gate offsets are NOT the same as gs101's — they sit 0x3c higher,
 * because Tensor G4 inserts extra gates ahead of them — which is why the
 * gs101 driver cannot simply be pointed at a different base address:
 *
 *	gate            gs101    zumapro
 *	UFS_EMBD aclk   0x20d0   0x210c
 *	UFS_EMBD unipro 0x20d4   0x2110
 *	UFS_EMBD fmp    0x20d8   0x2114
 *
 * As on gs101, bit 21 of each gate register is the enable.
 *
 * CORRECTION, measured on hardware 2026-09-07. This file used to claim that
 * "the bootloader does NOT leave this path running: it brings UFS up, reads
 * the boot image, then tears it down". That is false. Logging every one of
 * these registers before writing them shows the bootloader leaves the entire
 * path up:
 *
 *	TOP noc_gate 0x00200000   ufs_gate 0x00200000
 *	HSI2 noc_user 0x00000010  ufs_user 0x00000010
 *	all six leaf gates        0x00200000
 *
 * which is exactly what the code below sets them to. Every write here is a
 * no-op on this hardware.
 *
 * The earlier observation behind the false claim — that the leaf gates read
 * 0x00000000 — was real, but self-inflicted: the gates were registered
 * without CLK_IS_CRITICAL, so the clock framework disabled the very clocks
 * the bootloader had left running. CLK_IS_CRITICAL did not fix the
 * bootloader's teardown, because there was no teardown; it stopped this
 * driver from performing one.
 *
 * The driver is still needed, as a clock provider: the UFS node references
 * these gates by phandle and will not probe without them, and CLK_IS_CRITICAL
 * is still required to stop the framework gating them. But it is not the
 * reason UFS fails, and the writes below are kept only so the state is
 * asserted rather than assumed.
 *
 * What it sets, matching what the bootloader already has:
 *
 *   - the top-level gates that feed the block at all, in CMU_TOP:
 *       CLK_CON_GAT_GATE_CLKCMU_HSI2_UFS_EMBD  0x20e0
 *       CLK_CON_GAT_GATE_CLKCMU_HSI2_NOC       0x20d8
 *   - the "user" multiplexers inside CMU_HSI2, which otherwise select the
 *     24.576 MHz oscillator rather than the clock from CMU_TOP:
 *       PLL_CON0_MUX_CLKCMU_HSI2_UFS_EMBD_USER 0x630, bit 4
 *       PLL_CON0_MUX_CLKCMU_HSI2_NOC_USER      0x610, bit 4
 *
 * (zumapro calls the bus clock NOC where gs101 calls it BUS; the mux bit
 * position, 4, is the same as gs101's.)
 *
 * The dividers are left as the bootloader programmed them: the rate only has
 * to be plausible for the UFS driver's timing arithmetic, and the device tree
 * states it.
 *
 * The gates are registered CLK_IS_CRITICAL, as gs101 does for the same
 * clocks. Without it they are registered disabled and stay that way: a dump
 * of the live registers on hardware showed the CMU_TOP gates and both user
 * muxes correctly set by the code above, while every leaf gate in CMU_HSI2
 * still read 0x00000000. Storage cannot calibrate its PHY with its own
 * clocks switched off. Marking them critical has the framework enable them
 * at registration and never gate them again, which is the behaviour this
 * block needs and what the bootloader had before it tore the path down.
 */

#include <linux/clk-provider.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/moduleparam.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#define ZUMAPRO_GATE_ENABLE_BIT		21

/* CMU_TOP: gates feeding the HSI2 block. */
#define CLK_CON_GAT_GATE_CLKCMU_HSI2_NOC	0x20d8
#define CLK_CON_GAT_GATE_CLKCMU_HSI2_UFS_EMBD	0x20e0

/* CMU_HSI2: user muxes. Bit 4 picks CMU_TOP over the oscillator. */
#define PLL_CON0_MUX_CLKCMU_HSI2_NOC_USER	0x610
#define PLL_CON0_MUX_CLKCMU_HSI2_UFS_EMBD_USER	0x630
#define ZUMAPRO_USER_MUX_SEL_BIT		BIT(4)

static void zumapro_set_bits(void __iomem *reg, u32 bits)
{
	writel(readl(reg) | bits, reg);
}

struct zumapro_gate_desc {
	const char *name;
	unsigned int offset;
};

/*
 * Order matters: it is the index used from the device tree, so the UFS node's
 * clock-names map onto these positions.
 */
static const struct zumapro_gate_desc zumapro_hsi2_gates[] = {
	{ "hsi2_ufs_embd_aclk",	0x210c },	/* core_clk         */
	{ "hsi2_ufs_embd_unipro", 0x2110 },	/* sclk_unipro_main */
	{ "hsi2_ufs_embd_fmp",	0x2114 },	/* fmp              */
	{ "hsi2_qe_ufs_embd_aclk", 0x20cc },	/* aclk             */
	{ "hsi2_qe_ufs_embd_pclk", 0x20d0 },	/* pclk             */
	{ "hsi2_sysreg_pclk",	0x20e8 },	/* sysreg           */
};

/*
 * Leave the CMU_HSI2 user muxes exactly as the bootloader set them.
 *
 * Forcing them to CMU_TOP is only right if the bootloader had closed the
 * path. Pass clk_zumapro_hsi2.keep_boot_mux=1 to test the other possibility --
 * that the bootloader's setting was the working one and overriding it is
 * what starves the M-PHY of its reference clock.
 */
static bool keep_boot_mux;
module_param(keep_boot_mux, bool, 0444);
MODULE_PARM_DESC(keep_boot_mux, "do not touch the CMU_HSI2 user muxes");

static DEFINE_SPINLOCK(zumapro_clk_lock);

static int zumapro_cmu_hsi2_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct clk_hw_onecell_data *data;
	const char *parent;
	void __iomem *base, *top;
	unsigned int i;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	top = devm_platform_ioremap_resource(pdev, 1);
	if (IS_ERR(top))
		return PTR_ERR(top);

	/*
	 * Report what the bootloader actually left here before touching it.
	 *
	 * The comment this replaces asserted that the bootloader had closed
	 * this path, and that was never checked. It matters: the bootloader
	 * read the kernel off UFS, so whatever state it left behind is a
	 * working one, and the user mux below decides whether the block is
	 * fed from CMU_TOP or from the oscillator. If the M-PHY wants the
	 * oscillator and we point it at CMU_TOP, we break the reference clock
	 * the PHY calibrates against -- which would look exactly like the
	 * failure being chased: digital registers fine, calibration never
	 * completing.
	 */
	dev_info(dev,
		 "bootloader left: TOP noc_gate 0x%08x ufs_gate 0x%08x, HSI2 noc_user 0x%08x ufs_user 0x%08x\n",
		 readl(top + CLK_CON_GAT_GATE_CLKCMU_HSI2_NOC),
		 readl(top + CLK_CON_GAT_GATE_CLKCMU_HSI2_UFS_EMBD),
		 readl(base + PLL_CON0_MUX_CLKCMU_HSI2_NOC_USER),
		 readl(base + PLL_CON0_MUX_CLKCMU_HSI2_UFS_EMBD_USER));
	for (i = 0; i < ARRAY_SIZE(zumapro_hsi2_gates); i++)
		dev_info(dev, "bootloader left: %s (0x%04x) 0x%08x\n",
			 zumapro_hsi2_gates[i].name,
			 zumapro_hsi2_gates[i].offset,
			 readl(base + zumapro_hsi2_gates[i].offset));

	zumapro_set_bits(top + CLK_CON_GAT_GATE_CLKCMU_HSI2_NOC,
			 BIT(ZUMAPRO_GATE_ENABLE_BIT));
	zumapro_set_bits(top + CLK_CON_GAT_GATE_CLKCMU_HSI2_UFS_EMBD,
			 BIT(ZUMAPRO_GATE_ENABLE_BIT));
	if (!keep_boot_mux) {
		zumapro_set_bits(base + PLL_CON0_MUX_CLKCMU_HSI2_NOC_USER,
				 ZUMAPRO_USER_MUX_SEL_BIT);
		zumapro_set_bits(base + PLL_CON0_MUX_CLKCMU_HSI2_UFS_EMBD_USER,
				 ZUMAPRO_USER_MUX_SEL_BIT);
	}

	dev_info(dev, "HSI2 clock path enabled (top gates%s)\n",
		 keep_boot_mux ? ", user muxes left as booted" : " + user muxes");

	/*
	 * One parent for all of them. Modelling the CMU_TOP mux/divider tree
	 * would mean porting most of clk-gs101.c; the bootloader has already
	 * set that path up, so the device tree simply states the rate.
	 */
	parent = of_clk_get_parent_name(dev->of_node, 0);
	if (!parent)
		return dev_err_probe(dev, -EINVAL, "no parent clock\n");

	data = devm_kzalloc(dev, struct_size(data, hws,
					     ARRAY_SIZE(zumapro_hsi2_gates)),
			    GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	data->num = ARRAY_SIZE(zumapro_hsi2_gates);

	for (i = 0; i < ARRAY_SIZE(zumapro_hsi2_gates); i++) {
		const struct zumapro_gate_desc *g = &zumapro_hsi2_gates[i];
		struct clk_hw *hw;

		hw = devm_clk_hw_register_gate(dev, g->name, parent,
					       CLK_SET_RATE_PARENT |
					       CLK_IS_CRITICAL,
					       base + g->offset,
					       ZUMAPRO_GATE_ENABLE_BIT,
					       0, &zumapro_clk_lock);
		if (IS_ERR(hw))
			return dev_err_probe(dev, PTR_ERR(hw),
					     "failed to register %s\n", g->name);
		data->hws[i] = hw;
	}

	return devm_of_clk_add_hw_provider(dev, of_clk_hw_onecell_get, data);
}

static const struct of_device_id zumapro_cmu_hsi2_of_match[] = {
	{ .compatible = "google,zumapro-cmu-hsi2" },
	{ }
};

static struct platform_driver zumapro_cmu_hsi2_driver = {
	.driver = {
		.name = "zumapro-cmu-hsi2",
		.of_match_table = zumapro_cmu_hsi2_of_match,
		.suppress_bind_attrs = true,
	},
	.probe = zumapro_cmu_hsi2_probe,
};
builtin_platform_driver(zumapro_cmu_hsi2_driver);

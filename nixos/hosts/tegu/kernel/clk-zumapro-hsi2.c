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
 * The upstream muxes and dividers in CMU_TOP are not modelled. The bootloader
 * configures them before handing over and clk_ignore_unused keeps them, so
 * the parent rate is taken from the device tree.
 */

#include <linux/clk-provider.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#define ZUMAPRO_GATE_ENABLE_BIT		21

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

static DEFINE_SPINLOCK(zumapro_clk_lock);

static int zumapro_cmu_hsi2_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct clk_hw_onecell_data *data;
	const char *parent;
	void __iomem *base;
	unsigned int i;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

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
					       CLK_SET_RATE_PARENT,
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

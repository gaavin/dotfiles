// SPDX-License-Identifier: GPL-2.0-only
/*
 * The USI11 clock divider in CMU_PERIC1 of the Google Tensor G4 (zumapro).
 *
 * This exists for one reason, and it was measured rather than assumed. The
 * SPI controller here is described by mainline as
 *
 *	static const struct s3c64xx_spi_port_config gs101_spi_port_config = {
 *		.clk_div	= 4,
 *		.clk_from_cmu	= true,
 *		...
 *
 * clk_from_cmu means the controller has no internal mux and prescaler: the
 * bit clock is whatever the CMU hands it, and spi-s3c64xx sets the speed by
 * calling clk_set_rate() on "spi_busclk0". Against the fixed-clock stub this
 * port used at first, that call cannot do anything, so a request for 1 MHz
 * ran the bus at 400 MHz / 4 and the transfer died:
 *
 *	spidev spi0.0: I/O Error: rx-1 tx-1 rx-f tx-f len-1 dma-0 res-(-5)
 *	spidev spi0.0: SPI transfer failed: -5
 *
 * So one settable divider is needed, and only that. Every gate and mux on
 * this path already reads open at boot -- the same as HSI2's did for UFS --
 * so nothing here turns anything on, and this driver deliberately does not
 * model gates. No leaf gate has been positively attributed to this USI (the
 * numbering runs 0..15 and Google's "spi_20" is an alias, not an index), and
 * registering the wrong ones as CLK_IS_CRITICAL would assert something
 * unverified while leaving the real ones free to be switched off.
 *
 * Register data is from Google's own tables for this SoC
 * (google-modules/soc/gs, drivers/soc/google/cal-if/zuma):
 *
 *	SFR_BLOCK(CMU_PERIC1, 0x10c00000, 0x8000)
 *	SFR(CLK_CON_DIV_DIV_CLK_PERIC1_USI11_USI, 0x1810, CMU_PERIC1)
 *	SFR_ACCESS(..._DIVRATIO, 0, 4, ...)   bits [3:0], divide by ratio + 1
 *	SFR_ACCESS(..._BUSY,    16, 1, ...)
 *
 * The parent is 400 MHz, computed from the CMU as the bootloader leaves it:
 * CMU_TOP PERIC1_IP selects PLL_SHARED2_D2 with a ratio of 0, shared2 runs at
 * 800 MHz, and the D2 tap halves it. With the controller's own /4 that gives
 * a reachable SPI range of 6.25 MHz to 100 MHz, and exactly 10 MHz -- the
 * touch part's maximum, from Google's board file -- at ratio 9.
 */

#include <linux/clk-provider.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#define CLK_CON_DIV_CLK_PERIC1_USI11_USI	0x1810
#define DIVRATIO_SHIFT				0
#define DIVRATIO_WIDTH				4

/* Fixed by the CMU_TOP path above; see the comment at the top of the file. */
#define ZUMAPRO_PERIC1_PCLK_RATE		66656248

static DEFINE_SPINLOCK(zumapro_peric1_lock);

static int zumapro_cmu_peric1_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct clk_hw_onecell_data *data;
	const char *parent;
	void __iomem *base;
	struct clk_hw *hw;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	parent = of_clk_get_parent_name(dev->of_node, 0);
	if (!parent)
		return dev_err_probe(dev, -EINVAL, "no parent clock\n");

	data = devm_kzalloc(dev, struct_size(data, hws, 2), GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	data->num = 2;

	/*
	 * The APB clock. Its divider lives in CMU_TOP and is shared with every
	 * other PERIC1 peripheral, so it is stated rather than modelled: this
	 * driver has no business changing a rate other devices depend on.
	 */
	hw = devm_clk_hw_register_fixed_rate(dev, "peric1_usi11_pclk", NULL, 0,
					     ZUMAPRO_PERIC1_PCLK_RATE);
	if (IS_ERR(hw))
		return dev_err_probe(dev, PTR_ERR(hw), "pclk\n");
	data->hws[0] = hw;

	/*
	 * The function clock, and the only writable thing here. Samsung's
	 * DIVRATIO divides by value + 1, which is what the generic divider
	 * does with no flags set.
	 */
	hw = devm_clk_hw_register_divider(dev, "peric1_usi11_ipclk", parent, 0,
					  base + CLK_CON_DIV_CLK_PERIC1_USI11_USI,
					  DIVRATIO_SHIFT, DIVRATIO_WIDTH, 0,
					  &zumapro_peric1_lock);
	if (IS_ERR(hw))
		return dev_err_probe(dev, PTR_ERR(hw), "ipclk\n");
	data->hws[1] = hw;

	dev_info(dev, "USI11 divider registered, ipclk currently %lu Hz\n",
		 clk_hw_get_rate(hw));

	return devm_of_clk_add_hw_provider(dev, of_clk_hw_onecell_get, data);
}

static const struct of_device_id zumapro_cmu_peric1_of_match[] = {
	{ .compatible = "google,zumapro-cmu-peric1" },
	{ }
};

static struct platform_driver zumapro_cmu_peric1_driver = {
	.driver = {
		.name = "zumapro-cmu-peric1",
		.of_match_table = zumapro_cmu_peric1_of_match,
		.suppress_bind_attrs = true,
	},
	.probe = zumapro_cmu_peric1_probe,
};
builtin_platform_driver(zumapro_cmu_peric1_driver);

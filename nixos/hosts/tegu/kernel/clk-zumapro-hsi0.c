// SPDX-License-Identifier: GPL-2.0-only
/*
 * The USI2 clock divider in CMU_HSI0 of the Google Tensor G4 (zumapro).
 *
 * This replaces an earlier driver that programmed CMU_PERIC1. That was
 * simply the wrong block: the touch SPI is spi_20 at 0x111d0000, and the
 * stock device tree gives it
 *
 *	clocks = <&clk 0x238>, <&clk 0x233>;
 *	clock-names = "ipclk_spi", "gate_spi_clk";
 *
 * against clock-controller@26040000. Resolving those IDs through Google's
 * own include/dt-bindings/clock/zuma.h gives VDOUT_CLK_HSI0_USI2_USI and
 * GATE_HSI0_USI2_USI -- HSI0, not PERIC1. The address space agrees, since
 * 0x110-0x111 is HSI0 and the sysreg holding this USI's mode select is
 * named sysreg_hsi0@11020000. "USI11" appears in the pad name of the touch
 * reset line (XAPC_USI11_RTSn_DI); that is a pad label, not this block.
 *
 * The old driver's divider did respond to clk_set_rate() and debugfs did
 * report the requested rate, which is exactly why it survived so long: it
 * was software agreeing with itself against a register belonging to another
 * peripheral, while the SPI ran at whatever the bootloader had left.
 *
 * Register data from Google's tables for this SoC
 * (google-modules/soc/gs, drivers/soc/google/cal-if/zuma):
 *
 *	SFR_BLOCK(CMU_HSI0, 0x11000000, 0x8000)
 *	SFR(CLK_CON_DIV_DIV_CLK_HSI0_USI2, 0x181c, CMU_HSI0)
 *	SFR_ACCESS(..._DIVRATIO, 0, 4, ...)	bits [3:0], divide by ratio + 1
 *
 * flexpmu_cal_local_zuma.h states the same pair independently as
 * ("CLK_CON_DIV_DIV_CLK_HSI0_USI2", 0x11000000, 0x181c).
 *
 * Only the divider is modelled. Every mux and gate on this path was read on
 * hardware and is already open, and by Google's own ra_get_gate() semantics
 * a gate register with MANUAL (bit 20) clear is controlled by
 * ENABLE_AUTOMATIC_CLKGATING (bit 28), not by the CG_VAL bit a gate driver
 * would write -- so registering gates here would write a bit the hardware
 * ignores while claiming to control something.
 */

#include <linux/clk-provider.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#define CLK_CON_DIV_CLK_HSI0_USI2	0x181c
#define DIVRATIO_SHIFT			0
#define DIVRATIO_WIDTH			4

/*
 * CMU_TOP's divider on the way in, the second reg of this node.
 *
 *	SFR(CLK_CON_DIV_CLKCMU_HSI0_PERI, 0x1890, CMU_TOP)
 *	SFR_ACCESS(..._DIVRATIO, 0, 4, ...)
 *
 * Modelled so the bus can actually be slowed down. With only the HSI0
 * divider the floor is 399.36 MHz / 16 / 4 = 6.24 MHz, which is 1.6x below
 * the default and proved nothing when the touch part behaved identically at
 * both. Chaining this one reaches about 390 kHz, which is a real test.
 *
 * It reads 0 (divide by one) on this hardware and only moves when something
 * asks for a rate the HSI0 divider alone cannot reach.
 */
#define CLK_CON_DIV_CLKCMU_HSI0_PERI	0x0
#define CMU_TOP_DIVRATIO_WIDTH		4

/*
 * The HSI0 NOC clock, which becomes this USI's APB clock. Measured, not
 * assumed: PLL_CON0_MUX_CLKCMU_HSI0_NOC_USER (0x11000620) reads 0, so bit 4
 * selects OSCCLK_HSI0 rather than the CMU_TOP feed -- HSI0's bus is parked on
 * the oscillator because nothing else in the block is in use.
 *
 * Stated rather than modelled. Neither spi-s3c64xx nor exynos-usi does any
 * arithmetic with it; both only enable it. It is here so the DT phandles
 * resolve and so the number on record is the one the hardware showed.
 */
#define ZUMAPRO_HSI0_PCLK_RATE		24576000

static DEFINE_SPINLOCK(zumapro_hsi0_lock);

static int zumapro_cmu_hsi0_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct clk_hw_onecell_data *data;
	const char *parent;
	void __iomem *base;
	void __iomem *top;
	struct clk_hw *hw;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	parent = of_clk_get_parent_name(dev->of_node, 0);
	if (!parent)
		return dev_err_probe(dev, -EINVAL, "no parent clock\n");

	top = devm_platform_ioremap_resource(pdev, 1);
	if (IS_ERR(top))
		return dev_err_probe(dev, PTR_ERR(top), "no CMU_TOP divider\n");

	data = devm_kzalloc(dev, struct_size(data, hws, 2), GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	data->num = 2;

	hw = devm_clk_hw_register_fixed_rate(dev, "hsi0_usi2_pclk", NULL, 0,
					     ZUMAPRO_HSI0_PCLK_RATE);
	if (IS_ERR(hw))
		return dev_err_probe(dev, PTR_ERR(hw), "pclk\n");
	data->hws[0] = hw;

	/*
	 * The function clock, and the only writable thing here. Samsung's
	 * DIVRATIO divides by value + 1, which is what the generic divider
	 * does with no flags set.
	 *
	 * spi-s3c64xx must be able to set this. gs101's port config sets
	 * clk_from_cmu, so the controller has no prescaler and the driver
	 * asks for speed * 4 here, then believes whatever clk_get_rate()
	 * returns. Against the previous fixed-clock stub it believed 400 MHz
	 * and wrote CH_CFG = 0x43 -- CH_HS_EN, which it only sets at 30 MHz
	 * and above -- while asking the pads for a 100 MHz bit clock. That is
	 * ten times the touch part's rated maximum, from Google's board file.
	 */
	hw = devm_clk_hw_register_divider(dev, "hsi0_peri_div", parent, 0,
					  top + CLK_CON_DIV_CLKCMU_HSI0_PERI,
					  DIVRATIO_SHIFT, CMU_TOP_DIVRATIO_WIDTH,
					  0, &zumapro_hsi0_lock);
	if (IS_ERR(hw))
		return dev_err_probe(dev, PTR_ERR(hw), "peri div\n");

	/*
	 * CLK_SET_RATE_PARENT so a request the local divider cannot satisfy
	 * walks up to CMU_TOP instead of being clamped silently.
	 */
	hw = devm_clk_hw_register_divider(dev, "hsi0_usi2_ipclk",
					  "hsi0_peri_div", CLK_SET_RATE_PARENT,
					  base + CLK_CON_DIV_CLK_HSI0_USI2,
					  DIVRATIO_SHIFT, DIVRATIO_WIDTH, 0,
					  &zumapro_hsi0_lock);
	if (IS_ERR(hw))
		return dev_err_probe(dev, PTR_ERR(hw), "ipclk\n");
	data->hws[1] = hw;

	dev_info(dev, "USI2 divider registered, ipclk currently %lu Hz\n",
		 clk_hw_get_rate(hw));

	return devm_of_clk_add_hw_provider(dev, of_clk_hw_onecell_get, data);
}

static const struct of_device_id zumapro_cmu_hsi0_of_match[] = {
	{ .compatible = "google,zumapro-cmu-hsi0" },
	{ }
};

static struct platform_driver zumapro_cmu_hsi0_driver = {
	.driver = {
		.name = "zumapro-cmu-hsi0",
		.of_match_table = zumapro_cmu_hsi0_of_match,
		.suppress_bind_attrs = true,
	},
	.probe = zumapro_cmu_hsi0_probe,
};
builtin_platform_driver(zumapro_cmu_hsi0_driver);

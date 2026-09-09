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
#include <linux/moduleparam.h>
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

/*
 * The USB32DRD path, for dwc3 at 0x11210000.
 *
 * Every offset here is Google's, from cal-if/zuma/cmucal-sfr.c, and none of
 * it is gs101's. That distinction is the whole point: the gs101 numbers are
 * available, they compile, and they are wrong. github.com/zumapro-mainline
 * ships gs101's USB block in a file called clk-zuma.c -- REF_CLK_40 at 0x2078
 * where this SoC has it at 0x20ac, and four signal names (ACLK_PHYCTRL,
 * BUS_CLK_EARLY, USB20_PHY_REFCLK_26, USBPCS_APB_CLK) that do not occur
 * anywhere in zuma's tables at all. See ../notes/UPSTREAM.md.
 *
 * One offset in this table is confirmed against hardware rather than only
 * against the tables: QCH_CON_USI2_HSI0_QCH is 0x30cc there, and the boot
 * probe read 0x110030cc live and got 0x00000002. The block base and the
 * table's numbering are therefore both right.
 *
 * Note what this SoC has that gs101 does not: four eUSB gates. The stock
 * device tree's phy node says phy_eusb_version = <0x701>, and these are its
 * clocks.
 */
#define CLK_CON_GAT_USB_SUBCTL_APB_PCLK	0x20a0
#define CLK_CON_GAT_USB_LINK_ACLK	0x20a4
#define CLK_CON_GAT_USB_REF_CLK_40	0x20ac
#define CLK_CON_GAT_USB_DPPHY_CTRL_PCLK	0x20b4
#define CLK_CON_GAT_USB_EUSB_CTRL_PCLK	0x20b8
#define CLK_CON_GAT_USB_DPPHY_TCA_APB	0x20c0
#define CLK_CON_GAT_USB_EUSB_APB_CLK	0x20d8
#define CLK_CON_GAT_USB_EUSB_PHY_REFCLK	0x20dc

/* Bit 21 is the enable, as clk-zumapro-hsi2.c establishes for UFS's gates. */
#define ZUMAPRO_GATE_ENABLE_BIT		21

/* User muxes: bit 4 picks the CMU_TOP feed over the oscillator. */
#define PLL_CON0_MUX_CLKCMU_HSI0_USB32DRD_USER	0x650
#define PLL_CON0_MUX_CLKCMU_HSI0_USB20_USER	0x640
#define ZUMAPRO_USER_MUX_SEL_BIT	BIT(4)

/* Local muxes and dividers inside CMU_HSI0. */
#define CLK_CON_MUX_CLK_HSI0_USB20_REF	0x1004
#define CLK_CON_MUX_CLK_HSI0_USB32DRD	0x1008
#define CLK_CON_DIV_CLK_HSI0_USB	0x1804
#define CLK_CON_DIV_CLK_HSI0_USB32DRD	0x1808

/*
 * Q-channel controls.
 *
 * Enabled by default now, because it was measured: they read 0x00000002 as
 * the bootloader leaves them -- bit 0, the enable, clear on all seven -- and
 * writing it takes, 0x00000002 -> 0x00000003, read back from userspace after
 * the boot rather than inferred from a console.
 *
 * clk-zumapro-hsi2.c never touches a QCH and UFS runs, which is why this was
 * a parameter first. The difference is that the bootloader succeeded at UFS
 * and failed at USB ("[E] failed to get eUSB revision -62"), so it left the
 * UFS Q-channels enabled and the USB ones not.
 *
 * It does not make dwc3 work. See the note above the USB node in
 * ../dts/zumapro.dtsi: the whole clock domain is on and the core still will
 * not soft-reset, because that needs the PHY.
 */
#define QCH_CON_USB32DRD_QCH_LINK	0x30c0
#define QCH_CON_USB32DRD_QCH_SUBCTL	0x30bc
#define QCH_CON_USB32DRD_QCH_EUSBCTL	0x30b8
#define QCH_CON_USB32DRD_QCH_EUSBPHY	0x30a8
#define QCH_CON_USB32DRD_QCH_DPPHY_CTRL	0x30b0
#define QCH_CON_USB32DRD_QCH_DPPHY_TCA	0x30b4
#define QCH_CON_USB32DRD_QCH_REF	0x3000
#define ZUMAPRO_QCH_ENABLE_BIT		BIT(0)

/* CMU_TOP, reached through the second and third reg of this node. */
#define CLK_CON_DIV_CLKCMU_HSI0_USB32DRD_OFF	0x4	/* 0x26041894 */
#define CLK_CON_GAT_GATE_CLKCMU_HSI0_PERI_OFF	0x0	/* 0x260420c0 */
#define CLK_CON_GAT_GATE_CLKCMU_HSI0_USB_OFF	0x4	/* 0x260420c4 */

struct zumapro_hsi0_gate {
	const char *name;
	unsigned int offset;
};

/*
 * Order is the device-tree index, and indices 0 and 1 are already spoken for
 * by the USI2 pair the touchscreen uses. These start at 2; nothing existing
 * may be renumbered.
 */
static const struct zumapro_hsi0_gate zumapro_hsi0_usb_gates[] = {
	{ "hsi0_usb_link_aclk",	    CLK_CON_GAT_USB_LINK_ACLK },
	{ "hsi0_usb_subctl_pclk",   CLK_CON_GAT_USB_SUBCTL_APB_PCLK },
	{ "hsi0_usb_ref_clk_40",    CLK_CON_GAT_USB_REF_CLK_40 },
	{ "hsi0_usb_dpphy_ctrl_pclk", CLK_CON_GAT_USB_DPPHY_CTRL_PCLK },
	{ "hsi0_usb_eusb_ctrl_pclk", CLK_CON_GAT_USB_EUSB_CTRL_PCLK },
	{ "hsi0_usb_dpphy_tca_apb", CLK_CON_GAT_USB_DPPHY_TCA_APB },
	{ "hsi0_usb_eusb_apb_clk",  CLK_CON_GAT_USB_EUSB_APB_CLK },
	{ "hsi0_usb_eusb_phy_refclk", CLK_CON_GAT_USB_EUSB_PHY_REFCLK },
};

#define ZUMAPRO_HSI0_USI_CLKS	2
#define ZUMAPRO_HSI0_NR_CLKS \
	(ZUMAPRO_HSI0_USI_CLKS + ARRAY_SIZE(zumapro_hsi0_usb_gates))

static const struct { const char *name; unsigned int offset; } zumapro_hsi0_qch[] = {
	{ "link",	QCH_CON_USB32DRD_QCH_LINK },
	{ "subctl",	QCH_CON_USB32DRD_QCH_SUBCTL },
	{ "eusbctl",	QCH_CON_USB32DRD_QCH_EUSBCTL },
	{ "eusbphy",	QCH_CON_USB32DRD_QCH_EUSBPHY },
	{ "dpphy_ctrl",	QCH_CON_USB32DRD_QCH_DPPHY_CTRL },
	{ "dpphy_tca",	QCH_CON_USB32DRD_QCH_DPPHY_TCA },
	{ "ref",	QCH_CON_USB32DRD_QCH_REF },
};

/*
 * keep_boot_mux still defaults to touching the muxes, because the bootloader
 * left them selecting the oscillator (0x00000000) rather than the CMU_TOP
 * feed, and it failed at USB -- so unlike the UFS path its state here is not
 * known-good. Setting bit 4 was measured to take: usermux32 reads 0x00000010
 * afterwards.
 */
static bool keep_boot_mux;
module_param(keep_boot_mux, bool, 0444);
MODULE_PARM_DESC(keep_boot_mux, "do not touch the CMU_HSI0 USB user muxes");

static bool force_qch = true;
module_param(force_qch, bool, 0444);
MODULE_PARM_DESC(force_qch, "set the enable bit in the USB32DRD QCH_CONs (default on)");

static void zumapro_hsi0_set_bits(void __iomem *reg, u32 bits)
{
	writel(readl(reg) | bits, reg);
}

static DEFINE_SPINLOCK(zumapro_hsi0_lock);

static int zumapro_cmu_hsi0_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct clk_hw_onecell_data *data;
	const char *parent;
	void __iomem *base;
	void __iomem *top;
	void __iomem *topg;
	struct resource *res;
	struct clk_hw *hw;
	unsigned int i;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	parent = of_clk_get_parent_name(dev->of_node, 0);
	if (!parent)
		return dev_err_probe(dev, -EINVAL, "no parent clock\n");

	/*
	 * Map, do not claim. clk-zumapro-hsi2.c already requests CMU_TOP as
	 * 0x26040000 + 0x8000 for the UFS path, and 0x1890 is inside it, so
	 * devm_platform_ioremap_resource() here returns -EBUSY and takes the
	 * whole clock controller down with it -- which is exactly what it did:
	 * "supplier 11000000.clock-controller not ready", no SPI, no touch.
	 * Two drivers touching disjoint registers of one CMU is the normal
	 * shape of this SoC; neither should own the window.
	 */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!res)
		return dev_err_probe(dev, -EINVAL, "no CMU_TOP divider reg\n");

	top = devm_ioremap(dev, res->start, resource_size(res));
	if (!top)
		return dev_err_probe(dev, -ENOMEM, "cannot map CMU_TOP\n");

	/*
	 * The CMU_TOP gates, a second small window rather than one wide one.
	 * 0x260420c0 and 0x260420c4 are adjacent -- HSI0_PERI's gate and
	 * USB32DRD's -- and the boot probe has already read the first of them
	 * safely. Describing the span between the divider at 0x1890 and these
	 * would be a 0x830-byte window this port has no business sweeping.
	 */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 2);
	if (!res)
		return dev_err_probe(dev, -EINVAL, "no CMU_TOP gate reg\n");

	topg = devm_ioremap(dev, res->start, resource_size(res));
	if (!topg)
		return dev_err_probe(dev, -ENOMEM, "cannot map CMU_TOP gates\n");

	data = devm_kzalloc(dev, struct_size(data, hws, ZUMAPRO_HSI0_NR_CLKS),
			    GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	data->num = ZUMAPRO_HSI0_NR_CLKS;

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

	/*
	 * The USB32DRD path.
	 *
	 * Say what is there before changing it. dwc3 already probes far enough
	 * on this hardware to write DCTL.CSFTRST and poll it -- the registers
	 * answer -- and times out waiting for the core to execute the reset,
	 * which is what a controller with no clock does. So these registers
	 * are the hypothesis, and their before-state is the measurement that
	 * says whether it was right.
	 */
	dev_info(dev, "usb before: TOP div 0x%08x gate 0x%08x, USER usb32 0x%08x usb20 0x%08x, MUX 0x%08x/0x%08x, DIV 0x%08x/0x%08x\n",
		 readl(top + CLK_CON_DIV_CLKCMU_HSI0_USB32DRD_OFF),
		 readl(topg + CLK_CON_GAT_GATE_CLKCMU_HSI0_USB_OFF),
		 readl(base + PLL_CON0_MUX_CLKCMU_HSI0_USB32DRD_USER),
		 readl(base + PLL_CON0_MUX_CLKCMU_HSI0_USB20_USER),
		 readl(base + CLK_CON_MUX_CLK_HSI0_USB32DRD),
		 readl(base + CLK_CON_MUX_CLK_HSI0_USB20_REF),
		 readl(base + CLK_CON_DIV_CLK_HSI0_USB32DRD),
		 readl(base + CLK_CON_DIV_CLK_HSI0_USB));

	for (i = 0; i < ARRAY_SIZE(zumapro_hsi0_usb_gates); i++)
		dev_info(dev, "usb before: %-26s (0x%04x) 0x%08x\n",
			 zumapro_hsi0_usb_gates[i].name,
			 zumapro_hsi0_usb_gates[i].offset,
			 readl(base + zumapro_hsi0_usb_gates[i].offset));

	for (i = 0; i < ARRAY_SIZE(zumapro_hsi0_qch); i++)
		dev_info(dev, "usb before: qch %-11s (0x%04x) 0x%08x\n",
			 zumapro_hsi0_qch[i].name, zumapro_hsi0_qch[i].offset,
			 readl(base + zumapro_hsi0_qch[i].offset));

	/* CMU_TOP first: without this gate the block is fed nothing at all. */
	zumapro_hsi0_set_bits(topg + CLK_CON_GAT_GATE_CLKCMU_HSI0_USB_OFF,
			      BIT(ZUMAPRO_GATE_ENABLE_BIT));

	if (!keep_boot_mux) {
		zumapro_hsi0_set_bits(base + PLL_CON0_MUX_CLKCMU_HSI0_USB32DRD_USER,
				      ZUMAPRO_USER_MUX_SEL_BIT);
		zumapro_hsi0_set_bits(base + PLL_CON0_MUX_CLKCMU_HSI0_USB20_USER,
				      ZUMAPRO_USER_MUX_SEL_BIT);
	}

	if (force_qch)
		for (i = 0; i < ARRAY_SIZE(zumapro_hsi0_qch); i++)
			zumapro_hsi0_set_bits(base + zumapro_hsi0_qch[i].offset,
					      ZUMAPRO_QCH_ENABLE_BIT);

	/*
	 * CLK_IS_CRITICAL, as clk-zumapro-hsi2.c does for UFS and as gs101
	 * does for the same clocks: enabled at registration and never gated
	 * again. dwc3 gets its clocks by phandle, but a clock the framework
	 * believes is unused is one it will turn off before dwc3 ever probes.
	 */
	for (i = 0; i < ARRAY_SIZE(zumapro_hsi0_usb_gates); i++) {
		const struct zumapro_hsi0_gate *g = &zumapro_hsi0_usb_gates[i];

		hw = devm_clk_hw_register_gate(dev, g->name, parent,
					       CLK_SET_RATE_PARENT |
					       CLK_IS_CRITICAL,
					       base + g->offset,
					       ZUMAPRO_GATE_ENABLE_BIT,
					       0, &zumapro_hsi0_lock);
		if (IS_ERR(hw))
			return dev_err_probe(dev, PTR_ERR(hw), "%s\n", g->name);
		data->hws[ZUMAPRO_HSI0_USI_CLKS + i] = hw;
	}

	for (i = 0; i < ARRAY_SIZE(zumapro_hsi0_usb_gates); i++)
		dev_info(dev, "usb after:  %-26s (0x%04x) 0x%08x\n",
			 zumapro_hsi0_usb_gates[i].name,
			 zumapro_hsi0_usb_gates[i].offset,
			 readl(base + zumapro_hsi0_usb_gates[i].offset));

	/*
	 * The QCHs after, not only before. Leaving this out is what made the
	 * first attempt at them unreadable: the driver wrote the registers and
	 * then never said what they became, so a boot that changed nothing and
	 * a boot whose parameter never arrived produced identical logs.
	 */
	for (i = 0; i < ARRAY_SIZE(zumapro_hsi0_qch); i++)
		dev_info(dev, "usb after:  qch %-11s (0x%04x) 0x%08x\n",
			 zumapro_hsi0_qch[i].name, zumapro_hsi0_qch[i].offset,
			 readl(base + zumapro_hsi0_qch[i].offset));

	dev_info(dev, "usb after:  TOP gate 0x%08x, USER usb32 0x%08x usb20 0x%08x%s%s\n",
		 readl(topg + CLK_CON_GAT_GATE_CLKCMU_HSI0_USB_OFF),
		 readl(base + PLL_CON0_MUX_CLKCMU_HSI0_USB32DRD_USER),
		 readl(base + PLL_CON0_MUX_CLKCMU_HSI0_USB20_USER),
		 keep_boot_mux ? ", user muxes left as booted" : "",
		 force_qch ? ", qch forced" : "");

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

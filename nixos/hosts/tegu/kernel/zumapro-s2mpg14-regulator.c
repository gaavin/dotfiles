// SPDX-License-Identifier: GPL-2.0-only
/*
 * The two S2MPG14 rails the Pixel 9a's touchscreen runs on.
 *
 * Register data from Google's own header for this part,
 * google-modules/soc/gs, include/linux/mfd/samsung/s2mpg14-register.h:
 *
 *	S2MPG14_PM_L4M_CTRL  = 0x2E	group 5: min 1800000, step 25000
 *	S2MPG14_PM_L25M_CTRL = 0x43	group 4: min  700000, step 25000
 *
 * with S2MPG14_REG_ENABLE_MASK_7 = BIT(7) in the same register as the
 * voltage selector, and 64 voltages so the selector is the low 6 bits.
 *
 * Those offsets are confirmed against the hardware rather than trusted.
 * A read-only dump of this PMIC (kernel/zumapro-pmic-dump.c, output in
 * notes/s2mpg14-dump.txt) has 0x2E = 0x3c and 0x43 = 0x2c. Decoding the
 * selectors with the groups above gives
 *
 *	0x3c & 0x3f = 60 -> 1800000 + 60 * 25000 = 3300000 uV
 *	0x2c & 0x3f = 44 ->  700000 + 44 * 25000 = 1800000 uV
 *
 * and Google's board file (zuma-tegu-common-touch.dtsi) gives AVDD 3300000
 * and DVDD 1800000. Two exact hits, so the map is right. Both also read
 * with bit 7 clear: the rails are correctly programmed and switched off,
 * which is why the touch part is silent on a SPI bus that demonstrably
 * works, and why its active-low IRQ sits at 0 through a pull-up.
 *
 * Why this is not sec-acpm.c plus s2mps11.c. Mainline's MFD knows only
 * S2MPG10/11, whose register map is not this one -- on S2MPG10 the LDO
 * block starts at 0x40, which would put "LDO4M" at 0x43, and 0x43 here is
 * LDO25M. Enabling AVDD at that address would have switched on DVDD at a
 * voltage decoded from the wrong group and looked like partial success.
 * sec_pmic_probe() also installs a regmap-irq chip, which writes mask
 * registers at probe and needs an interrupt this port cannot yet supply:
 * gs101 takes it from a GPIO and zumapro has no pinctrl driver here.
 *
 * So this talks to ACPM directly and registers only the two rails whose
 * offsets are verified. Every write is a read-modify-write of BIT(7)
 * through acpm's update_reg; nothing here touches a voltage selector
 * unless the regulator core explicitly asks, and the device tree pins
 * both rails to the values the hardware already holds.
 */

#include <linux/device.h>
#include <linux/firmware/samsung/exynos-acpm-protocol.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regulator/driver.h>
#include <linux/regulator/machine.h>
#include <linux/regulator/of_regulator.h>

#define PMIC_ACPM_CHAN		2
#define PMIC_SPEEDY_MAIN	0
#define PMIC_TYPE_PMIC		0x01

#define S2MPG14_PM_L4M_CTRL	0x2e
#define S2MPG14_PM_L25M_CTRL	0x43

#define S2MPG14_LDO_ENABLE	BIT(7)
#define S2MPG14_LDO_VSEL_MASK	0x3f
#define S2MPG14_LDO_N_VOLTAGES	64
#define S2MPG14_ENABLE_TIME_LDO	128

struct zumapro_s2mpg14 {
	struct acpm_handle *acpm;
};

static int s2mpg14_read(struct regulator_dev *rdev, u8 reg, u8 *val)
{
	struct zumapro_s2mpg14 *pmic = rdev_get_drvdata(rdev);

	return pmic->acpm->ops->pmic.read_reg(pmic->acpm, PMIC_ACPM_CHAN,
					      PMIC_TYPE_PMIC, reg,
					      PMIC_SPEEDY_MAIN, val);
}

static int s2mpg14_update(struct regulator_dev *rdev, u8 reg, u8 val, u8 mask)
{
	struct zumapro_s2mpg14 *pmic = rdev_get_drvdata(rdev);

	return pmic->acpm->ops->pmic.update_reg(pmic->acpm, PMIC_ACPM_CHAN,
						PMIC_TYPE_PMIC, reg,
						PMIC_SPEEDY_MAIN, val, mask);
}

static int s2mpg14_enable(struct regulator_dev *rdev)
{
	return s2mpg14_update(rdev, rdev->desc->enable_reg,
			      rdev->desc->enable_mask, rdev->desc->enable_mask);
}

static int s2mpg14_disable(struct regulator_dev *rdev)
{
	return s2mpg14_update(rdev, rdev->desc->enable_reg, 0,
			      rdev->desc->enable_mask);
}

static int s2mpg14_is_enabled(struct regulator_dev *rdev)
{
	int ret;
	u8 val;

	ret = s2mpg14_read(rdev, rdev->desc->enable_reg, &val);
	if (ret)
		return ret;

	return !!(val & rdev->desc->enable_mask);
}

static int s2mpg14_get_voltage_sel(struct regulator_dev *rdev)
{
	int ret;
	u8 val;

	ret = s2mpg14_read(rdev, rdev->desc->vsel_reg, &val);
	if (ret)
		return ret;

	return val & rdev->desc->vsel_mask;
}

static int s2mpg14_set_voltage_sel(struct regulator_dev *rdev, unsigned int sel)
{
	return s2mpg14_update(rdev, rdev->desc->vsel_reg, sel,
			      rdev->desc->vsel_mask);
}

static const struct regulator_ops zumapro_s2mpg14_ldo_ops = {
	.enable			= s2mpg14_enable,
	.disable		= s2mpg14_disable,
	.is_enabled		= s2mpg14_is_enabled,
	.get_voltage_sel	= s2mpg14_get_voltage_sel,
	.set_voltage_sel	= s2mpg14_set_voltage_sel,
	.list_voltage		= regulator_list_voltage_linear,
	.map_voltage		= regulator_map_voltage_linear,
};

#define S2MPG14_LDO(_name, _id, _reg, _min_uV)				\
	{								\
		.name		= _name,				\
		.of_match	= of_match_ptr(_name),			\
		.regulators_node = of_match_ptr("regulators"),		\
		.id		= _id,					\
		.ops		= &zumapro_s2mpg14_ldo_ops,		\
		.type		= REGULATOR_VOLTAGE,			\
		.owner		= THIS_MODULE,				\
		.min_uV		= _min_uV,				\
		.uV_step	= 25000,				\
		.n_voltages	= S2MPG14_LDO_N_VOLTAGES,		\
		.vsel_reg	= _reg,					\
		.vsel_mask	= S2MPG14_LDO_VSEL_MASK,		\
		.enable_reg	= _reg,					\
		.enable_mask	= S2MPG14_LDO_ENABLE,			\
		.enable_time	= S2MPG14_ENABLE_TIME_LDO,		\
	}

/*
 * Only the rails whose offsets have been checked against a live read. The
 * part has far more; adding one means confirming its group and register
 * the same way, not extrapolating from these two.
 */
static const struct regulator_desc zumapro_s2mpg14_regulators[] = {
	S2MPG14_LDO("LDO4M",  0, S2MPG14_PM_L4M_CTRL,  1800000),
	S2MPG14_LDO("LDO25M", 1, S2MPG14_PM_L25M_CTRL,  700000),
};

static int zumapro_s2mpg14_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct regulator_config config = { };
	struct zumapro_s2mpg14 *pmic;
	int i, sel;

	pmic = devm_kzalloc(dev, sizeof(*pmic), GFP_KERNEL);
	if (!pmic)
		return -ENOMEM;

	pmic->acpm = devm_acpm_get_by_node(dev, dev->parent->of_node);
	if (IS_ERR(pmic->acpm))
		return dev_err_probe(dev, PTR_ERR(pmic->acpm),
				     "no acpm handle\n");

	config.dev = dev;
	config.driver_data = pmic;

	for (i = 0; i < ARRAY_SIZE(zumapro_s2mpg14_regulators); i++) {
		const struct regulator_desc *desc =
			&zumapro_s2mpg14_regulators[i];
		struct regulator_dev *rdev;

		rdev = devm_regulator_register(dev, desc, &config);
		if (IS_ERR(rdev))
			return dev_err_probe(dev, PTR_ERR(rdev),
					     "failed to register %s\n",
					     desc->name);

		/*
		 * KERN_ERR so it survives the console loglevel on a phone
		 * whose only output is a receive-only UART. Reports what the
		 * rail actually reads back, not what was asked for.
		 */
		sel = s2mpg14_get_voltage_sel(rdev);
		dev_err(dev, "%s: sel %d -> %d uV, %s\n", desc->name, sel,
			sel < 0 ? sel : desc->min_uV + sel * desc->uV_step,
			s2mpg14_is_enabled(rdev) > 0 ? "on" : "off");
	}

	return 0;
}

static const struct of_device_id zumapro_s2mpg14_of_match[] = {
	{ .compatible = "google,zumapro-s2mpg14-regulator" },
	{ }
};

static struct platform_driver zumapro_s2mpg14_driver = {
	.driver = {
		.name = "zumapro-s2mpg14-regulator",
		.of_match_table = zumapro_s2mpg14_of_match,
		.suppress_bind_attrs = true,
	},
	.probe = zumapro_s2mpg14_probe,
};
builtin_platform_driver(zumapro_s2mpg14_driver);

#!/usr/bin/env python3
"""Teach mainline's Samsung PMIC MFD about the S2MPG14, and register the two
rails the Pixel 9a's touchscreen runs on.

This replaces kernel/zumapro-s2mpg14-regulator.c, which drove those rails by
hand-rolled ACPM calls. That driver's header listed two reasons the mainline
stack could not be used; both are now gone. Mainline gained S2MPG10/11 support
over sec-acpm.c (which puts a regmap on top of ACPM, so the ordinary regmap
regulator ops work), and the register map that was missing is supplied here.

The register data is taken from the zumapro-mainline tree
(github.com/zumapro-mainline/linux, commit 97f3c05b) and then checked, name by
name, against Google's own header in google-modules/soc/gs,
include/linux/mfd/samsung/s2mpg14-register.h. All 169 names in the former
appear in the latter with the same address, so the header is a faithful subset
and is used as-is.

Three things in that tree are NOT followed, because comparing it against
Google's header showed they are wrong for this part:

 1. It reuses s2mpg10_irq_chip for the S2MPG14. The S2MPG14's common block has
    no interrupt registers at all -- it is VGPIO0..3, I3C_DAA, IBI0..3, CHIPID
    at 0x0b -- whereas S2MPG10 has CHIPID at 0x00, INT at 0x01 and INT_MASK at
    0x02. regmap-irq would therefore read status from VGPIO1 and write its
    mask byte into VGPIO2, a live virtual-GPIO control interface. The chained
    PMIC chip is wrong too: S2MPG10 has six INT registers (INT1M..INT6M at
    0x06..0x0b) and S2MPG14 has five (INT1M..INT5M at 0x05..0x09), so every
    mask write lands one register high and the last two land on STATUS1 and
    STATUS2. sec_irq_init() returns NULL for this part instead, the way it
    already does for the S2DOS05; regmap_irq_get_domain() is NULL-safe and
    sec_pmic_probe() carries on. Nothing here needs a PMIC interrupt.

 2. It gives the S2MPG14 an RTC regmap built from S2MPG10's offsets. Google's
    header has no S2MPG14 RTC block whatsoever, so that regmap describes
    nothing. sec_pmic_acpm_probe() skips it when the config is NULL.

 3. Its s2mpg14_regulators[] holds one entry, buck7m, and no LDO -- yet its own
    device tree refers to an ldo5m that therefore cannot bind. The rails this
    port needs are LDO4M and LDO25M, so those are what is registered here.

The LDO parameters are Google's, from drivers/regulator/s2mpg14-regulator.c:

	LDO4M   group 5, 64 selectors, L4M_CTRL  0x2e, enable BIT(7)
	LDO25M  group 4, 64 selectors, L25M_CTRL 0x43, enable BIT(7)

with S2MPG14_REG_MIN5/STEP5 = 1800000/25000 and MIN4/STEP4 = 700000/25000.
Both were confirmed on this phone before either source was read: a read-only
dump had 0x2e = 0x3c and 0x43 = 0x2c, which decode to 3300000 uV and 1800000
uV, exactly the AVDD and DVDD in Google's board file. BIT(7) rather than the
7:6 field is Google's own choice for these two; LDO5M/6M/9M next to them do use
7:6, and mainline models the same split for the S2MPG10 (regulator_desc_ldo
uses BIT(7), regulator_desc_ldo_gpio uses GENMASK(7, 6)).

The S2MPG15 is deliberately left out. It is the second PMIC on speedy channel
1, nothing this port drives hangs off it, and adding it would mean writing to a
device no experiment here has touched. Wiring it up later is the same shape as
this: a header, a platform-data entry, an of_match line and a regulator table.
"""
import sys

hdr_src = sys.argv[1] if len(sys.argv) > 1 else "s2mpg14.h"

def edit(path, subs, guard=None):
	s = open(path).read()
	if guard and guard in s:
		sys.exit("sec-acpm-s2mpg14: %s already carries %s; drop this patch" % (path, guard))
	for anchor, new in subs:
		if anchor not in s:
			sys.exit("sec-acpm-s2mpg14: anchor moved in %s:\n%s" % (path, anchor))
		if s.count(anchor) != 1:
			sys.exit("sec-acpm-s2mpg14: anchor is not unique in %s:\n%s" % (path, anchor))
		s = s.replace(anchor, new)
	open(path, "w").write(s)

# --- the register map ------------------------------------------------------
open("include/linux/mfd/samsung/s2mpg14.h", "w").write(open(hdr_src).read())

# --- enum sec_device_type --------------------------------------------------
edit("include/linux/mfd/samsung/core.h", [
	("\tS2MPG11,\n", "\tS2MPG11,\n\tS2MPG14,\n"),
], guard="S2MPG14")

# --- sec-acpm.c: regmaps and platform data ---------------------------------
acpm_regmaps = '''
/*
 * S2MPG14. The common block is not S2MPG10's: there is no interrupt register
 * pair in it, CHIPID sits at 0x0b, and 0x00..0x03 are the VGPIOs. The PMIC
 * block ends at SW_RESET rather than S2MPG10's LDO_SENSE4.
 */
static const struct regmap_range s2mpg14_common_registers[] = {
	regmap_reg_range(0x00, 0x25), /* All common registers */
};

static const struct regmap_range s2mpg14_common_ro_registers[] = {
	regmap_reg_range(0x0b, 0x0b), /* CHIPID */
	regmap_reg_range(0x0e, 0x0e), /* I3C_STA */
};

static const struct regmap_access_table s2mpg14_common_wr_table = {
	.yes_ranges = s2mpg14_common_registers,
	.n_yes_ranges = ARRAY_SIZE(s2mpg14_common_registers),
	.no_ranges = s2mpg14_common_ro_registers,
	.n_no_ranges = ARRAY_SIZE(s2mpg14_common_ro_registers),
};

static const struct regmap_access_table s2mpg14_common_rd_table = {
	.yes_ranges = s2mpg14_common_registers,
	.n_yes_ranges = ARRAY_SIZE(s2mpg14_common_registers),
};

static const struct regmap_config s2mpg14_regmap_config_common = {
	.name = "common",
	.reg_bits = ACPM_ADDR_BITS,
	.val_bits = 8,
	.max_register = S2MPG14_COMMON_TEST_MODE2,
	.wr_table = &s2mpg14_common_wr_table,
	.rd_table = &s2mpg14_common_rd_table,
};

static const struct regmap_range s2mpg14_pmic_registers[] = {
	regmap_reg_range(0x00, 0xe4), /* All PMIC registers */
};

static const struct regmap_range s2mpg14_pmic_ro_registers[] = {
	regmap_reg_range(0x00, 0x04), /* INT1..INT5 */
	regmap_reg_range(0x0a, 0x0f), /* STATUSx PWRONSRC OFFSRCx BUCHG */
};

static const struct regmap_access_table s2mpg14_pmic_wr_table = {
	.yes_ranges = s2mpg14_pmic_registers,
	.n_yes_ranges = ARRAY_SIZE(s2mpg14_pmic_registers),
	.no_ranges = s2mpg14_pmic_ro_registers,
	.n_no_ranges = ARRAY_SIZE(s2mpg14_pmic_ro_registers),
};

static const struct regmap_access_table s2mpg14_pmic_rd_table = {
	.yes_ranges = s2mpg14_pmic_registers,
	.n_yes_ranges = ARRAY_SIZE(s2mpg14_pmic_registers),
};

static const struct regmap_config s2mpg14_regmap_config_pmic = {
	.name = "pmic",
	.reg_bits = ACPM_ADDR_BITS,
	.val_bits = 8,
	.max_register = S2MPG14_PMIC_SW_RESET,
	.wr_table = &s2mpg14_pmic_wr_table,
	.rd_table = &s2mpg14_pmic_rd_table,
};

static const struct regmap_range s2mpg14_meter_registers[] = {
	regmap_reg_range(0x00, 0xe5), /* All meter registers */
};

static const struct regmap_access_table s2mpg14_meter_rd_table = {
	.yes_ranges = s2mpg14_meter_registers,
	.n_yes_ranges = ARRAY_SIZE(s2mpg14_meter_registers),
};

static const struct regmap_config s2mpg14_regmap_config_meter = {
	.name = "meter",
	.reg_bits = ACPM_ADDR_BITS,
	.val_bits = 8,
	.max_register = S2MPG14_METER_EXT_SIGNED_DATA_2,
	.rd_table = &s2mpg14_meter_rd_table,
};

/*
 * None of the three is cached. S2MPG10's configs use REGCACHE_FLAT with
 * num_reg_defaults_raw, which makes regmap read the entire block out of the
 * device at init -- one ACPM round trip per register, against a layout this
 * port has not verified for the S2MPG14. Nothing here reads often enough to
 * want a cache, and the meter regmap in particular is only built because
 * probe always builds one; no meter driver is registered.
 *
 * No RTC config at all. Google's register header has no S2MPG14 RTC block, so
 * there is nothing for one to describe, and probe skips it when it is NULL.
 */
static const struct sec_pmic_acpm_platform_data s2mpg14_data = {
	.device_type = S2MPG14,
	.acpm_chan_id = 2,
	.speedy_channel = 0,
	.regmap_cfg_common = &s2mpg14_regmap_config_common,
	.regmap_cfg_pmic = &s2mpg14_regmap_config_pmic,
	.regmap_cfg_meter = &s2mpg14_regmap_config_meter,
};

'''
edit("drivers/mfd/sec-acpm.c", [
	("#include <linux/mfd/samsung/s2mpg11.h>\n",
	 "#include <linux/mfd/samsung/s2mpg11.h>\n#include <linux/mfd/samsung/s2mpg14.h>\n"),
	("static const struct of_device_id sec_pmic_acpm_of_match[] = {",
	 acpm_regmaps.lstrip("\n") + "static const struct of_device_id sec_pmic_acpm_of_match[] = {"),
	('\t{ .compatible = "samsung,s2mpg11-pmic", .data = &s2mpg11_data, },\n',
	 '\t{ .compatible = "samsung,s2mpg11-pmic", .data = &s2mpg11_data, },\n'
	 '\t{ .compatible = "samsung,s2mpg14-pmic", .data = &s2mpg14_data, },\n'),
], guard="s2mpg14_data")

# --- sec-common.c: cells and probe -----------------------------------------
edit("drivers/mfd/sec-common.c", [
	("static const struct resource s2mps11_rtc_resources[] = {",
	 "/* Only the regulator: there is no S2MPG14 meter or gpio driver here. */\n"
	 "static const struct mfd_cell s2mpg14_devs[] = {\n"
	 '\tMFD_CELL_NAME("s2mpg14-regulator"),\n'
	 "};\n\n"
	 "static const struct resource s2mps11_rtc_resources[] = {"),
	("\tcase S2MPG10:\n\tcase S2MPG11:\n\t\t/* For s2mpg1x, the revision is in a different regmap */\n\t\treturn;\n",
	 "\tcase S2MPG10:\n\tcase S2MPG11:\n\tcase S2MPG14:\n\t\t/* For s2mpg1x, the revision is in a different regmap */\n\t\treturn;\n"),
	("\tcase S2MPS11X:\n\t\tsec_devs = s2mps11_devs;\n",
	 "\tcase S2MPG14:\n\t\tsec_devs = s2mpg14_devs;\n"
	 "\t\tnum_sec_devs = ARRAY_SIZE(s2mpg14_devs);\n\t\tbreak;\n"
	 "\tcase S2MPS11X:\n\t\tsec_devs = s2mps11_devs;\n"),
], guard="s2mpg14_devs")

# --- sec-irq.c: no interrupt chip for this part -----------------------------
edit("drivers/mfd/sec-irq.c", [
	("\tcase S2MPG10:\n\tcase S2MPG11:\n\t\treturn sec_irq_init_s2mpg1x(sec_pmic);\n",
	 "\tcase S2MPG10:\n\tcase S2MPG11:\n\t\treturn sec_irq_init_s2mpg1x(sec_pmic);\n"
	 "\tcase S2MPG14:\n"
	 "\t\t/*\n"
	 "\t\t * No interrupt chip. The S2MPG14's common block has no INT or\n"
	 "\t\t * INT_MASK register -- it interrupts over I3C IBI -- and its\n"
	 "\t\t * five PMIC INT registers sit one below S2MPG10's six, so\n"
	 "\t\t * s2mpg10_irq_chip would write masks into the VGPIOs and into\n"
	 "\t\t * STATUS1/STATUS2. Nothing needs those interrupts here.\n"
	 "\t\t */\n"
	 "\t\treturn NULL;\n"),
], guard="case S2MPG14:")

# --- s2mps11.c: the two rails ----------------------------------------------
ldo_descs = '''
/* S2MPG14 LDO group 4 and group 5, 64 selectors each (Google's MIN4/STEP4,
 * MIN5/STEP5). Group 5 carries LDO4M at 3.3 V, group 4 LDO25M at 1.8 V.
 */
S2MPG10_VOLTAGE_RANGE(s2mpg14_ldo, 4, 700000, 700000, 2275000, STEP_25_MV);
S2MPG10_VOLTAGE_RANGE(s2mpg14_ldo, 5, 1800000, 1800000, 3375000, STEP_25_MV);

/*
 * Enable is BIT(7), not the 7:6 field the GPIO-controllable rails use; that is
 * Google's own choice for these two, and matches the split mainline already
 * models for the S2MPG10. No supply_name: this port does not describe the
 * input rails, and naming one that the device tree does not provide would
 * leave the regulator waiting for a supply that never arrives.
 */
#define regulator_desc_s2mpg14_ldo(_num, _range) {			\\
	.name		= "ldo"#_num"m",				\\
	.of_match	= of_match_ptr("ldo"#_num"m"),			\\
	.regulators_node = of_match_ptr("regulators"),			\\
	.id		= S2MPG14_LDO##_num,				\\
	.ops		= &s2mps15_reg_ldo_ops,				\\
	.type		= REGULATOR_VOLTAGE,				\\
	.owner		= THIS_MODULE,					\\
	.linear_ranges	= _range,					\\
	.n_linear_ranges = ARRAY_SIZE(_range),				\\
	.n_voltages	= _range##_count,				\\
	.vsel_reg	= S2MPG14_PMIC_L##_num##M_CTRL,			\\
	.vsel_mask	= GENMASK(5, 0),				\\
	.enable_reg	= S2MPG14_PMIC_L##_num##M_CTRL,			\\
	.enable_mask	= BIT(7),					\\
}

static const struct regulator_desc s2mpg14_regulators[] = {
	regulator_desc_s2mpg14_ldo(4, s2mpg14_ldo_vranges5),
	regulator_desc_s2mpg14_ldo(25, s2mpg14_ldo_vranges4),
};

'''
edit("drivers/regulator/s2mps11.c", [
	("#include <linux/mfd/samsung/s2mpg11.h>\n",
	 "#include <linux/mfd/samsung/s2mpg11.h>\n#include <linux/mfd/samsung/s2mpg14.h>\n"),
	("static int s2mps14_pmic_enable_ext_control(struct s2mps11_info *s2mps11,",
	 ldo_descs.lstrip("\n") + "static int s2mps14_pmic_enable_ext_control(struct s2mps11_info *s2mps11,"),
	("\tcase S2MPG10:\n\t\trdev_num = ARRAY_SIZE(s2mpg10_regulators);\n",
	 "\tcase S2MPG14:\n\t\trdev_num = ARRAY_SIZE(s2mpg14_regulators);\n"
	 "\t\tregulators = s2mpg14_regulators;\n"
	 "\t\tBUILD_BUG_ON(ARRAY_SIZE(s2mpg14_regulators) > S2MPS_REGULATOR_MAX);\n"
	 "\t\tbreak;\n"
	 "\tcase S2MPG10:\n\t\trdev_num = ARRAY_SIZE(s2mpg10_regulators);\n"),
	('\t{ .name = "s2mpg10-regulator", .driver_data = S2MPG10 },\n',
	 '\t{ .name = "s2mpg14-regulator", .driver_data = S2MPG14 },\n'
	 '\t{ .name = "s2mpg10-regulator", .driver_data = S2MPG10 },\n'),
], guard="s2mpg14_regulators")

print("sec-acpm-s2mpg14: ok")

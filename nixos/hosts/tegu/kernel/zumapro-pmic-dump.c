// SPDX-License-Identifier: GPL-2.0-only
/*
 * Read-only dump of the Tensor G4 (zumapro) main PMIC over ACPM.
 *
 * ACPM itself is up: power-management binds exynos-acpm-protocol,
 * 15110000.mailbox binds exynos-acpm-mbox, nothing is deferred, and the
 * gs101-acpm-clk device exists -- which exynos-acpm.c only creates after a
 * successful probe. So the mailbox, IRQ 80, the SRAM and the 0xa000 initdata
 * offset are all confirmed, and Tensor G4 speaks the gs101 protocol.
 *
 * What is NOT known is the PMIC's register map. This phone has S2MPG14 and
 * S2MPG15; mainline's sec-acpm.c knows only S2MPG10 and S2MPG11, and no
 * source available to this port describes S2MPG14 -- google-modules/soc/gs
 * mentions the name once, in exynos-pm.c, with no table.
 *
 * Declaring the node as "samsung,s2mpg10-pmic" to borrow the driver would not
 * be a harmless experiment. sec_pmic_probe() installs a regmap-irq chip, and
 * regmap-irq WRITES the interrupt mask registers at probe. On a part whose map
 * differs those writes land at S2MPG10's offsets inside a live PMIC, which
 * controls every rail on the board including the ones this phone boots from.
 * A wrong guess at a SPI register costs a reboot; this does not.
 *
 * So this reads and prints, and never writes. acpm_pmic_ops has read_reg and
 * bulk_read alongside write_reg/update_reg; only the read side is referenced
 * here. Channel 2 and speedy channel 0 come from mainline's own s2mpg10_data,
 * and are the first thing the dump tests: if they are wrong for S2MPG14 the
 * reads fail or return nothing that looks like a register file, and that is
 * the answer to a question rather than damage.
 */

#include <linux/device.h>
#include <linux/firmware/samsung/exynos-acpm-protocol.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#define PMIC_ACPM_CHAN		2
#define PMIC_SPEEDY_MAIN	0
#define PMIC_SPEEDY_SUB		1

#define TYPE_COMMON		0x00
#define TYPE_PMIC		0x01
#define TYPE_RTC		0x02
#define TYPE_METER		0x0a

/* exynos-acpm-pmic.c: ACPM_PMIC_BULK_MAX_COUNT, a hard cap of 8. */
#define BULK_MAX		8
#define DUMP_LEN		0x40

static void zumapro_pmic_dump_type(struct acpm_handle *acpm, struct device *dev,
				   const char *name, u8 type, u8 speedy)
{
	const struct acpm_pmic_ops *pmic = &acpm->ops->pmic;
	u8 buf[DUMP_LEN];
	int ret, i;

	memset(buf, 0, sizeof(buf));

	/*
	 * In chunks of ACPM_PMIC_BULK_MAX_COUNT. exynos-acpm-pmic.c rejects
	 * anything larger with -EINVAL before a single word reaches ACPM, so
	 * asking for all 64 at once -- which this did at first -- says nothing
	 * about the PMIC. Report per chunk: a failure partway through is a
	 * different fact from a failure at offset 0.
	 */
	for (i = 0; i < DUMP_LEN; i += BULK_MAX) {
		ret = pmic->bulk_read(acpm, PMIC_ACPM_CHAN, type, i, speedy,
				      BULK_MAX, buf + i);
		if (ret) {
			dev_err(dev, "speedy%u %-6s +0x%02x: bulk_read failed: %d\n",
				speedy, name, i, ret);
			return;
		}
	}

	for (i = 0; i < DUMP_LEN; i += 16)
		dev_err(dev,
			"speedy%u %-6s +0x%02x: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
			speedy, name, i,
			buf[i + 0], buf[i + 1], buf[i + 2], buf[i + 3],
			buf[i + 4], buf[i + 5], buf[i + 6], buf[i + 7],
			buf[i + 8], buf[i + 9], buf[i + 10], buf[i + 11],
			buf[i + 12], buf[i + 13], buf[i + 14], buf[i + 15]);
}

static int zumapro_pmic_dump_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct acpm_handle *acpm;

	acpm = devm_acpm_get_by_node(dev, dev->parent->of_node);
	if (IS_ERR(acpm))
		return dev_err_probe(dev, PTR_ERR(acpm), "no acpm handle\n");

	/*
	 * KERN_ERR throughout. On this phone the only way a message is read is
	 * over a receive-only UART, and anything below the console loglevel is
	 * simply never seen.
	 */
	dev_err(dev, "S2MPG14/15 dump, chan %u, read-only\n", PMIC_ACPM_CHAN);

	zumapro_pmic_dump_type(acpm, dev, "common", TYPE_COMMON, PMIC_SPEEDY_MAIN);
	zumapro_pmic_dump_type(acpm, dev, "pmic",   TYPE_PMIC,   PMIC_SPEEDY_MAIN);
	zumapro_pmic_dump_type(acpm, dev, "rtc",    TYPE_RTC,    PMIC_SPEEDY_MAIN);
	zumapro_pmic_dump_type(acpm, dev, "meter",  TYPE_METER,  PMIC_SPEEDY_MAIN);
	zumapro_pmic_dump_type(acpm, dev, "common", TYPE_COMMON, PMIC_SPEEDY_SUB);
	zumapro_pmic_dump_type(acpm, dev, "pmic",   TYPE_PMIC,   PMIC_SPEEDY_SUB);

	dev_err(dev, "dump complete\n");

	return 0;
}

static const struct of_device_id zumapro_pmic_dump_of_match[] = {
	{ .compatible = "google,zumapro-pmic-dump" },
	{ }
};

static struct platform_driver zumapro_pmic_dump_driver = {
	.driver = {
		.name = "zumapro-pmic-dump",
		.of_match_table = zumapro_pmic_dump_of_match,
		.suppress_bind_attrs = true,
	},
	.probe = zumapro_pmic_dump_probe,
};
builtin_platform_driver(zumapro_pmic_dump_driver);

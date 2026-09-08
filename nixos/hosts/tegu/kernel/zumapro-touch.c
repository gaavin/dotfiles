// SPDX-License-Identifier: GPL-2.0-only
/*
 * Synaptics TouchComm v1 over SPI for the Pixel 9a (tegu).
 *
 * Mainline has no TouchComm driver in any form -- only RMI4, a different
 * protocol -- and Google's is a large out-of-tree module. This is a minimal
 * one written against their protocol sources
 * (google-modules/touch/synaptics_touch, branch android-gs-tegu-6.1-android16,
 * syna_c10/tcm/synaptics_touchcom_core_v1.c):
 *
 *   command  [ cmd, len_lo, len_hi, payload... ]
 *   response [ 0xa5, code, len_lo, len_hi ] followed by len payload bytes
 *
 * 0xa5 is TCM_V1_MESSAGE_MARKER and 0x5a is TCM_V1_MESSAGE_PADDING.
 *
 * WHAT THIS DOES AND DOES NOT DO
 *
 * It powers the part, resets it, identifies it, asks for touch reports and
 * logs what arrives. It does not yet decode touch coordinates. TouchComm's
 * touch report is a configurable bitfield sequence described by a
 * report-config the part supplies at runtime, and writing that decoder blind
 * -- before this port has ever seen the device answer -- would be inventing a
 * format rather than reading one. The reports are dumped instead so the
 * layout can be read off real data, which is how every other part of this
 * port was settled.
 *
 * TWO THINGS ARE MISSING FROM THE SOC AND ARE WORKED AROUND HERE
 *
 * There is no pinctrl driver for zumapro, so neither the reset line
 * (gpp1-1, peric0) nor the interrupt (gpn0-0, alive) can be requested
 * properly. Reset is therefore driven by writing the GPIO block directly,
 * exactly as kernel/zumapro-ufs-restore.c already does for the UFS pins, and
 * the driver polls instead of taking the ATTN interrupt. Both are shims that
 * a real pinctrl driver should delete.
 */

#include <linux/delay.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>
#include <linux/spi/spi.h>
#include <linux/workqueue.h>

#define TCM_MARKER		0xa5
#define TCM_HEADER_SIZE		4

#define CMD_IDENTIFY		0x02
#define CMD_RESET		0x04
#define CMD_ENABLE_REPORT	0x05

#define STATUS_IDLE		0x00
#define STATUS_OK		0x01

#define REPORT_IDENTIFY		0x10
#define REPORT_TOUCH		0x11

/* From Google's board file: reset-active-ms, reset-delay-ms, power-delay-ms */
#define TOUCH_RESET_ACTIVE_MS	2
#define TOUCH_RESET_DELAY_MS	50
#define TOUCH_POWER_DELAY_MS	200

#define TOUCH_POLL_MS		16

/*
 * Google polls for a command response every CMD_RESPONSE_POLLING_DELAY_MS up
 * to CMD_RESPONSE_TIMEOUT_MS, and retries a header whose marker is wrong with
 * a 5-10 ms sleep between tries (synaptics_touchcom_core_v1.c). A single read
 * 20 ms after the command -- which is what this driver did first -- is simply
 * too early, and reported the part as silent when it was not.
 */
#define TOUCH_RESP_POLL_MS	10
#define TOUCH_RESP_TRIES	100

/*
 * The ATTN line, gpn0-0, active low. No pinctrl driver, so it is read
 * directly like the reset pad.
 *
 * The bank layout is from Google's own table (soc-gs,
 * drivers/pinctrl/gs/pinctrl-gs.c, zuma_pin_custom[]): 0x15060000 is
 * GPIO_CUSTOM_ALIVE, holding gpn0..gpn9, one pin each, 0x20 apart, gpn0
 * first. So CON is +0x00 and DAT +0x04, and gpn0's only pin is bit 0.
 *
 * This line has read 0 in every measurement in this port, including with a
 * pull-up enabled and read back as enabled -- and gpn3, in the same block,
 * reads 1, so the block and the reads are good. 0 is ambiguous: it is what
 * an asserted ATTN looks like, and also what an unpowered part clamping
 * through its ESD diodes looks like. It is logged, not trusted.
 */
#define ALIVE_BASE		0x15060000
#define ALIVE_SIZE		0x10
#define GPN0_DAT		0x04
#define GPN0_ATTN_PIN		0

/*
 * peric0's GPIO block, and gpp1 within it. Banks are 0x20 apart and gpp1 is
 * the second, so CON is +0x20 and DAT +0x24; each pin takes 4 bits of CON,
 * so pin 1 is bits [7:4], and 1 there means output. The touch reset is
 * active low (synaptics,reset-on-state = 0 in Google's board file).
 */
#define PERIC0_BASE		0x10840000
#define PERIC0_SIZE		0x40
#define GPP1_CON		0x20
#define GPP1_DAT		0x24
#define GPP1_RESET_PIN		1

struct zumapro_touch {
	struct spi_device *spi;
	struct input_dev *input;
	struct regulator *vdd;
	struct regulator *avdd;
	struct delayed_work poll;
	void __iomem *peric0;
	void __iomem *alive;
	u8 hdr[TCM_HEADER_SIZE];	/* last header read, for diagnostics */
	u8 rxbuf[512];
	u8 txfill[512];		/* all 0xff; see zumapro_touch_spi_read() */
};

static void zumapro_touch_reset(struct zumapro_touch *ts)
{
	u32 con, dat;

	if (!ts->peric0)
		return;

	con = readl(ts->peric0 + GPP1_CON);
	con &= ~(0xfu << (GPP1_RESET_PIN * 4));
	con |= 0x1u << (GPP1_RESET_PIN * 4);		/* output */
	writel(con, ts->peric0 + GPP1_CON);

	dat = readl(ts->peric0 + GPP1_DAT);
	writel(dat & ~BIT(GPP1_RESET_PIN), ts->peric0 + GPP1_DAT);
	msleep(TOUCH_RESET_ACTIVE_MS);
	writel(dat | BIT(GPP1_RESET_PIN), ts->peric0 + GPP1_DAT);
	msleep(TOUCH_RESET_DELAY_MS);
}

static int zumapro_touch_cmd(struct zumapro_touch *ts, u8 cmd,
			     const u8 *payload, u16 len)
{
	u8 buf[8];

	if (len + 3 > sizeof(buf))
		return -EINVAL;

	buf[0] = cmd;
	buf[1] = len & 0xff;
	buf[2] = (len >> 8) & 0xff;
	if (len)
		memcpy(&buf[3], payload, len);

	return spi_write(ts->spi, buf, len + 3);
}

/*
 * Clock bytes in while holding MOSI high.
 *
 * This is not spi_read(). spi_read() sends zeroes, and on TouchComm a byte on
 * MOSI is a command byte -- so reading with it feeds the device a stream of
 * 0x00 and walks the message framing off its boundaries. The first log from
 * this driver showed exactly that: 0xa5 markers and a 0x10 REPORT_IDENTIFY
 * appearing *inside* what had been read as payload. Google's platform layer
 * fills its TX buffer with 0xff for every read (syna_tcm2_platform_spi.c),
 * and so does this.
 */
static int zumapro_touch_spi_read(struct zumapro_touch *ts, u8 *buf, size_t len)
{
	struct spi_transfer xfer = {
		.tx_buf = ts->txfill,
		.rx_buf = buf,
		.len = len,
	};
	struct spi_message msg;

	if (len > sizeof(ts->txfill))
		return -EINVAL;

	spi_message_init(&msg);
	spi_message_add_tail(&xfer, &msg);

	return spi_sync(ts->spi, &msg);
}

/*
 * Read one message. Returns the payload length, or negative.
 *
 * An idle TouchComm bus reads as all 0xff, so a header of ff ff ff ff is
 * "nothing to say" rather than a message of 65535 bytes -- taking that length
 * at face value is what produced 512-byte dumps of filler. Both that and a
 * missing marker are reported as -ENOMSG, which the poll loop ignores
 * silently; anything else would flood a receive-only UART every 16 ms.
 */
static int zumapro_touch_read(struct zumapro_touch *ts, u8 *code)
{
	u8 *hdr = ts->hdr;
	int ret, len;

	ret = zumapro_touch_spi_read(ts, hdr, TCM_HEADER_SIZE);
	if (ret)
		return ret;

	if (hdr[0] != TCM_MARKER)
		return -ENOMSG;

	*code = hdr[1];
	len = hdr[2] | (hdr[3] << 8);

	/* Filler, or a length this driver has no buffer for: resynchronise. */
	if (len > sizeof(ts->rxbuf))
		return -ENOMSG;

	if (len) {
		ret = zumapro_touch_spi_read(ts, ts->rxbuf, len);
		if (ret)
			return ret;
	}

	return len;
}

/* Raw gpn0 DAT, or ~0 when the block is not mapped. */
static u32 zumapro_touch_attn_dat(struct zumapro_touch *ts)
{
	return ts->alive ? readl(ts->alive + GPN0_DAT) : ~0u;
}

/* True when the part has a message waiting. Assume yes if unmapped. */
static bool zumapro_touch_attn(struct zumapro_touch *ts)
{
	if (!ts->alive)
		return true;

	return !(zumapro_touch_attn_dat(ts) & BIT(GPN0_ATTN_PIN));
}

/*
 * Wait for a message, retrying as Google's core does rather than reading once
 * and declaring the part silent.
 */
static int zumapro_touch_read_wait(struct zumapro_touch *ts, u8 *code)
{
	int ret, i;

	for (i = 0; i < TOUCH_RESP_TRIES; i++) {
		ret = zumapro_touch_read(ts, code);
		if (ret != -ENOMSG)
			return ret;

		/*
		 * Show the bytes, not just -ENOMSG. All 0x00 is MISO held low,
		 * which is what an unpowered part does; all 0xff is an idle
		 * bus and a part that is powered but not answering. That
		 * distinction decides where to look next, and the previous
		 * version of this loop threw it away.
		 */
		if (i < 3 || i == TOUCH_RESP_TRIES - 1)
			dev_err(&ts->spi->dev,
				"try %d: hdr %*ph, gpn0 0x%08x\n", i,
				TCM_HEADER_SIZE, ts->hdr,
				zumapro_touch_attn_dat(ts));

		msleep(TOUCH_RESP_POLL_MS);
	}

	return -ETIMEDOUT;
}

static void zumapro_touch_poll(struct work_struct *work)
{
	struct zumapro_touch *ts =
		container_of(work, struct zumapro_touch, poll.work);
	u8 code = 0;
	int len;

	if (!zumapro_touch_attn(ts))
		goto again;

	len = zumapro_touch_read(ts, &code);
	if (len >= 0) {
		/*
		 * KERN_ERR: the only output from this phone is a receive-only
		 * UART, and anything under the console loglevel is never seen.
		 * This is loud on purpose and should become an input event
		 * once the report layout has been read off real data.
		 */
		dev_err(&ts->spi->dev, "report 0x%02x, %d bytes: %*ph\n",
			code, len, min(len, 16), ts->rxbuf);
	}

again:
	schedule_delayed_work(&ts->poll, msecs_to_jiffies(TOUCH_POLL_MS));
}

static int zumapro_touch_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	struct zumapro_touch *ts;
	u8 code = 0;
	int ret, len;

	ts = devm_kzalloc(dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	ts->spi = spi;
	spi_set_drvdata(spi, ts);
	memset(ts->txfill, 0xff, sizeof(ts->txfill));

	ts->vdd = devm_regulator_get(dev, "vdd");
	if (IS_ERR(ts->vdd))
		return dev_err_probe(dev, PTR_ERR(ts->vdd), "no vdd\n");

	ts->avdd = devm_regulator_get(dev, "avdd");
	if (IS_ERR(ts->avdd))
		return dev_err_probe(dev, PTR_ERR(ts->avdd), "no avdd\n");

	/* See the comment at the top: no pinctrl, so drive the pads directly. */
	ts->peric0 = devm_ioremap(dev, PERIC0_BASE, PERIC0_SIZE);
	if (!ts->peric0)
		dev_err(dev, "no peric0 mapping; reset will not be driven\n");

	ts->alive = devm_ioremap(dev, ALIVE_BASE, ALIVE_SIZE);
	if (!ts->alive)
		dev_err(dev, "no alive mapping; polling without ATTN\n");

	/*
	 * Sample the interrupt line before anything is powered. If it reads
	 * the same here as it does with both rails up and the part out of
	 * reset, the line is telling us nothing and the driver should stop
	 * treating it as evidence either way.
	 */
	dev_err(dev, "gpn0 before power: 0x%08x\n", zumapro_touch_attn_dat(ts));

	ret = regulator_enable(ts->vdd);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable vdd\n");

	ret = regulator_enable(ts->avdd);
	if (ret) {
		regulator_disable(ts->vdd);
		return dev_err_probe(dev, ret, "cannot enable avdd\n");
	}

	msleep(TOUCH_POWER_DELAY_MS);
	dev_err(dev, "rails on: vdd %d uV, avdd %d uV, gpn0 0x%08x\n",
		regulator_get_voltage(ts->vdd), regulator_get_voltage(ts->avdd),
		zumapro_touch_attn_dat(ts));

	zumapro_touch_reset(ts);

	if (ts->peric0)
		dev_err(dev, "after reset: gpp1 CON 0x%08x DAT 0x%08x, gpn0 0x%08x\n",
			readl(ts->peric0 + GPP1_CON),
			readl(ts->peric0 + GPP1_DAT),
			zumapro_touch_attn_dat(ts));

	ret = zumapro_touch_cmd(ts, CMD_IDENTIFY, NULL, 0);
	if (ret) {
		dev_err(dev, "IDENTIFY write failed: %d\n", ret);
		goto err;
	}

	len = zumapro_touch_read_wait(ts, &code);
	if (len < 0)
		/*
		 * Not fatal. The bus and the rails are known good, so keep the
		 * poll loop running and report what does arrive -- failing the
		 * probe here would take the only instrument off the device.
		 */
		dev_err(dev, "no answer to IDENTIFY (%d); polling anyway\n",
			len);
	else
		dev_err(dev, "IDENTIFY -> code 0x%02x, %d bytes: %*ph\n",
			code, len, min(len, 24), ts->rxbuf);

	ts->input = devm_input_allocate_device(dev);
	if (!ts->input) {
		ret = -ENOMEM;
		goto err;
	}

	ts->input->name = "Synaptics TouchComm";
	ts->input->id.bustype = BUS_SPI;
	input_set_abs_params(ts->input, ABS_MT_POSITION_X, 0, 1079, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_POSITION_Y, 0, 2423, 0, 0);
	ret = input_mt_init_slots(ts->input, 10, INPUT_MT_DIRECT);
	if (ret)
		goto err;

	ret = input_register_device(ts->input);
	if (ret)
		goto err;

	INIT_DELAYED_WORK(&ts->poll, zumapro_touch_poll);
	schedule_delayed_work(&ts->poll, msecs_to_jiffies(TOUCH_POLL_MS));

	return 0;

err:
	regulator_disable(ts->avdd);
	regulator_disable(ts->vdd);
	return ret;
}

static void zumapro_touch_remove(struct spi_device *spi)
{
	struct zumapro_touch *ts = spi_get_drvdata(spi);

	cancel_delayed_work_sync(&ts->poll);
	regulator_disable(ts->avdd);
	regulator_disable(ts->vdd);
}

static const struct of_device_id zumapro_touch_of_match[] = {
	{ .compatible = "google,zumapro-tcm-spi" },
	{ }
};
MODULE_DEVICE_TABLE(of, zumapro_touch_of_match);

static struct spi_driver zumapro_touch_driver = {
	.driver = {
		.name = "zumapro-touch",
		.of_match_table = zumapro_touch_of_match,
	},
	.probe = zumapro_touch_probe,
	.remove = zumapro_touch_remove,
};
module_spi_driver(zumapro_touch_driver);

MODULE_DESCRIPTION("Synaptics TouchComm v1 over SPI for Tensor G4");
MODULE_LICENSE("GPL");

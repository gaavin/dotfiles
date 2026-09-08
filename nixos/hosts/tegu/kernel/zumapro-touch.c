// SPDX-License-Identifier: GPL-2.0-only
/*
 * Synaptics TouchComm v1 over SPI for the Pixel 9a (tegu).
 *
 * Mainline has no TouchComm driver in any form -- only RMI4, a different
 * protocol -- and Google's is a large out-of-tree module. This is written
 * against their protocol sources (google-modules/touch/synaptics_touch,
 * branch android-gs-tegu-6.1-android16):
 *
 *   command  [ cmd, len_lo, len_hi, payload... ]
 *   message  [ 0xa5, code, len_lo, len_hi ] followed by len payload bytes
 *
 * 0xa5 is TCM_V1_MESSAGE_MARKER. The part on this board identifies itself as
 * a Synaptics S3908 running application firmware:
 *
 *   a5 10 18 00 01 01 53 33 39 30 38 47 41 31 42 30 ...
 *   |  |  |____| |  |  |____________________________
 *   |  |  len 24 |  mode 1 = application firmware   part number "S3908GA1B0"
 *   |  REPORT_IDENTIFY                              (ASCII)
 *   marker
 *
 * WHAT MADE IT TALK
 *
 * Chip select. Mainline hardcodes S3C64XX_SPI_QUIRK_CS_AUTO for
 * google,gs101-spi, so nSS is timed by the hardware and no device can ask
 * for anything else; Google's own spi-s3c64xx reads
 * samsung,spi-chip-select-mode per slave, and tegu's touch node sets 0,
 * which is MANUAL_CS_MODE. Under hardware-timed chip select this part
 * answered with one byte and then a line rising to its pull-up, which looks
 * convincingly like a device that has stopped talking. kernel/spi-manual-cs.py
 * drops the quirk; do not put it back.
 *
 * A whole message arrives in a single chip-select assertion, so this reads
 * header and payload in one transfer rather than doing the vendor's chunked
 * continued-read dance -- that exists for parts with a small max_read_size,
 * and re-reading here would restart the message instead of continuing it.
 *
 * PINS
 *
 * Reset (gpp1-1) and ATTN (gpn0-0) are ordinary GPIOs now that this port has
 * pin-controller data (kernel/zuma-pinctrl-data.c). Both used to be poked
 * through ioremap because there was no pinctrl driver at all; that could
 * drive a pad but never supply an interrupt.
 *
 * The driver still polls the ATTN level rather than taking its interrupt.
 * That is deliberate for now: the line is level triggered and stays asserted
 * until the message is drained, so an interrupt handler that fails to drain
 * one would storm, and the read path is too young to bet the machine on.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/io.h>
#include <linux/ktime.h>
#include <linux/hex.h>
#include <linux/kernel.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>
#include <linux/spi/spi.h>
#include <linux/workqueue.h>
#include <linux/unaligned.h>

#define TCM_MARKER		0xa5
#define TCM_HEADER_SIZE		4

#define STATUS_IDLE		0x00
#define STATUS_OK		0x01
#define STATUS_CONTINUED_READ	0x03

#define CMD_IDENTIFY		0x02
#define CMD_RESET		0x04
#define CMD_ENABLE_REPORT	0x05
#define CMD_TCM2_ACK		0x07	/* Google's detect magic; a no-op on v1 */
#define CMD_GET_APPLICATION_INFO 0x20
#define CMD_GET_TOUCH_REPORT_CONFIG 0x25

#define REPORT_IDENTIFY		0x10
#define REPORT_TOUCH		0x11

/*
 * Touch report configuration opcodes, from synaptics_touchcom_func_touch.h.
 * The config is a byte stream: control codes on their own, entity codes
 * followed by a bit width. Walking it against the report bitstream is the
 * whole decoder -- the layout is the part's to define, not ours to assume.
 */
#define TR_END			0x00
#define TR_FOREACH_ACTIVE	0x01
#define TR_FOREACH_ALL		0x02
#define TR_FOREACH_END		0x03
#define TR_PAD_TO_BYTE		0x04
#define TR_TIMESTAMP		0x05
#define TR_OBJ_INDEX		0x06
#define TR_OBJ_CLASS		0x07
#define TR_OBJ_X		0x08
#define TR_OBJ_Y		0x09
#define TR_OBJ_Z		0x0a
#define TR_OBJ_X_WIDTH		0x0b
#define TR_OBJ_Y_WIDTH		0x0c
#define TR_NUM_ACTIVE		0x18

/* Object classification: synaptics_touchcom_func_touch.h. */
#define OBJ_LIFT		0
#define OBJ_FINGER		1

/* From Google's board file: reset-active-ms, reset-delay-ms, power-delay-ms */
#define TOUCH_RESET_ACTIVE_MS	2
#define TOUCH_RESET_DELAY_MS	50
#define TOUCH_POWER_DELAY_MS	200

#define TOUCH_POLL_MS		16

/*
 * How long to wait for the part after reset. Google's reset-delay-ms of 50 is
 * not enough on its own: measured here, reads return 0x00 -- the part driving
 * MISO low while it boots -- for well past that. Rather than pick a bigger
 * magic number, poll until it produces a real marker.
 */
#define TOUCH_BOOT_TRIES	100
#define TOUCH_BOOT_POLL_MS	10

/* Command responses: the vendor polls every 10 ms up to 3 s. */
#define TOUCH_RESP_POLL_MS	10
#define TOUCH_RESP_TRIES	100

/*
 * The largest single read: a continued read is two header bytes, the payload
 * and one end-of-message byte. Every buffer involved has to be at least that
 * big -- sizing txfill for the payload alone made spi_read() reject transfers
 * with -EINVAL before they reached the bus.
 *
 * 256 payload bytes covers everything this part sends: identify is 24, the
 * application info 32, the report config a few dozen, a touch report under a
 * hundred.
 */
#define TCM_PAYLOAD_MAX		256
#define TCM_READ_MAX		(TCM_PAYLOAD_MAX + 4)
#define TCM_CONFIG_MAX		128
#define TCM_MAX_OBJECTS		10

/*
 * Offsets into struct tcm_application_info. Eight u16 fields, then
 * customer_config_id[MAX_SIZE_CONFIG_ID] -- and that constant is 16, not the
 * 10 this driver first assumed, which put max_x six bytes early, inside the
 * config id. Wrong offsets here do not fail loudly; they yield screen bounds
 * that look like plausible numbers.
 */
#define APP_INFO_MAX_X		32
#define APP_INFO_MAX_Y		34
#define APP_INFO_MAX_OBJECTS	36

/* The SPI controller's own registers, mapped read-only for diagnostics. */
#define SPI_BASE		0x111d0000
#define SPI_SIZE		0x30
#define SPI_CH_CFG		0x00
#define SPI_MODE_CFG		0x08
#define SPI_CS_REG		0x0c
#define SPI_SWAP_CFG		0x28
#define SPI_FB_CLK		0x2c

struct zumapro_touch {
	struct spi_device *spi;
	struct input_dev *input;
	struct regulator *vdd;
	struct regulator *avdd;
	struct delayed_work poll;
	struct gpio_desc *reset;
	struct gpio_desc *attn;
	void __iomem *spiregs;

	u8 hdr[TCM_HEADER_SIZE];	/* last header read, for diagnostics */
	unsigned int rxlen;		/* bytes the last sysfs read returned */
	u32 speed_hz;			/* 0 = the device's own maximum */
	bool polling;

	/* What the part told us about itself. */
	u8 config[TCM_CONFIG_MAX];
	unsigned int config_len;
	unsigned int max_objects;
	unsigned int max_x;
	unsigned int max_y;

	u8 msgbuf[TCM_READ_MAX];	/* one whole message, header included */
	u8 rxbuf[TCM_PAYLOAD_MAX];	/* its payload, and sysfs reads */
	u8 txfill[TCM_READ_MAX];	/* all 0xff; see zumapro_touch_spi_read() */
};

static void zumapro_touch_reset(struct zumapro_touch *ts)
{
	if (!ts->reset)
		return;

	gpiod_set_value_cansleep(ts->reset, 1);		/* active low in DT */
	msleep(TOUCH_RESET_ACTIVE_MS);
	gpiod_set_value_cansleep(ts->reset, 0);
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
 * 0x00 and walks the message framing off its boundaries. Google's platform
 * layer fills its TX buffer with 0xff for every read, and so does this.
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
 * Read one whole message. Returns the payload length, with the payload at
 * ts->rxbuf, or negative.
 *
 * Read the header, then exactly the payload, and not one byte more.
 *
 * Over-reading is not free on this bus. Every MOSI byte is a command byte to
 * a TouchComm part, and a read holds MOSI high, so clocking past the end of a
 * message feeds the device a run of 0xff commands. An earlier version of this
 * function read a fixed 260-byte block to get header and payload in one chip
 * select; it retrieved the identify report exactly once and then left the
 * part answering STATUS_IDLE to every command that followed.
 *
 * The second read is a continued read, which is what STATUS_CONTINUED_READ
 * exists for: marker, that status, the payload, then an end-of-message 0x5a
 * (syna_tcm_v1_continued_read()).
 */
static int zumapro_touch_read(struct zumapro_touch *ts, u8 *code)
{
	u8 *buf = ts->msgbuf;
	int ret, len;

	ret = zumapro_touch_spi_read(ts, ts->hdr, TCM_HEADER_SIZE);
	if (ret)
		return ret;

	if (ts->hdr[0] != TCM_MARKER)
		return -ENOMSG;

	*code = ts->hdr[1];
	len = ts->hdr[2] | (ts->hdr[3] << 8);

	/* Filler, or a length this driver has no buffer for: resynchronise. */
	if (len > TCM_PAYLOAD_MAX)
		return -ENOMSG;

	if (!len)
		return 0;

	ret = zumapro_touch_spi_read(ts, buf, len + 3);
	if (ret)
		return ret;

	if (buf[0] != TCM_MARKER || buf[1] != STATUS_CONTINUED_READ)
		return -ENOMSG;

	memcpy(ts->rxbuf, buf + 2, len);

	return len;
}

/*
 * True when the part has a message waiting.
 *
 * The line is active low and the DT says so, so gpiod returns 1 when it is
 * asserted. Assume a message is waiting if there is no GPIO, which keeps the
 * driver working on a tree without pinctrl rather than going silent.
 */
static bool zumapro_touch_attn(struct zumapro_touch *ts)
{
	if (!ts->attn)
		return true;

	return gpiod_get_value_cansleep(ts->attn) == 1;
}

/*
 * Wait for the part to raise ATTN, then read one message.
 *
 * Never read speculatively. A read holds MOSI high and this part treats every
 * MOSI byte as a command byte, so polling a silent device feeds it a stream of
 * 0xff commands -- and enough of those wedge it into answering nothing at all.
 * That is what a hundred blind four-byte retries did here: the boot where the
 * identify arrived on the first read worked, and every boot that had to retry
 * ended with the part mute and MISO low.
 *
 * ATTN is the interrupt Google's driver reads on. It idles high and asserts
 * while a message is waiting, so it says exactly when a read is free.
 */
static int zumapro_touch_read_attn(struct zumapro_touch *ts, u8 *code,
				   unsigned int tries)
{
	unsigned int i;

	for (i = 0; i < tries; i++) {
		if (zumapro_touch_attn(ts))
			return zumapro_touch_read(ts, code);

		msleep(TOUCH_RESP_POLL_MS);
	}

	return -ETIMEDOUT;
}

/*
 * Send a command and collect its response. Reports the part volunteers while
 * we wait are logged and skipped -- an identify report turns up after every
 * reset and is not an answer to whatever was just asked.
 */
static int zumapro_touch_request(struct zumapro_touch *ts, u8 cmd,
				 const u8 *payload, u16 plen)
{
	struct device *dev = &ts->spi->dev;
	u8 code = 0;
	int ret, i;

	ret = zumapro_touch_cmd(ts, cmd, payload, plen);
	if (ret)
		return ret;

	for (i = 0; i < TOUCH_RESP_TRIES; i++) {
		ret = zumapro_touch_read_attn(ts, &code, 1);
		if (ret >= 0) {
			if (code == STATUS_OK)
				return ret;

			if (code != STATUS_IDLE)
				dev_dbg(dev, "cmd 0x%02x: skipping report 0x%02x\n",
					cmd, code);
		}

		msleep(TOUCH_RESP_POLL_MS);
	}

	dev_err(dev, "cmd 0x%02x: no response (last code 0x%02x)\n", cmd, code);
	return -ETIMEDOUT;
}

/*
 * Extract a big-endian-by-byte, LSB-first-within-byte field, exactly as
 * syna_tcm_get_touch_data() does. Getting this wrong silently yields
 * plausible-looking coordinates, so it follows the vendor bit for bit.
 */
static u32 zumapro_touch_bits(const u8 *buf, size_t len, unsigned int offset,
			      unsigned int bits)
{
	unsigned int remaining = bits;
	unsigned int bit_off = offset % 8;
	unsigned int byte_off = offset / 8;
	u32 out = 0;

	if (!bits || bits > 32 || offset + bits > len * 8)
		return 0;

	while (remaining) {
		unsigned int avail = 8 - bit_off;
		unsigned int take = min(avail, remaining);
		u8 b = buf[byte_off] >> bit_off;

		b &= 0xff >> (8 - take);
		out |= (u32)b << (bits - remaining);

		bit_off = 0;
		byte_off++;
		remaining -= take;
	}

	return out;
}

struct zumapro_touch_obj {
	u8 status;
	u32 x, y, z;
};

/*
 * Walk the report config against the report and emit multitouch events.
 * Mirrors syna_tcm_parse_touch_report()'s control flow.
 */
static void zumapro_touch_report(struct zumapro_touch *ts, const u8 *report,
				 unsigned int report_len)
{
	struct zumapro_touch_obj objs[TCM_MAX_OBJECTS] = { };
	unsigned int active_objects = 0, objects = 0;
	unsigned int idx = 0, offset = 0, obj = 0, next = 0;
	unsigned int end_of_foreach = 0;
	bool have_active_count = false;
	bool active_only = false;
	unsigned int i, reported = 0;

	while (idx < ts->config_len) {
		u8 code = ts->config[idx++];
		unsigned int bits;
		u32 data;

		if (code == TR_END)
			break;

		switch (code) {
		case TR_FOREACH_ACTIVE:
			obj = 0;
			next = idx;
			active_only = true;
			continue;
		case TR_FOREACH_ALL:
			obj = 0;
			next = idx;
			active_only = false;
			continue;
		case TR_FOREACH_END:
			end_of_foreach = idx;
			if (active_only) {
				if (have_active_count) {
					objects++;
					obj++;
					if (objects < active_objects)
						idx = next;
				} else if (offset < report_len * 8) {
					obj++;
					idx = next;
				}
			} else {
				obj++;
				if (obj < ts->max_objects)
					idx = next;
			}
			continue;
		case TR_PAD_TO_BYTE:
			offset = ALIGN(offset, 8);
			continue;
		}

		/* Everything else is an entity: one byte of width follows. */
		if (idx >= ts->config_len)
			break;

		bits = ts->config[idx++];
		data = zumapro_touch_bits(report, report_len, offset, bits);
		offset += bits;

		if (obj >= TCM_MAX_OBJECTS)
			continue;

		switch (code) {
		case TR_OBJ_INDEX:
			obj = data;
			break;
		case TR_OBJ_CLASS:
			objs[obj].status = data;
			break;
		case TR_OBJ_X:
			objs[obj].x = data;
			break;
		case TR_OBJ_Y:
			objs[obj].y = data;
			break;
		case TR_OBJ_Z:
			objs[obj].z = data;
			break;
		case TR_NUM_ACTIVE:
			active_objects = data;
			have_active_count = true;
			if (!active_objects && end_of_foreach)
				idx = end_of_foreach;
			break;
		default:
			break;
		}
	}

	for (i = 0; i < ts->max_objects && i < TCM_MAX_OBJECTS; i++) {
		bool down = objs[i].status != OBJ_LIFT;

		input_mt_slot(ts->input, i);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, down);
		if (!down)
			continue;

		reported++;
		input_report_abs(ts->input, ABS_MT_POSITION_X, objs[i].x);
		input_report_abs(ts->input, ABS_MT_POSITION_Y, objs[i].y);
		if (objs[i].z)
			input_report_abs(ts->input, ABS_MT_PRESSURE, objs[i].z);
	}

	input_mt_sync_frame(ts->input);
	input_sync(ts->input);

	dev_dbg(&ts->spi->dev, "touch: %u object(s) down\n", reported);
}

/*
 * A runtime interface for talking to this part, because a kernel change here
 * costs an eleven-minute flash of an 11 GB rootfs -- any change to the kernel
 * moves the closure, so init= moves with it and the rootfs has to match.
 * Hard-coding one experiment per build is the wrong trade at that price.
 *
 * Everything below is driven from userspace over the command channel:
 *
 *	echo 'r 32'        > .../tcm_xfer   read 32 bytes, MOSI high
 *	echo 'w 07'        > .../tcm_xfer   write raw bytes, one chip select
 *	echo 'wr 07 4'     > .../tcm_xfer   write, then read: separate selects
 *	echo 'x 07 4'      > .../tcm_xfer   write and read in ONE message
 *	echo 'reset'       > .../tcm_xfer   pulse the reset pad
 *	echo 'mode 0'      > .../tcm_xfer   set SPI mode, 0-3
 *	echo 'hz 6000000'  > .../tcm_xfer   set speed for later transfers
 *	echo 'poll 0'      > .../tcm_xfer   silence the report poller
 *	echo 't 02 00 00'  > .../tcm_xfer   full duplex: send those, capture MISO
 *	echo 'regs'        > .../tcm_xfer   dump the controller's registers
 *	cat  .../tcm_xfer                   the bytes the last read returned
 *
 * Every transfer logs how long it took. That distinguishes the two things a
 * buffer of 0xff cannot: a device that stopped driving MISO, and a
 * controller that stopped clocking. At 390 kHz a 256-byte read must take
 * about 5 ms, and anything much shorter means the clock stopped early.
 *
 * "t" matters because a plain "w" throws MISO away, so anything the part
 * says while a command is being written has been invisible until now.
 *
 * "x" is the interesting one. The SPI core is meant to hold chip select
 * across the transfers of a single message, but this controller runs with
 * S3C64XX_SPI_QUIRK_CS_AUTO, where the hardware drives nSS from PACKET_CNT
 * per transfer. A split read measured that directly:
 *
 *	split 4+12: a5 18 ff ff | a5 18 ff ff ff ff ff ff ff ff ff ff
 *
 * The second transfer restarted the device's message, so chip select really
 * does drop between transfers of one message here.
 */
#define TCM_XFER_MAX		TCM_PAYLOAD_MAX

static int zumapro_touch_parse_hex(const char *p, u8 *out, size_t max,
				   const char **end)
{
	unsigned int n = 0;
	int v;

	while (*p == ' ')
		p++;

	while (n < max) {
		v = hex_to_bin(p[0]);
		if (v < 0)
			break;

		/*
		 * A lone digit is the trailing read count, not a malformed
		 * byte -- "wr 02 00 00 4" ends in one. Returning -EINVAL here
		 * is what made every wr/x command fail on the first run.
		 */
		if (hex_to_bin(p[1]) < 0)
			break;

		out[n++] = (v << 4) | hex_to_bin(p[1]);
		p += 2;

		while (*p == ' ')
			p++;
	}

	*end = p;
	return n;
}

/*
 * spi_sync(), timed. A read that returns all 0xff looks the same whether the
 * part went quiet or the controller stopped clocking; the elapsed time tells
 * them apart, because the clock cannot stop early and still take as long as
 * the bit count demands.
 */
static int zumapro_touch_timed_sync(struct zumapro_touch *ts,
				    struct spi_message *msg, const char *tag)
{
	ktime_t t0 = ktime_get();
	int ret;

	ret = spi_sync(ts->spi, msg);

	dev_err(&ts->spi->dev, "%s: %lld us, ret %d\n", tag,
		ktime_us_delta(ktime_get(), t0), ret);

	return ret;
}

static ssize_t tcm_xfer_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	struct zumapro_touch *ts = spi_get_drvdata(to_spi_device(dev));
	struct spi_transfer xfer[2] = { };
	u8 tx[TCM_XFER_MAX];
	struct spi_message msg;
	const char *p = buf;
	unsigned int val;
	int n, ret;

	if (sysfs_streq(buf, "reset")) {
		zumapro_touch_reset(ts);
		return count;
	}

	if (sscanf(buf, "mode %u", &val) == 1) {
		if (val > 3)
			return -EINVAL;

		ts->spi->mode = (ts->spi->mode & ~(SPI_CPOL | SPI_CPHA)) | val;
		ret = spi_setup(ts->spi);
		return ret ? ret : count;
	}

	if (sscanf(buf, "hz %u", &val) == 1) {
		ts->speed_hz = val;
		return count;
	}

	if (sscanf(buf, "poll %u", &val) == 1) {
		ts->polling = !!val;
		if (ts->polling)
			schedule_delayed_work(&ts->poll, 0);
		else
			cancel_delayed_work(&ts->poll);
		return count;
	}

	if (sysfs_streq(buf, "regs")) {
		if (!ts->spiregs)
			return -ENODEV;

		dev_err(dev, "ch_cfg %08x clk_cfg %08x mode_cfg %08x cs %08x int %08x status %08x pkt %08x swap %08x fb %08x\n",
			readl(ts->spiregs + 0x00), readl(ts->spiregs + 0x04),
			readl(ts->spiregs + SPI_MODE_CFG),
			readl(ts->spiregs + SPI_CS_REG),
			readl(ts->spiregs + 0x10), readl(ts->spiregs + 0x14),
			readl(ts->spiregs + 0x20),
			readl(ts->spiregs + SPI_SWAP_CFG),
			readl(ts->spiregs + SPI_FB_CLK));
		return count;
	}

	spi_message_init(&msg);
	ts->rxlen = 0;

	/* Full duplex: send the given bytes and keep what comes back. */
	if (!strncmp(p, "t ", 2)) {
		n = zumapro_touch_parse_hex(p + 2, tx, sizeof(tx), &p);
		if (n <= 0)
			return -EINVAL;

		xfer[0].tx_buf = tx;
		xfer[0].rx_buf = ts->rxbuf;
		xfer[0].len = n;
		xfer[0].speed_hz = ts->speed_hz;
		spi_message_add_tail(&xfer[0], &msg);
		ts->rxlen = n;

		ret = zumapro_touch_timed_sync(ts, &msg, "t");
		return ret ? ret : count;
	}

	if (!strncmp(p, "r ", 2)) {
		if (kstrtouint(p + 2, 0, &val) || !val || val > TCM_XFER_MAX)
			return -EINVAL;

		memset(tx, 0xff, val);
		xfer[0].tx_buf = tx;
		xfer[0].rx_buf = ts->rxbuf;
		xfer[0].len = val;
		xfer[0].speed_hz = ts->speed_hz;
		spi_message_add_tail(&xfer[0], &msg);
		ts->rxlen = val;

		ret = zumapro_touch_timed_sync(ts, &msg, "r");
		return ret ? ret : count;
	}

	if (!strncmp(p, "w ", 2) || !strncmp(p, "wr ", 3) ||
	    !strncmp(p, "x ", 2)) {
		bool split = (p[0] == 'w' && p[1] == 'r');
		bool one_cs = (p[0] == 'x');

		p += split ? 3 : 2;

		n = zumapro_touch_parse_hex(p, tx, sizeof(tx), &p);
		if (n <= 0)
			return -EINVAL;

		xfer[0].tx_buf = tx;
		xfer[0].len = n;
		xfer[0].speed_hz = ts->speed_hz;

		/* Plain "w": write and stop. */
		if (!split && !one_cs) {
			spi_message_add_tail(&xfer[0], &msg);
			ret = spi_sync(ts->spi, &msg);
			return ret ? ret : count;
		}

		if (kstrtouint(p, 0, &val) || !val || val > TCM_XFER_MAX)
			return -EINVAL;

		memset(ts->txfill, 0xff, val);
		xfer[1].tx_buf = ts->txfill;
		xfer[1].rx_buf = ts->rxbuf;
		xfer[1].len = val;
		xfer[1].speed_hz = ts->speed_hz;
		ts->rxlen = val;

		if (one_cs) {
			/* Both transfers in one message. */
			spi_message_add_tail(&xfer[0], &msg);
			spi_message_add_tail(&xfer[1], &msg);
			ret = spi_sync(ts->spi, &msg);
			return ret ? ret : count;
		}

		/* Separate messages, so separate chip selects. */
		spi_message_add_tail(&xfer[0], &msg);
		ret = spi_sync(ts->spi, &msg);
		if (ret)
			return ret;

		spi_message_init(&msg);
		spi_message_add_tail(&xfer[1], &msg);
		ret = spi_sync(ts->spi, &msg);
		return ret ? ret : count;
	}

	return -EINVAL;
}

static ssize_t tcm_xfer_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	struct zumapro_touch *ts = spi_get_drvdata(to_spi_device(dev));

	if (!ts->rxlen)
		return sysfs_emit(buf, "\n");

	return sysfs_emit(buf, "%*ph\n", (int)min_t(unsigned int, ts->rxlen, 64),
			  ts->rxbuf);
}

static DEVICE_ATTR_RW(tcm_xfer);

static struct attribute *zumapro_touch_attrs[] = {
	&dev_attr_tcm_xfer.attr,
	NULL,
};
ATTRIBUTE_GROUPS(zumapro_touch);

static void zumapro_touch_poll(struct work_struct *work)
{
	struct zumapro_touch *ts =
		container_of(work, struct zumapro_touch, poll.work);
	u8 code = 0;
	int len;

	if (!ts->polling)
		return;

	/*
	 * Only touch the bus when the part says it has something. ATTN is
	 * trustworthy now: it idles high and asserts while a message waits.
	 */
	if (!zumapro_touch_attn(ts))
		goto again;

	len = zumapro_touch_read(ts, &code);
	if (len < 0)
		goto again;

	if (code == REPORT_TOUCH && ts->config_len)
		zumapro_touch_report(ts, ts->rxbuf, len);
	else if (code != STATUS_IDLE)
		dev_dbg(&ts->spi->dev, "report 0x%02x, %d bytes: %*ph\n",
			code, len, min(len, 16), ts->rxbuf);

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

	ts->reset = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_HIGH);	/* logical 1 = asserted; held until the pulse below */
	if (IS_ERR(ts->reset))
		return dev_err_probe(dev, PTR_ERR(ts->reset), "reset gpio\n");
	if (!ts->reset)
		dev_err(dev, "no reset gpio; the part will not be reset\n");

	ts->attn = devm_gpiod_get_optional(dev, "attn", GPIOD_IN);
	if (IS_ERR(ts->attn))
		return dev_err_probe(dev, PTR_ERR(ts->attn), "attn gpio\n");

	ts->spiregs = devm_ioremap(dev, SPI_BASE, SPI_SIZE);
	if (ts->spiregs)
		dev_err(dev, "spi: ch_cfg 0x%08x mode_cfg 0x%08x cs 0x%08x swap 0x%08x fb %u\n",
			readl(ts->spiregs + SPI_CH_CFG),
			readl(ts->spiregs + SPI_MODE_CFG),
			readl(ts->spiregs + SPI_CS_REG),
			readl(ts->spiregs + SPI_SWAP_CFG),
			readl(ts->spiregs + SPI_FB_CLK));

	dev_info(dev, "attn before power: %s\n",
		 zumapro_touch_attn(ts) ? "asserted" : "idle");

	ret = regulator_enable(ts->vdd);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable vdd\n");

	ret = regulator_enable(ts->avdd);
	if (ret) {
		regulator_disable(ts->vdd);
		return dev_err_probe(dev, ret, "cannot enable avdd\n");
	}

	msleep(TOUCH_POWER_DELAY_MS);
	dev_info(dev, "rails on: vdd %d uV, avdd %d uV, attn %s\n",
		 regulator_get_voltage(ts->vdd), regulator_get_voltage(ts->avdd),
		 zumapro_touch_attn(ts) ? "asserted" : "idle");

	zumapro_touch_reset(ts);

	/*
	 * A TouchComm part queues a REPORT_IDENTIFY of its own after reset, so
	 * wait for that rather than for a fixed delay -- reset-delay-ms of 50
	 * is measurably not long enough, and reads return 0x00 while it boots.
	 */
	len = zumapro_touch_read_attn(ts, &code, TOUCH_BOOT_TRIES);

	if (len < 0) {
		dev_err(dev, "part did not report in after reset (%d)\n", len);
	} else if (code == REPORT_IDENTIFY && len >= 22) {
		/*
		 * struct tcm_identification_info: version, mode, then a
		 * 16-byte ASCII part number and a 4-byte build id.
		 */
		dev_info(dev, "TouchComm v%u mode %u, part %.16s, build %u\n",
			 ts->rxbuf[0], ts->rxbuf[1], &ts->rxbuf[2],
			 get_unaligned_le32(&ts->rxbuf[18]));
	} else {
		dev_err(dev, "unexpected first message 0x%02x, %d bytes: %*ph\n",
			code, len, min(len, 24), ts->rxbuf);
	}

	/*
	 * Screen bounds and object count belong to the part, not to this
	 * driver. Hardcoding 1080x2424 would be inventing numbers that the
	 * device is willing to state.
	 */
	ts->max_objects = TCM_MAX_OBJECTS;
	ret = zumapro_touch_request(ts, CMD_GET_APPLICATION_INFO, NULL, 0);
	if (ret >= APP_INFO_MAX_OBJECTS + 2) {
		ts->max_x = get_unaligned_le16(&ts->rxbuf[APP_INFO_MAX_X]);
		ts->max_y = get_unaligned_le16(&ts->rxbuf[APP_INFO_MAX_Y]);
		ts->max_objects = min_t(unsigned int, TCM_MAX_OBJECTS,
					get_unaligned_le16(&ts->rxbuf[APP_INFO_MAX_OBJECTS]));

		dev_info(dev, "app info: %ux%u, %u objects\n",
			 ts->max_x, ts->max_y, ts->max_objects);
	} else {
		dev_err(dev, "no application info (%d); using panel defaults\n",
			ret);
		ts->max_x = 1079;
		ts->max_y = 2423;
	}

	/*
	 * The touch report layout. Without it there is nothing to decode
	 * against, so the poll loop falls back to logging raw reports.
	 */
	ret = zumapro_touch_request(ts, CMD_GET_TOUCH_REPORT_CONFIG, NULL, 0);
	if (ret > 0 && ret <= TCM_CONFIG_MAX) {
		memcpy(ts->config, ts->rxbuf, ret);
		ts->config_len = ret;
		dev_info(dev, "touch report config, %d bytes: %*ph\n",
			 ret, min(ret, 32), ts->config);
	} else {
		dev_err(dev, "no touch report config (%d); reports stay raw\n",
			ret);
	}

	ts->input = devm_input_allocate_device(dev);
	if (!ts->input) {
		ret = -ENOMEM;
		goto err;
	}

	ts->input->name = "Synaptics TouchComm";
	ts->input->id.bustype = BUS_SPI;
	input_set_abs_params(ts->input, ABS_MT_POSITION_X, 0, ts->max_x, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_POSITION_Y, 0, ts->max_y, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_PRESSURE, 0, 255, 0, 0);
	ret = input_mt_init_slots(ts->input, ts->max_objects, INPUT_MT_DIRECT);
	if (ret)
		goto err;

	ret = input_register_device(ts->input);
	if (ret)
		goto err;

	/* Ask for touch reports; without this the part stays quiet. */
	code = REPORT_TOUCH;
	ret = zumapro_touch_request(ts, CMD_ENABLE_REPORT, &code, 1);
	if (ret < 0)
		dev_err(dev, "could not enable touch reports (%d)\n", ret);

	ts->polling = true;
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
		.dev_groups = zumapro_touch_groups,
	},
	.probe = zumapro_touch_probe,
	.remove = zumapro_touch_remove,
};
module_spi_driver(zumapro_touch_driver);

MODULE_DESCRIPTION("Synaptics TouchComm v1 over SPI for Tensor G4");
MODULE_LICENSE("GPL");

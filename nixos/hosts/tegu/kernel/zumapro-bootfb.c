// SPDX-License-Identifier: GPL-2.0-only
/*
 * Google Tensor G4 (zumapro) boot framebuffer
 *
 * The Pixel bootloader leaves the boot logo scanning out on DECON0 when it
 * jumps to the kernel. Mainline has no driver for this display pipeline,
 * so rather than program it we read back what the bootloader configured,
 * reserve the buffer it is scanning from, and hand that buffer to simpledrm
 * as a "simple-framebuffer" platform device. The result is a DRM device,
 * an fbcon, and the kernel log on the panel without a UART cable.
 *
 * Register offsets come from the downstream display driver
 * (google-modules/display/samsung, cal_9865, shared by zuma and zumapro)
 * and the addresses from the downstream zumapro DTB.
 *
 * Two boot stages:
 *
 *  1. early_param "zumapro_bootfb" runs from parse_early_param(), before
 *     arm64_memblock_init(). It reads the DECON/DPP registers and reserves
 *     the framebuffer as NOMAP so the kernel neither allocates over it nor
 *     maps it cacheable (which would also stop ioremap_wc from mapping it).
 *
 *  2. A device_initcall keeps the panel refreshing (command-mode panels
 *     only push a frame when triggered), coerces the DMA pixel format to one
 *     simpledrm can blit into if the bootloader picked one it cannot, and
 *     registers the platform device.
 *
 * Nothing here powers anything on: if the display was off at kernel entry
 * the register reads would fault. The bootloader shows its logo right up to
 * the jump, so in practice the domain is on.
 */

#define pr_fmt(fmt) "zumapro-bootfb: " fmt

#include <linux/arm-smccc.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/memblock.h>
#include <linux/of_fdt.h>
#include <linux/platform_device.h>
#include <linux/platform_data/simplefb.h>
#include <linux/workqueue.h>
#include <asm/early_ioremap.h>

/* DECON0 register regions (downstream reg-names "main", "win", "wincon") */
#define DECON0_MAIN_BASE	0x19470000
#define DECON0_WIN_BASE		0x19480000
#define DECON0_WINCON_BASE	0x194a0000
#define DECON_MAIN_SIZE		0x100
#define DECON_WINDOWS		14
#define DECON_WIN_SIZE		(0x1000 * DECON_WINDOWS)

#define GLOBAL_CON		0x0020
#define  GLOBAL_CON_OP_MODE_CMD	BIT(8)
#define  GLOBAL_CON_RUN_STATUS	BIT(4)
#define  GLOBAL_CON_DECON_EN	BIT(1)
#define TRIG_CON		0x0030
#define  HW_TRIG_SEL_MASK	GENMASK(25, 24)
#define  HW_TRIG_SEL_NONE	(3 << 24)
#define  SW_TRIG_EN		BIT(8)
#define  HW_TRIG_MASK_DECON	BIT(4)
#define  SW_TRIG_DET_EN		BIT(1)
#define  HW_TRIG_EN		BIT(0)
#define SHD_REG_UP_REQ		0x0050
#define  SHD_REG_UP_REQ_GLOBAL	BIT(31)
#define  SHD_REG_UP_REQ_CMP	BIT(20)
#define  SHD_REG_UP_REQ_WIN(w)	BIT(w)

#define WIN_OFFSET(w)		(0x1000 * (w))
#define DECON_CON_WIN(w)	(WIN_OFFSET(w) + 0x00)	/* wincon region */
#define  WIN_CHMAP_GET(v)	(((v) >> 4) & 0xf)
#define  WIN_EN			BIT(0)
#define WIN_START_POSITION(w)	(WIN_OFFSET(w) + 0x0c)	/* win region */
#define WIN_END_POSITION(w)	(WIN_OFFSET(w) + 0x10)
#define  WIN_POS_Y(v)		(((v) >> 16) & 0x3fff)
#define  WIN_POS_X(v)		((v) & 0x3fff)

/* DPP read-DMA blocks: L0-L6 in DPUF0, L7-L13 in DPUF1, 0x1000 apart */
#define DPUF0_DMA_BASE		0x19900000
#define DPUF1_DMA_BASE		0x19d00000
#define DPP_PER_DPUF		7
#define DMA_SIZE		0x100

#define RDMA_ENABLE		0x0000
#define  IDMA_SFR_UPDATE_FORCE	BIT(4)	/* latch the shadowed SFRs now */
#define RDMA_IN_CTRL_0		0x0008
#define  IDMA_IMG_FORMAT_MASK	GENMASK(13, 8)
#define  IDMA_IMG_FORMAT(v)	((v) << 8)
#define  IDMA_ROT_MASK		GENMASK(6, 4)
#define  IDMA_COMP_MASK		GENMASK(3, 0)	/* AFBC, SBWC, SAJC, BLOCK */
#define RDMA_SRC_WIDTH		0x0010
#define RDMA_SRC_HEIGHT		0x0014
#define RDMA_SRC_OFFSET		0x0018
#define  IDMA_SRC_OFFSET_Y(v)	(((v) >> 16) & 0xffff)
#define  IDMA_SRC_OFFSET_X(v)	((v) & 0xffff)
#define RDMA_IMG_SIZE		0x001c
#define  IDMA_IMG_HEIGHT(v)	(((v) >> 16) & 0xffff)
#define  IDMA_IMG_WIDTH(v)	((v) & 0xffff)
#define RDMA_BASEADDR_P0	0x0040
#define RDMA_SRC_STRIDE_0	0x0050
#define  IDMA_STRIDE_0_SEL	BIT(31)
#define  IDMA_STRIDE_0_MASK	GENMASK(23, 0)

/* The DPU SysMMUs (v9). If one is enabled, RDMA_BASEADDR_P0 is an IOVA. */
#define DPUF0_SYSMMU_BASE	0x19840000
#define DPUF1_SYSMMU_BASE	0x19c40000
#define REG_MMU_CTRL		0x0000
#define  MMU_CTRL_ENABLE	BIT(0)

/* Refresh cadence for command-mode panels without a hardware trigger */
#define SW_TRIG_INTERVAL	msecs_to_jiffies(33)

/*
 * IDMA_IMG_FORMAT values for RGB. Samsung's names use the same convention
 * as DRM fourccs, so ARGB8888 here is DRM_FORMAT_ARGB8888. simpledrm only
 * knows the simplefb names, and the fbdev path can only blit into a subset
 * of those, so anything without a name is rewritten to XRGB8888 / RGB565.
 */
struct bootfb_format {
	const char *simplefb_name;	/* NULL: rewrite the DMA format */
	u8 bpp;
};

#define IDMA_FMT_XRGB8888	7
#define IDMA_FMT_RGB565		9

static const struct bootfb_format bootfb_formats[] = {
	/*
	 * The Pixel bootloader hands over a BGRA8888 buffer. Alpha is ignored
	 * for a scanout-only layer, so it is described as BGRX8888, which DRM
	 * can convert into (drm_fb_xrgb8888_to_bgrx8888). "b8g8r8x8" is added
	 * to the simplefb format table by this patch; upstream has no name for
	 * this order, which is why it previously had to be reported as
	 * x8r8g8b8 and came out with red and blue swapped.
	 */
	[0] = { "b8g8r8x8", 4 },	/* BGRA8888 */
	[1] = { NULL, 4 },		/* RGBA8888 */
	[2] = { "a8b8g8r8", 4 },	/* ABGR8888 */
	[3] = { "a8r8g8b8", 4 },	/* ARGB8888 */
	[4] = { "b8g8r8x8", 4 },	/* BGRX8888 */
	[5] = { NULL, 4 },		/* RGBX8888 */
	[6] = { "x8b8g8r8", 4 },	/* XBGR8888 */
	[IDMA_FMT_XRGB8888] = { "x8r8g8b8", 4 },
	[8] = { NULL, 2 },		/* BGR565 */
	[IDMA_FMT_RGB565] = { "r5g6b5", 2 },
};

static struct {
	bool found;
	bool cmd_mode;
	bool format_guessed;
	unsigned int win;
	unsigned int channel;
	unsigned int bpp;
	u32 fmt;
	u32 ctrl;
	phys_addr_t dma_base;
	phys_addr_t fb_base;
	resource_size_t fb_size;
	struct simplefb_platform_data pd;
} bootfb __initdata;

/*
 * Staged reset probes.
 *
 * This device has no serial console, and if the display turns out not to be
 * scanning at kernel entry there is no screen output either. What is left is
 * a single observable bit: whether the phone resets or sits there. So make
 * that bit deliberate. "zumapro_bootfb=<n>" resets the machine the moment
 * boot reaches stage <n>, using a direct PSCI SYSTEM_RESET SMC because the
 * kernel's own reboot machinery is not wired up this early. Firmware is up
 * (it is what launched us), so the call works from the first instruction.
 *
 * Boot once per stage: a reset means that stage was reached, a hang means it
 * was not. That bisects the failure to an exact line without any console.
 */
#define PSCI_0_2_FN_SYSTEM_RESET	0x84000009

static int bootfb_probe_stage __initdata = -1;

/*
 * Root compatible strings this SoC appears under.
 *
 * The mainline device tree in ../dts uses "google,zumapro". A stock Android
 * boot does not: the bootloader applies its dtbo, whose board fragment
 * rewrites the root node to
 *
 *     compatible = "google,ZUMA PRO TEGU", "google,ZUMA PRO";
 *
 * spaces, capitals and all. Both have to be accepted, or this driver
 * silently does nothing on exactly the configuration used to bring the
 * device up (fastboot boot, which keeps the stock device tree).
 */
static const char * const zumapro_dt_compat[] __initconst = {
	"google,zumapro",
	"google,ZUMA PRO",
};

static bool __init zumapro_dt_root_matches(void)
{
	unsigned long root = of_get_flat_dt_root();
	int i;

	for (i = 0; i < ARRAY_SIZE(zumapro_dt_compat); i++)
		if (of_flat_dt_is_compatible(root, zumapro_dt_compat[i]))
			return true;
	return false;
}

static void __init bootfb_probe(int stage)
{
	struct arm_smccc_res res;

	if (bootfb_probe_stage != stage)
		return;

	arm_smccc_smc(PSCI_0_2_FN_SYSTEM_RESET, 0, 0, 0, 0, 0, 0, 0, &res);
	/* Firmware declined; carry on booting rather than wedge here. */
}

static int __init zumapro_bootfb_early(char *arg)
{
	void __iomem *regs, *win, *wincon, *dma, *mmu;
	u32 con, ctrl, size, off, stride_reg, base, fmt;
	unsigned int w, ch = 0, bpp, stride, width, height;
	phys_addr_t start, end;

	if (arg && kstrtoint(arg, 10, &bootfb_probe_stage))
		bootfb_probe_stage = -1;

	/* Reached parse_early_param() at all */
	bootfb_probe(1);

	if (!zumapro_dt_root_matches())
		return 0;

	/* Flattened DT is parsed and the root is the SoC we expect */
	bootfb_probe(2);

	regs = early_ioremap(DECON0_MAIN_BASE, DECON_MAIN_SIZE);
	if (!regs)
		return 0;

	con = readl(regs + GLOBAL_CON);
	early_iounmap(regs, DECON_MAIN_SIZE);

	/* DECON0 MMIO is mapped and readable: its power domain is on */
	bootfb_probe(3);

	if (con & GLOBAL_CON_DECON_EN)
		bootfb_probe(4);	/* ... and it is enabled */
	if (con & GLOBAL_CON_RUN_STATUS)
		bootfb_probe(5);	/* ... and actively scanning out */

	if (!(con & GLOBAL_CON_DECON_EN)) {
		pr_info("DECON0 disabled (GLOBAL_CON=%08x), no boot framebuffer\n",
			con);
		return 0;
	}
	pr_info("DECON0 GLOBAL_CON=%08x (%srunning)\n", con,
		con & GLOBAL_CON_RUN_STATUS ? "" : "not ");
	bootfb.cmd_mode = con & GLOBAL_CON_OP_MODE_CMD;

	wincon = early_ioremap(DECON0_WINCON_BASE, DECON_WIN_SIZE);
	win = early_ioremap(DECON0_WIN_BASE, DECON_WIN_SIZE);
	if (!wincon || !win)
		goto unmap_win;

	for (w = 0; w < DECON_WINDOWS; w++) {
		u32 wc = readl(wincon + DECON_CON_WIN(w));

		if (!(wc & WIN_EN))
			continue;
		ch = WIN_CHMAP_GET(wc);
		pr_info("window %u enabled, channel %u, %ux%u+%ux%u\n", w, ch,
			WIN_POS_X(readl(win + WIN_END_POSITION(w))) + 1,
			WIN_POS_Y(readl(win + WIN_END_POSITION(w))) + 1,
			WIN_POS_X(readl(win + WIN_START_POSITION(w))),
			WIN_POS_Y(readl(win + WIN_START_POSITION(w))));
		break;
	}
	if (w == DECON_WINDOWS) {
		pr_info("DECON0 running but no window enabled\n");
		goto unmap_win;
	}
	if (ch >= 2 * DPP_PER_DPUF) {
		pr_info("channel %u is not a read DMA\n", ch);
		goto unmap_win;
	}
	/* A DECON window is enabled and mapped to a read-DMA channel */
	bootfb_probe(6);

	bootfb.win = w;
	bootfb.channel = ch;
	bootfb.dma_base = ch < DPP_PER_DPUF ?
		DPUF0_DMA_BASE + 0x1000 * ch :
		DPUF1_DMA_BASE + 0x1000 * (ch - DPP_PER_DPUF);

	mmu = early_ioremap(ch < DPP_PER_DPUF ? DPUF0_SYSMMU_BASE :
					       DPUF1_SYSMMU_BASE, 0x10);
	if (mmu) {
		u32 mmu_ctrl = readl(mmu + REG_MMU_CTRL);

		early_iounmap(mmu, 0x10);
		if (mmu_ctrl & MMU_CTRL_ENABLE) {
			pr_info("DPU SysMMU enabled (CTRL=%08x), DMA address is an IOVA\n",
				mmu_ctrl);
			goto unmap_win;
		}
	}

	dma = early_ioremap(bootfb.dma_base, DMA_SIZE);
	if (!dma)
		goto unmap_win;

	ctrl = readl(dma + RDMA_IN_CTRL_0);
	size = readl(dma + RDMA_IMG_SIZE);
	off = readl(dma + RDMA_SRC_OFFSET);
	stride_reg = readl(dma + RDMA_SRC_STRIDE_0);
	base = readl(dma + RDMA_BASEADDR_P0);
	width = IDMA_IMG_WIDTH(size);
	height = IDMA_IMG_HEIGHT(size);
	fmt = (ctrl & IDMA_IMG_FORMAT_MASK) >> 8;

	pr_info("L%u: base %08x src %ux%u img %ux%u off %u,%u ctrl %08x stride %08x\n",
		ch, base, readl(dma + RDMA_SRC_WIDTH), readl(dma + RDMA_SRC_HEIGHT),
		width, height, IDMA_SRC_OFFSET_X(off), IDMA_SRC_OFFSET_Y(off),
		ctrl, stride_reg);

	if (fmt >= ARRAY_SIZE(bootfb_formats) || !bootfb_formats[fmt].bpp) {
		pr_info("pixel format %u is not RGB, giving up\n", fmt);
		goto unmap_dma;
	}
	if (ctrl & IDMA_COMP_MASK) {
		pr_info("compressed/blocked layer (ctrl %08x), giving up\n", ctrl);
		goto unmap_dma;
	}
	if (ctrl & IDMA_ROT_MASK)
		pr_info("layer is rotated/flipped (ctrl %08x); console will be too\n",
			ctrl);
	if (!base || !width || !height) {
		pr_info("layer not configured, giving up\n");
		goto unmap_dma;
	}

	bpp = bootfb_formats[fmt].bpp;
	bootfb.bpp = bpp;
	bootfb.fmt = fmt;
	bootfb.ctrl = ctrl;
	if (stride_reg & IDMA_STRIDE_0_SEL)
		stride = stride_reg & IDMA_STRIDE_0_MASK;
	else
		stride = readl(dma + RDMA_SRC_WIDTH) * bpp;
	if (stride < width * bpp) {
		pr_info("stride %u too small for %u pixels, giving up\n", stride,
			width);
		goto unmap_dma;
	}

	bootfb.fb_base = (phys_addr_t)base +
		(phys_addr_t)IDMA_SRC_OFFSET_Y(off) * stride +
		(phys_addr_t)IDMA_SRC_OFFSET_X(off) * bpp;
	bootfb.fb_size = (resource_size_t)stride * (height - 1) + width * bpp;
	bootfb.format_guessed = !bootfb_formats[fmt].simplefb_name;
	bootfb.pd.width = width;
	bootfb.pd.height = height;
	bootfb.pd.stride = stride;
	bootfb.pd.format = bootfb.format_guessed ?
		(bpp == 2 ? "r5g6b5" : "x8r8g8b8") :
		bootfb_formats[fmt].simplefb_name;

	if (!memblock_is_memory(bootfb.fb_base)) {
		pr_info("framebuffer %pa is outside RAM, giving up\n",
			&bootfb.fb_base);
		goto unmap_dma;
	}

	start = ALIGN_DOWN(bootfb.fb_base, PAGE_SIZE);
	end = ALIGN(bootfb.fb_base + bootfb.fb_size, PAGE_SIZE);
	memblock_reserve(start, end - start);
	memblock_mark_nomap(start, end - start);
	bootfb.found = true;

	/* Full discovery succeeded and the framebuffer has been reserved */
	bootfb_probe(7);

	/*
	 * One compact line at KERN_ERR so it survives a quiet console and can
	 * be read off a photograph of the panel: on a device whose only output
	 * is the screen, a summary that scrolls away is no summary at all.
	 */
	pr_err("BOOTFB fmt=%u ctrl=%08x %ux%u stride=%u bpp=%u base=%pa as=%s%s\n",
	       fmt, ctrl, width, height, stride, bpp, &bootfb.fb_base,
	       bootfb.pd.format, bootfb.format_guessed ? " GUESSED" : "");

	/*
	 * Paint a stripe across the top of the panel. This device has no
	 * serial console, so this is the only evidence that gets out of early
	 * boot: if the stripe appears, the kernel started, this parameter ran,
	 * the DECON/DPP registers read back sanely, and fb_base points at the
	 * buffer the display is really scanning. If the kernel then dies
	 * before DRM comes up, the stripe stays on screen and says so.
	 *
	 * early_ioremap maps at most 256 KiB per call, hence only a stripe.
	 * The region is NOMAP, so there is no cacheable linear alias to
	 * conflict with these device-attribute writes.
	 */
	{
		unsigned int rows = min_t(unsigned int, height,
					  (256 * 1024) / stride);
		void __iomem *fb = early_ioremap(bootfb.fb_base, rows * stride);

		if (fb) {
			memset_io(fb, 0xff, rows * stride);
			early_iounmap(fb, rows * stride);
			pr_info("painted a %u-row stripe at %pa\n", rows,
				&bootfb.fb_base);
		}
	}

	pr_info("%ux%u %s stride %u at %pa (%s mode), reserved %pa-%pa\n",
		width, height, bootfb.pd.format, stride, &bootfb.fb_base,
		bootfb.cmd_mode ? "command" : "video", &start, &end);

unmap_dma:
	early_iounmap(dma, DMA_SIZE);
unmap_win:
	if (win)
		early_iounmap(win, DECON_WIN_SIZE);
	if (wincon)
		early_iounmap(wincon, DECON_WIN_SIZE);
	return 0;
}
early_param("zumapro_bootfb", zumapro_bootfb_early);

/*
 * Frame triggering.
 *
 * This panel is in command mode: DECON only pushes a frame when triggered, so
 * writes into the framebuffer are invisible until one happens. The bootloader
 * draws its logo and then stops triggering, which is why removing this code
 * left the screen stuck on the logo with the kernel running fine behind it.
 *
 * So this is the one place the driver does write to the display, and it is
 * necessary rather than opportunistic. Everything else (pixel format, window
 * configuration) is left exactly as the bootloader set it; attempts to
 * reprogram those were the cause of every display problem this port hit.
 *
 * A periodic software trigger runs regardless of whether the hardware TE
 * trigger could be unmasked. Relying on TE alone means trusting that the
 * bootloader left the panel's tear-effect signal running, which is not
 * something this port can verify.
 */
static void __iomem *decon_main;
static struct delayed_work sw_trig_work;

static void zumapro_bootfb_sw_trig(struct work_struct *work)
{
	u32 val = readl(decon_main + TRIG_CON);

	val &= ~HW_TRIG_MASK_DECON;
	val |= SW_TRIG_EN | SW_TRIG_DET_EN;
	writel(val, decon_main + TRIG_CON);
	writel(SHD_REG_UP_REQ_GLOBAL, decon_main + SHD_REG_UP_REQ);
	schedule_delayed_work(&sw_trig_work, SW_TRIG_INTERVAL);
}
/*
 * Stage 20: every initcall has run.
 *
 * The panel console has proved unreliable as evidence — it draws the boot
 * logo and then shows nothing, and text has only ever appeared when a panic
 * force-flushed the consoles. That makes "kernel hung in a driver" and
 * "kernel fine, console silent" indistinguishable. A reset is not
 * ambiguous: boot with zumapro_bootfb=20 and if the phone reboots, all
 * initcalls completed and the problem is later than driver init.
 */
static int __init zumapro_bootfb_late_probe(void)
{
	bootfb_probe(20);
	return 0;
}
late_initcall_sync(zumapro_bootfb_late_probe);

static int __init zumapro_bootfb_init(void)
{
	struct resource res;
	struct platform_device *pdev;

	if (!bootfb.found)
		return 0;

	decon_main = ioremap(DECON0_MAIN_BASE, DECON_MAIN_SIZE);
	if (!decon_main)
		return -ENOMEM;

	if (bootfb.cmd_mode) {
		u32 val = readl(decon_main + TRIG_CON);

		if ((val & HW_TRIG_SEL_MASK) != HW_TRIG_SEL_NONE) {
			val &= ~HW_TRIG_MASK_DECON;
			val |= HW_TRIG_EN;
			writel(val, decon_main + TRIG_CON);
			pr_err("BOOTFB hw trigger unmasked TRIG_CON=%08x\n", val);
		}
		/* Keep pushing frames even if TE never fires. */
		INIT_DELAYED_WORK(&sw_trig_work, zumapro_bootfb_sw_trig);
		schedule_delayed_work(&sw_trig_work, SW_TRIG_INTERVAL);
	}

	res = DEFINE_RES_MEM_NAMED(bootfb.fb_base, bootfb.fb_size,
				   "zumapro-bootfb");
	pdev = platform_device_register_resndata(NULL, "simple-framebuffer", 0,
						 &res, 1, &bootfb.pd,
						 sizeof(bootfb.pd));
	if (IS_ERR(pdev)) {
		pr_err("failed to register simple-framebuffer: %ld\n",
		       PTR_ERR(pdev));
		return PTR_ERR(pdev);
	}

	/*
	 * Repeat the summary here. The copy in the early parameter is printed
	 * long before any console exists, so on a device whose only output is
	 * the panel it has always scrolled away by the time anyone can read
	 * it. This one lands late enough to photograph.
	 */
	pr_err("BOOTFB fmt=%u ctrl=%08x %ux%u stride=%u bpp=%u base=%pa as=%s%s %s\n",
	       bootfb.fmt, bootfb.ctrl, bootfb.pd.width, bootfb.pd.height,
	       bootfb.pd.stride, bootfb.bpp, &bootfb.fb_base, bootfb.pd.format,
	       bootfb.format_guessed ? " GUESSED" : "",
	       bootfb.cmd_mode ? "command" : "video");
	return 0;
}
device_initcall(zumapro_bootfb_init);

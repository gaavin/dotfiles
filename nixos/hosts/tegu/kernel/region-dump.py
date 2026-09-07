#!/usr/bin/env python3
"""Dump the UFS register regions this port does not map, at boot and at probe.

The PMA register file responds to writes but nothing executes behind it, so
whatever gates the engine is outside the PHY's own registers. The obvious
place to look is the regions the stock firmware maps and we do not:

    region             base         stock     ours
    hci (standard)     0x13200000   0x200     0x200
    reg_hci (vs_hci)   0x13201100   0x2000    0x200     1/16th of it
    reg_ufsp           0x132a0000   0xa014    0x100
    reg_phy (PMA)      0x13204000   0x4000    0x3000
    reg_cport          0x13208000   0x804     not mapped at all

Google's MISC_CAL lives at reg_hci + 0x11B4 and carries MPHY_APBCLK_CAL,
which is outside our vs_hci window entirely. If there is a PMA reset or
enable in vs_hci, this port has never been able to see it.

This maps the regions directly by physical address, independent of the
device tree, and reports:

  - at arch_initcall, every non-zero register, which is the state the
    bootloader hands over;
  - at each UFS probe, what changed since then.

No writes. This is only to find out what is there.
"""
import sys

p = "drivers/soc/samsung/zumapro-ufs-restore.c"
s = open(p).read()

anchor = "static int __init zumapro_ufs_pins_init(void)"
if anchor not in s:
    sys.exit("region-dump: shim anchor moved in %s" % p)

block = '''/*
 * Regions the stock firmware maps. Sizes are the stock ones, not this
 * port's, which is the whole point: vs_hci in particular is mapped here at
 * 0x2000 where the device tree asks for 0x200.
 */
struct zumapro_ufs_region {
	const char *name;
	unsigned long base;
	size_t size;
	u32 *snap;
};

#define ZUMAPRO_VS_HCI_WORDS	(0x2000 / 4)
#define ZUMAPRO_HCI_WORDS	(0x200 / 4)
#define ZUMAPRO_SYSREG_WORDS	(0x1000 / 4)
#define ZUMAPRO_CPORT_WORDS	(0x804 / 4)

static u32 snap_vs_hci[ZUMAPRO_VS_HCI_WORDS];
static u32 snap_hci[ZUMAPRO_HCI_WORDS];
static u32 snap_sysreg[ZUMAPRO_SYSREG_WORDS];
static u32 snap_cport[ZUMAPRO_CPORT_WORDS];

static struct zumapro_ufs_region zumapro_ufs_regions[] = {
	{ "hci",     0x13200000, 0x200,  snap_hci    },
	{ "vs_hci",  0x13201100, 0x2000, snap_vs_hci },
	{ "sysreg",  0x13020000, 0x1000, snap_sysreg },
	{ "cport",   0x13208000, 0x804,  snap_cport  },
};

static bool zumapro_regions_captured;

/*
 * Called twice: once from the initcall below with "boot", and once per UFS
 * probe from ufs-exynos.c with "probe". The first pass records and prints
 * every non-zero register; later passes print only what moved.
 */
void zumapro_ufs_dump_regions(const char *when)
{
	unsigned int r, i, shown, changed;
	void __iomem *m;
	u32 v;

	for (r = 0; r < ARRAY_SIZE(zumapro_ufs_regions); r++) {
		struct zumapro_ufs_region *reg = &zumapro_ufs_regions[r];
		unsigned int words = reg->size / 4;

		m = ioremap(reg->base, reg->size);
		if (!m) {
			pr_warn("ufs-regions: %s: ioremap failed\\n", reg->name);
			continue;
		}

		shown = 0;
		changed = 0;
		for (i = 0; i < words; i++) {
			v = readl(m + (i * 4));

			if (!zumapro_regions_captured) {
				reg->snap[i] = v;
				if (v && shown < 64) {
					pr_info("ufs-regions boot %s +0x%04x = 0x%08x\\n",
						reg->name, i * 4, v);
					shown++;
				}
				if (v)
					changed++;
			} else if (v != reg->snap[i]) {
				changed++;
				if (shown < 64) {
					pr_info("ufs-regions %s %s +0x%04x = 0x%08x -> 0x%08x\\n",
						when, reg->name, i * 4,
						reg->snap[i], v);
					shown++;
				}
			}
		}

		pr_info("ufs-regions %s %s: %u %s%s\\n", when, reg->name, changed,
			zumapro_regions_captured ? "changed" : "non-zero",
			changed > 64 ? ", list truncated" : "");
		iounmap(m);
	}

	zumapro_regions_captured = true;
}

'''
s = s.replace(anchor, block + anchor, 1)

old = "	pr_info(\"zumapro-ufs-pins: gpp0 CON"
new = "	zumapro_ufs_dump_regions(\"boot\");\n\n	pr_info(\"zumapro-ufs-pins: gpp0 CON"
if old not in s:
    sys.exit("region-dump: pr_info anchor moved in %s" % p)
s = s.replace(old, new, 1)
open(p, "w").write(s)

# Call it once per probe from the host controller driver too.
q = "drivers/ufs/host/ufs-exynos.c"
t = open(q).read()
hook = "	{\n		/*\n		 * Raw UFSHCI offsets rather than the ufshci.h names,"
if hook not in t:
    sys.exit("region-dump: ufs-exynos probe hook anchor moved")
t = t.replace(hook,
              "	{\n		extern void zumapro_ufs_dump_regions(const char *when);\n\n"
              "		zumapro_ufs_dump_regions(\"probe\");\n	}\n\n" + hook, 1)
open(q, "w").write(t)
print("region-dump: instrumented shim and ufs-exynos")

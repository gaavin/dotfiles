#!/usr/bin/env python3
"""Snapshot the UFS PMA register space around the calibration trigger.

Every probe so far has read a handful of registers chosen in advance. None
has established the one thing that matters: whether the analogue block does
*anything at all* when the calibration trigger is written.

This takes three snapshots of the whole PMA window during CFG_PRE_INIT:

    A  before the table is applied
    B  after it, which includes the trigger -- the table's last two entries
       write COMN 0x50 = 0x0c then 0x00
    C  50ms later, with nothing written in between

and prints only the registers that changed.

A->B is a control: it should show our own writes landing, and confirms the
diff machinery works.

B->C is the experiment. Nothing writes the PMA in that window, so any change
is the hardware acting on its own. If registers move, calibration is running
and failing to finish, and the changes say where. If nothing moves at all,
the analogue block is inert and the trigger is not reaching it -- which sends
the search somewhere quite different from where it has been.
"""
import sys

p = "drivers/phy/samsung/phy-samsung-ufs.c"
s = open(p).read()

anchor = "#include \"phy-samsung-ufs.h\"\n"
if anchor not in s:
    sys.exit("pma-dump: include anchor moved in %s" % p)

helpers = anchor + """
/* PMA window as mapped by the device tree: 0x3000 bytes, one byte per reg. */
#define ZUMAPRO_PMA_REGS	(0x3000 / 4)

static bool pma_dump = true;
module_param(pma_dump, bool, 0444);
MODULE_PARM_DESC(pma_dump, "snapshot the UFS PMA around the calibration trigger");

static u8 pma_snap_a[ZUMAPRO_PMA_REGS];
static u8 pma_snap_b[ZUMAPRO_PMA_REGS];
static u8 pma_snap_c[ZUMAPRO_PMA_REGS];

static void zumapro_pma_snapshot(struct samsung_ufs_phy *phy, u8 *out)
{
	unsigned int i;

	for (i = 0; i < ZUMAPRO_PMA_REGS; i++)
		out[i] = readl(phy->reg_pma + (i * 4)) & 0xff;
}

/*
 * Print only what moved. Capped, because a PMA that is scribbling on itself
 * should not be able to fill the log and hide the summary line.
 */
static void zumapro_pma_diff(struct samsung_ufs_phy *phy, const char *what,
			     const u8 *before, const u8 *after)
{
	unsigned int i, changed = 0;

	for (i = 0; i < ZUMAPRO_PMA_REGS; i++) {
		if (before[i] == after[i])
			continue;
		changed++;
		if (changed <= 48)
			dev_err(phy->dev, "pma %s: reg 0x%03x (byte 0x%04x) 0x%02x -> 0x%02x\\n",
				what, i, i * 4, before[i], after[i]);
	}

	dev_err(phy->dev, "pma %s: %u register(s) changed%s\\n", what, changed,
		changed > 48 ? ", list truncated" : "");
}
"""
s = s.replace(anchor, helpers, 1)

old = """	if (keep_boot_phy && ufs_phy->ufs_phy_state == CFG_PRE_INIT) {"""
if old not in s:
    sys.exit("pma-dump: keep_boot_phy anchor moved; apply keep-boot-phy.py first")

pre = """	if (pma_dump && ufs_phy->ufs_phy_state == CFG_PRE_INIT)
		zumapro_pma_snapshot(ufs_phy, pma_snap_a);

	if (keep_boot_phy && ufs_phy->ufs_phy_state == CFG_PRE_INIT) {"""
s = s.replace(old, pre, 1)

old2 = """	for_each_phy_lane(ufs_phy, i) {
		if (ufs_phy->ufs_phy_state == CFG_PRE_INIT &&"""
if old2 not in s:
    sys.exit("pma-dump: wait-loop anchor moved in %s" % p)

post = """	if (pma_dump && ufs_phy->ufs_phy_state == CFG_PRE_INIT) {
		zumapro_pma_snapshot(ufs_phy, pma_snap_b);
		zumapro_pma_diff(ufs_phy, "A->B table+trigger",
				 pma_snap_a, pma_snap_b);

		/*
		 * Nothing writes the PMA here. Anything that moves is the
		 * hardware acting on its own.
		 */
		msleep(50);
		zumapro_pma_snapshot(ufs_phy, pma_snap_c);
		zumapro_pma_diff(ufs_phy, "B->C 50ms idle",
				 pma_snap_b, pma_snap_c);
	}

	for_each_phy_lane(ufs_phy, i) {
		if (ufs_phy->ufs_phy_state == CFG_PRE_INIT &&"""
s = s.replace(old2, post, 1)

if "#include <linux/delay.h>" not in s:
    s = s.replace("#include <linux/module.h>",
                  "#include <linux/delay.h>\n#include <linux/module.h>", 1)

open(p, "w").write(s)
print("pma-dump: instrumented samsung_ufs_phy_calibrate")

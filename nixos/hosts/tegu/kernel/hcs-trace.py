#!/usr/bin/env python3
"""Log HCS through the UFS driver's init, to find which step drops the link.

The region dump showed what the bootloader hands over:

    hci +0x0030 (HCS) = 0x0000010f
        DEVICE_PRESENT=1, UTRLRDY=1, UTMRLRDY=1, UCRDY=1, UPMCRS=1 (PWR_LOCAL)
    hci +0x0034 (HCE) = 0x00000001   controller enabled

The link is already up at hand-over. The device is present, both lists are
ready, UIC commands are accepted, and the power mode is settled. By the time
the driver's own probe reads HCS it is 0x00000000 and device_present is 0.

So this is not a bring-up problem. Something between hand-over and the first
probe tears down a working link, and afterwards nothing this port does can
rebuild it -- which is consistent with the PMA sitting inert, since the
bootloader had already calibrated and linked it.

This prints HCS at each step of the teardown and re-init so the destructive
one can be named rather than guessed:

    entry to hce_enable_notify PRE_CHANGE
    immediately before and after the HCI_SW_RST write
    after exynos_ufs_dev_hw_reset
    at hce_enable_notify POST_CHANGE

Read-only apart from the logging.
"""
import sys

p = "drivers/ufs/host/ufs-exynos.c"
s = open(p).read()

anchor = "static int exynos_ufs_host_reset(struct ufs_hba *hba)"
if anchor not in s:
    sys.exit("hcs-trace: host_reset anchor moved in %s" % p)

helper = """/* Read HCS and say what it means, at a named point in the sequence. */
static void zumapro_hcs(struct exynos_ufs *ufs, const char *where)
{
	u32 hcs = hci_readl(ufs, 0x30);

	dev_info(ufs->hba->dev,
		 "zumapro hcs %-22s 0x%08x dp=%d utrl=%d utmrl=%d ucrdy=%d upmcrs=%u\\n",
		 where, hcs, !!(hcs & 0x1), !!(hcs & 0x2), !!(hcs & 0x4),
		 !!(hcs & 0x8), (hcs >> 8) & 0x7);
}

""" + anchor
s = s.replace(anchor, helper, 1)

old_rst = "	hci_writel(ufs, UFS_SW_RST_MASK, HCI_SW_RST);"
if old_rst not in s:
    sys.exit("hcs-trace: SW_RST anchor moved")
s = s.replace(old_rst,
              "	zumapro_hcs(ufs, \"before HCI_SW_RST\");\n"
              + old_rst
              + "\n	zumapro_hcs(ufs, \"after HCI_SW_RST\");", 1)

old_dev = "		exynos_ufs_dev_hw_reset(hba);"
if old_dev not in s:
    sys.exit("hcs-trace: dev_hw_reset anchor moved")
s = s.replace(old_dev,
              "		zumapro_hcs(ufs, \"hce PRE, before devrst\");\n"
              + old_dev
              + "\n		zumapro_hcs(ufs, \"hce PRE, after devrst\");", 1)

old_post = "	case POST_CHANGE:\n		exynos_ufs_calc_pwm_clk_div(ufs);"
if old_post not in s:
    sys.exit("hcs-trace: hce POST anchor moved")
s = s.replace(old_post,
              "	case POST_CHANGE:\n		zumapro_hcs(ufs, \"hce POST entry\");\n"
              "		exynos_ufs_calc_pwm_clk_div(ufs);", 1)

open(p, "w").write(s)
print("hcs-trace: instrumented ufs-exynos")

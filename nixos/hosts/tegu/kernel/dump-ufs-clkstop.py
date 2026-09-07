#!/usr/bin/env python3
"""Report the host controller's clock-stop state just before PHY calibration.

The PHY's registers accept and hold writes, so its digital domain is alive,
but calibration never completes -- which points at the analogue side, and the
first thing to check there is whether the M-PHY reference clock is actually
running. HCI_CLKSTOP_CTRL carries REFCLK_STOP and REFCLKOUT_STOP; if either
is set when calibration is attempted, no calibration table could ever work.

exynos_ufs_ungate_clks() is supposed to have cleared them by this point. This
prints what the register actually contains rather than trusting that.
"""
import sys

p = "drivers/ufs/host/ufs-exynos.c"
s = open(p).read()

anchor = """	ret = phy_power_on(generic_phy);
	if (ret)
		goto out_exit_phy;"""
if anchor not in s:
    sys.exit("dump-ufs-clkstop: phy_power_on anchor moved in %s" % p)

probe = """	{
		/*
		 * Raw UFSHCI offsets rather than the ufshci.h names, so this
		 * probe cannot fail to build on an include that is not pulled
		 * in here.
		 *
		 * This runs at every link-startup PRE_CHANGE. On the first
		 * attempt it shows the state at hand-over; on attempts two
		 * onwards it shows the state left by the previous failure,
		 * which is the interesting one.
		 *
		 * HCS bit 0 (DEVICE_PRESENT) is the question that matters: it
		 * says whether the interconnect layer sees a UFS device at
		 * all. If it is clear, the device is not answering and the
		 * fault is its reset line, its reference clock or its supply
		 * -- not anything in the UniPro programming. If it is set, the
		 * device is there and the fault is in the link configuration.
		 *
		 * UECPA/UECDL latch the PHY-adapter and data-link errors; bit
		 * 31 means the value is valid.
		 */
		u32 cs = hci_readl(ufs, HCI_CLKSTOP_CTRL);
		u32 hcs = hci_readl(ufs, 0x30);		/* HCS   */
		u32 uecpa = hci_readl(ufs, 0x38);	/* UECPA */
		u32 uecdl = hci_readl(ufs, 0x3c);	/* UECDL */

		dev_info(hba->dev,
			 "zumapro: clkstop 0x%08x refclk_stop=%d refclkout_stop=%d mphy_apbclk_stop=%d misc 0x%08x lanes rx=%d tx=%d\\n",
			 cs, !!(cs & REFCLK_STOP), !!(cs & REFCLKOUT_STOP),
			 !!(cs & MPHY_APBCLK_STOP), hci_readl(ufs, HCI_MISC),
			 ufs->avail_ln_rx, ufs->avail_ln_tx);

		dev_info(hba->dev,
			 "zumapro: HCS 0x%08x device_present=%d, UECPA 0x%08x%s, UECDL 0x%08x%s, GPIO_OUT 0x%08x dev_rst_n=%d\\n",
			 hcs, !!(hcs & 0x1),
			 uecpa, (uecpa & 0x80000000) ? " (valid)" : "",
			 uecdl, (uecdl & 0x80000000) ? " (valid)" : "",
			 hci_readl(ufs, HCI_GPIO_OUT),
			 !!(hci_readl(ufs, HCI_GPIO_OUT) & 0x1));
	}

"""

s = s.replace(anchor, probe + anchor, 1)
open(p, "w").write(s)
print("dump-ufs-clkstop: instrumented exynos_ufs_phy_init")

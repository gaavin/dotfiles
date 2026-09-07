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
		u32 cs = hci_readl(ufs, HCI_CLKSTOP_CTRL);

		dev_info(hba->dev,
			 "zumapro: clkstop 0x%08x refclk_stop=%d refclkout_stop=%d mphy_apbclk_stop=%d misc 0x%08x lanes rx=%d tx=%d\\n",
			 cs, !!(cs & REFCLK_STOP), !!(cs & REFCLKOUT_STOP),
			 !!(cs & MPHY_APBCLK_STOP), hci_readl(ufs, HCI_MISC),
			 ufs->avail_ln_rx, ufs->avail_ln_tx);
	}

"""

s = s.replace(anchor, probe + anchor, 1)
open(p, "w").write(s)
print("dump-ufs-clkstop: instrumented exynos_ufs_phy_init")

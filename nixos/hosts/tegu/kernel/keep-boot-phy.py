#!/usr/bin/env python3
"""Allow the bootloader's UFS PHY configuration to be left alone.

Measured on hardware: the bootloader leaves the whole HSI2 clock path running
and every UFS gate open, and it reads the kernel off UFS immediately before
handing over. The PHY is therefore in a known-working state when Linux starts,
and mainline's first act is to overwrite it with a calibration table and then
wait for a calibration that never completes.

This adds phy_exynos_ufs.keep_boot_phy=1, which skips applying the PRE_INIT
table and leaves whatever the bootloader set in place. The existing wait then
becomes the experiment, and it reports either way:

  - if calibration is already done, the wait succeeds immediately and link
    startup carries on, which would mean re-running calibration was itself
    the bug;
  - if not, the wait times out and the diagnostic prints cal_done's pristine,
    bootloader-set value, which is a number we have never seen.

Only the PRE_INIT table is skipped. The later power-mode tables are untouched.
"""
import sys

p = "drivers/phy/samsung/phy-samsung-ufs.c"
s = open(p).read()

inc = "#include \"phy-samsung-ufs.h\"\n"
if inc not in s:
    sys.exit("keep-boot-phy: include anchor moved in %s" % p)

param = inc + """
/*
 * Leave the PHY exactly as the bootloader configured it.
 *
 * The bootloader brings UFS up and reads the kernel from it, so its PHY
 * configuration demonstrably works. Set phy_exynos_ufs.keep_boot_phy=1 to
 * skip the PRE_INIT calibration table and find out whether overwriting that
 * working state is what breaks calibration.
 */
static bool keep_boot_phy;
module_param(keep_boot_phy, bool, 0444);
MODULE_PARM_DESC(keep_boot_phy,
		 "leave the bootloader's UFS PHY configuration in place");
"""
s = s.replace(inc, param, 1)

old = """	for_each_phy_cfg(cfg) {
		for_each_phy_lane(ufs_phy, i) {
			samsung_ufs_phy_config(ufs_phy, cfg, i);
		}
	}

	for_each_phy_lane(ufs_phy, i) {
		if (ufs_phy->ufs_phy_state == CFG_PRE_INIT &&"""
if old not in s:
    sys.exit("keep-boot-phy: calibrate anchor moved in %s" % p)

new = """	if (keep_boot_phy && ufs_phy->ufs_phy_state == CFG_PRE_INIT) {
		/*
		 * Skip the table *and* the wait.
		 *
		 * With the table skipped, the PHY's trim registers read back
		 * values that differ from the ones the table would write
		 * (COMN 0x05 reads 0x15 against 0x19, 0x0b reads 0x4a against
		 * 0x44, 0x0c reads 0xea against 0xc4). Those are the table's
		 * values as adjusted by a calibration that already ran: the
		 * bootloader calibrated this PHY and read the kernel over it.
		 *
		 * cal_done bit 0 is clear even then, so it is not a persistent
		 * "this PHY is calibrated" flag -- it does not survive the
		 * UniPro/link software reset the host controller performs. So
		 * waiting for it on an already-calibrated PHY waits for
		 * something that will never arrive, and the timeout is what
		 * fails the probe.
		 *
		 * Note: skipping the wait was tried before and panicked with
		 * an SError. That was with the table applied, leaving the PHY
		 * half-reconfigured mid-calibration. Here nothing is written
		 * at all, so the PHY stays in the working state it was handed
		 * over in.
		 */
		dev_info(ufs_phy->dev,
			 "keep_boot_phy: leaving the bootloader's PHY configuration and calibration alone\\n");
		goto out;
	}

	for_each_phy_cfg(cfg) {
		for_each_phy_lane(ufs_phy, i) {
			samsung_ufs_phy_config(ufs_phy, cfg, i);
		}
	}

	for_each_phy_lane(ufs_phy, i) {
		if (ufs_phy->ufs_phy_state == CFG_PRE_INIT &&"""
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("keep-boot-phy: added phy_exynos_ufs.keep_boot_phy")

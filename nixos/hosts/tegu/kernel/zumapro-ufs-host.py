#!/usr/bin/env python3
"""Correct gs101's UFS host-controller data where Tensor G4 differs.

Two edits: the pre-link PCS values, and the controller quirks.

QUIRKS. Google's driver assembles hba->quirks and then takes four of them
back if the device tree node says so (ufs-exynos.c):

	hba->quirks = UFSHCD_QUIRK_PRDT_BYTE_GRAN |
			UFSHCI_QUIRK_SKIP_RESET_INTR_AGGR |
			UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR |
			UFSHCD_QUIRK_BROKEN_OCS_FATAL_ERROR | ...;

	if (of_find_property(np, "fixed-prdt-req_list-ocs", NULL))
		hba->quirks &= ~(UFSHCD_QUIRK_PRDT_BYTE_GRAN |
				UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR |
				UFSHCD_QUIRK_BROKEN_OCS_FATAL_ERROR |
				UFSHCI_QUIRK_SKIP_RESET_INTR_AGGR);

The stock Tensor G4 device tree does say so -- "fixed-prdt-req_list-ocs;" is
a property of ufs@13200000 in zumapro-a1-ipop.dtb -- so on this SoC all four
are wrong. mainline's gs101 drv_data sets three of them unconditionally, and
this port inherits them.

UFSHCD_QUIRK_PRDT_BYTE_GRAN is the one that shows. With it set, the driver
writes response_upiu_offset and prd_table_offset in bytes; without it, in
dwords. Tell a controller that wants dwords a byte offset and it puts the
response UPIU four times too far along, so the driver reads its own zeroed
buffer -- which is what the hardware said:

	ufshcd_dev_cmd_completion: Invalid device management cmd response: 0
	ufshcd_verify_dev_init: NOP OUT failed -22

The link itself was up by then: PHY calibration completed on both lanes and
link startup passed on the first attempt.

The pre-link edits follow.


The device tree binds this SoC's UFS controller to "google,gs101-ufs", so
gs101_ufs_pre_link() runs on Tensor G4. That is right for almost all of it:
compared entry by entry against Google's own table for this SoC
(google-modules/soc/gs, drivers/ufs/zuma/ufs-cal.h, init_cfg_evt1, the
PHY_PCS_* and UNIPRO_STD_MIB entries), mainline's gs101 sequence writes the
same attributes, in the same order, with the same values -- except in two
places.

1. The reference clock.

	#undef  USE_38_4_MHZ
	#define USE_38_4_MHZ	 /* 38.4MHz */
	...
	{0x200, 0x2800, 0x40, PMD_ALL, PHY_PCS_COMN, BRD_ALL},
	#ifdef USE_38_4_MHZ /*38.4MHz*/
	{0x202, 0x2808, 0x22, PMD_ALL, PHY_PCS_COMN, BRD_ALL},
	#else/*26MHz*/
	{0x202, 0x2808, 0x12, PMD_ALL, PHY_PCS_COMN, BRD_ALL},
	#endif

   Tensor G4 runs its M-PHY from a 38.4 MHz reference and Google selects that
   with PCS attribute 0x202 = 0x22. gs101 never writes 0x202 at all, so on
   this port the attribute keeps its reset value and the PCS is told the wrong
   reference frequency. (exynosautov920_ufs_pre_link() in mainline writes the
   same attribute, 0x202 = 0x02, which is what makes it clear the field is a
   per-SoC reference-clock selector rather than something gs101 may simply
   omit.)

2. PCS RX attribute 0x2F.

	{0x2F, 0x20BC, 0x79, PMD_ALL, PHY_PCS_RX, BRD_ALL}

   gs101 writes 0x69 here. Tensor G4 wants 0x79.

Everything else in that table already matches, including the attribute triples
behind mainline's VND_RX_LINERESET_VALUE2/1/0 (0x1B, 0x1C, 0x1D) and
VND_TX_LINERESET_PVALUE2/1/0 (0xAB, 0xAC, 0xAD), which Google writes as one
PHY_PCS_RX_LR_PRD / PHY_PCS_TX_LR_PRD entry at the first address of each run.

This patches gs101_ufs_pre_link() in place rather than adding a variant. This
kernel has exactly one board using "google,gs101-ufs" -- this one -- so a
variant would add a drv_data struct, a compatible and a device tree change to
express a difference that no other board here can observe. The anchors below
are exact, so if upstream changes those lines the build fails loudly instead
of silently writing gs101's values to Tensor G4.
"""
import sys

p = "drivers/ufs/host/ufs-exynos.c"
s = open(p).read()

# Locate gs101_ufs_pre_link() and edit only inside it: 0x200/0x2f appear in
# several SoCs' pre-link functions in this file.
start = s.find("static int gs101_ufs_pre_link(struct exynos_ufs *ufs)")
if start < 0:
    sys.exit("zumapro-ufs-prelink: gs101_ufs_pre_link() not found in %s" % p)
end = s.find("\nstatic int gs101_ufs_post_link(", start)
if end < 0:
    sys.exit("zumapro-ufs-prelink: end of gs101_ufs_pre_link() not found")
body = s[start:end]

old_200 = "\tufshcd_dme_set(hba, UIC_ARG_MIB(0x200), 0x40);\n"
if body.count(old_200) != 1:
    sys.exit("zumapro-ufs-prelink: PCS 0x200 open anchor moved or ambiguous")
new_200 = old_200 + """
	/*
	 * Tensor G4 clocks its M-PHY from a 38.4 MHz reference. Google selects
	 * that here (ufs-cal.h, init_cfg_evt1, guarded by USE_38_4_MHZ); the
	 * 26 MHz alternative in the same table is 0x12. gs101 does not write
	 * this attribute, so without it the PCS keeps its reset value and is
	 * told the wrong reference frequency.
	 */
	ufshcd_dme_set(hba, UIC_ARG_MIB(0x202), 0x22);
"""
body = body.replace(old_200, new_200, 1)

old_2f = "\t\tufshcd_dme_set(hba, UIC_ARG_MIB_SEL(0x2f, i), 0x69);\n"
if body.count(old_2f) != 1:
    sys.exit("zumapro-ufs-prelink: PCS 0x2f anchor moved or ambiguous")
new_2f = "\t\t/* 0x79 on Tensor G4; gs101's value is 0x69. */\n" \
         "\t\tufshcd_dme_set(hba, UIC_ARG_MIB_SEL(0x2f, i), 0x79);\n"
body = body.replace(old_2f, new_2f, 1)

s = s[:start] + body + s[end:]

# Drop the four quirks that "fixed-prdt-req_list-ocs" takes back on this SoC.
old_init = """	/* set ACG to be controlled by UFS_ACG_DISABLE */
	reg = hci_readl(ufs, HCI_IOP_ACG_DISABLE);"""
if s.count(old_init) != 1:
    sys.exit("zumapro-ufs-host: gs101_ufs_drv_init() body moved or ambiguous")
new_init = """	/*
	 * Tensor G4's controller has none of these faults. Its stock device
	 * tree carries "fixed-prdt-req_list-ocs", the property Google's driver
	 * reads to clear exactly this set. PRDT_BYTE_GRAN is the one that
	 * shows: with it set the driver states the response UPIU offset in
	 * bytes to a controller that reads dwords, so the response lands four
	 * times too far along and every device management command comes back
	 * as an all-zero UPIU.
	 */
	hba->quirks &= ~(UFSHCD_QUIRK_PRDT_BYTE_GRAN |
			 UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR |
			 UFSHCD_QUIRK_BROKEN_OCS_FATAL_ERROR |
			 UFSHCI_QUIRK_SKIP_RESET_INTR_AGGR);

""" + old_init
s = s.replace(old_init, new_init, 1)

open(p, "w").write(s)
print("zumapro-ufs-host: PCS 0x202=0x22 (38.4 MHz refclk), 0x2f=0x79, "
      "quirks cleared per fixed-prdt-req_list-ocs")

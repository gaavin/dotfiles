# github.com/zumapro-mainline — what to take and what not to

Checked 2026-09-09. Same goal as this port: "Making mainline linux run on
Google Tensor G4 based mobile devices with postmarketOS." Their `linux` fork
carries `zumapro.dtsi`, `zumapro-tegu.dts`, `zumapro-pinctrl.dtsi` and a
`drivers/clk/samsung/clk-zuma.c`, and they have `pmaports` alongside. Ahead of
this port in breadth: DTs for five devices (tegu, caiman, komodo, tokay,
comet) and one clock driver covering many CMUs, against this port's two
hand-written minimal ones.

## Take: the CMU_HSI0 USI clocks

Their `clk-zuma.c` agrees with what this port measured on hardware:

	CLK_CON_MUX_MUX_CLK_HSI0_USI2   0x101c
	CLK_CON_DIV_DIV_CLK_HSI0_USI2   0x181c   <- matches our measurement
	CLK_CON_GAT_GATE_CLK_HSI0_USI2  0x2120

and they declare `google,zumapro-cmu-hsi0`, the compatible this port's device
tree already uses. That part of the file is properly derived for this SoC.
`zuma-pinctrl-data.c` here already came from them.

## Do not take: anything USB

**Their USB clock and PHY description is gs101's, transplanted.** It names
registers this SoC does not have. Verified three ways rather than assumed:

	signal                theirs    mainline gs101   Google's zuma tables
	REF_CLK_40            0x2078    0x2078           0x20ac
	ACLK_PHYCTRL          0x206c    0x206c           does not exist
	BUS_CLK_EARLY         0x2070    0x2070           does not exist
	USB20_PHY_REFCLK_26   0x2074    0x2074           does not exist
	USBPCS_APB_CLK        0x2084    0x2084           does not exist

Every gs101 USB signal name has **zero** occurrences in
`cal-if/zuma/cmucal-sfr.c`. What zumapro actually has in CMU_HSI0 is a
different set, eUSB included:

	I_USBLINK_ACLK           0x20a4      I_USBSUBCTL_APB_PCLK    0x20a0
	I_USB32DRD_REF_CLK_40    0x20ac      I_USBDPPHY_CTRL_PCLK    0x20b4
	I_EUSB_CTRL_PCLK         0x20b8      I_USBDPPHY_TCA_APB_CLK  0x20c0
	I_EUSB_APB_CLK           0x20d8      I_EUSB_PHY_REFCLK_26    0x20dc

	QCH_CON_USB32DRD_QCH_LINK          0x30c0
	QCH_CON_USB32DRD_QCH_SUBCTL        0x30bc
	QCH_CON_USB32DRD_QCH_EUSBCTL       0x30b8
	QCH_CON_USB32DRD_QCH_EUSBPHY       0x30a8
	QCH_CON_USB32DRD_QCH_USBDPPHY_CTRL 0x30b0
	QCH_CON_USB32DRD_QCH_USBDPPHY_TCA  0x30b4
	DMYQCH_CON_USB32DRD_QCH_REF        0x3000

	CLK_CON_MUX_MUX_CLK_HSI0_USB20_REF   0x1004   (CMU_HSI0)
	CLK_CON_MUX_MUX_CLK_HSI0_USB32DRD    0x1008   (CMU_HSI0)
	CLK_CON_DIV_DIV_CLK_HSI0_USB32DRD    0x1808   (CMU_HSI0)
	CLK_CON_DIV_DIV_CLK_HSI0_USB         0x1804   (CMU_HSI0)
	CLK_CON_MUX_MUX_CLKCMU_HSI0_USB32DRD 0x109c   (CMU_TOP)

Their PHY node is likewise `google,gs101-usb31drd-phy` with
`reg-names = "phy", "pcs", "pma"` — three ranges. The stock zumapro node has
six, `phy_eusb_version = <0x701>` and `has_combo_phy = <0x01>`. Different
hardware behind the same name.

Their `usb@11210000` address and `GIC_SPI 402` are right; they match the stock
tree. It is what sits underneath that is wrong.

## The lesson this repeats

This is the same shape as the faults that cost this port its longest days: the
PHY isolation offset that was 0x3ec0 and not gs101's 0x3ec8, the calibration
bit that was TRSV 0x31d and not 0x338, and `0x181c` being HSI0's USI2 divider
here and CMU_TOP's CIS_CLK3 on gs101. A gs101 name that compiles is not a
zumapro register. Check every borrowed offset against
`cal-if/zuma/cmucal-sfr.c` before believing it.

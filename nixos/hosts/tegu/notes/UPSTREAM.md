# The two community zumapro trees — what to take

Nothing for this SoC is upstream. Two out-of-tree forks carry it, and since
2026-09-09 this port builds from the first of them rather than maintaining its
own description; see the README's "The kernel base changed".

| | |
| --- | --- |
| [Trijal08/kernel-mainline](https://github.com/Trijal08/kernel-mainline), branch `zumapro-google-caimito` | **This port's base.** 7.3-rc2 + ~400 commits, five board DTs including `zumapro-tegu.dts`, postmarketOS packaging |
| [zumapro-mainline/linux](https://github.com/zumapro-mainline/linux) | Where `clk-zuma.c` and the pinctrl bank data came from first; last pushed 2026-04 |

## Trijal08: what it already gets right

Checked against this port's own hardware measurements, which cost a boot each.
Every one of these agrees:

	UFS PHY isolation            0x3ec0, not gs101's 0x3ec8
	UFS calibration-done         TRSV 0x31d, and non-fatal on timeout
	UFS post-PMC CDR wait        absent (.wait_for_cdr = NULL)
	M-PHY reference clock        PCS 0x202 = 0x22 (38.4 MHz) in pre-link
	UFS quirks                   the four "fixed-prdt-req_list-ocs" clears
	Touch controller             spi@111d0000, USI in SPI mode
	Touch chip select            native, manual, 2 us setup delay
	Touch reset / IRQ            gpp1-1 active-low / gpn0-0 EINT
	Touch rails                  S2MPG14 LDO25M (DVDD), LDO4M (AVDD)
	Watchdogs                    0x10060000 / 0x10070000, IRQ 767 / 768
	CMU_HSI0 USI2 divider        0x181c

It goes well past that: pinctrl bank data for every block, a clock driver for
every CMU, secure power domains, System MMU v9, ACPM TMU thermal zones, cpufreq
with OPP tables, MCT v3 and c2 idle, the eUSB2 + USB-DP combo PHY, PCIe with
BCM4390 Wi-Fi, the exynos9 DECON/DSIM display pipeline, an AoC stack with audio
on top, and the Samsung s5400 modem.

## Trijal08: what it does not cover for this board

- **The display.** `DRM_EXYNOS` is not enabled in their `zumapro_defconfig` at
  all, and their DECON/DSIM and panel work targets komodo and caiman. Their
  `zumapro-tegu.dts` uses the bootloader's framebuffer through a
  `simple-framebuffer` node instead, exactly as this port does.
- **Wi-Fi, modem and audio are board files this board does not have.**
  `zumapro-caimito-bcm4390.dtsi`, `-s5400.dtsi` and `-cs35l41.dtsi` are
  included only by the four caimito boards.
- **Their defconfig and their newer commits have drifted.** `GOOGLE_AOC=m` is
  in it, but `CONFIG_TRUSTY` is not, and the AoC needs Trusty to come out of
  reset — so the AoC silently drops out of a build made from that defconfig.
  Verify what is actually in `.config` before concluding a subsystem is on.
- **tegu is the least-tested board in the tree.** Their `zumapro-tegu.dts`
  carries a plausible-looking framebuffer geometry (1080×2424 at 0xfac00000,
  `a8r8g8b8`) where this port measured the bootloader handing over BGRA; the
  `format` there may simply never have been looked at on hardware.

## The USB clock offsets: unresolved, and hardware decides

This file used to say flatly that any USB clock description in either tree was
gs101's, transplanted. Both trees name the CMU_HSI0 USB gates at gs101's
offsets:

	signal                theirs    mainline gs101   Google's zuma cmucal
	I_USB31DRD_REF_CLK_40 0x2078    0x2078           0x20ac (as USB32DRD)
	ACLK_PHYCTRL          0x206c    0x206c           no such name
	BUS_CLK_EARLY         0x2070    0x2070           no such name
	USB20_PHY_REFCLK_26   0x2074    0x2074           no such name
	USBPCS_APB_CLK        0x2084    0x2084           no such name

and every gs101 USB signal name has zero occurrences in
`cal-if/zuma/cmucal-sfr.c`, where what exists instead is

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

**But this port also measured eight live gates in the 0x206c–0x2088 range, all
reading `0x00200000` at dwc3 probe** — the value a gate in MANUAL mode with the
clock running reads. Registers that "do not exist" do not answer like that. So
the disagreement is probably about *names* in a vendor table, not about
addresses, and the flat claim above was over-stated: it was derived by grepping
Google's cmucal, never by writing one of these registers and watching the block
respond.

Which means the next round of USB work is a boot, not more reading. USB is
enabled for this board by their `zumapro-pixel-common.dtsi`, so the very next
flash tests it.

## The lesson that keeps repeating

A gs101 name that compiles is not a zumapro register, and a vendor table that
lacks a name is not proof the register is absent. Both directions have cost
this port days: the PHY isolation offset that was 0x3ec0 and not gs101's
0x3ec8, the calibration bit that was TRSV 0x31d and not 0x338, `0x181c` being
HSI0's USI2 divider here and CMU_TOP's CIS_CLK3 on gs101 — and now a USB clock
table this file dismissed while the hardware was answering at those very
offsets. Measure before believing either the borrowed name or the objection to
it.

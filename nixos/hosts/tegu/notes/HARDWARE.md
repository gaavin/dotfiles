# tegu hardware register reference

Everything this port has established about the Pixel 9a (Tensor G4, `zumapro`),
in one place. **Every address here is either read on hardware or taken from
Google's own `cal-if/zuma/` tables.** Where a value came from gs101 and turned
out wrong, the wrong value is kept alongside the right one — those pairs are
the most expensive lessons in the port.

Rule for anything added here: a gs101 name that compiles is not a zumapro
register. Check `drivers/soc/google/cal-if/zuma/cmucal-sfr.c` first.

## Blocks

	PMU                     0x15460000
	CMU_TOP                 0x26040000
	CMU_HSI0                0x11000000  (USB + the USI the touchscreen uses)
	CMU_HSI2                0x13000000  (UFS)
	pinctrl alive (gpn*)    0x15060000
	pinctrl peric0 (gpp*)   0x10840000
	pinctrl peric1 (gpb*)   0x10c40000
	sysreg_hsi0             0x11020000
	sysreg_ufs              0x13020000
	debug UART (ttySAC0)    0x10870000  IRQ 641
	watchdog cluster0/1     0x10060000 / 0x10070000  IRQ 767 / 768
	ACPM mailbox            0x15110000  IRQ 80
	ACPM SRAM               0x15700000  initdata base 0xa000

Watchdog IRQs are two higher than gs101's 765/766. ACPM's initdata base is the
same as gs101's, so the shared-memory layout matches and only addresses differ.

## Power domains (PMU 0x15460000)

	pd-hsi0 CONFIGURATION   0x15462a80   measured 0x00000001
	pd-hsi0 STATUS          0x15462a84   measured 0x00000001   bit 0 = powered

STATUS is the one that decides; CONFIGURATION is a request. Source:
`PMUCAL_SEQ_DESC(PMUCAL_READ, "HSI0_STATUS", 0x15460000, 0x2a84, (0x1 << 0))`
in `flexpmu_cal_local_zuma.h`.

	UFS PHY isolation       PMU +0x3ec0   NOT gs101's +0x3ec8
	USB PHY pmu_offset      PMU +0x3eb0   (+0x3eb4 for DP)

## USB — controller and PHY

	dwc3 controller         0x11210000  len 0x10000   IRQ 402 (0x192)
	usbdrd phy              0x11100000  six ranges:
	                          0x11100000 0x200   0x11110000 0x200
	                          0x11120000 0x200   0x11130000 0x800
	                          0x11140000 0x800   0x11210000 0x10000
	phy IRQs                399, 397, 404

From the stock node: `phy_version = <0x600>`, `phy_eusb_version = <0x701>`,
`has_combo_phy = <0x01>`, `sub_phy_version = <0x801>`, `usbdp_mode = <0x01>`,
`phy_ref_clock = <0x124f800>` (19.2 MHz), `ip_type = <0x00>`.

**This is eUSB2 behind a combo USB-DP block.** gs101's is a plain USB2+USB3 PHY
with three ranges named phy/pcs/pma. Mainline's `google,gs101-usb31drd-phy`
does not describe this hardware.

### USB clocks, CMU_HSI0 (base 0x11000000)

Gates, enable is **bit 21**. All eight read `0x00200000` (already open) before
Linux touches them:

	I_USBSUBCTL_APB_PCLK    0x20a0      I_USBLINK_ACLK          0x20a4
	I_USB32DRD_REF_CLK_40   0x20ac      I_USBDPPHY_CTRL_PCLK    0x20b4
	I_EUSB_CTRL_PCLK        0x20b8      I_USBDPPHY_TCA_APB_CLK  0x20c0
	I_EUSB_APB_CLK          0x20d8      I_EUSB_PHY_REFCLK_26    0x20dc

Q-channels, enable is **bit 0**. All read `0x00000002` from the bootloader
(enable clear); writing bit 0 takes, verified `0x2 -> 0x3`:

	QCH_CON_USB32DRD_QCH_REF        0x3000  (DMYQCH)
	QCH_CON_USB32DRD_QCH_EUSBPHY    0x30a8
	QCH_CON_USB32DRD_QCH_USBDPPHY_CTRL 0x30b0
	QCH_CON_USB32DRD_QCH_USBDPPHY_TCA  0x30b4
	QCH_CON_USB32DRD_QCH_EUSBCTL    0x30b8
	QCH_CON_USB32DRD_QCH_SUBCTL     0x30bc
	QCH_CON_USB32DRD_QCH_LINK       0x30c0

Muxes and dividers:

	PLL_CON0_MUX_CLKCMU_HSI0_USB20_USER     0x640   bit 4 = CMU_TOP feed
	PLL_CON0_MUX_CLKCMU_HSI0_USB32DRD_USER  0x650   bit 4 = CMU_TOP feed
	CLK_CON_MUX_MUX_CLK_HSI0_USB20_REF      0x1004
	CLK_CON_MUX_MUX_CLK_HSI0_USB32DRD       0x1008
	CLK_CON_DIV_DIV_CLK_HSI0_USB            0x1804
	CLK_CON_DIV_DIV_CLK_HSI0_USB32DRD       0x1808

The bootloader leaves both user muxes at `0x00000000` — the oscillator, not the
CMU_TOP feed. Setting bit 4 takes (`usermux32` reads `0x00000010` after).

### USB clocks, CMU_TOP (base 0x26040000)

	CLK_CON_DIV_CLKCMU_HSI0_USB32DRD        0x1894   (0x26041894)
	CLK_CON_GAT_GATE_CLKCMU_HSI0_USB32DRD   0x20c4   (0x260420c4)
	CLK_CON_MUX_MUX_CLKCMU_HSI0_USB32DRD    0x109c

**gs101 values that are wrong here**, and which a third-party tree ships as
zumapro's (see UPSTREAM.md): `REF_CLK_40` at 0x2078 (correct: 0x20ac), and the
signal names `ACLK_PHYCTRL`, `BUS_CLK_EARLY`, `USB20_PHY_REFCLK_26`,
`USBPCS_APB_CLK` — none of which occur anywhere in zuma's tables.

### USB state as of 2026-09-09

Power domain on, registers reachable, every gate open, Q-channels enabled, user
muxes on the CMU_TOP feed — and `DWC3 controller soft reset failed, -ETIMEDOUT`.
`dwc3_core_soft_reset()` calls `phy_init()` before asserting `DCTL.CSFTRST`, so
the PHY is a prerequisite, not a later step.

## Touchscreen

	SPI controller (spi_20)  0x111d0000  IRQ 408
	USI wrapper              0x111d00c0  len 0x20
	USI mode select          sysreg_hsi0 + 0x101c   (USI_V2_SW_CONF_SPI)
	reset                    gpp1-1, active low
	ATTN                     gpn0-0, active HIGH (measured; Google's DT says low)
	rails                    LDO25M vdd 1.8V, LDO4M avdd 3.3V, over ACPM

Clocks, CMU_HSI0:

	CLK_CON_MUX_MUX_CLK_HSI0_USI2   0x101c
	CLK_CON_DIV_DIV_CLK_HSI0_USI2   0x181c   confirmed on hardware
	CLK_CON_GAT_GATE_CLK_HSI0_USI2  0x2120
	QCH_CON_USI2_HSI0_QCH           0x30cc   read live as 0x00000002

CMU_TOP: `CLK_CON_DIV_CLKCMU_HSI0_PERI` 0x1890, gate 0x20c0.

**The touch SPI is clocked from CMU_HSI0, not CMU_PERIC1.** "USI11" is the pad
name of the reset line (`XAPC_USI11_RTSn_DI`), not the block. Getting this wrong
ran the bus at 100 MHz against a part rated for 10.

Part: Synaptics **S3908**, firmware `GA1B0-15.0`, TouchComm **v1**, mode 1.
Panel 1080x2424 (`goog,display-resolution`). Report config is **128 bytes**,
delivered as one 60-byte read plus continued reads of 60 and 17.

## UFS

	controller       0x13200000   IRQ 466
	phy (PMA)        0x13204000
	sysreg           0x13020000 + 0x710  (IOCC)
	refclk           38.4 MHz, selected by PCS attribute 0x202 = 0x22
	cal-done         TRSV 0x31d bit 0    NOT gs101's 0x338 bit 3
	PHY isolation    PMU + 0x3ec0        NOT gs101's + 0x3ec8
	PCS RX 0x2f      0x79                gs101 uses 0x69

Gates, CMU_HSI2 — **0x3c higher than gs101's**, because Tensor G4 inserts extra
gates ahead of them:

	UFS_EMBD aclk    0x210c   (gs101 0x20d0)
	UFS_EMBD unipro  0x2110   (gs101 0x20d4)
	UFS_EMBD fmp     0x2114   (gs101 0x20d8)
	qe aclk/pclk     0x20cc / 0x20d0     sysreg pclk 0x20e8

CMU_TOP: NOC gate 0x20d8, UFS_EMBD gate 0x20e0. User muxes in CMU_HSI2:
NOC 0x610, UFS_EMBD 0x630, bit 4 selects CMU_TOP.

The stock tree carries `fixed-prdt-req_list-ocs` on the UFS node; mainline's
gs101 sets those four quirks unconditionally and must not here.

## Bootloader behaviour

- **ABL truncates `boot.img`'s command line.** It cut ours mid-token at
  `fbcon=font:TER16x32,n`, dropped both `console=` entries, and appended its
  own. A module parameter appended there silently never arrives. Put
  parameters on **`vendor_boot`'s `--vendor_cmdline`**, which arrives intact.
- ABL rewrites the DT root compatible to `google,ZUMA PRO`.
- `boot.img`'s ramdisk is ignored; the generic ramdisk lives in `init_boot`,
  and ABL concatenates vendor_kernel_boot, vendor_boot, then init_boot.
- BL2 arms a 60 s cluster watchdog every boot.
- Each watchdog reset burns an A/B retry; at zero the slot is marked
  unbootable. `fastboot --set-active=a` restores it to 3.
- The bootloader leaves the UFS clock path fully running, and leaves USB's
  gates open but its Q-channels disabled and its muxes on the oscillator.
- It fails at USB: `[E] failed to get eUSB revision -62`.

## Conventions on this SoC

	CMU gate enable         bit 21
	QCH enable              bit 0
	user mux CMU_TOP feed   bit 4
	Samsung DIVRATIO        divides by value + 1

A gate register with MANUAL (bit 20) clear is controlled by
ENABLE_AUTOMATIC_CLKGATING (bit 28), not by the CG_VAL bit a gate driver
writes — so a gate driver can appear to work while writing a bit the hardware
ignores. Check the read-back, always.

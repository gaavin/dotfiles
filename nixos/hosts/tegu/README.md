# tegu — Google Pixel 9a (Tensor G4) on mainline NixOS

Status: **it boots.** Mainline Linux 7.3-rc1 runs NixOS 26.11 on a Tensor G4
(`zumapro`) from the phone's own UFS storage, with Plasma Mobile on the panel
and a login prompt on UART.

```
Power mode changed to : FAST series_B G_4 L_2
sd 0:0:0:0: [sda] 31147008 4096-byte logical blocks: (128 GB/119 GiB)
EXT4-fs (sda34): mounted filesystem r/w with ordered data mode
Welcome to NixOS 26.11 (Zokor)!
[  OK  ] Reached target Graphical Interface.
tegu login:
```

Not yet a usable phone: no touch input, no USB, no WLAN, no modem, no GPU.

The "powers off after a few minutes" that this file used to describe was the
cluster watchdog. BL2 arms it for 60 s (`WD: enabled(60s, 1/3)`) and nothing
petted it, so a working system was reset on a timer — `RST_STAT: 0x1 -
CLUSTER0_NONCPU_WDTRESET`. Linux now owns it. Each such reset also burned an
A/B retry, and at zero ABL forces fastboot and marks the slot unbootable;
`fastboot --set-active=a` restores it.

Everything below was established on hardware. Where something is inferred
rather than observed it says so.

## Why this is not a daily driver

Mainline has no Tensor G4 support at all. As of 7.3-rc1 upstream carries device
trees only for the Tensor G1 (`gs101`, Pixel 6). Nobody has posted `zuma` or
`zumapro` support, postmarketOS has no `google-tegu` port, and Mobile NixOS has
no Google phones. Google's own mainline effort skipped to the Pixel 10 and only
reaches a serial shell.

So every hardware description here was reverse-derived from Google's downstream
sources, then tested by booting it.

## What works

| | State |
| --- | --- |
| Boot to userspace | **Yes.** Memory, interrupts, timers, SMP, driver model, initramfs |
| Panel as console | **Yes**, via the bootloader's framebuffer (see below) |
| Our own device tree | **Yes.** Bootloader fills in the real 8 GiB; machine reports as "Google Pixel 9a" |
| Debug UART | **Yes** (`ttySAC0` at `0x10870000`), with a USB-C debug board; read-only |
| Register access from userspace | **Yes**, `/dev/mem` (`STRICT_DEVMEM` deliberately off) |
| Rescue userspace | **Yes**, linked into the kernel image |
| Serial console | **Yes**, with a USB-C debug board (read-only) |
| Storage | **Yes.** UFS at gear 4, 2 lanes; boots from an 11 GB ext4 root |
| Graphical session | **Yes.** Plasma Mobile, on the bootloader's framebuffer |
| Watchdog | **Yes.** BL2 arms a 60 s cluster watchdog; Linux now owns it |
| Touch SPI bus | **Yes.** Loopback echoes at 9.98 MHz. The part itself is unpowered |
| ACPM | **Yes.** Mailbox, SRAM and protocol confirmed; the route to the PMIC |
| Touch input | No — needs the S2MPG14 rails, pinctrl, and a TouchComm driver |
| USB, WLAN, modem, GPU, audio, camera | No |

## The panel console

This predates the UART and is still the fastest signal when the kernel dies
before the serial console comes up.

The bootloader leaves the boot logo scanning out on DECON0 when it jumps to the
kernel. `kernel/zumapro-bootfb.c` reads the DECON window and DPP read-DMA
registers during early boot, works out where the framebuffer is, reserves it,
and registers it as a `simple-framebuffer`. simpledrm binds, fbcon attaches,
and with `console=tty0` the whole boot log lands on the screen.

Measured on hardware:

```
DECON0 window 0 -> DPP read-DMA L0 (0x19900000)
1080x2424, stride 4320, 4 bytes/pixel, BGRA8888, command mode
framebuffer at 0x fac00000
```

**Pixel format.** The bootloader hands over BGRA8888. simplefb has no name for
that channel order, so this tree adds `b8g8r8x8` to its table and reports the
truth; alpha is meaningless for a scanout-only layer and DRM already knows how
to convert into BGRX8888. Do **not** try to fix this by reprogramming the
scanout engine instead: those registers are shadowed and only latch on a frame
boundary, so the writes silently do nothing, and poking a live display engine
mid-boot destabilises it. That mistake cost several boot cycles.

## Serial console

A USB-C debug board gives a read-only UART. This is by far the best instrument
available and everything below it in this section is what had to be done
*without* one.

```sh
picocom -b 115200 /dev/ttyACM0      # or: cat /dev/ttyACM0
```

The kernel writes to it with `console=ttySAC0,115200n8`; `earlycon` works too,
and the bootloader's own log comes out at the same rate. Note the debug board
occupies the USB-C port, so fastboot and UART are not simultaneously
available: flash first, then attach the board and power on. Flashing the
kernel to `boot_a` means the phone boots mainline unattended, which is the
workflow this port now uses.

## Debugging a device with almost no output

This is the part worth reading before changing anything.

**Staged reset probes.** `zumapro_bootfb=<n>` issues a PSCI `SYSTEM_RESET` the
moment boot reaches stage `<n>`. Boot once per stage: a reset means the stage
was reached, a hang means it was not. That turns the single bit this device can
signal into a bisect, and it is what located the device-tree match bug with no
console at all. Stages are listed in the driver.

**The early stripe.** The driver paints a white bar across the top of the panel
as soon as it has found the framebuffer, before any driver exists. If the bar
appears, the kernel started, the parameter ran, the registers read sanely, and
the address is right — even if the kernel dies immediately after.

**ramoops.** The device tree points pstore at Android's window
(`0xfd3ff000`, 2 MiB console). Only readable with root on the Android side,
which is why it was not used here.

**Reading the panel.** Photographing a scrolling console is a poor instrument.
Anything you want to read must be printed *late*, at `KERN_ERR`, or from the
rescue userspace; early messages have always scrolled away by the time the
screen can be photographed.

## Hard-won facts about this device

Things that are not documented anywhere and cost real time to discover:

1. **The bootloader rewrites the device tree's identity.** A stock boot applies
   its dtbo, whose board fragment overwrites the root node with
   `compatible = "google,ZUMA PRO TEGU", "google,ZUMA PRO"` — spaces and
   capitals. Every source file on disk says `google,zumapro`. Code matching on
   the file's value silently never runs.

2. **`boot.img`'s ramdisk is ignored.** On this generation the generic ramdisk
   lives in the separate `init_boot` partition, and that is what the bootloader
   hands the kernel. A `fastboot boot` of your own image runs *Android's* init,
   which aborts immediately because a mainline kernel has no SELinux. The
   initramfs therefore has to be linked into the kernel image
   (`CONFIG_INITRAMFS_SOURCE`, see `initramfs.nix`).

3. **Android's ramdisk is unpacked on top of ours,** and its root turns `/bin`
   into a symlink. Anything in `/bin` can vanish underfoot. Hence `/tegu-bin`
   and `/tegu-init`, names Android does not use.

4. **The kernel image format is lz4 legacy frame,** byte-identical in magic to
   the stock kernel (`02 21 4c 18`). This was verified against the stock image
   rather than guessed.

5. **Adding a USB controller node bootloops the device.** The block is almost
   certainly powered down at hand-off, with no clock or power-domain driver to
   bring it back, so probing it reads dead registers. Check the power state
   from userspace via `/dev/mem` before letting the kernel touch it again.

6. **The bootloader watchdog resets a hung kernel after roughly two minutes,**
   which is easily mistaken for a successful reset. Time your observations.

7. **An interactive shell on `/dev/console` prevents fbcon taking over the
   panel,** leaving the boot splash up with no log. The panel is a log, not a
   terminal.

8. **The bootloader leaves the UFS clock path fully running.** Measured
   2026-09-07 by logging every register before writing it: the CMU_TOP gates
   read `0x00200000`, both CMU_HSI2 user muxes read `0x00000010`, and all six
   leaf gates read `0x00200000` — exactly the values `clk-zumapro-hsi2.c`
   sets. This file previously asserted the opposite, that the bootloader
   "tears the path down", and that false claim survived several rounds of
   debugging because it was written down as though it were measured.

   The evidence behind it was self-inflicted. The leaf gates *were* observed
   reading `0x00000000`, but only because they had been registered without
   `CLK_IS_CRITICAL`, so the clock framework disabled the clocks the
   bootloader had left on. `CLK_IS_CRITICAL` did not undo a teardown by the
   bootloader; it stopped this port performing one.

9. **The bootloader hands over a working UFS.** Its command line includes
   `ufs_pixel_fips140.fips_first_lba=...`, and it reads the kernel off the
   flash immediately before jumping to it. Anything that fails afterwards is
   something Linux does to a working block, not setup that was never done.

10. **A pad name is not a clock domain.** The touch reset line's pad is called
    `XAPC_USI11_RTSn_DI`, and that "USI11" sent this port at a divider in
    CMU_PERIC1 for weeks. The SPI is CMU_HSI0's USI2. A clock provider that
    accepts `clk_set_rate()` and reports the rate back through debugfs proves
    only that software agrees with itself — the stock DTB's `clocks` phandle
    is the authority.

11. **`vendor_boot` must not carry a cmdline.** ABL concatenates boot.img's and
    vendor_boot's, and the last `init=` wins. vendor_boot is the one image
    small enough to reflash alone (24 KB against 18 MB), which makes it
    exactly the image that must not be able to name a closure the rootfs does
    not have. Getting this wrong ends in "Failed to start Find NixOS closure".

12. **`flash.sh`'s vbmeta step fails on this device** — `Failed to find
    AVB_MAGIC at offset: 0` — and under `set -eu` that aborted the script
    *before* `flash userdata`, leaving a new boot.img against an old rootfs.
    It is now non-fatal. Verification is already disabled on an unlocked
    device booting unsigned kernels.

13. **Do not blind-scan an MMIO region.** Sweeping `sysreg_hsi0` with `devmem`
    faulted at +0x0014 and raised a fatal SError at +0x1000. The stock DTS
    declares that node as `reg = <0x11020000 0x10000>`, but that is an
    address-map allocation, not a promise that every word answers. Widen
    dumps across *named* registers, never across an address range.

14. **A successful probe can be completely silent.** Every message in
    `exynos-acpm.c` is an error path, so an empty boot log said nothing about
    whether ACPM worked. `/sys/bus/platform/devices/*/driver` and the
    `gs101-acpm-clk` device answered it in one boot. Check the driver model,
    not the log.

## Layout

| File | Purpose |
| --- | --- |
| `dts/zumapro.dtsi` | SoC: 4×A520 + 3×A720 + 1×X4, PSCI, GIC-v3, arch timer, debug UART, firmware/modem carve-outs, ramoops |
| `dts/zumapro-pixel-common.dtsi` | `chosen`, placeholder memory node (the bootloader patches in the real 8 GiB) |
| `dts/zumapro-tegu.dts` | Board |
| `kernel/zumapro-bootfb.c` | Boot framebuffer adoption, staged reset probes, early stripe |
| `kernel/apply.sh` | Grafts everything below into the kernel tree; fails loudly if an upstream anchor moves |
| `kernel/clk-zumapro-hsi2.c` | CMU_HSI2 clock provider for UFS. Its writes are no-ops (see fact 8); needed so the UFS node can resolve its clocks |
| `kernel/clk-zumapro-hsi0.c` | CMU_HSI0 USI2 divider — the touch SPI's real clock (see fact 10) |
| `kernel/zumapro-ufs-host.py` | Tensor G4 host-controller corrections: PCS `0x202` (the 38.4 MHz reference), PCS RX `0x2f`, and the four quirks the stock tree drops |
| `kernel/zumapro-pmic-dump.c` | Read-only dump of the S2MPG14 register map over ACPM. Never writes; see the file for why that matters |
| `kernel/add-zumapro-wdt.py` | `google,zumapro-wdt`, with no PMU quirks — zumapro's PMU offsets are unverified and gs101's differ |
| `touch-probe.sh` | Boot-time register dump for the touch stack, via `devmem` (never `dd`: arm64 restricts `/dev/mem` `read()` to real memory) |
| `tegu-cmd.sh`, `../../tools/tegu-cmd` | Run a shell command passed on the kernel command line. The write half of the debug loop on a phone with a receive-only UART |
| `kernel/add-zumapro-ufs-phy.py` | Adds the `google,zumapro-ufs-phy` variant: isolation offset, calibration-done register, Tensor G4 PMA table, failure diagnostics |
| `kernel/dump-ufs-clkstop.py` | Diagnostic: prints `HCI_CLKSTOP_CTRL` at calibration time |
| `kernel/keep-boot-phy.py` | Adds `phy_exynos_ufs.keep_boot_phy=1` to skip the PRE_INIT table |
| `kernel.nix` | 7.3-rc1, arm64 defconfig with other SoCs and unused subsystems trimmed |
| `initramfs.nix`, `rescue-init` | Rescue userspace, linked into the kernel image |
| `cross-kernel.nix` | Cross-compiles the kernel from x86_64 instead of emulating |
| `default.nix` | NixOS host (aspirational: needs a root filesystem) |
| `images.nix` | Flashable images and `flash.sh` |

## Building

```sh
cd ~/dotfiles/nixos
nix build .#tegu-images -L
```

From `mina` (x86_64) the kernel cross-compiles natively; the NixOS closure's
small derivations run under emulation, which needs
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.

For bring-up you usually only want the kernel:

```sh
nix build .#tegu-images.kernel
```

## Running it

The device tree must be flashed; `fastboot boot` alone uses the phone's own.
`images.nix` produces a `flash.sh` that writes the full set:

```sh
nix build .#tegu-images
result/flash.sh                   # boot, init_boot, vendor_boot, dtbo, vbmeta
```

### The bring-up loop actually used

For kernel work, only `boot` needs rewriting, and the boot image is just the
lz4 kernel — the ramdisk is linked into it (fact 2), so `mkbootimg` needs
nothing else:

```sh
K=$(nix build .#tegu-images --no-link --print-out-paths)
test -s "$K/Image.lz4" || exit 1          # see below
mkbootimg --kernel "$K/Image.lz4" --header_version 4 \
  --cmdline "console=tty0 console=ttySAC0,115200n8 earlycon zumapro_bootfb \
             fbcon=nodefer clk_ignore_unused pd_ignore_unused panic=0 \
             loglevel=7 no_console_suspend rdinit=/tegu-init" \
  --out boot.img
fastboot flash boot boot.img
```

**Always check the image exists before flashing.** `nix build` prints the
output path it *would* have produced inside its error text, so scraping that
path is not evidence the build succeeded. Two builds were reported as
successful in this port that had in fact failed.

Because the boot image carries the command line, a kernel parameter can be
changed with a `mkbootimg` and a flash — no rebuild. That is how
`phy_exynos_ufs.keep_boot_phy=1` and `clk_zumapro_hsi2.keep_boot_mux=1` are
meant to be tested.

Note the debug board occupies the USB-C port: flash first, then attach it and
power on.

**Android will not boot after this.** It cannot run against this device tree.
Restore with a GrapheneOS factory image.

Recovering a bootloop: hold Power ~15 s, then Volume Down + Power for fastboot.

## Storage: solved

UFS works. The phone boots from it, mounts an 11 GB ext4 root and reaches a
Plasma Mobile session. Getting there took most of this port, and the useful
part is not the fixes but which beliefs turned out to be wrong.

**What actually fixed it.** Tensor G4's M-PHY runs from a 38.4 MHz reference,
selected by PCS attribute `0x202 = 0x22` (`USE_38_4_MHZ` in Google's
`ufs-cal.h`; the 26 MHz alternative is `0x12`). gs101 never writes `0x202` at
all, so mainline left the PHY on the wrong reference and calibration could
never converge. Alongside it: PCS RX `0x2f` is `0x79` here rather than
gs101's `0x69`; the `fixed-prdt-req_list-ocs` quirks the stock tree sets, of
which `UFSHCD_QUIRK_PRDT_BYTE_GRAN` misplaced every response UPIU; Tensor
G4's own hibern8 tables; empty PHY power-mode tables; and no `wait_for_cdr`,
which polls a register this SoC does not have.

**What was believed and was wrong,** each held with confidence at the time:

- That the bootloader tore the UFS clock path down. It does not — it leaves
  every gate running. The evidence was self-inflicted: the gates had been
  registered without `CLK_IS_CRITICAL`, so the clock framework disabled what
  the bootloader had left on. The driver was performing the teardown it
  claimed to be repairing.
- That calibration was failing. It was never starting — a 50 ms window
  watching all 3072 PMA registers showed not one bit move.
- That restoring the reference-clock pin fixed calibration. It was inferred
  from a re-bind that showed no errors, but `phy_init()` skips `ops->init`
  when `init_count` is non-zero, so the re-bound driver was skipping
  calibration silently. Silence was read as success.

## Touch: the SPI bus works, the part is unpowered

The controller is finished and proven. In internal loopback it echoes
`a5 5a 0f f0` byte for byte at 9.98 MHz, so the clock, the datapath and the
FIFOs are all good. A normal transfer completes and returns `00 00 00 00` —
the bus drives, and the part says nothing.

**The bug was the wrong CMU.** `spi@111d0000` is clocked by CMU_HSI0's USI2,
not CMU_PERIC1's USI11. The stock DTB settles it: the node's `clocks` resolve
through Google's `zuma.h` to `VDOUT_CLK_HSI0_USI2_USI` and
`GATE_HSI0_USI2_USI`. "USI11" came from the *pad name* of the touch reset
line, `XAPC_USI11_RTSn_DI` — a label on a pad, not the block behind the
controller.

The old driver looked like it worked: `clk_set_rate()` returned success, the
register changed, debugfs reported 40 MHz. It was software agreeing with
itself against a register belonging to another peripheral. The cost is
visible in `CH_CFG`, read back mid-failure as `0x43` — `CH_HS_EN | RXCH_ON |
TXCH_ON`. `spi-s3c64xx` only sets `CH_HS_EN` at 30 MHz and above, and
`cur_speed` is `clk_get_rate(src_clk) / 4`, so every transfer was configured
for a **100 MHz bit clock against a part rated at 10 MHz**.

Six hypotheses were tested against hardware and refuted before that one:
`ENCLK_ENABLE` (the register is read-only zero, which is what `clk_from_cmu`
means), the USI's `CLKSTOP_ON` (already clear), the PERIC1 gates, `CS_REG`'s
`SIG_INACT`, the USI2 Q-Channel (every QCH in CMU_HSI0 reads `0x2`, including
blocks that plainly work), and clock gating generally. Every finding that
survived came from a dump; no hypothesis did.

**Why the part is silent.** Its rails are S2MPG14 `LDO25M` (DVDD 1.8 V) and
`LDO4M` (AVDD 3.3 V), and nothing enables them — Google's driver turns them on
itself with a 200 ms settle, so nothing before Linux has reason to. It also
explains the one measurement that fitted nothing else: the active-low IRQ on
`gpn0-0` reads 0 even with a pull-up enabled and reading back `0x3`. An idle
input with a pull-up reads 1; an unpowered part clamps it low through its ESD
diodes.

## ACPM works, and the PMIC map does not exist here

ACPM is up on Tensor G4 with mainline's gs101 driver unchanged:

    soc@0:power-management -> exynos-acpm-protocol
    15110000.mailbox       -> exynos-acpm-mbox
    gs101-acpm-clk                (exists)
    devices_deferred              (empty)

That confirms the mailbox at `0x15110000`, IRQ 80, the SRAM at `0x15700000`
and the `0xa000` initdata offset. Note the protocol needed no zumapro
variant: mainline's `ACPM_GS101_INITDATA_BASE` is `0xa000` and zumapro's own
device tree declares `initdata-base = <0xa000>`.

It had to be confirmed from the driver model, not the log. **Every message in
`exynos-acpm.c` is an error path, so a successful probe prints nothing** — a
silent boot is equally consistent with "worked" and "never bound".
`gs101-acpm-clk` is the real signal, since the driver only creates it after a
successful probe.

**The next step is blocked on a register map, not on code.** This phone has
S2MPG14/15; mainline's `sec-acpm.c` knows S2MPG10/11, and no source available
to this port describes S2MPG14 — `google-modules/soc/gs` names it once, in
`exynos-pm.c`, with no table.

Borrowing the driver by declaring `samsung,s2mpg10-pmic` is **not** a harmless
experiment: `sec_pmic_probe()` installs a regmap-irq chip, and regmap-irq
*writes* the interrupt mask registers at probe. On a part whose map differs
those writes land at S2MPG10's offsets inside a live PMIC that controls every
rail on the board, including the ones the phone boots from. Hence
`kernel/zumapro-pmic-dump.c`: it references only `bulk_read`, dumps 64
registers of each access type on both speedy channels, and never writes.

## Next steps, in order

1. **Read S2MPG14's register map** with `zumapro-pmic-dump.c`, compare against
   mainline's S2MPG10 tables, and confirm whether channel 2 / speedy 0 are
   right for this part. Only then write regulator descriptors and enable
   `LDO25M`/`LDO4M`.
2. **A zumapro pinctrl driver.** It blocks two things at once: `sec-acpm`
   requires an interrupt (`platform_get_irq` is mandatory in its probe) and
   gs101 supplies it from a GPIO, and touch needs `irq-gpio = <&gpn0 0>` and
   `reset-gpio = <&gpp1 1>` — currently poked with `devmem` from a shell
   script, which no driver can rely on. Mainline has the Samsung pinctrl
   driver and gs101 bank tables; zumapro needs its own. The stock DTS gives
   the bank lists and their GIC interrupts, and hardware confirms the 0x20
   bank stride; per-bank pin counts are the missing piece.
3. **A `synaptics,tcm-spi` driver.** Absent from mainline in any form — only
   RMI4, a different protocol.

2. **USB.** `usb@11210000`, PHY `@11100000`. Establish the power state from
   userspace first (item 5 above). A gadget serial console ends the
   photograph-the-screen workflow; `USB_G_SERIAL` and `U_SERIAL_CONSOLE` are
   already enabled in the config.
3. **Clocks and power domains, properly.** `clk-zumapro-hsi2.c` covers one
   block and does not model the CMU_TOP mux/divider tree at all. A real
   driver, starting from `drivers/clk/samsung/clk-gs101.c`, is still needed
   for the GPU, touch and USB. Note this is **not** what blocks storage —
   that belief was wrong, see fact 8.
4. **Touch.** Synaptics TouchCom over SPI (`spi@111d0000`, IRQ `gpn0-0`, reset
   `gpp1-1`). No mainline driver exists; Google's is a large out-of-tree module.
   Needs pinctrl and USI/SPI clocks first.
5. **Display proper.** DPU/DSIM plus the `google,gs-tg4a/b/c` panel driver, to
   replace the borrowed bootloader framebuffer.

## Sources

Downstream references used, all fetched at bring-up time:

- GrapheneOS `kernel_devices_google_tegu` — board device tree sources
- GrapheneOS `device_google_tegu-kernels_6.1` — prebuilt DTBs, `dtbo.img`, stock kernel
- AOSP `kernel/google-modules/display/samsung`, branch `android-gs-tegu-6.1-android16` — DECON/DPP register maps (`cal_9865`)

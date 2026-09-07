# tegu — Google Pixel 9a (Tensor G4) on mainline NixOS

Status: **mainline Linux boots on this phone.** 7.3-rc1 comes up on a Tensor G4
(`zumapro`), runs to userspace, and prints its log over UART and on the panel.
There is no root filesystem yet, so it is not a usable system: UFS storage
still fails to bring its link up. See "What works" for the honest boundary and
"Storage" for exactly where that stands.

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
| Storage | Described, probes, **link does not come up**: PHY calibration times out. Cause unknown; see "Storage" |
| USB, WLAN, modem, GPU, touch, audio, camera | No |

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

## Layout

| File | Purpose |
| --- | --- |
| `dts/zumapro.dtsi` | SoC: 4×A520 + 3×A720 + 1×X4, PSCI, GIC-v3, arch timer, debug UART, firmware/modem carve-outs, ramoops |
| `dts/zumapro-pixel-common.dtsi` | `chosen`, placeholder memory node (the bootloader patches in the real 8 GiB) |
| `dts/zumapro-tegu.dts` | Board |
| `kernel/zumapro-bootfb.c` | Boot framebuffer adoption, staged reset probes, early stripe |
| `kernel/apply.sh` | Grafts everything below into the kernel tree; fails loudly if an upstream anchor moves |
| `kernel/clk-zumapro-hsi2.c` | CMU_HSI2 clock provider for UFS. Its writes are no-ops (see fact 8); needed so the UFS node can resolve its clocks |
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

## Next steps, in order

1. **Storage. This is the blocker, and the cause is not yet known.**

       samsung-ufs-phy 13204000.phy: zumapro: failed to get phy cal done -110
       exynos-ufshc 13200000.ufs: link startup failed 1

   Three real bugs were found and fixed on the way here. None of them made
   the link come up, and it is worth being explicit that each was believed to
   be *the* fix at the time:

   - **PHY isolation offset.** Mainline's gs101 data writes PMU `0x3ec8`;
     zumapro's control is `0x3ec0`. Before this the first PHY access raised
     an SError and panicked the kernel. Fixed; necessary, not sufficient.
   - **Calibration-done register.** gs101 polls TRSV `0x338` bit 3. This SoC
     reports in TRSV `0x31d` bit 0 (Google's `PHY_EMB_CAL_WAIT` entry,
     `{0x0000, 0xC74, 0x01, ...}`). Fixed; necessary, not sufficient.
   - **The PMA calibration table was Tensor G1's.** Mainline ships only
     gs101's analogue table. Replaced with this SoC's, transcribed from
     Google's `init_cfg_evt1` and verified entry-for-entry by script.
     Necessary, not sufficient.

   ### What the hardware now says

   Every input to calibration that this port can reach is correct, and
   calibration still never completes:

   | Probe | Reading |
   | --- | --- |
   | PMA register readback | all five sampled registers hold what we wrote (`ok`) |
   | `cal_done` (TRSV `0x31d`) | `0x38` — a live value, but bit 0 never sets |
   | `HCI_CLKSTOP_CTRL` | `0x00000000` — `REFCLK_STOP`, `REFCLKOUT_STOP`, `MPHY_APBCLK_STOP` all clear |
   | `HCI_MISC` | `0x00000d10` — `CLK_CTRL_EN_MASK` cleared, as `ungate_clks` intends |
   | PMU isolation `0x3ec0` | `0x00000001` with `en=0x1` — PHY genuinely un-isolated |
   | Lanes | `rx=2 tx=2` — UniPro answers capability queries |
   | Clock tree | bootloader already had it all running (fact 8) |

   Read together: the PHY's **digital domain is alive and correctly
   addressed**, and the **calibration state machine never starts**. That is
   not a register-programming fault, which is why three rounds of register
   fixes did not move it.

   ### Eliminated, with the evidence

   Recorded so none of this is repeated:

   - *Timeout too short* — Google allows `100 * 40us` = 4 ms; we allow 40 ms.
   - *Missing probe-time setup* — Google's `ufs_cal_init` only stores a
     pointer; it does nothing to the hardware.
   - *Lane iteration differences* — Google skips COMN registers on lane 1
     exactly as mainline does.
   - *M-PHY APB gating around PMA access* — Google only does that under
     `__UFS_CAL_FW__`, a bootloader-only build; the kernel path is plain.
   - *Transcription error in the table* — gs101's own table has the identical
     shape (enter cal, configure, trigger, clear) on register `0x43` with
     `0x10/0x18/0x00` against our `0x50` and `0x08/0x0c/0x00`.
   - *Wrong clocks, or our clock driver breaking them* — fact 8. The
     bootloader's values and ours are identical.
   - *`unipro` region too small* — the driver's highest offset is `0x78c0`;
     we map `0x8000`.
   - *`pll_lock_status`* was quoted as evidence in earlier working notes.
     Disregard it: this SoC's tables contain no `PHY_PLL_WAIT` entry, so
     register `0x1e` is not the PLL status here.

   ### Current hypothesis (untested as of this commit)

   The bootloader hands over a *working* PHY (fact 9). Mainline's first act is
   to overwrite it with a calibration table and wait for a calibration that
   never finishes. **Re-running calibration may itself be the bug** — the
   sequence opens by writing `0x50 = 0x08` to enter calibration mode, which
   plausibly requires a PHY power-cycle the bootloader performed and we do
   not.

   `kernel/keep-boot-phy.py` adds `phy_exynos_ufs.keep_boot_phy=1`, which
   skips the PRE_INIT table and leaves the bootloader's configuration alone.
   The existing wait then answers the question either way:

   - calibration already done → the wait returns immediately and link startup
     continues;
   - not done → it times out and prints `cal_done`'s pristine value, a number
     never yet observed, because every reading so far was taken *after* the
     PHY had been overwritten.

   **This is the next thing to run.** The build was in progress when the
   session ended; nothing in the repository depends on its outcome.

   ### If that fails, in order of promise

   - **Regulators.** `vcc`/`vccq`/`vccq2` are all "assuming enabled" because
     there is no PMIC driver. `vccq` feeds the M-PHY, and a dead analogue rail
     behind a live digital one produces exactly the observed signature. Not
     from scratch: mainline already has `drivers/firmware/samsung/exynos-acpm-pmic.c`
     and the S2MPG10/11 MFD and regulator drivers for this SoC family.
   - **pinctrl.** mainline's gs101 UFS node carries
     `pinctrl-0 = <&ufs_rst_n &ufs_refclk_out>` — device reset and the
     reference-clock pin. Ours has none, because there is no pinctrl driver
     for this SoC.
   - **Host-controller sequence.** Google writes UniPro attributes mainline
     does not (`0x3000`, `0x3001`, `0x4020`, `0x4021`), and uses `0x2f = 0x79`
     where mainline's gs101 uses `0x69`. These affect link startup rather than
     calibration, so they matter only once calibration succeeds.

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

# tegu — Google Pixel 9a (Tensor G4) on mainline NixOS

Status: **mainline Linux boots on this phone.** 7.3-rc1 comes up on a Tensor G4
(`zumapro`), runs to userspace, and prints its log on the panel with no debug
cable. There is no root filesystem yet, so it is not a usable system. See
"What works" for the honest boundary.

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
| Debug UART | **Probes and binds** (`ttySAC0` at `0x10870000`). Untested for output: no cable |
| Register access from userspace | **Yes**, `/dev/mem` (`STRICT_DEVMEM` deliberately off) |
| Rescue userspace | **Yes**, linked into the kernel image |
| Storage, USB, WLAN, modem, GPU, touch, audio, camera | No |

## The panel console

There is no debug cable, so the port needs output that does not depend on one.

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

## Layout

| File | Purpose |
| --- | --- |
| `dts/zumapro.dtsi` | SoC: 4×A520 + 3×A720 + 1×X4, PSCI, GIC-v3, arch timer, debug UART, firmware/modem carve-outs, ramoops |
| `dts/zumapro-pixel-common.dtsi` | `chosen`, placeholder memory node (the bootloader patches in the real 8 GiB) |
| `dts/zumapro-tegu.dts` | Board |
| `kernel/zumapro-bootfb.c` (+ `.patch`) | Boot framebuffer adoption, staged reset probes, early stripe |
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

```sh
fastboot flash vendor_boot        result/vendor_boot.img
fastboot flash vendor_kernel_boot result/vendor_boot.img
fastboot flash dtbo               result/dtbo.img      # empty overlay
fastboot boot                     result/boot.img      # RAM boot, nothing written
```

**Android will not boot after this.** It cannot run against this device tree.
Restore with a GrapheneOS factory image.

Recovering a bootloop: hold Power ~15 s, then Volume Down + Power for fastboot.

## Next steps, in order

1. **Storage.** Add the UFS controller (`ufs@13200000`, sysreg `@13020000`) so a
   root filesystem can mount. Mainline has `samsung,exynos-ufs` with gs101
   support. Blocker: no clock driver, so it likely needs fixed-clock stubs in
   the device tree standing in for the real controller.
2. **USB.** `usb@11210000`, PHY `@11100000`. Establish the power state from
   userspace first (item 5 above). A gadget serial console ends the
   photograph-the-screen workflow; `USB_G_SERIAL` and `U_SERIAL_CONSOLE` are
   already enabled in the config.
3. **Clocks and power domains.** `samsung,zuma-clock` has no mainline driver.
   Start from `drivers/clk/samsung/clk-gs101.c`. This unblocks nearly
   everything else, including the GPU.
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

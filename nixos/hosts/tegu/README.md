# tegu — Google Pixel 9a on mainline NixOS

Status: **bring-up scaffold, untested on hardware.** The first build's goal
is the kernel log on the panel. Nothing else is expected to work yet; see
"What is missing" before assuming anything does.

## Why this is not a daily driver yet

The Pixel 9a uses the Tensor G4 (`zumapro`). As of Linux 7.3-rc1 mainline
carries device trees only for the Tensor G1 (`gs101`, Pixel 6 family);
nobody has posted `zuma`/`zumapro` support, postmarketOS has no `google-tegu`
port, and Mobile NixOS has no Google phones at all. Google's own mainline
effort skipped to the Pixel 10 (Tensor G5, Nov 2025), and even that only
reaches a UART shell with an unreleased bootloader.

So every hardware description here was reverse-derived from the downstream
`android-gs-tegu-6.1` device tree (the `zumapro-a1-*.dtb` and `dtbo.img`
shipped by GrapheneOS) and from Google's downstream display driver.

## Debugging without a serial cable

There is no USB-C debug cable on hand, so the port needs a feedback path
that does not depend on the UART. It has two:

1. **The bootloader's framebuffer.** ABL leaves the boot logo scanning out
   on DECON0 when it jumps to the kernel. `kernel/zumapro-bootfb.c` reads the
   DECON window and DPP read-DMA registers before memory is handed to the
   allocator, reserves the buffer the hardware is scanning from, and
   registers it as a `simple-framebuffer`. simpledrm picks it up, fbcon
   attaches, and with `console=tty0` the kernel log, the initrd emergency
   shell and systemd all end up on the panel. On command-mode panels it also
   unmasks the TE trigger so the screen keeps refreshing. Register offsets
   come from `google-modules/display/samsung` (`cal_9865`).

   What you should see: the boot logo goes away, a penguin and white-on-black
   log lines appear within a few seconds of `fastboot boot`. If the screen
   stays on the logo, the kernel died before the DRM device came up (or the
   framebuffer discovery bailed out; the reason is in the pstore log below).
   If the screen goes black, the display power domain or clocks were gated.

2. **ramoops.** The DT points pstore at the same window Android uses
   (`0xfd3ff000`, 2 MiB console + 2 MiB pmsg), so a crash survives a reset.
   Reboot into the stock kernel and read `/sys/fs/pstore/console-ramoops-0`
   (needs root on the Android side, i.e. a rooted or debug build).

## What is here

| File | Purpose |
| --- | --- |
| `dts/zumapro.dtsi` | SoC: 4xA520 + 3xA720 + 1xX4, PSCI, GIC-v3 @0x10400000, arch timer (24.576 MHz), debug UART @0x10870000 (SPI 641, 200 MHz clock), all firmware/modem/log carve-outs as `no-map`, Android's ramoops window |
| `dts/zumapro-pixel-common.dtsi` | `chosen`/`stdout-path`, placeholder memory node (ABL patches in the real 8 GiB) |
| `dts/zumapro-tegu.dts` | Board: `google,tegu` |
| `kernel/zumapro-bootfb.c` (+ `.patch`) | Boot framebuffer adoption driver described above; applied as a kernel patch so the option survives nixpkgs' config generation |
| `kernel.nix` | Linux 7.3-rc1 from kernel.org, arm64 defconfig with every other SoC off and media/sound/WLAN/ethernet trimmed; simpledrm + fbcon (Terminus 16x32), UFS-Exynos, DWC3-Exynos, pstore-ram built in |
| `cross-kernel.nix` | Swaps in the same kernel cross-compiled from x86_64, used by the `x86_64-linux` package output |
| `default.nix` | NixOS host: root on the `userdata` partition, systemd initrd with emergency shell on the panel, Plasma Mobile + SDDM autologin, NetworkManager, SSH, USB NCM gadget service |
| `images.nix` | `boot.img` / `init_boot.img` / `vendor_boot.img` / `vendor_kernel_boot.img` (header v4, lz4 kernel, NixOS initrd, DTB), empty `dtbo.img`, unverified `vbmeta.img`, ext4 `rootfs.img`, `flash.sh` |

Verified on the build host: the flake evaluates, the kernel `.config`
generates with `ZUMAPRO_BOOTFB`/`DRM_SIMPLEDRM`/`FRAMEBUFFER_CONSOLE`, the
device tree compiles, and the bootfb driver compiles warning-free (`W=1`)
against 7.3-rc1 with the aarch64 cross toolchain.

## What is missing

Requested for the first build were touch, GPU and display. Here is why only
the display (as a dumb framebuffer) made it:

| Subsystem | State | Notes |
| --- | --- | --- |
| Display out | bootloader framebuffer via simpledrm | No mode setting, no brightness, no panel control; whatever ABL configured (1080x2424) stays. Real support needs a DPU/DSIM driver plus the `google,gs-tg4a/b/c` panel driver, none of which exist upstream |
| Touch | none | Synaptics TouchCom over SPI (`synaptics,tcm-spi` on `spi@111d0000`, IRQ `gpn0-0`, reset `gpp1-1`). Mainline has no TouchCom driver (only RMI4, a different protocol); Google's is a large out-of-tree module tied to their touch-offload stack. Also needs the zumapro pinctrl bank table and the USI/SPI clocks |
| GPU | none | Mali G715 (`mali@1f000000`, panthor-class) sits in the `g3d` power domain, which is off at kernel entry and is switched through ACPM firmware. Panthor is built as a module but has no DT node; probing it with the domain off faults the bus |
| UART console | described, untested | Needs a USB-C debug cable (SBU pins, 3.3 V) and `fastboot oem uart enable` |
| Clocks / pinctrl / PMIC (ACPM) | none | `samsung,zuma-clock` has no mainline driver; `clk_ignore_unused` + `pd_ignore_unused` keep bootloader state |
| UFS storage | driver built, no DT node | `ufs@13200000`, sysreg `@13020000`; until it is described `/` cannot mount and stage 1 drops to a shell on the panel |
| USB (DWC3) | driver built, no DT node | `usb@11210000`, PHY `@11100000`; needed for gadget networking and SSH |
| WLAN/BT (bcmdhd4383), modem (S5300/S5400), GNSS | none | downstream-only drivers |
| Audio, camera, NFC, haptics, fingerprint | none | |

## Building

```sh
cd ~/dotfiles/nixos
nix build .#tegu-images -L
ls -l result/
```

From `mina` (x86_64) this cross-compiles the kernel natively and assembles the
images natively; the NixOS closure is fetched from the binary cache and its
~300 small derivations run under QEMU user emulation, which needs
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` switched in first. From
an aarch64 host everything builds natively.

`result/rootfs.img` is the full Plasma Mobile closure; leave it out of a
first panel-only test with `nix build .#tegu-images.kernel` if space is tight.

## Flashing (bootloader unlocked, phone in fastboot)

For the first attempts do not flash at all: `fastboot boot result/boot.img`
runs the kernel once from RAM and a power-cycle brings Android back. Note
that `fastboot boot` uses the DTB and cmdline embedded in the stock
`vendor_boot`, so for the DT to take effect `vendor_boot` has to be flashed.

```sh
result/flash.sh            # boot, init_boot, vendor_boot, vendor_kernel_boot, dtbo, vbmeta
result/flash.sh --rootfs   # additionally writes rootfs.img over userdata (destroys Android data)
```

Restore Android afterwards with a stock factory image (`flash-all.sh`).

## Next steps, in order

1. Boot it. Expected outcome: log on the panel, ending in the initrd
   emergency shell because there is no root device. Photograph the screen.
2. Add the UFS controller + PHY nodes (`ufs@13200000`) so `/` mounts and
   Plasma Mobile starts, rendering through llvmpipe on the same framebuffer.
3. Add DWC3 + USB PHY nodes for NCM networking and SSH; from then on the
   panel is no longer the only console.
4. Port the zumapro pinctrl bank table and the USI/SPI clocks, then either
   port Google's TouchCom driver or write a minimal one against the
   TouchCom protocol so Plasma Mobile gets input.
5. Port the zumapro clock controller (start from `drivers/clk/samsung/clk-gs101.c`)
   and the ACPM power-domain interface; only then is panthor worth wiring up.
6. Display stack proper: DPU/DSIM (downstream `gs-drm`) and the `tg4a/b/c`
   panel driver.

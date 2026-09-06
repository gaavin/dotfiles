# tegu — Google Pixel 9a on mainline NixOS

Status: **bring-up scaffold, untested on hardware.** Expect a UART console at
best. See "What is missing" before assuming anything works.

## Why this is not a daily driver yet

The Pixel 9a uses the Tensor G4 (`zumapro`). As of Linux 7.3-rc1 mainline
carries device trees only for the Tensor G1 (`gs101`, Pixel 6 family);
nobody has posted `zuma`/`zumapro` support, postmarketOS has no `google-tegu`
port, and Mobile NixOS has no Google phones at all. Google's own mainline
effort skipped to the Pixel 10 (Tensor G5, Nov 2025), and even that only
reaches a UART shell with an unreleased bootloader.

So every hardware description here was reverse-derived from the downstream
`android-gs-tegu-6.1` device tree (the `zumapro-a1-*.dtb` shipped by
GrapheneOS) and needs a phone with a serial cable to iterate on.

## What is here

| File | Purpose |
| --- | --- |
| `dts/zumapro.dtsi` | SoC: 4xA520 + 3xA720 + 1xX4, PSCI, GIC-v3 @0x10400000, arch timer (24.576 MHz), debug UART @0x10870000 (SPI 641, 200 MHz clock), all firmware/modem/log carve-outs as `no-map`, Android's ramoops window |
| `dts/zumapro-pixel-common.dtsi` | `chosen`/`stdout-path`, placeholder memory node (ABL patches in the real 8 GiB) |
| `dts/zumapro-tegu.dts` | Board: `google,tegu` |
| `kernel.nix` | Linux 7.3-rc1 from kernel.org, arm64 defconfig with every other SoC off and media/sound/WLAN/ethernet trimmed; UFS-Exynos, DWC3-Exynos, simpledrm, pstore-ram built in |
| `default.nix` | NixOS host: root on the `userdata` partition, systemd initrd with emergency shell, Plasma Mobile + SDDM autologin, NetworkManager, SSH, USB NCM gadget service |
| `images.nix` | `boot.img` / `init_boot.img` / `vendor_boot.img` / `vendor_kernel_boot.img` (header v4, lz4 kernel, NixOS initrd, DTB), empty `dtbo.img`, unverified `vbmeta.img`, ext4 `rootfs.img`, `flash.sh` |

Verified on the build host: the flake evaluates, the kernel `.config`
generates, and the device tree compiles (`dtc`, 29 reserved regions). The
kernel itself has not been compiled yet (see "Building").

## What is missing (all of it needs hardware in hand)

| Subsystem | State | Notes |
| --- | --- | --- |
| UART console | described, untested | Needs a USB-C debug cable (SBU pins, 3.3 V) and `fastboot oem uart enable` |
| Clocks / pinctrl / PMIC (ACPM) | none | `samsung,zuma-clock` has no mainline driver; `clk_ignore_unused` keeps bootloader state |
| UFS storage | driver built, no DT node | Controller/PHY addresses for zumapro still to be lifted from the downstream DTB; until then `/` cannot mount and stage 1 drops to a shell |
| USB (DWC3) | driver built, no DT node | Needed for gadget networking and charging control |
| Display (DPU/DSIM, `google,gs-tg4*` panels) | none | Bootloader does not leave a framebuffer, so not even simpledrm |
| Touch (Synaptics TCM SPI) | none | needs SPI + pinctrl first |
| WLAN/BT (bcmdhd4383), modem (S5300/S5400), GNSS | none | downstream-only drivers |
| GPU (Mali G715, panthor) | none | needs clocks/power domains |
| Audio, camera, NFC, haptics, fingerprint | none | |

## Building

Native `aarch64-linux` only. On `mina` (x86_64) enable
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` and rebuild first; the
kernel then compiles under QEMU user emulation (slow but unattended).

```sh
cd ~/dotfiles/nixos
nix build .#tegu-images -L        # kernel + initrd + rootfs, ~10+ GiB of store
ls -l result/
```

`result/rootfs.img` is the full Plasma Mobile closure; leave it out of a first
UART-only test with `nix build .#tegu-images.kernel` if space is tight.

## Flashing (bootloader unlocked, phone in fastboot)

```sh
result/flash.sh            # boot, init_boot, vendor_boot, vendor_kernel_boot, dtbo, vbmeta
result/flash.sh --rootfs   # additionally writes rootfs.img over userdata (destroys Android data)
```

Restore Android afterwards with a stock factory image (`flash-all.sh`).

## Debugging without a serial cable

The DT points ramoops at the same window Android uses (`0xfd3ff000`, 2 MiB
console + 2 MiB pmsg). If mainline gets as far as the console driver, the
log survives a reset: reboot into the stock kernel and read
`/sys/fs/pstore/console-ramoops-0`.

## Next steps, in order

1. Confirm the earlycon prints on the UART (`earlycon=gs101,mmio32,0x10870000`).
2. Add the UFS controller + PHY nodes from `zumapro-a1-foplp.dts` (downstream) so `/` mounts.
3. Add DWC3 + USB PHY nodes for NCM networking and SSH.
4. Port the zumapro clock controller (start from `drivers/clk/samsung/clk-gs101.c`).
5. Display stack: DPU/DSIM (downstream `gs-drm`) and the `tg4a/b/c` panel driver.

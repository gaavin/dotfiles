# tegu — Google Pixel 9a (Tensor G4) on mainline NixOS

Status: **it boots.** Mainline Linux runs NixOS 26.11 on a Tensor G4
(`zumapro`) from the phone's own UFS storage, with Plasma Mobile on the panel
and a login prompt on UART.

Since 2026-09-09 the kernel is no longer this port's own tree, and since
2026-10-09 it is no longer patched at build time either: both live in a kernel
repository of their own — see [The kernel moved into its own
repository](#the-kernel-moved-into-its-own-repository-2026-10-09). **On its
first boot USB came up**, which had been this port's blocker: `dwc3` probes,
the eUSB2 + USB-DP combo PHY initialises, and the host enumerates
`18d1:4ee1 NixOS Pixel 9a` about 40 s after reset. The touchscreen works on
their `syna_tcm`.

```
Power mode changed to : FAST series_B G_4 L_2
sd 0:0:0:0: [sda] 31147008 4096-byte logical blocks: (128 GB/119 GiB)
EXT4-fs (sda34): mounted filesystem r/w with ordered data mode
Welcome to NixOS 26.11 (Zokor)!
[  OK  ] Reached target Graphical Interface.
tegu login:
```

Not yet a usable phone: no WLAN, no modem, no GPU acceleration, no audio.

The "powers off after a few minutes" that this file used to describe was the
cluster watchdog. BL2 arms it for 60 s (`WD: enabled(60s, 1/3)`) and nothing
petted it, so a working system was reset on a timer — `RST_STAT: 0x1 -
CLUSTER0_NONCPU_WDTRESET`. Linux now owns it. Each such reset also burned an
A/B retry, and at zero ABL forces fastboot and marks the slot unbootable;
`fastboot --set-active=a` restores it.

Everything below was established on hardware. Where something is inferred
rather than observed it says so.

## The kernel moved into its own repository (2026-10-09)

Until now the kernel was always partly assembled at build time: `kernel.nix`
fetched a tree and then ran `kernel/apply.sh` from the Nix build, which
appended a device tree, installed a driver and applied six `.patch` files. The
kernel on the phone therefore existed nowhere as a source tree — not in this
repository, and not in the one it was fetched from.

It now lives in one of its own, [gaavin/linux][kfork], branch `pixel9a`:

- current mainline **`master`** as the base (a torvalds/linux commit whose
  Makefile still reports 7.3.0-rc6), so the repository is standalone and not a
  GitHub fork of anyone;
- the shared zumapro Tensor G4 work — [Trijal08/kernel-mainline][trijal],
  branch `zumapro-google-caimito`, 680 commits — **cherry-picked and rebased
  onto that master commit** so the ancestry is genuine mainline;
- this port's own tegu bring-up as a real commit on top: the board device
  tree, the boot framebuffer driver, the simplefb BGRA/BGRX name, the fuel
  gauge's gate, the BCM4383 support in brcmfmac, the simpledrm damage clip,
  and the board's Kconfig options in `zumapro_defconfig`.

`kernel.nix` now just fetches that repository at a pinned commit. There is no
`apply.sh` and there are no `.patch` files: `kernel/` and `dts/` are gone, and
the kernel a build produces is exactly the kernel in the repository.

That tree independently reached every hardware conclusion this port paid boots
for — PHY isolation at `0x3ec0`, calibration-done at TRSV `0x31d`, no CDR wait,
PCS `0x202 = 0x22` for the 38.4 MHz M-PHY reference, the four quirks the stock
`fixed-prdt-req_list-ocs` property clears, the touchscreen on `spi@111d0000`
with native manual chip select and a 2 µs CS setup delay — and then kept going
where this port had not started: pinctrl and clock drivers for every CMU,
secure power domains, System MMU v9, ACPM TMU thermal zones, cpufreq, MCT v3,
the eUSB2 + USB-DP combo PHY that USB here is blocked on, PCIe, Wi-Fi, and the
exynos9 DECON/DSIM display pipeline. The silicon is the same either way, and
re-deriving any one of those would cost weeks of boots.

The measurements behind each tegu commit are in that commit's message, where
they belong — with the code they explain, not in a script that rewrites the
source underneath them. The old self-contained bring-up kernel — this port's
own `zumapro.dtsi`, the HSI0/HSI2 clock drivers, `zumapro-touch.c`, the UFS
patchers — is still at commit `32c547c` here.

**Booted 2026-09-09, and it came up.** Evidence, all from the build host with
no debug cable attached: the gadget enumerated with the product strings this
repo's `usb-gadget-net` unit writes, which means the flashed closure ran from
UFS and systemd reached `multi-user.target`; and it stayed up for minutes,
which means the cluster watchdog is being petted. Touch was confirmed on the
phone. What was new and therefore at risk, and how it landed:

- **The watchdog is now gs101's variant with the PMU quirks on**
  (`google,gs101-wdt` + `samsung,syscon-phandle`), where this port used a
  variant with no PMU access at all because zumapro's PMU offsets were
  unverified. Theirs writes `CLUSTER0_NONCPU_INT_EN`/`_OUT` at gs101's
  offsets. **Fine:** the phone stayed up well past the 60 s BL2 arms.
- **Memory is described statically** — the low 2 GiB bank in `zumapro.dtsi`
  plus three 2 GiB banks in `zumapro-pixel-common.dtsi`, which is exactly the
  Pixel 9a's 8 GiB — instead of relying on ABL to patch one placeholder node.
- **Every rail on both PMICs is now described**, so `regulator_ignore_unused`
  is on the command line. Without it the regulator framework switches off
  every LDO and buck no driver has claimed, at `late_initcall`, on a phone
  whose panel has no driver.
- **`bootargs` is forced back to empty** by the kernel's
  `arch/arm64/boot/dts/exynos/google/zumapro-tegu-nixos.dtsi`. The shared tree
  puts postmarketOS's arguments there; `images.nix` is the only place this port
  wants the command line to come from.
- **Their defconfig builds the AoC, the Touch Bus Negotiator, the modem and
  GNSS as modules.** Nothing on the boot path needs them, and NixOS carries
  the module tree in the closure, so this is only a note for when audio or
  the negotiator matter.
- **USB was the surprise.** `zumapro-pixel-common.dtsi` enables `usbdrd31`,
  `usbdrd31_dwc3` and `usbdrd31_phy` for every board, so the flash that tested
  the base swap also tested the PHY this port had spent a session narrowing
  down — and it works. Their CMU_HSI0 USB gate offsets are the gs101 ones
  `notes/UPSTREAM.md` had dismissed as transplanted; the hardware says the
  addresses are right.

[trijal]: https://github.com/Trijal08/kernel-mainline/commits/zumapro-google-caimito/
[kfork]: https://github.com/gaavin/linux

## Why this is not a daily driver

Mainline has no Tensor G4 support at all: as of v7.3-rc6 upstream carries device
trees only for the Tensor G1 (`gs101`, Pixel 6), nothing has been posted for
`zuma` or `zumapro`, and Mobile NixOS has no Google phones. Google's own
mainline effort skipped to the Pixel 10 and only reaches a serial shell.

Out of tree, two community trees do carry this SoC —
[Trijal08/kernel-mainline][trijal] (whose zumapro work this port's kernel
rebases onto mainline v7.3-rc6, aimed at the Pixel 9 family, with postmarketOS
packaging) and
[zumapro-mainline/linux](https://github.com/zumapro-mainline/linux) — and
between them most of the SoC is described. None of it is upstream, none of it
is a phone you would carry, and the Pixel 9a is the least-tested board in
either.

So every hardware description here was reverse-derived from Google's downstream
sources, then tested by booting it.

## What works

| | State |
| --- | --- |
| Boot to userspace | **Yes.** Memory, interrupts, timers, SMP, driver model, initramfs |
| Panel as console | **Yes**, via the bootloader's framebuffer (see below) |
| Device tree | The shared tree's `zumapro.dtsi` + `zumapro-tegu.dts`, with this port's board deltas on top; machine reports as "Pixel 9a" |
| Debug UART | **Yes** (`ttySAC0` at `0x10870000`), with a USB-C debug board; read-only |
| Register access from userspace | **Yes**, `/dev/mem` (`STRICT_DEVMEM` deliberately off) |
| Rescue userspace | **Yes**, linked into the kernel image |
| Serial console | **Yes**, with a USB-C debug board (read-only) |
| Storage | **Yes.** UFS at gear 4, 2 lanes; boots from an 11 GB ext4 root |
| Graphical session | **Yes.** Plasma Mobile, on the bootloader's framebuffer |
| Watchdog | **Yes.** BL2 arms a 60 s cluster watchdog; Linux now owns it |
| Touch SPI bus | **Yes.** Loopback echoes at 9.98 MHz |
| ACPM | **Yes.** Mailbox, SRAM and protocol confirmed; the route to the PMIC |
| S2MPG14 rails | **Yes.** `LDO4M` and `LDO25M` enabled over ACPM, verified by reading the enable bit back from the PMIC |
| Touch input | **Yes**, now on the shared tree's `syna_tcm` over an s3c64xx that holds a native chip select across the whole message |
| USB | **Yes**, first boot of the shared tree, 2026-09-09. A UDC exists, the NCM gadget binds, and the host sees `18d1:4ee1`. `ssh max@10.42.0.1` over the USB-C port replaces the reflash-per-question loop |
| USB serial console | **Yes**, 2026-09-10. An `acm.GS0` function beside the NCM one gives `/dev/ttyGS0` on the phone and `/dev/ttyACM0` on the host, with a getty on it — the first channel that can carry a keystroke *in*, which the UART cannot |
| WLAN (Broadcom BCM4383) | **Half there.** The part is identified, the driver now knows it, and the vendor firmware boots the dongle — but the host<->dongle msgbuf path over PCIe does not work yet, so no `wlan0`. See "Wi-Fi" below |
| Modem, GPU, audio, camera | No. Drivers for all of them are in the shared tree, aimed at the Pixel 9 boards, and none of it is enabled for tegu yet |

## The panel console

This predates the UART and is still the fastest signal when the kernel dies
before the serial console comes up.

The bootloader leaves the boot logo scanning out on DECON0 when it jumps to the
kernel. The kernel repository's `drivers/video/zumapro-bootfb.c` reads the
DECON window and DPP read-DMA registers during early boot, works out where the
framebuffer is, reserves it, and registers it as a `simple-framebuffer`.
simpledrm binds, fbcon attaches, and with `console=tty0` the whole boot log
lands on the screen.

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

5. **Adding a USB controller node does not bootloop the device.** This entry
   used to say it did, and that the block was powered down at hand-off with no
   driver to bring it back, so dwc3 read dead registers. Every part of that is
   false, and it went unchecked for months because it was written from one
   observation and a plausible story. Measured 2026-09-09: a bare `snps,dwc3`
   node at `0x11210000` boots to a graphical target, `pd-hsi0` STATUS
   (`0x15462a84` bit 0) reads 1, and dwc3 writes `DCTL.CSFTRST` and polls it —
   so the registers answer. What actually fails is the soft reset, because
   `dwc3_core_soft_reset()` needs `phy_init()` first and there is no PHY yet.
   The original bootloop was real; its cause was never established.

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

15. **A GPIO bank dump is CON, DAT, PUD, DRV — in that order.** The touch
    IRQ `gpn0-0` was read as idling high, and this file briefly said the part
    had come alive, because the `0x00000001` in a bank's dump row was taken
    for DAT when it is PUD. `gpn0` DAT has read 0 in every measurement of
    this port, including through a pull-up that reads back as enabled.

    That reading is *ambiguous*, which is the actual lesson: 0 on an
    active-low ATTN is what an asserted interrupt looks like and equally what
    an unpowered part clamping through its ESD diodes looks like. `gpn3`, one
    bank along, reads 1, so the block and the reads are sound. The line
    cannot settle the question on its own and the driver no longer pretends
    it can.

16. **`find` lies in a sparse checkout.** `soc-gs` is cloned sparse and
    blobless, so files that exist in the repository are absent from the
    working tree. An empty `find` was read here as "no source describes
    S2MPG14" and used to justify reverse-engineering a register map;
    `git ls-tree -r HEAD --name-only` listed `s2mpg14-register.h` and three
    more files that had been there all along. It mattered: mainline's S2MPG10
    map puts `LDO4M` at `0x43`, which on S2MPG14 is `LDO25M`, so the guess
    would have powered the wrong rail from the wrong voltage group and looked
    like partial success.

## Layout

| File | Purpose |
| --- | --- |
| `kernel.nix` | Points at the port's kernel fork (pinned commit), its `zumapro_defconfig`, and the NixOS/bring-up config on top |
| `initramfs.nix`, `rescue-init` | Rescue userspace, linked into the kernel image |
| `cross-kernel.nix` | Cross-compiles the kernel from x86_64 instead of emulating |
| `default.nix` | NixOS host: root on the phone's `userdata`, Plasma Mobile, the kernel command line |
| `images.nix` | Flashable images and `flash.sh` |
| `notes/HARDWARE.md` | Every address, offset and measured value this port established, in one place — including the gs101 values that turned out wrong and what they should be |
| `notes/UPSTREAM.md` | The community trees: what each got right, and the traps in taking a gs101 name for a zumapro register |
| `notes/HANDOVER.md`, `notes/HANDOVER-PROMPT.md` | Briefing for picking this up cold, and the prompt to hand a new session |
| `notes/s2mpg14-dump.txt` | The live PMIC dump, and how the vendor map was matched against it |
| `touch-probe.sh`, `spi-*.sh` | Bring-up probes over `devmem` (never `dd`: arm64 restricts `/dev/mem` `read()` to real memory). All written against this port's own touch driver, which the shared tree's `syna_tcm` replaces — kept for the register maps in them |
| `tegu-cmd.sh`, `../../tools/tegu-cmd` | Run a shell command passed on the kernel command line. The write half of the debug loop on a phone with a receive-only UART |
| `uart-capture.py` | Capture the UART to a file, tolerating the characters it drops |

The kernel pieces that used to sit here — `kernel/apply.sh`, the six
`kernel/*.patch` files, `kernel/zumapro-bootfb.c`, `kernel/check.sh` and
`dts/zumapro-tegu-nixos.dtsi` — moved into the port's kernel repository
([gaavin/linux][kfork], branch `pixel9a`) as real commits; see [The kernel
moved into its own repository](#the-kernel-moved-into-its-own-repository-2026-10-09).
`check.sh` has no counterpart there: it existed to compile a driver that lived
outside the kernel against a kernel in the store, and the driver now lives in
the tree, so the kernel build is the check.

Gone with the base swap, and recoverable from commit `32c547c`: this port's
`zumapro.dtsi` and board files, `clk-zumapro-hsi0.c`, `clk-zumapro-hsi2.c`,
`zuma-pinctrl-data.c`, `zumapro-touch.c`, `zumapro-pmic-dump.c`,
`zumapro-ufs-restore.c`, the S2MPG14 regulator patcher, and the seven UFS
patchers and diagnostics. The shared tree has a better version of every one.

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
FASTBOOT_SERIAL=59201JEBF29944 result/flash.sh --rootfs
```

`flash.sh` **does not reboot** unless you pass `--reboot`. Set
`FASTBOOT_SERIAL` whenever more than one Android device is attached: fastboot
with no serial picks one for you, and this port has already aimed a flash at
a second Google phone that happened to be plugged in.

Pass `--rootfs` whenever the closure changes. `boot.img` names the closure it
expects, so a boot image flashed without its matching rootfs drops the phone
into an emergency shell.

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

## Touch: the part answers

The part is a Synaptics **S3908**, firmware `GA1B0-15.0`, TouchComm **v1**,
mode 1 (`MODE_APPLICATION_FIRMWARE`). It says so itself, in one read:

	a5 10 18 00 01 01 "S3908GA1B0-15.0\0" 62 2f 44 00 00 04 5a

Header, version, mode, part number, build id, max write size, end-of-message.
It now also answers commands, reports its own touch-report layout, and streams
`REPORT_TOUCH` frames that decode to coordinates on `/dev/input`.

**Chip select was why commands did nothing.** Not MOSI, not the clock, not the
rails -- all of those were already proven. A command's frame never closed, so
the part never saw a complete write. The fix is `spi_setup()` either side of
every command, which is heavier than it looks and is load-bearing on both
sides:

	s3c64xx_spi_setup()
	  -> pm_runtime_get_sync()      forces a resume
	    -> s3c64xx_spi_hwinit()     releases CS, and zeroes cur_speed
	      -> next transfer runs s3c64xx_spi_config() instead of skipping it

`s3c64xx_spi_transfer_one()` skips `s3c64xx_spi_config()` whenever speed and
bits-per-word are unchanged, so without the zeroed `cur_speed` the controller
is never reprogrammed. A bare CS pulse instead of `spi_setup()` gets framing
but answers `STATUS_IDLE`; dropping the call *after* the write leaves the part
not driving MISO at all. Both halves were measured, in `spi-replicate-probe.sh`.

**ATTN does not mean "a message is waiting".** It was believed to, and that
belief cost the report config: `CMD_IDENTIFY` was answered and
`CMD_GET_TOUCH_REPORT_CONFIG` was not, purely by luck of timing. The line drops
as soon as a read starts consuming a message while the rest is still queued, it
sits high on a wedged part with nothing to say, and it is meaningless in the
window after reset. The boot that captured 1086 `REPORT_TOUCH` frames sampled
it low throughout. So the driver reads on a timer and looks for the marker,
which is what every measured success has done. A read costs clock cycles and
nothing else.

**Drain before a command, on the part's padding rather than on ATTN.** Writing
into the middle of a message is the one thing known to destroy the exchange;
`0x5a` padding is the part saying it has nothing more.

**The first command after a boot is never answered.** Three times over, with a
warm-up, with a delay, with and without a controller re-init -- while identical
later ones are answered. It is not understood. The driver spends a throwaway
`CMD_IDENTIFY` on it rather than letting it eat a real request.

**`CMD_GET_APPLICATION_INFO` is not sent.** It has never answered on this part,
and an unanswered command is not free -- three take it from talking to driving
MISO low. It carries sensor dimensions and object count, and Google's own
`goog,display-resolution = <1080 2424>` already covers both.

**A message is one transfer, and it must fit under the FIFO.** Reading the
4-byte header and coming back for the rest loses exactly 4 bytes, because
`s3c64xx_spi_transfer_one()` calls `s3c64xx_flush_fifo()` after every transfer
and that drains the RX FIFO. A transfer of `fifo_depth` (64) or more is split
into `fifo_depth - 1` chunks, each its own datapath enable -- the same boundary,
now inside the message. So a single read is 60 bytes and a longer message is
finished with **continued reads**: further reads whose first two bytes are the
marker and `STATUS_CONTINUED_READ`, as `syna_tcm_v1_continued_read()` does. The
128-byte touch report config takes the first read plus two chunks, 60 bytes and
17, and arrives whole — measured on the phone.

**A chunk needs the same `spi_setup()` a command does.** Without it every chunk
answers `0x5a` padding instead of `a5 03`, exactly as a command answers nothing
without it: this controller does not close the frame between two `spi_sync()`
calls on its own. That one call is the difference between 56 bytes and 128.

The first build to attempt continued reads had it wrong in a way worth
recording: it returned the continuation's error instead of the 56 bytes it
already held, which turned a working truncation into `no touch report config
(-110); reports stay raw`. The prefix is now the fallback, and the driver gives
up on continuations after one failure rather than retrying every long message.

**Reads must not transmit.** tegu sets `synaptics,spi-byte-delay-us = <0>`, so
Google's read is `syna_spi_read()`'s `tx_buf = NULL` branch; `spi-s3c64xx` sets
`CH_TXCH_ON` only for a non-NULL `tx_buf` and never asks for a dummy buffer, so
MOSI is undriven for a whole read. Every MOSI byte is a command byte here, and
driving 0xff through reads is what left the part mute in earlier logs.

Two suspects are retired. `FB_CLK_SEL` is not one: Google's `controller-data`
sets `samsung,spi-feedback-delay = <0>`, mainline's default. And the ATTN line
is electrically sound -- `gpn0` PUD reads 0, forcing a pull-*up* still read low
(so the part drives it) -- it simply does not carry the meaning it was given.

### The bug before this one: the wrong CMU

`spi@111d0000` is clocked by CMU_HSI0's USI2, not CMU_PERIC1's USI11. The stock
DTB settles it: the node's `clocks` resolve through Google's `zuma.h` to
`VDOUT_CLK_HSI0_USI2_USI` and `GATE_HSI0_USI2_USI`. "USI11" came from the *pad
name* of the touch reset line, `XAPC_USI11_RTSn_DI` — a label on a pad, not the
block behind the controller.

The old driver looked like it worked: `clk_set_rate()` returned success, the
register changed, debugfs reported 40 MHz. It was software agreeing with itself
against a register belonging to another peripheral. The cost shows in `CH_CFG`,
read back mid-failure as `0x43` — `CH_HS_EN | RXCH_ON | TXCH_ON`.
`spi-s3c64xx` only sets `CH_HS_EN` at 30 MHz and above, and `cur_speed` is
`clk_get_rate(src_clk) / 4`, so every transfer was configured for a **100 MHz
bit clock against a part rated at 10 MHz**.

Six hypotheses were tested against hardware and refuted before that one:
`ENCLK_ENABLE` (the register is read-only zero, which is what `clk_from_cmu`
means), the USI's `CLKSTOP_ON` (already clear), the PERIC1 gates, `CS_REG`'s
`SIG_INACT`, the USI2 Q-Channel (every QCH in CMU_HSI0 reads `0x2`, including
blocks that plainly work), and clock gating generally. Every finding that
survived came from a dump; no hypothesis did.

**It was also unpowered.** Its rails are S2MPG14 `LDO4M` (AVDD 3.3 V, reg
`0x2E`) and `LDO25M` (DVDD 1.8 V, reg `0x43`), enable at `BIT(7)` — a single
bit for both, confirmed against Google's own descriptors, not the two-bit 7:6
field some other rails use. Nothing turns them on before Linux. Mainline's
`sec-acpm` now does it, and ATTN going high as they come up is the measurement
that proves it.


## ACPM works, and the PMIC map was in the vendor tree all along

ACPM is up on Tensor G4 with mainline's gs101 driver unchanged:

    soc@0:power-management -> exynos-acpm-protocol
    15110000.mailbox       -> exynos-acpm-mbox
    gs101-acpm-clk                (exists)
    devices_deferred              (empty)

That confirms the mailbox at `0x15110000`, IRQ 80, the SRAM at `0x15700000`
and the `0xa000` initdata offset. The protocol needed no zumapro variant:
mainline's `ACPM_GS101_INITDATA_BASE` is `0xa000` and zumapro's own device
tree declares `initdata-base = <0xa000>`.

It had to be confirmed from the driver model, not the log. **Every message in
`exynos-acpm.c` is an error path, so a successful probe prints nothing** — a
silent boot is equally consistent with "worked" and "never bound".
`gs101-acpm-clk` is the real signal, since the driver only creates it after a
successful probe.

**This README previously said no source available here described S2MPG14.
That was wrong**, and it is worth recording why. `soc-gs` is a *sparse,
blobless* checkout: `find` shows an empty tree while the repository holds the
files. `git ls-tree -r HEAD --name-only` turns up `s2mpg14-register.h`,
`s2mpg14-regulator.c`, `s2mpg14-core.c` and `rtc-s2mpg14.c`, and they had
been there the whole time. Look for the vendor's own source, and look
properly, before reverse-engineering anything on this SoC.

Reading the map mattered more than it looks. Mainline's S2MPG10 layout puts
`LDO4M` at `0x43`; on S2MPG14 that address is **`LDO25M`**. Enabling "AVDD"
by analogy would have switched on DVDD at a voltage taken from the wrong
group — and it would have looked like partial success. That is also why
`kernel/zumapro-pmic-dump.c` exists and only ever calls `bulk_read`:
borrowing `sec-acpm.c` by declaring `samsung,s2mpg10-pmic` is not a harmless
experiment, because `sec_pmic_probe()` installs a regmap-irq chip and
regmap-irq *writes* the mask registers at probe, inside a live PMIC that owns
every rail on the board.

The driver here is deliberately not `sec-acpm.c`: it talks to ACPM directly,
so it needs no interrupt (there is no pinctrl driver to supply one) and it
cannot write an S2MPG10 offset by accident.

## Wi-Fi: the part is a BCM4383, and it boots

The Wi-Fi side of this board is Broadcom's **BCM4383**, on PCIe channel 1. The
shared tree's note ("tegu uses a different part") is right: its device table
carries `0x4438` for the 4390 the other Zumapro boards use, and this board
enumerates as `14e4:4449` and reports chipcommon ID `0x4383`. Mainline had
never heard of either number, so the tegu commit in [gaavin/linux][kfork] adds
all of it to brcmfmac
(`drivers/net/wireless/broadcom/brcm80211/brcmfmac/`), taken from Google's own
driver for this part (`kernel/google-modules/wlan/bcmdhd/bcm4383`):

| what | value | where the vendor keeps it |
| --- | --- | --- |
| chip common ID | `0x4383` | `BCM4383_CHIP_ID`, `include/bcmdevs.h` |
| PCIe endpoint | `0x4449` | `BCM4383_D11AX_ID`, `include/bcmdevs.h` |
| CR4 RAM base | `0x6e0000` | `CR4_4383_RAM_BASE`, `include/sbchipc.h` |

plus the firmware mapping for the blob in `./wifi-firmware/`, which is the
vendor image's `fw_bcmdhd.bin` renamed (see that directory's README). The
device tree side is a PCIe node of this port's own, with the PERST/reg-on/wake
GPIOs the vendor node drives; without `reset-gpios` the host driver refuses to
probe, and the link then trains at Gen 2 x1.

That much works, and the boot log shows it:

    pci 0000:01:00.0: [14e4:4449] type 00 class 0x028000 PCIe Endpoint
    brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac4383a3-pcie for chip BCM4383/2
    brcmf_chip_get_raminfo RAM: base=0x6e0000 size=2228224 (0x220000)
    CONSOLE: RTE (PCIE-MSGBUF) 20.25.929.104.5 (ge373607) on BCM4383 r2
    CONSOLE: wl0: Broadcom BCM4383 802.11 Wireless Controller 20.25.929.104.5
    CONSOLE: ThreadX v5.6 initialized

So the firmware is the right one, the RAM base is right, and the dongle boots
far enough to attach both radios. What it does *not* survive is the next step:
as soon as the host starts feeding the msgbuf rings, the dongle traps.

### Where it stops, and how it was measured

    brcmf_pcie_init_ringbuffers Using host memory indices
    brcmf_pcie_ring_mb_write_wptr W w_ptr 8 (0), ring 0
    CONSOLE: err check: core 0x1810a000, error 2, axi id 0x10001, addr(0x00000000:00819fe8)
    CONSOLE: AXI timeout
    CONSOLE: TRAP 4(8f7ed0): pc 72b34a, lr 72b33d, sp 8f7f28
    brcmf_pcie_handle_mb_data D2H_MB_DATA: FW HALT

The dongle halts on its own AXI bus timeout, at a different address each probe
(`0x8196b0`, `0x819fe8`, `0x81b380`, `0x83581c`), and the host gets PCIe AER
completion aborts at the same time. `msgbuf` is a *shared memory* protocol: the
rings live in host RAM and the dongle DMAs into them, so this is the
device->host direction failing, not the firmware.

What has been ruled out since, by driving BAR1 from userspace: the device is
unbound, so `setpci -s 01:00.0 0x84.l=00800000` (the window register) plus
`devmem 0x60000000+off` reaches the dongle's RAM directly, `/dev/mem` being
open on this port.

* **The window mechanism is fine.** With the window at `0x800000`, offsets
  `0..0xfffff` read back as ordinary memory and `0x100000` and up read
  `0xffffffff`: the mapping really is `window + offset`, and the RAM really is
  `0x6e0000-0x8fffff`. The shared tree's BAR1 window sliding, and the RAM size
  the driver computes, are both correct -- and every address the dongle traps
  on (`0x8196b0`, `0x819fe8`, `0x81b380`, `0x83581c`) is inside backed RAM, so
  it is not a memory hole either.
* **REFUTED 2026-10-09.** That leaves the **other** direction. The dongle is not failing to reach its
  own memory; it is failing when it goes out to host memory, which is exactly
  what msgbuf needs: the ring and index buffers the host publishes are *64-bit
  coherent allocations* (measured `h2d_w_idx_hostaddr = 0x91e0aa000`, ring at
  `0x91e0ac000`). The PCIe node has no `dma-ranges` and no `iommus` property at
  all, so nothing describes how a device-initiated access reaches DRAM. The
  vendor driver configures that itself (its node has an `"ia"` register region,
  `use-ia`/`use-sysmmu` flags, and a `samsung,pcie-sysmmu` at `131c0000` that
  stock Android leaves disabled); mainline's `pci-exynos.c` does neither.

Two of those candidates have since been tested, with the DMA knobs the tegu
commit adds to brcmfmac
(`drivers/net/wireless/broadcom/brcm80211/brcmfmac/pcie.c`). Both knobs are
read at probe time, so each run is "write the parameter, re-bind the PCI
device" over ssh:

| `dma_mask_bits` | `force_tcm_idx` | result |
| --- | --- | --- |
| 64 | 0 | the original failure (AXI timeout on the first command) |
| 32 | 0 | **identical** -- so the buffers' address range is not it |
| 64 | 1 | **two commands further**: revision info and the CLM blob now succeed, then `Retrieving cur_etheraddr failed, -5` and the same trap |

`force_tcm_idx` skips `BRCMF_PCIE_SHARED_DMA_INDEX`, i.e. it keeps the ring
*indices* in dongle RAM instead of host RAM. That the driver gets further
without them says the dongle *can* read the ring items out of host memory --
it is the host-resident index feature that breaks first. A write/read-back
sweep of the whole range from userspace (34 addresses at 64 KiB steps, windows
`0x400000` and `0x800000`) also finds no hole, so every address the dongle
traps on is writable through BAR1. **REFUTED 2026-10-09** -- see "Corrected
diagnosis" below. The vendor's own WLAN node has no `dma-ranges`, no `iommus`
and no `"ia"` register region, and the access that dies is a *host-initiated*
read of dongle RAM, not a device-initiated access to a host address.

The devcoredump (`/sys/class/devcoredump/devcdN/data`, the raw 2.2 MB of
dongle RAM at `rambase`) is what made this readable: the real shared-info
block, the ring info and the published host addresses can all be pulled out of
it with a little Python.

### Corrected diagnosis, 2026-10-09: it is a host read, and the vendor DT describes no DMA either

Both claims above were wrong, and each one sent a session down a path that
could not pay off, so they are worth spelling out.

**The vendor's WLAN node has no missing DMA description.** The factory dtbo
carries the WLAN's own overlay -- fragment@54, the one with `pcie,wlan-gpio` --
and the base DTB's `pcie@13120000` (this board's Wi-Fi channel) reads:

    ranges = <0x82000000 0x00 0x60000000 0x60000000 0x00 0xff0000>;
    reg-names = "elbi", "dbi", "config";
    wlan-reg-on-gpios / host-wake-gpios / device-wake-gpios
    max-link-speed = <0x02>;

`dma-ranges` is absent, `iommus` is absent, and there is no `"ia"` register
region among the `reg-names`. The `use-ia` / `use-sysmmu` strings are DT
*property names*, and the overlay sets both of them to `"false"`:

    fragment@54 { status = "okay"; num-lanes = <0x01>;
                  use-sicd = "true"; use-ia = "false"; use-l1ss = "true";
                  use-msi = "true"; use-sysmmu = "false";
                  max-link-speed = <0x03>; ep-device-type = <0x01>;
                  pcie,wlan-gpio = <0xffffffff 0x04 0x01>; };

So stock Android does not describe device->host DMA for this board either, the
`"ia"`+BAR2 lead is dead, and neither is the `samsung,pcie-sysmmu` at
`131c0000` (which the vendor's driver only enables behind `use_sysmmu`). Read
from Google's own `pcie-exynos-rc.c`
(`kernel/google-modules/soc/gs`, `android-gs-tegu-6.1-android16`): `use-ia`
gates `exynos_pcie_rc_use_ia()`, `use-sysmmu` gates `pcie_sysmmu_enable()`,
`use-sicd` is only `exynos_update_ip_idle_status()` CPU-idle bookkeeping, and
every `EP_BCM_WIFI`-specific hook in that driver is gated on
`s2mpu || use_sysmmu` -- both false here.

**The access that dies is a host *read* of dongle RAM.** With the UART board
attached, the kernel prints the endpoint's own AER header log instead of
having to dig it out of the dongle's console buffer:

    brcmfmac 0000:01:00.0: [15] CmpltAbrt | Completer | Transaction Layer (First)
    brcmfmac 0000:01:00.0: AER: TLP Header: 0x00000001 0x0000000f 0x6006aabc 0x00000000

`0x00000001` is Fmt `000` / type `00000` / length 1 -- a 3DW **Memory Read**
-- at `0x6006aabc`. With the BAR1 window at `0x800000` that is dongle
backplane `0x86aabc`, exactly the address the dongle's own console names
(`addr(0x00000000:0086aabc)`, `AXI timeout`). So the dongle, as *completer*,
aborts a read the host made of its RAM, because the AXI read behind it timed
out. Seen so far at `0x8196b0`, `0x819fe8`, `0x81b380`, `0x83581c`, `0x850090`
and `0x86aabc` -- always past the end of the firmware image (`0x6e0000 +
0x136c3d = 0x816c3d`), and never the same address twice.

**And the address is backed, so it is not a hole, a window bug or a size bug.**
With the window at `0x800000`, `devmem 0x60050090` reads `0x00000010` and
`0x900000` and up read `0xffffffff`, so RAM really does run to `0x900000`;
BAR1 is 4 MB (Region 2 at `0x60000000`), so `tcm_size = bar1_size = 0x400000`
and `brcmf_pcie_tcm_addr()`'s `win = mem_offset & ~(tcm_size - 1)` arithmetic
is right; the window register reads back `0x00800000`, the value the TLP
address implies; and the driver's own sentinel read at `rambase + ramsize - 4`
(`0x8ffffc`) *succeeds while the firmware is running*. What changes is not the
address but the dongle's state: its backplane answers while the firmware is
halted and stops answering once the firmware is up.

**How not to measure it.** Poking that range from userspace is not safe. A
`devmem` *read* at `0x850090` is fine, but a `devmem` *write* there took the
whole phone down -- USB gadget gone, SSH unreachable, console silent -- and a
later `setpci` read of the RC's DBI at `0x1a0`/`0xb44` appears to have done the
same. Use the UART for anything in that range, and prefer the driver's own
paths to hand-rolled MMIO.

**Separately: the console panics the phone, and it is not the MMIO.** Two
"hangs" during this work turned out to be a panic that fires once the console
draws after userspace is up -- which is exactly what logging in does:

    memcpy_toio+0x44/0xc0 (P)
    drm_fb_xrgb8888_to_bgrx8888+0x64/0xb0
    drm_sysfb_plane_helper_atomic_update+0x160/0x1a0
    drm_atomic_helper_commit_planes+0x100/0x340
    drm_atomic_helper_commit_tail+0x74/0xf0
    commit_tail+0x13c/0x1b0
    commit_work+0x1c/0x30
    Code: 8b060006 aa0103e4 aa0003e3 f8408485 (f9000065)
    Kernel panic - not syncing: Oops: Fatal exception

`drm_sysfb_plane_helper_atomic_update()` is this port's own path --
`drivers/video/zumapro-bootfb.c` in the kernel repository reserves the
bootloader's buffer and hands it to simpledrm -- so that fault is a *store into
the framebuffer*, not into dongle
RAM, and it is a different bug from the Wi-Fi one. It is also what made the
UART console go silent minutes into both earlier sessions.

**Root-caused 2026-10-09.** The panic is a *fault address*, and it came out of
boot -1's persisted journal rather than the console. Note `panic=0` means the
phone does not reboot itself, but the watchdog does, so the boot after the
panic has that boot's journal in `/var/log/journal`:

    Unable to handle kernel paging request at virtual address ffff8000829fd000
      ESR = 0x0000000096000047   EC = 0x25 DABT   WnR = 1
      FSC = 0x07: level 3 translation fault
    [ffff8000829fd000] pgd=0 p4d=...403 pud=...403 pmd=...403 pte=0

So it is a **store** into a page with no PTE. `/proc/vmallocinfo` says which
page -- and the answer is not the dongle:

    ffff800082000000-ffff8000829fe000  10477568  ioremap  phys=0x00000000fac00000

That is the bootloader framebuffer this port maps (`BOOTFB ... 1080x2424
stride=4320 bpp=4 base=0x00000000fac00000 as=b8g8r8x8`, printed at boot), and
`ffff8000829fd000` is the last page of the mapping -- the guard page one past
the end, which is exactly where a blit that runs one row too far lands.

The one-row-too-far comes from `drivers/gpu/drm/sysfb/drm_sysfb_modeset.c`
being pristine upstream and its plane update mixing two rects:

    struct drm_rect dst_clip = plane_state->dst;
    if (!drm_rect_intersect(&dst_clip, &damage))
            continue;
    iosys_map_incr(&dst, drm_fb_clip_offset(dst_pitch, dst_format, &dst_clip));
    blit_to_crtc(&dst, &dst_pitch, shadow_plane_state->data, fb, &damage, ...);

`dst` is offset to `dst_clip`'s corner, but the *row count* comes from
`drm_rect_height(&damage)` inside the blit -- and a client's damage clips are
not required to be inside the plane's destination, so when they are not, the
blit walks past the end of the plane. The live state shows the client that can
do it: `plane[35]` is KWin's `fb=44`, `format=XR24`, `size=1080x2424`,
`pitch[0]=4352`, against this port's destination pitch of 4320.

The tegu commit's `drm_sysfb` fix
(`drivers/gpu/drm/sysfb/drm_sysfb_modeset.c`) hands the blit `&dst_clip` -- the
rect the destination was actually offset by, which is what the helper's own
documentation requires ("the destination is at the top-left corner") -- and
`drm_warn_once`s the offending rect if the clip ever has to bite, so a boot
says whether the oversized damage is real instead of leaving it to be inferred
from a fault address. The fix can only narrow what is written, so it is safe
whatever the damage does. With it in, the serial console is an interactive
channel again; without it, expect a login on it to end the boot.

### The msgbuf failure: a D2H mailbox word this firmware does not drive (2026-10-09)

**The LTR question is answered, and the answer is no.** `PCI_EXP_LNKSTA` on
`01:00.0` and the RC's ELBI `RDLH_LINKUP` (`0x131202c8`) were read on the
phone after a failure, over the USB-gadget link:

    ELBI 0x131202c8 = 0x03999811      LTSSM = low 6 bits = 0x11 = L0
    ELBI 0x13120054 = 0x00000001      LTSSM enable, as left by link training
    EP  LnkSta: Speed 5GT/s, Width x1; DevSta/CESta clean
    RC  LnkSta: Speed 5GT/s, Width x1

The link never left L0 and neither end has an error latched, so the dongle is
failing from the inside and the LTR/L1SS arm is **not** the cause. That is
exactly what the discriminator was for: it was refuted before a build was
spent on it.

**What it is instead: a missing `mb_via_ctl` check.** The firmware advertises
shared flags `0x70050107`, which *clears* `BRCMF_PCIE_SHARED_USE_MAILBOX`
(bit 25), so brcmfmac sets `shared->mb_via_ctl = true` -- mailbox words go
over the **control ring**, not the TCM mailbox registers. The H2D *send* side
honours that (`brcmf_pcie_send_mb_data()`, `pcie.c:994`). The D2H *poll* does
not: `brcmf_pcie_poll_mb_data()` reads `shared->dtoh_mb_data_addr` over TCM
unconditionally, and it is called from both the MSI ISR thread and the poll
worker. On this part that word reads back `0xffffffff`, and
`brcmf_pcie_handle_mb_data()` only asks "is this bit set?", so a single
garbage word decodes as `DS_ENTER_REQ | DS_EXIT | D3_ACK | FW_HALT` at once
and the driver tears down a dongle that never halted.

Measured in one boot, with the addresses taken from the same probe:

    Shared RAM addr: 0x00833234            (fw-published, at rambase+ramsize-4)
    Console: base 8332b4, buf 884ed0, size 8192
    dtoh_mb_data_addr = 0x008a0b88         (read back through BAR1 afterwards)
    ...
    brcmf_pcie_ring_mb_write_wptr W w_ptr 17 (0), ring 0   <- first dcmd doorbell
    brcmf_pcie_handle_mb_data D2H_MB_DATA: 0xffffffff
    D2H_MB_DATA: DEEP SLEEP REQ / DS EXIT / D3 ACK / FW HALT
    brcmf_fw_crashed
    brcmf_pcie_get_memdump dump at 0x006E0000: len=2228224
    AER CmpltAbrt, TLP Header: 0x00000001 0x0000000f 0x600a0b88   (bp 0x8a0b88)
    CONSOLE: err check: core 0x1810a000, error 2, axi id 0x10001,
             addr(0x00000000:008a0b88)
    CONSOLE: AXI timeout / TRAP 4(8f7ed0): pc 72b34a, ...

`0x600a0b88` is the D2H mailbox and nothing else -- not the console buffer
(`0x884ed0`), not the ring info (`0x8a0848`), not a hole. After the halt a
`devmem` read of that offset returns 0 (the driver cleared it after reading)
and every neighbour reads normally, so the location is ordinary RAM.

The fix is to skip the TCM poll when the firmware drives the mailbox over the
control ring. The D2H word already arrives there through
`brcmf_pcie_d2h_mb_rx` -- wired as `bus->ops->d2h_mb_rx` and fed from
`msgbuf.c:1448` -- so the poll is redundant in that mode. The one-line branch
is in the tegu commit's brcmfmac ctl-mailbox change
(`drivers/net/wireless/broadcom/brcm80211/brcmfmac/pcie.c`); it mirrors the H2D
side rather than inventing a new mechanism.

### What the vendor and the shared tree both do, and this port does not

Mainline's `pci-exynos.c` implements none of the `use-*` properties above. The
two differences that are already implemented in the shared port tree, and
simply never reached on this path, are:

* **The LTR + L1SS arm.** `zumapro_pcie_wifi_l1ss_enable()` in the shared tree
  is the port of the vendor's `exynos_pcie_rc_set_l1ss()` BCM branch. Its mask
  (`pci_exynos.wifi_l1ss_mask`) defaults to `0`, so the *substates* stay off,
  but it still writes the RC's 26 MHz aux-clock frequency (`0xb40 = 0x1a`,
  which clocks the L1SS timers), `L1SS_CONTROL2` `TPowerOn = 200us`
  (`0x1a0 = 0xa1`), `L1_SUBSTATES = 0xea` (`0xb44`), and -- unconditionally --
  **enables the LTR mechanism on both the RC and the endpoint**. Nothing in
  this port's boot calls *that* function: it exists for the out-of-tree
  `bcmdhd`. The shared tree's own BCM4390 commits say why that can matter:
  "the BCM4390 firmware never sees LTR active", and "the BCM4390 firmware
  engages its deep-sleep protocol once L1SS is armed". A firmware that gates
  its own power state on LTR, and never sees LTR, is a candidate for a
  backplane that stops answering.

  **Corrected 2026-10-09: `brcmfmac` does arm the same thing, by a second
  route, and it is live-testable without a build.** The pinned tree's
  `pcie.c` carries `brcmf_pcie_enable_l1ss()`, selected by the module
  parameter `brcmfmac.l1ss` (0 = off, the default; 1 = LTR + L1.2 threshold
  only, link stays L0; 2 = full L1SS + ASPM-L1). It writes the same
  TPowerOn/LTR-latency/L1.2-threshold values to the endpoint *and* its
  upstream root port through the generic PCI config accessors -- no DBI, no
  MMIO -- and it **is** called, from `brcmf_pcie_setup()`. So the sequence a
  build was about to be spent on is already reachable. The string
  `brcmfmac.l1ss` is present in `Image` of `.#tegu-images`, so the currently
  flashed kernel has it too. Two consequences the plan did not account for:

  * the call sits **after** `brcmf_pcie_init_ringbuffers()` and
    `brcmf_attach()`, i.e. *after* the point at which the 4383 traps, so
    `echo 1 > /sys/module/brcmfmac/parameters/l1ss` plus a re-bind cannot
    affect the trap at all;
  * because every write it makes is an ordinary PCI config access, the same
    sequence can be applied from userspace with `setpci` *before* binding the
    driver -- which is the only way to have LTR in place while msgbuf
    initialises. `~/tegu-work/wifi-diag.sh preltr` does that; run the
    read-only `state` arm first, since the link is what tells us whether LTR
    is even the question.

* **Gen3 link training -- checked, and NOT a difference for this part.** The
  shared tree converges the BCM Wi-Fi link at **Gen3** until initial training
  (`57a33514f2`, `6fd93e3edc`) and reports "both RC and EP (BCM4390, dev 4438)
  negotiate 8.0 GT/s x1", and this port's node sets `max-link-speed = <2>`,
  which looked like a real divergence. It is not: that work is about the
  **BCM4390**, and the BCM4383 endpoint only advertises 5 GT/s --
  `lspci -vv` gives `LnkCap: Speed 5GT/s, Width x1` and `LnkCap2: Supported
  Link Speeds: 2.5-5GT/s`. The driver's own log agrees and is not a fault
  report: `Wi-Fi link trained: sub-Gen3 (LNKSTA 0xb012)` / `PCIe Gen.2 x1 link
  up`. So `max-link-speed = <2>` matches the part and should stay. (Reading the
  vendor's two DT sources alone is still ambiguous -- the base DTB says
  `<0x02>` and the WLAN overlay says `<0x03>` -- but the endpoint's own
  capability register is not.)

**What is *not* a difference, despite this port's dtsi saying so:** the pin
muxes. The vendor's stock DTB defines `wlan-pcie1-clkreq-pins` on `gph3-1`
(func 2, pud 3, drv 3, con-pdn 3, pud-pdn 3), `wlan-reg-on-pins` on `gph3-4`,
`wlan-dev-wake-pins` on `gph3-5` and `pcie1-perst-pins` on `gph3-0` -- byte for
byte the same as the groups in the kernel's
`arch/arm64/boot/dts/exynos/google/zumapro-tegu-nixos.dtsi`. The
CLKREQ#/PERST/WLAN_EN wiring this port wrote is right, and the shared tree's
`pcie1_clkreq`/`pcie1_perst` labels are the same pins, not gs101's `gph2-*`.

## Next steps, in order

The base swap booted, and it closed both items this list used to open with.
What is left is mostly board description rather than reverse engineering.

1. **Wi-Fi.** The chip is a BCM4383 and the driver plus firmware boot it (see
   the Wi-Fi section above). What is left is the host<->dongle msgbuf path, and
   the section's "Corrected diagnosis" is the current state of it: the dongle
   aborts a *host read* of its own RAM because its AXI read timed out, the
   address is backed, and the backplane only stops answering once the firmware
   is up. The one tree-attested difference left standing is the **LTR/L1SS
   arm** (`zumapro_pcie_wifi_l1ss_enable()`, which nothing calls on the
   `brcmfmac` path); Gen3 link training was checked and is *not* a difference,
   because the BCM4383 endpoint is a Gen2-only part. Before spending a build on
   that arm, the cheap discriminator is to read the link's own state after a
   failure: if the LTSSM has left L0, this is power management and the arm is
   the right fix; if it is still in L0, the dongle is failing from the inside
   and the arm will not help. Read `PCI_EXP_LNKSTA` on `01:00.0` and
   `PCIE_ELBI_RDLH_LINKUP` in the RC's ELBI for that. Both are named registers,
   so they are safe, unlike the hand-rolled MMIO below. For a re-bind without a
   flash,
   the phone is reachable over its USB gadget (`ssh max@10.42.0.1`) as long as
   the UART board is unplugged -- the two are mutually exclusive -- and
   `echo 0000:01:00.0 > /sys/bus/pci/drivers/brcmfmac/bind` re-runs the whole
   probe in seconds. With the UART board in, log in at the console instead:
   it is the only channel that survives a hung interconnect, and it prints the
   endpoint's AER decode, which the dongle's console buffer does not.
   `/sys/class/devcoredump/devcdN/data` would be the 2.2 MB image of dongle
   RAM, but no dump has been produced so far. **Do not hand-poke that range
   with `devmem` writes or with `setpci` on undocumented RC DBI offsets** --
   both have hung the phone.
2. **The display, properly.** The one place the shared tree does not cover this
   board: `DRM_EXYNOS` is not even enabled in their `zumapro_defconfig`, their
   exynos9 DECON/DSIM work is aimed at komodo and caiman, and the panel drivers
   they added are those panels. tegu keeps the bootloader's framebuffer until it
   has a panel driver of its own — 1080×2424, command mode, DSC. Enable
   `DRM_EXYNOS9_DECON` and the zuma DSIM, then write the tegu panel against
   their komodo one. This is what stands between the phone and a display that
   can change modes, sleep, or dim.
3. **Audio.** The AoC path is the deep one: their `GOOGLE_AOC` needs GSA and
   Trusty to release the core from reset, and their own defconfig does not
   currently build it (`CONFIG_TRUSTY` is absent, so `GOOGLE_AOC=m` silently
   drops out — check `.config` before assuming audio is a config away). The
   speaker amplifier on this board also has to be identified; theirs is a
   CS35L41 pair in `zumapro-caimito-cs35l41.dtsi`.
4. **Modem.** Their `s5xxx` driver reaches a stable ONLINE with data on the
   caimito boards, over PCIe CH0 with a CP power sequencer and a bit-banged
   SPMI bus. Everything board-specific is in `zumapro-caimito-s5400.dtsi`.
5. **The long tail, roughly in order of how much a phone needs it:** charger
   and fuel gauge (`max77779`), the GPU's ACPM DVFS and thermal throttling,
   deep idle (MCT v3 and the c2 states are in their DT already), NFC, the
   camera flash LED, GNSS.

Worth an early check now that a shell is reachable: whether cpufreq has OPPs,
whether the ACPM TMU thermal zones read sane temperatures, and whether USB
negotiated SuperSpeed or fell back to high speed.

## Sources

Downstream references used, all fetched at bring-up time:

- GrapheneOS `kernel_devices_google_tegu` — board device tree sources
- GrapheneOS `device_google_tegu-kernels_6.1` — prebuilt DTBs, `dtbo.img`, stock kernel
- AOSP `kernel/google-modules/display/samsung`, branch `android-gs-tegu-6.1-android16` — DECON/DPP register maps (`cal_9865`)

Community trees for this SoC:

- [Trijal08/kernel-mainline][trijal], branch `zumapro-google-caimito` — whose zumapro work this port's kernel ([gaavin/linux][kfork], branch `pixel9a`) rebases onto mainline v7.3-rc6
- [zumapro-mainline/linux](https://github.com/zumapro-mainline/linux) — the other one; `clk-zuma.c` and the pinctrl data came from here first

See `notes/UPSTREAM.md` for what each got right and where a borrowed gs101
name is not a zumapro register.

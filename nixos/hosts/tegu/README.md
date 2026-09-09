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

Not yet a usable phone: no USB, no WLAN, no modem, no GPU.

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
| Touch SPI bus | **Yes.** Loopback echoes at 9.98 MHz |
| ACPM | **Yes.** Mailbox, SRAM and protocol confirmed; the route to the PMIC |
| S2MPG14 rails | **Yes.** `LDO4M` and `LDO25M` enabled over ACPM, verified by reading the enable bit back from the PMIC |
| Touch input | **Yes.** Synaptics S3908 (fw `GA1B0-15.0`) answers commands and streams reports; coordinates reach `/dev/input` |
| USB | Not yet, and the reason is now precise. Controller described and reachable, clocks on; blocked on an eUSB2 + combo USB-DP PHY driver |
| WLAN, modem, GPU, audio, camera | No |

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
| `dts/zumapro.dtsi` | SoC: 4×A520 + 3×A720 + 1×X4, PSCI, GIC-v3, arch timer, debug UART, firmware/modem carve-outs, ramoops |
| `dts/zumapro-pixel-common.dtsi` | `chosen`, placeholder memory node (the bootloader patches in the real 8 GiB) |
| `dts/zumapro-tegu.dts` | Board |
| `kernel/zumapro-bootfb.c` | Boot framebuffer adoption, staged reset probes, early stripe |
| `kernel/apply.sh` | Grafts everything below into the kernel tree; fails loudly if an upstream anchor moves |
| `kernel/clk-zumapro-hsi2.c` | CMU_HSI2 clock provider for UFS. Its writes are no-ops (see fact 8); needed so the UFS node can resolve its clocks |
| `kernel/clk-zumapro-hsi0.c` | CMU_HSI0 USI2 divider — the touch SPI's real clock (see fact 10) |
| `kernel/zumapro-ufs-host.py` | Tensor G4 host-controller corrections: PCS `0x202` (the 38.4 MHz reference), PCS RX `0x2f`, and the four quirks the stock tree drops |
| `kernel/zumapro-pmic-dump.c` | Read-only dump of the S2MPG14 register map over ACPM. Never writes; see the file for why that matters |
| `kernel/zumapro-s2mpg14-regulator.c` | The two touch rails as regulators, over ACPM directly. Not `sec-acpm.c`: that knows S2MPG10's map, where `0x43` is a different LDO |
| `kernel/check.sh` | Cross-compile one of these drivers against the kernel's store build tree, in seconds, without building an image |
| `kernel/zumapro-touch.c` | Synaptics TouchComm v1 over SPI. Owns the rails, drives reset, decodes reports into input events |
| `notes/s2mpg14-dump.txt` | The live PMIC dump, and how the vendor map was matched against it |
| `notes/HANDOVER.md`, `notes/HANDOVER-PROMPT.md` | Briefing for picking this up cold, and the prompt to hand a new session |
| `kernel/add-zumapro-wdt.py` | `google,zumapro-wdt`, with no PMU quirks — zumapro's PMU offsets are unverified and gs101's differ |
| `notes/HARDWARE.md` | Every address, offset and measured value this port has established, in one place — including the gs101 values that turned out wrong and what they should be |
| `notes/UPSTREAM.md` | What to take from github.com/zumapro-mainline and what not to — their CMU_HSI0 USI clocks agree with our measurements; their USB clocks and PHY are gs101's and name registers this SoC does not have |
| `touch-probe.sh` | Register dump for the touch stack, via `devmem` (never `dd`: arm64 restricts `/dev/mem` `read()` to real memory). No longer runs at boot — it drives reset and pulls ATTN, which belong to the driver now; `systemctl start tegu-touch-probe` when the driver is unbound |
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

## Next steps, in order

1. **The eUSB2 + combo USB-DP PHY.** Everything under it is done and
   measured: the domain is powered, the registers answer, every CMU gate was
   already open, the Q-channels are enabled and the user muxes moved off the
   oscillator. What remains is `DWC3 controller soft reset failed,
   -ETIMEDOUT`, and `dwc3_core_soft_reset()` calls `phy_init()` before
   asserting `DCTL.CSFTRST` — so the PHY is a prerequisite, not a later step.
   `notes/HANDOVER.md` opens with the method to use, which is the one that
   worked for the UFS PHY. Mainline's `google,gs101-usb31drd-phy` is a
   starting point and not a fit: this is eUSB2 behind a combo block with six
   register ranges against gs101's three.

   Two loose ends to tidy when it works: `USB_G_SERIAL=y` (precomposed)
   contends with the configfs gadget in `default.nix` for the single UDC, and
   `USB_CONFIGFS` is not set at all, so that unit has never worked — it exits
   0 on an empty `/sys/class/udc` and reports success.
2. **A zumapro pinctrl driver.** It removes three problems at once: touch
   reset is currently written straight into peric0's GPIO block from the
   driver, the touch IRQ is polled at 16 ms instead of taken from `gpn0-0`,
   and `sec-acpm` cannot probe at all without an interrupt. Mainline has the
   Samsung pinctrl driver and gs101 bank tables; zumapro needs its own — and
   the data is already written down. `soc-gs`'s
   `drivers/pinctrl/gs/pinctrl-gs.c` carries a full set of `zumapro_pin_*[]`
   tables giving every bank's pin count, offset, name and EINT number, with
   the block base in the comment above each. They are *not* zuma's — that set
   exists separately and differs — so take the ones named for zumapro. Both
   banks this port already pokes by hand agree with them. This is a
   transcription job, not a reverse-engineering one.
3. **USB.** `usb@11210000`, PHY `@11100000`. A gadget serial console would end
   the reflash-per-question loop that costs this port most of its time;
   `USB_G_SERIAL` and `U_SERIAL_CONSOLE` are already enabled.
4. **Clocks and power domains, properly.** `clk-zumapro-hsi0.c` and
   `clk-zumapro-hsi2.c` each cover one block and do not model the CMU_TOP
   mux/divider tree at all. A real driver, starting from
   `drivers/clk/samsung/clk-gs101.c`, is still needed for the GPU and USB.
   Note this is **not** what blocked storage — that belief was wrong, see
   fact 8.
5. **Display proper.** DPU/DSIM plus the `google,gs-tg4a/b/c` panel driver, to
   replace the borrowed bootloader framebuffer.

## Sources

Downstream references used, all fetched at bring-up time:

- GrapheneOS `kernel_devices_google_tegu` — board device tree sources
- GrapheneOS `device_google_tegu-kernels_6.1` — prebuilt DTBs, `dtbo.img`, stock kernel
- AOSP `kernel/google-modules/display/samsung`, branch `android-gs-tegu-6.1-android16` — DECON/DPP register maps (`cal_9865`)

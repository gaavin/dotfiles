# tegu handover

Mainline Linux 7.3-rc1 + NixOS on a Google Pixel 9a (Tensor G4, `zumapro`).
Repo `~/dotfiles`, work in `nixos/hosts/tegu`. Read `README.md` first — it is
current as of this handover.

## The one thing to understand about this device

**There is no interactive access.** The UART debug board is receive-only, so
you cannot type into the phone. No SSH, no adb. The loop is:

1. You build and flash.
2. The user reboots the phone and pastes the UART log.
3. You read the log.

Every question you want answered must be *arranged in advance* — compiled into
a driver, or written into the boot-time probe, or sent through the command
channel below. Budget one boot per question and make each one count.

## The command channel (use this, not full rebuilds)

`nixos/tools/tegu-cmd` runs a shell command on the phone. It rebuilds only
`vendor_boot` (24 KB, ~0.1 s to flash) with the command base64'd onto the
kernel command line; `tegu-cmd.sh` on the phone decodes and runs it, echoing
each line to `/dev/kmsg` so it lands on the UART.

	cd ~/dotfiles/nixos
	./tools/tegu-cmd 'cat /proc/consoles'
	./tools/tegu-cmd -f /path/to/script.sh

Then ask the user to reboot. Constraints that have already cost boots:

- The kernel command line is **2048 bytes** and three things share it:
  boot.img's cmdline, ABL's own 277 bytes, and yours. The tool budgets this
  and gzips automatically when needed. If a payload silently truncates the
  phone answers `base64 decode failed`.
- The systemd unit sets `path=`, which **replaces** PATH. NixOS adds
  coreutils/findutils/gnugrep/gnused itself, so `od` and `tr` work but `gzip`
  does not — the tool calls `/run/current-system/sw/bin/gunzip` by absolute
  path for that reason.
- Use `devmem` for MMIO, never `dd`: arm64 restricts `/dev/mem` `read()` to
  real memory, so `dd` returns EFAULT on registers while `devmem` (mmap)
  works.

## Building and flashing

	cd ~/dotfiles/nixos
	nix build .#tegu-images -L

A kernel or DT change needs a full flash; a rootfs-only change does too,
because the system store path changes and `boot.img` names it. Always flash
with an explicit serial — **a second Google phone is attached to this host**:

	fb=/nix/store/...-android-tools-37.0.0/bin/fastboot
	img=$(nix build --no-link --print-out-paths .#tegu-images)
	S=59201JEBF29944
	for p in boot init_boot vendor_boot vendor_kernel_boot dtbo; do
	  $fb -s $S flash $p "$img/$p.img" || break
	done
	$fb -s $S flash userdata "$img/rootfs.img"

Do **not** run `flash.sh` blindly and do not reboot the phone yourself — the
user asked to do that themselves. Notes:

- The rootfs is 11 GB and takes ~245 s. Check the exit status; a failed
  transfer leaves a half-written rootfs that will not boot.
- `vbmeta` fails on this device (`Failed to find AVB_MAGIC`) and is now
  non-fatal in flash.sh. Skip it.
- `vendor_boot` must never carry a cmdline. It is the only image small enough
  to reflash alone, so an `init=` in it goes stale against the rootfs and you
  get "Failed to start Find NixOS closure" and an emergency shell.

## State

Working: boot to userspace, own device tree, UFS at gear 4 (boots from an
11 GB ext4 root), Plasma Mobile, panel console via the bootloader's
framebuffer, UART console, watchdog, ACPM.

**Touchscreen — the current task.**

- The SPI bus is *finished and proven*. Internal loopback echoes
  `a5 5a 0f f0` byte for byte at 9.98 MHz. Controller, clock, datapath and
  FIFOs are all good. Do not re-investigate this.
- The rails are real and mainline drives them. LDO4M (AVDD 3.3 V) and LDO25M
  (DVDD 1.8 V) come up through `sec-acpm`, and ATTN goes from low to high the
  moment they do -- the first time that line has ever read high here.
- Pinctrl is real. Both alive controllers probe, `gpn0` exists, and the touch
  SPI device binds instead of waiting forever for a supplier.

### Read Google's own sources before designing an experiment

Three trees, cloned under /tmp/tegu-work (tmpfs -- re-clone if gone), from the
`zumapro-mainline` orbit:

| tree | what it settles |
| --- | --- |
| `tegu-dt` | `dts/zuma-tegu-common-touch.dtsi` -- the real `spitouch` node for *this phone* |
| `synaptics` | `syna_gtd/syna_tcm2_platform_spi.c`, `tcm/synaptics_touchcom_core_v1.c` |
| `soc-gs` | SoC hardware tables (sparse clone -- ask `git ls-tree`, not the filesystem) |

Every touch question answered on 2026-09-08 was answered by reading these, and
each had cost boots to guess at. Look here first.

### Where it got to

Stages 1 and 2 are done on hardware. What is left is the part itself.

Three defects were fixed together, each against vendor evidence:

1. **The ATTN gate trusted a pulled line.** The bootloader leaves a pull-*down*
   on gpn0-0 (PUD reads 0x1, measured). ATTN is active low, so the line reads
   asserted whenever nothing drives it -- rails off, reset held, or the part
   still booting. `-42` after reset was a read twelve milliseconds after reset
   release into a part that had not booted, and the wait returned the first
   header it saw instead of retrying. Google's `ts-irq` clears that pull; the
   device tree now does too, and `-ENOMSG` no longer ends a wait.
2. **Reads were transmitting.** The driver held MOSI high, believing Google
   fills 0xff. Google does -- but only when `synaptics,spi-byte-delay-us` is
   nonzero, and tegu sets it to 0. The real path is `tx_buf = NULL`, and
   `spi-s3c64xx` sets `CH_TXCH_ON` only for a non-NULL `tx_buf` and never asks
   the core for a dummy buffer, so **MOSI is not driven at all** through an
   Android read. Every MOSI byte is a command byte to this part.
3. **The poll loop could hammer forever** on that same untrustworthy gate. It
   now stops after 64 markerless reads and says so.

**`FB_CLK_SEL` is retired as a suspect.** Google's `controller-data` sets
`samsung,spi-feedback-delay = <0>`, which is mainline's default. The earlier
note naming it the prime cause of degrading headers was wrong.

### Next log to read

The post-reset wait is now an instrument. It samples ATTN for 500 ms without
putting a byte on the bus and logs every transition -- and says so when there
are none -- then reads eight times at 50 ms apart, logging every header that is
not a marker:

	zumapro-touch ...: boot: attn asserted at reset release
	zumapro-touch ...: boot: first read header a5 10 18 00
	zumapro-touch ...: boot: attn idle at 120 ms
	zumapro-touch ...: boot: attn asserted after 500 ms, 2 transitions
	zumapro-touch ...: boot: read 0 header ff ff ff ff

Read it as: does ATTN ever idle (is the line the part's to speak for), and what
comes back off the bus (mute, still booting, or out of frame).

`tcm_xfer` gained `fb N`, `mosi 0|1` and `attn`, so the feedback tap, the MOSI
drive and the line itself can be swept from userspace through `tegu-cmd`
without a rebuild.


### Known-incomplete in the touch driver

- **The ATTN gate is honest now but still unproven.** The pull-down is cleared
  and the poll loop backs off after 64 markerless reads instead of hammering,
  but no message has yet been read *because* the line said one was waiting.
  Until that happens, treat a quiet log as "the gate may be wrong", not as
  "the part is quiet" — `echo attn > tcm_xfer` prints the raw level.

- **No coordinate decoding.** TouchComm's touch report is a bitfield sequence
  described by a report-config the part supplies at runtime. It is deliberately
  not written yet: the driver logs raw reports so the layout can be read off
  real data. Google's decoder is in
  `/tmp/tegu-work/synaptics/syna_c10/tcm/synaptics_touchcom_func_touch.c`.
- **Still polling, by choice.** Reset and ATTN are real gpiods now, and `gpn0`
  has an irq_domain, so `interrupts-extended` would resolve today. The line is
  level-low and stays asserted until the message is drained, so a handler that
  failed to drain would storm the machine. One line to change once a read has
  succeeded.

### Next after touch

1. A **zumapro pinctrl driver**. It unblocks three things: the touch reset and
   IRQ (removing both shims above), and `sec-acpm`'s mandatory interrupt.
   Mainline has the Samsung pinctrl driver and gs101 bank tables; zumapro
   needs its own.

   **The bank tables already exist and are complete**, and zumapro has its
   own — do not use zuma's, they differ (zumapro's GPIO_ALIVE adds `gpa11`
   and `gpa12`). `soc-gs`, `drivers/pinctrl/gs/pinctrl-gs.c`, has
   `zumapro_pin_alive[]`, `zumapro_pin_custom[]`, `zumapro_pin_far[]`,
   `zumapro_pin_gsacore0..3[]`, `zumapro_pin_gsactrl[]`,
   `zumapro_pin_hsi1[]`, `zumapro_pin_hsi2[]`, `zumapro_pin_hsi2ufs[]`,
   `zumapro_pin_peric0[]` and `zumapro_pin_peric1[]`, each entry giving pin
   count, offset, name and EINT number, with the block base in the comment
   above it. Two entries are already load-bearing here and both check out
   against hardware: `gpn0` is bank 0 of GPIO_CUSTOM_ALIVE (`0x15060000`, one
   pin) and `gpp1` is bank 1 of GPIO_PERIC0 (`0x10840000` + 0x20, four pins).
   This is transcription into mainline's `samsung_pin_bank_data` form, not
   reverse-engineering.

   One thing those tables do *not* cover: the touch SPI pads. Google's board
   file calls them `GPB10[4..7]`, and no `gpb` bank exists in any zumapro
   block or in the stock DTS — which is consistent with Google's own SPI node
   carrying `pinctrl-0 = <>`. Firmware sets those pads up and Linux never
   touches them, so pad muxing is not a suspect for the silent touchscreen.
2. Coordinate decoding, from logged reports.
3. USB (DWC3 + eUSB/combo PHY) would end the reflash-per-question loop.

## Vendor sources — and a trap that cost real time

`/tmp/tegu-work/` holds:

- `soc-gs` — Google's SoC kernel, branch `android-gs-tegu-6.1-android16`.
  Clock tables (`cal-if`), UFS PHY tables, and the S2MPG14 PMIC headers.
- `synaptics` — `google-modules/touch/synaptics_touch`, same branch. TouchComm
  protocol.
- `tegu-dt` — board device trees. `zuma-tegu-common-touch.dtsi` is the
  touchscreen's.
- `zumapro-stock.dts` — decompiled stock DTB. The authority on addresses,
  interrupts and clock IDs.

**`soc-gs` is a sparse, blobless checkout. Grepping the working tree lies.**
This is how the S2MPG14 register map was declared "not available anywhere"
while sitting in a repo already on disk. Always:

	git -C /tmp/tegu-work/soc-gs ls-tree -r --name-only HEAD | grep -i <thing>
	git -C /tmp/tegu-work/soc-gs sparse-checkout add drivers/mfd drivers/regulator

If something seems missing, look for more Google repos before concluding it
does not exist. `git ls-remote --heads
https://android.googlesource.com/kernel/google-modules/<name>` works.

## How to work on this port

Read this part. It is the difference between progress and burning boots.

- **Dumps beat hypotheses, overwhelmingly.** Every durable finding here came
  from reading registers. In this session six consecutive hypotheses about the
  SPI stall were refuted against hardware; the answer came from the stock
  DTB's `clocks` phandle. If you have a theory, find the measurement that
  distinguishes it from its negation, and prefer widening a dump to narrowing
  a guess.
- **Software agreeing with itself is not evidence.** The SPI bug survived
  weeks because a clock provider accepted `clk_set_rate()` and reported the
  rate back through debugfs — against a register in the wrong CMU. A `dev_info`
  saying a thing was configured proves only that your code ran.
- **Verify your instrument before believing a negative.** A "no data" result
  was `dd` failing silently on `/dev/mem`; a "spi-pipe failed" was the script
  branching on an exit status that is 1 for a partial block; a "nodes missing
  from the DTB" was `dtc` not being on PATH with `-q` swallowing the error.
  Each cost boots. When a result says "nothing happened", suspect the tool.
- **A successful probe can print nothing.** Every message in `exynos-acpm.c`
  is an error path. Check `/sys/bus/platform/devices/*/driver` and
  `/sys/kernel/debug/devices_deferred`, not the log.
- **Never blind-scan an MMIO range.** Sweeping `sysreg_hsi0` raised a fatal
  SError. A `reg` size in the DTS is an address-map allocation, not a promise
  that every word answers. Widen across *named* registers only.
- **Be careful what you write to the PMIC.** It powers the rails this phone
  boots from. The S2MPG10 map predicts LDO4M at 0x43; on S2MPG14 that address
  is LDO25M, so an "enable AVDD" there would have quietly switched on DVDD.
  Read first, confirm the map against known values, then write.
- **Write down what was refuted, not just what worked.** The commit log and
  the README carry the dead ends deliberately, so they are not re-walked.

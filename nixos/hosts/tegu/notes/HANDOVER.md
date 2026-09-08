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
- The part was silent because it is unpowered. Its rails are S2MPG14 LDO4M
  (AVDD 3.3 V, reg 0x2E) and LDO25M (DVDD 1.8 V, reg 0x43), enable at BIT(7).
  A live read had both correctly programmed and switched **off**.
- **The rails are on and the part answers.**
  `kernel/zumapro-s2mpg14-regulator.c` sets the enable bit over ACPM and reads
  it back from the PMIC: `LDO25M 0x2c -> 0xac`, `LDO4M 0x3c -> 0xbc`. The
  device then replies on the bus with `0xa5` (`TCM_V1_MESSAGE_MARKER`) and
  `0x10` (`REPORT_IDENTIFY`). Clock, SPI controller, ACPM, register map,
  rails, reset — the whole chain works.

### Where it got to, and the open question

Four logs in. Fixed along the way, all real bugs:

1. `spi_read()` transmits zeroes, and on TouchComm a MOSI byte is a command
   byte. Reads now drive MOSI high, as `syna_tcm2_platform_spi.c` does.
2. An idle bus reads all 0xff, so a header of `ff ff ff ff` was taken as a
   65535-byte message. Implausible lengths now resynchronise.
3. A single read 20 ms after the command called the part silent. Google's core
   polls every 10 ms up to 3 s; the driver now retries 100 x 10 ms.
4. `regulator_enable()` returning 0 was being read as "the rail is on". It
   means ACPM accepted the message. The enable path now reads the register
   back, and that is what proved the rails.

**A correction that is in the git history.** One log was read as showing
`gpn0` idling high and a commit claimed the part had come alive. That was a
misread — in a bank dump the words are CON, DAT, PUD, DRV, and the
`0x00000001` was PUD. `gpn0` DAT reads 0 in every measurement, including
through a pull-up that reads back as enabled, and 0 is what an asserted
active-low ATTN and an unpowered part clamping through its ESD diodes both
look like. Do not use that line as evidence until the part has answered once.

**The open question is the header.** Google's header says a v1 identify packet
is 24 = `0x18` bytes, so the true header is almost certainly `a5 10 18 00`:

	try 0: hdr a5 10 ff ff      byte 0 right, byte 1 right, rest wrong
	try 1: hdr a5 18 ff ff      0x18 is the length byte, one position early
	poll:  hdr a5 18 ff 00

Byte 0 is right on every read, byte 1 is right or one bit out, and it degrades
from there. That is a sampling problem, not a protocol one.

Ruled out, so do not spend a boot on them:

- **Not a short read.** `s3c64xx_spi_wait_for_pio()` spins until `RX_FIFO_LVL`
  reaches the transfer length and returns `-EIO` otherwise. `spi_sync()`
  returned 0, so all four bytes came off the wire.
- **Not byte swapping.** Mainline writes 0 to `SWAP_CFG` at init.
- **Not pad muxing.** No `gpb` bank exists in any zumapro pinctrl block or in
  the stock DTS, and Google's own SPI node carries an empty `pinctrl-0`.
  Firmware owns those pads.

**The suspect is `FB_CLK_SEL`**, the feedback tap the controller samples MISO
on (`0x111d0000` + 0x2c, four settings). Mainline writes it once at setup from
`samsung,spi-feedback-delay`, which defaults to 0. Internal loopback cannot
see this: it never leaves the controller, so there is no round trip to
compensate — which is how a bus that echoes `a5 5a 0f f0` byte for byte can
still read a real device wrong.

**Next log to read.** The driver now sweeps all four taps and dumps 32 raw
bytes at each, which is header plus a whole 24-byte identify packet in one
chip-select assertion:

	zumapro-touch ...: spi: ch_cfg ... mode_cfg ... swap ... fb ...
	zumapro-touch ...: dump fb0: <16 bytes> | <16 bytes>
	zumapro-touch ...: dump fb1: ...
	zumapro-touch ...: dump slow: ...
	zumapro-touch ...: dump after IDENTIFY: ...

A tap that yields `a5 10 18 00` followed by real data is the answer, and the
fix is a `controller-data` child node on the touchscreen with
`samsung,spi-feedback-delay = <n>` — after which the sweep, which pokes the
controller's register behind its driver's back, must come out.

If no tap works, the next instrument is a genuinely slow clock. The floor
today is about 6.24 MHz against 9.98: the USI2 divider is four bits wide off a
fixed 399.36 MHz parent and `spi-s3c64xx` divides by four again. Modelling the
CMU_TOP HSI0_PERI divider (`0x26041890`, reads 0) is what buys a real sweep.

### Known-incomplete in the touch driver

- **The poll loop is gated on a line nobody has validated.** `zumapro_touch_poll()`
  skips the bus unless `gpn0` reads low. Today it always reads low, so the
  gate is a no-op and the probe-time diagnostics run regardless — but the
  moment that line starts behaving, a wrong polarity or a wrong pin means the
  driver silently stops reading. Delete the gate, or prove the line, before
  trusting an empty log.

- **No coordinate decoding.** TouchComm's touch report is a bitfield sequence
  described by a report-config the part supplies at runtime. It is deliberately
  not written yet: the driver logs raw reports so the layout can be read off
  real data. Google's decoder is in
  `/tmp/tegu-work/synaptics/syna_c10/tcm/synaptics_touchcom_func_touch.c`.
- **Two shims for missing SoC support.** Reset is driven by writing peric0's
  GPIO block directly (`0x10840000`, gpp1 CON +0x20 / DAT +0x24, pin 1, active
  low), and it polls at 16 ms instead of taking the `gpn0-0` interrupt. Both
  exist only because there is no zumapro pinctrl driver.

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

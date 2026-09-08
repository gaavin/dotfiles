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
- `kernel/zumapro-s2mpg14-regulator.c` writes the enable bit over ACPM and
  `kernel/zumapro-touch.c` drives reset, but **the part has never answered**.
  What is proven is the CMU_HSI0 clock, the SPI controller, ACPM, the
  register map, and that reset is driven. What is *not* proven is that the
  rails actually come up.

### Where it got to, and the open question

Three logs in, IDENTIFY still times out. Fixed along the way, all real bugs:

1. `spi_read()` transmits zeroes, and on TouchComm a MOSI byte is a command
   byte — so every read was feeding the part 0x00. Google fills TX with 0xff
   for reads (`syna_tcm2_platform_spi.c`); the driver now does the same.
2. An idle bus reads all 0xff, so a header of `ff ff ff ff` was taken as a
   65535-byte message and printed as filler. Implausible lengths now
   resynchronise.
3. A single read 20 ms after the command called the part silent. Google's
   core polls every `CMD_RESPONSE_POLLING_DELAY_MS` (10 ms) up to
   `CMD_RESPONSE_TIMEOUT_MS` (3000 ms) and retries a wrong-marker header with
   a 5–10 ms sleep. The driver now retries 100 × 10 ms.

**A correction you need, because it is in the git history.** One log was read
as showing `gpn0` idling high, and a commit and a README section were written
saying the part had come alive. That was a misread: in a bank dump the words
are CON, DAT, PUD, DRV, and the `0x00000001` was PUD. `gpn0` DAT reads 0 in
every measurement, including through a pull-up that reads back as enabled.

That reading is *ambiguous* and cannot settle anything on its own — 0 is what
an asserted active-low ATTN looks like and equally what an unpowered part
clamping through its ESD diodes looks like. (`gpn3`, one bank along, reads 1,
so the block and the reads are sound.) Do not use this line as evidence in
either direction until the part has answered once.

**The open question is whether the rails actually come up.**
`regulator_enable()` returning 0 means ACPM accepted the message and reported
no PMIC error. It is not a read of the bit. The enable path now reads the
register back and logs `0xNN -> 0xNN`, and fails with `-EIO` if bit 7 did not
stick.

**Next log to read**, in priority order:

	zumapro-s2mpg14-regulator ...: LDO4M: reg 0x2e: 0x3c -> 0xbc (want bit 7 set)
	zumapro-s2mpg14-regulator ...: LDO25M: reg 0x43: 0x2c -> 0xac (want bit 7 set)
	zumapro-touch ...: gpn0 before power / rails on / after reset
	zumapro-touch ...: try 0: hdr XX XX XX XX, gpn0 0xNNNNNNNN

1. If the enable bit does **not** stick, the touch part is a side issue and
   the question becomes how this PMIC is really enabled — start with whether
   ACPM will write this register at all (try `write_reg` with the whole byte
   rather than `update_reg`), then with `S2MPG14_PM_PCTRLSEL1..11` /
   `DCTRLSEL1..7` at 0x97–0xA8, which select what actually drives a rail.
2. If it does stick, read the header bytes. All `0x00` means MISO is held
   low — a part that is still not powered, despite the bit. All `0xff` means
   an idle bus and a powered part that is not answering, which moves the
   search to TouchComm framing: the bus turn-around delay (`TAT_DELAY_US`),
   whether header and payload must share one chip-select assertion, and
   `syna_tcm_v1_read()` in
   `/tmp/tegu-work/synaptics/syna_c10/tcm/synaptics_touchcom_core_v1.c`.
3. Anything else in the header is real data and the framing is close.

### Known-incomplete in the touch driver

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

   **The bank tables already exist and are complete.** `soc-gs`,
   `drivers/pinctrl/gs/pinctrl-gs.c`, has `zuma_pin_alive[]`,
   `zuma_pin_custom[]`, `zuma_pin_far[]`, `zuma_pin_gsacore0..3[]`,
   `zuma_pin_gsactrl[]`, `zuma_pin_hsi1[]`, `zuma_pin_hsi2[]`,
   `zuma_pin_hsi2ufs[]` and the peric banks, each entry giving pin count,
   offset, name and EINT numbers, with the block base in the comment above
   it. `google,zumapro-pinctrl` shares zuma's data. For example
   `0x15060000` is GPIO_CUSTOM_ALIVE and holds `gpn0`..`gpn9`, one pin each,
   0x20 apart, `gpn0` first — which is what makes the touch IRQ readable at
   `0x15060004` today. Nothing here needs reverse-engineering; it needs
   transcribing into mainline's `samsung_pin_bank_data` form.
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

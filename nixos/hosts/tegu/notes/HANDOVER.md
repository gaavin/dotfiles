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

**Touchscreen — the current task.** Reads work perfectly. Writes do nothing.

### Established on hardware. Do not re-investigate.

| Fact | Evidence |
| --- | --- |
| SPI bus, clock, controller | loopback echoes `a5 5a 0f f0` at 9.98 MHz |
| Both rails | `sec-acpm`; vdd 1.8 V, avdd 3.3 V, and ATTN goes high the moment they do |
| pinctrl, reset, ATTN | `gpn0` PUD reads 0; forcing a pull-**up** still read low, so the part drives it; idles high after a clean reset |
| The part | Synaptics **S3908**, fw `GA1B0-15.0`, build 4468578, TouchComm **v1**, mode 1 = `MODE_APPLICATION_FIRMWARE` |
| A whole message in one read | `r 29` returns `a5 10 18 00 01 01 "S3908GA1B0-15.0\0" 62 2f 44 00 00 04 5a` — header, payload, end-of-message, exact |
| Command codes, hex parser | checked byte-for-byte against the vendor enum |

**A message must be read in one transfer.** Reading the 4-byte header and
coming back for the rest loses exactly 4 bytes — the `a5 03` and the two
payload bytes after it — so the payload arrives starting at `part_number[0]`.
`s3c64xx_spi_transfer_one()` calls `s3c64xx_flush_fifo()` after every transfer,
which drains and discards the RX FIFO. Stay under the 64-byte FIFO too: a
transfer of `fifo_depth` or more is split into `fifo_depth - 1` chunks, each
its own datapath enable, which puts that boundary back inside the message.

**Reads must not transmit.** `synaptics,spi-byte-delay-us = <0>` on tegu, so
`syna_spi_read()` takes its `tx_buf = NULL` branch. `spi-s3c64xx` sets
`CH_TXCH_ON` only for a non-NULL `tx_buf` and never requests a dummy buffer, so
MOSI is undriven for the whole read. Every MOSI byte is a command byte to this
part.

**`FB_CLK_SEL` is not a suspect.** Google sets `samsung,spi-feedback-delay = <0>`,
which is mainline's default.

### The open question: the controller cannot transmit

	Q1 undriven   a5 10 18 00 01 01 53 33 ...   <- full identify
	Q2 tx-zeros   00 00 00 ...                  <- broken
	Q3 tx-ffs     00 00 00 ...                  <- broken

Three full-duplex reads of the same message, differing only in what sits on
MOSI. Any transfer with a non-NULL tx_buf -- which is what sets CH_TXCH_ON --
returns zeros, whatever the data. Zeros and 0xff fail identically, so this is
not the part objecting to what it is told; the transfer dies when the transmit
channel is enabled.

That is why every command has failed. Not a protocol fault, not framing, not
the part refusing: the controller does not transmit in this configuration, so
no command has ever reached the part. Reads work because they are the one path
that leaves TX off (tx_buf = NULL).

**Do not repeat these.** All were tried against the command path and all failed
for this reason: bare and zero-padded commands, command and reply in one chip
select ("x") and in two ("wr"), the vendor's exact 4+31 split read beforehand,
a full 35-byte drain beforehand, and SPI modes 0-3 (0 and 1 read correctly, 2
and 3 corrupt reads; none accept a command).

Where to look next: Google runs this bus with `dma-mode`, `dmas = <&pdma1 18
&pdma1 19>`, `swap-mode = <1>` and `samsung,spi-fifosize = <0x40>`; this port
sets none of them and mainline never parses `swap-mode`. And the SPI pads have
no pinctrl anywhere -- Google's own node carries `pinctrl-0 = <>` with a TODO,
there is no `gpb` bank in this SoC, so the pads are however the bootloader left
them and MOSI may simply not be muxed.

### Superseded: writes have no effect

	W: id     a5 10 18 00 01 01 53 33 ... 5a   <- perfect
	W: ident  5a 5a 5a ...                     <- CMD_IDENTIFY, nothing
	W: rst    5a 5a 5a ...                     <- CMD_RESET, nothing

`CMD_RESET` is unmistakable if it lands, and it does not. Reads need MISO, CLK
and CS; writes additionally need MOSI. Splitting "MOSI never reaches the pad"
from "the part ignores commands" is the next job. Note there is **no `gpb` bank
anywhere in this SoC** — the banks are `gpp*`, `gph*`, `gpn*`, `gps*` — so the
SPI pads have no pinctrl behind them and the mux cannot be inspected that way.

### Rules that were learned the hard way

- **The probe must not talk to the part beyond identify.** A failing command is
  a hundred polls; three of them take the part from `5a` padding to `0x00` to
  not driving MISO at all, within thirty seconds of boot. Every userspace
  experiment run before this rule was measuring wreckage. `poll 1` through
  `tcm_xfer` starts the report loop by hand.
- **Trace every path that touches the bus before flashing.** An early return
  guarded on the *failure* path let the *success* path fall through into
  `CMD_ENABLE_REPORT` and the poll loop, and cost a boot to discover.
- **A log line must print what was actually read.** `ts->hdr` is only written
  by a successful read; printing it after a failure shows the previous
  message's header as if it were this one.
- **Rate-limit anything the poll loop can print.** An unbounded `dev_err` there
  made whole boots unreadable and forced logs to be pasted by hand.
- **The UART dies for up to a minute across a reboot** (shared USB-C hub takes
  the XIAO down with the phone). Do not paper over it with `sleep` in a
  `tegu-cmd` script — that output is lost too. Keep scripts prompt and re-run.
- **`tcm_xfer` only exists after `probe()` returns.** The driver core adds
  `dev_groups` after probe, so a `tegu-cmd` script must wait for the file
  rather than assume it.


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

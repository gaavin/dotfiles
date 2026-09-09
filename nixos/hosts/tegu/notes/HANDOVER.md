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
- `-f` **strips whole-line comments, indentation and blank lines** before
  encoding, so a probe can be documented in the repo and still fit. The real
  ceiling is about **1.4 KB of encoded payload**, and the encoding costs a
  factor of 1.8 over the stripped source: gzip, base64, then base64 again
  because the phone side always decodes one layer. `spi-tx-probe.sh` is 7 KB
  in the repo, 1.4 KB stripped and 1396 bytes encoded — the budget is real and
  it is why that experiment is two scripts rather than one. Check before
  flashing; the tool refuses rather than truncating.
- A here-document whose body has lines starting with `#` will be mangled by
  that stripping. Do not send one.

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
| SPI bus, clock, controller | hand-driven loopback echoes `a5 5a 0f f0`, TX FIFO 4→0, TX_DONE set, no error bits |
| Both rails | `sec-acpm`; vdd 1.8 V, avdd 3.3 V, and ATTN goes high the moment they do |
| pinctrl, reset, ATTN | `gpn0` PUD reads 0; forcing a pull-**up** still read low, so the part drives it; idles high after a clean reset |
| MOSI is connected | driving it stops the part answering, where an undriven read on the same part reads a perfect identify |
| The firmware is running | `a5 c2 02 00 20 00` = REPORT_FW_STATUS, `b5_fast_relaxation` — routine telemetry from a sensing part |
| Commanding on a pending message wedges it | ATTN high, wrote anyway, part released MISO mid-message and went silent |
| Draining stops the wedging | commanding on a pending message is what killed it; drained, it survives commands |
| A reset pulse does not revive a wedged part | only a full boot does |
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

### Settled: the controller transmits, and the part hears it

Measured 2026-09-09 by `spi-tx-probe.sh`, which drives the transfer by hand
against the registers with the SPI core never asked to transfer:

	P2 armed mode=0x1FF80008 pkt=0x00010004 cs=0x00000000
	P2 fill[0x00000100 tx=4 rx=0 d=0] en[0x02020002 tx=0 rx=4 d=1]
	P2 rx_lvl=4 rx=a5 5a 0f f0
	P3 fill[0x00000100 tx=4 rx=0 d=0] en[0x02020002 tx=0 rx=4 d=1]
	P3 rx_lvl=4 rx=5a 5a 5a 5a

**P2, internal loopback.** The TX FIFO took four bytes (`tx=4`), the shifter
drained them (`tx=0`), TX_DONE set, four bytes arrived, and they are exactly
the four that went in. No error bits: STATUS[5:2] is zero in both readings.
The transmit datapath works. `L4/L5` are dead twice over -- by this, and by
the measured hwinit wipe that explains why they read what they read.

**P3, loopback off, aimed at the part.** Identical transmit behaviour, and the
part answered `5a 5a 5a 5a`. **0x5A is TouchComm padding** -- what this device
sends when it has nothing to say. Not 0xff, which is the line floating to its
pull-up with nothing driving; not 0x00, which is what a wedged part returns.
The part is powered, clocked, selected, listening, and driving MISO.

So the whole chain is proven end to end: **CLK, CS, MOSI, MISO, the FIFOs and
the shifter all work, and the pads are muxed.** "MOSI never reaches the pad"
is retired, and so is every framing built on the controller being at fault.
The remaining fault is above the wire.

Also learned, and not obvious: **RX_DATA presents the queue packed, and a read
pops one byte.** Four successive 32-bit reads with four bytes queued returned
0xf00f5aa5, 0x00f00f5a, 0x0000f00f, 0x000000f0 -- the whole remaining queue,
little-endian, each time. That is consistent with `ioread8_rep()` on the read
path, which takes the low byte; it would matter for a 32-bit `cur_bpw`.

### MOSI is connected and the part decodes it

`spi-mosi-probe.sh`, 2026-09-09. Four reads of a freshly reset part, changing
only what sits on MOSI, each retrying until it sees the 0xa5 marker:

	v0  undriven   tries=0   a5 10 18 00 01 01 53 33   perfect identify
	v1  8x 0x00    tries=12  no marker
	v2  8x 0xff    tries=12  00 00 00 00 00 00 00 00
	v3  undriven   tries=12  00 00 00 00 00 00 00 00   after a reset pulse

If MOSI were not reaching the part, v1 and v2 would have read the identify
exactly as v0 did -- a driven read clocks the same, the part would simply see
nothing different. Instead driving it stopped the part answering, and v0
brackets that as a healthy part on the same boot. **The wire is live and the
part acts on what arrives.**

Content matters, not just activity, which is what makes this decoding rather
than interference. From the variant boot before it:

	02 00 00                  part stays healthy, no response
	02 00 00 + five 00        part stays healthy, no response
	04 00 00  (CMD_RESET)     part stays healthy, no response, ATTN stays low
	00 x8 / ff x8             part stops answering entirely

An eight-byte write beginning 0x02 is harmless; eight bytes of 0x00 or 0xff
are not. The part is parsing the first byte.

**A reset pulse does not recover a broken part.** v3 reset and still read
0x00 with ATTN stuck high, which is this port's long-standing wedged
signature. Only a full boot brings it back. That changes the recovery model:
once a boot's part is gone, the boot is over, and it explains why whole
sessions used to end early.

### What is left

A valid command is received and produces nothing. CMD_RESET is the sharpest
case -- unmistakable if acted on, and it is not acted on -- while malformed
bytes visibly break the part. So the part sees the first byte, distinguishes
0x02 from 0x00, and still never answers.

Ruled out, each measured rather than assumed:

- **SPI mode.** Writing CPOL/CPHA into CH_CFG directly does move the bus:
  padding read back as 5a, b4, 69, one 0x5a stream sampled 0, 1 and 2 bits
  late. No mode produced a reply. The driver's `mode N` had never worked --
  mainline sets `cur_mode` only inside its bpw/speed check, where Google sets
  it outside, so every earlier mode result in this file was measured against a
  bus that never changed mode.
- **Clock rate.** 10 MHz and the slowest this tree reaches, both silent.
- **Poll time.** The vendor allows CMD_RESPONSE_TIMEOUT_MS = 3000 at 2 ms
  intervals; ATTN never rose at all, so there was nothing to miss.
- **Packet shape.** `syna_tcm_v1_write()` builds command, length low, length
  high and nothing else; no CRC, because the vendor clears has_crc when the
  bytes past a message read 0x5a5a, and this part's do.
- **Trailing clocks.** A padded eight-byte command behaves like a bare one.
- **swap-mode.** For 8-bit words Google writes SWAP_CFG = 0, as mainline does.

The next thing to try is the length field. A command whose length bytes are
misread would be parsed as valid, leave the part waiting for payload that
never comes, and produce exactly this: no response, no error, and a part that
breaks when the next write arrives as unexpected payload. Sending a command
with a real payload -- CMD_SET_DYNAMIC_CONFIG, or CMD_ENABLE_REPORT with its
one report-type byte -- would distinguish "the length is misread" from "the
whole command is ignored", because the two predict different amounts of
follow-on damage.

### The AOC, scoped: it is not running, so it is not the touch problem

The touch SPI bus is shared. Google's node carries `goog,tbn-enabled` and
`tbn,mode = <2>`, which is `TBN_MODE_AOC_CHANNEL` in
`google-modules/touch/common`, and the owner enum is AP or AOC. Worth knowing,
and this port did not know it.

But the AOC is started **by the AP**, and this port has no AOC driver, so on
these boots it never starts. From `google-modules/aoc`, `aoc.c`:

	start_firmware_load()  ->  request_firmware_nowait(...)
	    gsa_enabled = of_property_read_bool(..., "gsa-enabled");
	    if (gsa_enabled) { aoc_fw_authenticate(prvdata, fw); }
	    ...
	    /* start AOC */
	    if (gsa_enabled)
	            rc = gsa_send_aoc_cmd(prvdata->gsa_dev, GSA_AOC_START);
	    else
	            aoc_release_from_reset(prvdata);

Nothing in our boot path does any of that. The consistency of the reads agrees:
a second master actively driving this bus would corrupt them sometimes, and
they have been perfect on every boot for the whole investigation.

**What bringing it up would cost**, if it is ever wanted for its own sake
(audio, sensors, hotword, LPTW): `aoc.c` is 2812 lines; the firmware is
authenticated by the GSA, so a GSA driver is needed too (`linux/gsa/gsa_aoc.h`
— note `google-modules/gsa` has no `android-gs-tegu-6.1-android16` head, so
finding the right repo is itself a step); plus the firmware image from the
vendor partition, an IOMMU, the `aoc_s2mpu`, and 48 mailbox channels. Mainline
has nothing at all — the only `aoc` in 7.3-rc1 is Amlogic's AO clock
controller. It is a bring-up on the scale of UFS or larger, and the TBN
service sits at the very top of it.

Sources are cloned at `/tmp/tegu-work/aoc` and `/tmp/tegu-work/aoc-ipc`
(branch `android-gs-tegu-6.1-android16`), `aoc_tbn_service_dev.c` included.

`spi-len-probe.sh` confirms the "not running" claim from the hardware rather
than from this reasoning: it reads `pd-aoc@15462280` and `aoc_req` at
0x154b0000, both named in the stock DTS and both in the always-on alive
domain. The AOC block at 0x17000000 is deliberately untouched — it is behind
an S2MPU and an unbacked read on this SoC is a fatal SError.

### Google's four controller differences, checked against mainline

The stock node carries `dma-mode`, `dmas = <&pdma1 18 &pdma1 19>`,
`swap-mode = <1>` and `samsung,spi-fifosize = <0x40>`, and this port sets none
of them. None can explain a transmit fault -- and the measurement above says
there is no transmit fault to explain:

- **fifosize.** Mainline does not parse `samsung,spi-fifosize`; the property it
  reads is `fifo-depth`, and it never gets that far because
  `gs101_spi_port_config` sets `.fifo_depth = 64` before the device tree is
  consulted. In *Google's* driver the property is mandatory and derives
  `fifo_lvl_mask = (fifosize << 1) - 1` = 0x7f, which is what it is for.
- **dma-mode / dmas.** `s3c64xx_spi_can_dma()` returns false unless both
  channels exist *and* `xfer->len >= fifo_depth`. Every transfer here is 4 to
  35 bytes, so even fully wired DMA would run them as PIO.
- **swap-mode.** Mainline never parses it and `s3c64xx_spi_hwinit()` writes
  SWAP_CFG = 0. With CH_TSZ and BUS_TSZ both BYTE there is nothing to swap.

Bit positions agree between the two drivers where it counts: Google's
`exynos_spi_port_config` has `rx_lvl_offset = 15` and `tx_st_done = 25`, the
same as mainline's gs101. Only the FIFO level mask differs -- 0x7f against
mainline's 9-bit GENMASKs -- which is immaterial at depth 64. Note the at-rest
STATUS reads 0x01000000 and neither driver names bit 24, so keep the raw word
in any dump rather than only a decode.

### Superseded: the controller cannot transmit (first framing)

**The readings below stand; the conclusion drawn from them does not.** The
controller transmits — measured above. Q2/Q3 returning zeros is the *part*
objecting to what it was told and pulling MISO down, not the controller
failing to send.


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

**Wrong as stated.** Writes reach the part: it answers padding to them. What
fails is getting a *command* understood.


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
- **A controller register written from userspace does not survive the next
  transfer.** `s3c64xx_spi_runtime_resume()` calls `s3c64xx_spi_hwinit()`,
  which rewrites MODE_CFG, INT_EN, SWAP_CFG, PACKET_CNT and CS_REG from
  scratch, and the controller autosuspends two seconds after a transfer — so
  a devmem poke and the transfer meant to use it are always separated by a
  full re-init. `s3c64xx_spi_prepare_message()` rewrites FB_CLK even more
  often, once per message. Either drive the whole transfer by hand, or set
  the bit through the driver. This is what put an unmeasured caveat on the
  loopback result below.


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

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

**Touchscreen — WORKING (2026-09-09).** The part answers commands, the full vendor bring-up runs, and it streams **REPORT_TOUCH frames with live coordinates that move under a finger**. See "TOUCH DATA" below. What remains is decoding the report layout properly and moving the fix out of userspace into the SPI driver.

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
| ATTN drops mid-message | it means "a message waits", not "a message is unfinished" — drain until the part returns `5a` padding |
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

### ATTN goes low mid-message, and that has poisoned every drain

`spi-len-probe.sh`, 2026-09-09, and the important line is the one that was not
being looked for:

	d1 drained=0 w=38 47 41 tries=8 attn=0x00000000 r=5a 5a 5a 5a 5a 5a

`38 47 41` is ASCII **"8GA"** -- payload from the middle of the identify
string `S3908GA1B0-15.0`. The health check before it had read the first eight
bytes and stopped, leaving the part part-way through its message, and **ATTN
read 0 the whole time**. The drain loop trusted ATTN, found it low, drained
nothing, and wrote the command straight into the middle of a message -- which
is the one thing already known to destroy the exchange.

So the rule this port has been using is wrong. **ATTN means "a message is
waiting", not "a message is unfinished".** Once a read has begun consuming
one, ATTN drops while the rest of the message is still queued. Draining has to
continue until the part actually returns 0x5a padding; every drain in every
probe so far, and in the driver, has stopped too early.

That does not rescue the other two, which is the disappointing half:

	d2 drained=0 w=5a 5a 5a 5a tries=8 attn=0 r=5a 5a 5a 5a 5a 5a
	d3 drained=0 w=5a 5a 5a   tries=8 attn=0 r=5a 5a 5a 5a 5a 5a

Both wrote to a genuinely quiet part -- `w=5a` proves it was emitting padding,
not a message -- and both got nothing back, with ATTN never rising. `d2` is
`02 01 00 02`, a command declaring one payload byte and supplying it; `d3` is
`20 00 00`, CMD_GET_APPLICATION_INFO, a different command entirely. Neither is
answered.

The part stayed healthy throughout: `h0` through `h3` all read padding on the
first try. So neither a length-bearing command nor a different command code
breaks it, and the earlier breakage from eight bytes of 0x00 or 0xff remains
the only write that has ever killed it.

**Where that leaves the command path.** A well-formed command, sent to a quiet
healthy part, at the right speed and mode, with correct framing, produces no
response and no error. The next thing to fix is the drain -- read until
padding, not until ATTN drops -- and then re-run the command with a drain that
actually works, because every command result recorded in this file was taken
with a drain that could stop mid-message.

### The AOC: its power domain is ON, so it is not excluded

The touch SPI bus is shared. Google's node carries `goog,tbn-enabled` and
`tbn,mode = <2>`, which is `TBN_MODE_AOC_CHANNEL` in
`google-modules/touch/common`, and the owner enum is AP or AOC. Worth knowing,
and this port did not know it.

The AP is what loads and starts AOC *firmware*, and this port has no AOC
driver, so that never happens here. From `google-modules/aoc`, `aoc.c`:

	start_firmware_load()  ->  request_firmware_nowait(...)
	    gsa_enabled = of_property_read_bool(..., "gsa-enabled");
	    if (gsa_enabled) { aoc_fw_authenticate(prvdata, fw); }
	    ...
	    /* start AOC */
	    if (gsa_enabled)
	            rc = gsa_send_aoc_cmd(prvdata->gsa_dev, GSA_AOC_START);
	    else
	            aoc_release_from_reset(prvdata);

Nothing in our boot path does any of that. **But the power domain is on**,
measured 2026-09-09:

	aoc pd=0x00000001 0x00000001 0x00000010 req=0x00000001

`pd-aoc@15462280` +0x00 and +0x04 are the Exynos PD configuration and status
words and both read 1, and `aoc_req` reads 1. This was predicted to read zero
and it does not. A powered domain is not proof that firmware is running --
the bootloader may simply leave it up -- but "the AOC is held off, so it
cannot be involved" is refuted, and the negotiator is back on the suspect
list rather than closed.

Pulling the other way: the reads have been perfect on every boot of this
investigation, and a second master actively driving the bus would corrupt them
intermittently.

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

### What happens after commands work, read off the vendor driver

Short, and worth knowing so the command path is not treated as the whole job.
`syna_dev_set_up_app_fw()` in `syna_tcm2.c` is the entire bring-up:

	CMD_GET_APPLICATION_INFO      0x20   sensor dimensions, max touches
	CMD_GET_TOUCH_REPORT_CONFIG   0x25   the report format, so reports parse
	CMD_ENABLE_REPORT             0x05   payload one byte, REPORT_TOUCH 0x11

so the wire packet to start touch is `05 01 00 11`. There is no hidden step
between identify and touch data -- no firmware download, no calibration, no
handshake. `STARTUP_REFLASH` and the custom report-format and gesture hooks
are all `#ifdef`s this port does not need. **Everything is gated on the
command channel, and nothing else is missing.**

Also settled, free, from the identify this port already captured. The v1
`struct tcm_identification_info` is `version, mode, part_number[16],
build_id[4], max_write_size[2]` = 24 bytes, exactly the payload length read:

	01              version 1
	01              mode 1, MODE_APPLICATION_FIRMWARE
	"S3908GA1B0-15.0\0"
	62 2f 44 00     build 4468578
	00 04           max_write_size = 1024

Every field decodes, which is a strong check that the read path is byte-exact
and framed correctly. **`max_write_size` is 1024**, so `syna_tcm_v1_write()`
chunking through `CMD_CONTINUE_WRITE` never engages for a command this small;
a three-byte command is one transfer, and that is what this port sends.

### TOUCH DATA (2026-09-09)

`spi-coords2-probe.sh`. Live coordinates, moving under a finger:

	IDLE a5 11 17 00 00 00 00 00 00 00 00 00 00 01 01 10 36 1f b8 2f 1d 00 07 07 07 07 00 5a
	XY1  a5 11 17 00 00 00 00 00 00 00 00 00 00 01 01 10 d6 1e c8 2f 35 00 09 07 09 07 35 5a
	XY2  a5 11 17 00 00 00 00 00 00 00 00 00 00 01 01 10 de 14 93 0a 0a 00 5a
	XY3  a5 11 17 00 00 00 00 00 00 00 00 00 00 01 01 10 5e 1c e8 34 3a 00 08 0a 0a 08 5a 5a
	XY4  a5 11 17 00 00 00 00 00 00 00 00 00 00 01 01 10 6b 22 9a 2a 40 00 0a 0a 0a 0a d2 5a

	Z: touch=914 diff=913

`a5` marker, `0x11` REPORT_TOUCH, `0x0017` = 23 payload bytes. The per-object
bytes move as the finger moves: `36 1f b8` -> `d6 1e c8` -> `de 14 93` ->
`5e 1c e8` -> `6b 22 9a`. An earlier boot counted **1086 reports in 16.5 s**.

**The exact field layout is not yet known and must not be guessed.** Several
12-bit packings were tried against the 1080x2424 panel and each gave plausible
values for some frames and out-of-range ones for others. The answer is not a
curve fit -- `CMD_GET_TOUCH_REPORT_CONFIG` returns **128 bytes** describing it,
of which only the first 11 have been captured:

	10 08   GESTURE_ID              1 byte
	1b 38   GESTURE_DATA            7 bytes
	1e 08   SENSING_MODE            1 byte
	17 08   NSM_STATE               1 byte
	18 08   NUM_OF_ACTIVE_OBJECTS   1 byte
	04      PAD_TO_NEXT_BYTE

The remaining 12 report bytes are the `foreach` object records. Parse the
config rather than hardcoding: it is a stream of `code` bytes where control
codes 0x00-0x04 (END, FOREACH_ACTIVE_OBJECT, FOREACH_OBJECT, FOREACH_END,
PAD_TO_NEXT_BYTE) carry no operand and every other code is followed by a
`bits` byte. Extraction is LSB-first within each byte --
`syna_tcm_get_touch_data()` in `synaptics_touchcom_func_touch.c` is the
reference, and `zumapro_touch_bits()` already implements it.

Note `diff=913` of 914: something changes in nearly every frame regardless of
touch, so "differs from the previous frame" is a poor touch detector. Likely a
timestamp or frame counter.

**A read is capped at 63 bytes** -- `fifo_depth` is 64 and a transfer of that
or more is split, which puts a chip-select boundary inside the message. The
128-byte config therefore needs continued reads (`a5 03`,
STATUS_CONTINUED_READ), or 59 bytes at a time, which is enough to reach the
object fields.

### THE FIX: chip select is never deasserted

The whole seven-boot puzzle is one register. `spi-release-probe.sh` isolated
it: an arm that pulses `CS_REG` and touches **nothing else** got a reply on the
first read where the control got nothing in twelve.

	A  after=spi_setup  t=0   a5 00 00 00
	B  after=spi_setup  t=0   a5 c2 02 00 20 00
	R  after=CS pulse   t=0   a5 00 00 00
	C  after=nothing    t=12  5a 5a 5a ...      <- control

And `cs=0x00000000`. This build already strips `S3C64XX_SPI_QUIRK_CS_AUTO`
(`kernel/spi-manual-cs.py`), so `set_cs()` writes 0 to assert and 1 to release
-- and reading **0 after a transfer means chip select is left asserted**. The
part never sees the transaction close. Reads never cared, because a queued
message streams out on any clock; a command needs the boundary to be acted on.

`spi_setup()` fixes it as a side effect: it calls `pm_runtime_get_sync()`,
forcing a resume and so `hwinit()`, which writes `CS_SIG_INACT`.

**The working sequence, reproducible:** `spi_setup()`, command, `spi_setup()`,
read. `spi-replicate-probe.sh` confirmed both halves are load-bearing -- drop
the one before and no STATUS_OK arrives; drop the one after and the part stops
driving MISO entirely. The BEFORE half has its own mechanism:
`s3c64xx_spi_transfer_one()` skips `s3c64xx_spi_config()` unless speed or bpw
changed, and `hwinit()` zeroes `cur_speed` to force it, so the command's own
transfer reconfigures CH_CFG and the clock instead of running on leftovers.

**This is a workaround, not the fix.** The real change belongs in
`spi-s3c64xx`: deassert chip select at the end of a message. Note
`spi_set_cs()` in the SPI core passes the driver a *pin level*, not an
activate flag (`ctlr->set_cs(spi, !enable)`), so instrument the polarity
before writing that patch rather than reasoning about it.

**The first command after boot is not answered**, three times over, warm-up or
not, while later identical ones are. Unexplained; a driver should not trust
its first command.

### The bring-up runs

`spi-bringup-probe.sh` and `spi-report-probe.sh`:

	25 00 00      -> a5 01 80 00 10 08 1b 38 1e 08 ...   STATUS_OK, 128 bytes
	05 01 00 11   -> a5 01 00 00                         STATUS_OK, reports on

`CMD_GET_APPLICATION_INFO` (0x20) has never answered. It is not needed for
reports -- it carries sensor dimensions, which matter for scaling coordinates.

### Three ways to lose a result you already have

All three happened in one session, all to the *observation* rather than the
experiment, and each cost a boot:

- **Truncation.** The report loop logged 44 characters. The header and the
  first 11 payload bytes fit; the coordinates started at byte 11. 1086 reports
  were captured and every one was cut off immediately before the answer.
- **Flooding.** Putting `mode 0` before each read makes the driver print two
  lines per iteration. At 1500 iterations that is 3000+ lines, and at 115200
  baud a 60-character line takes ~5 ms -- so the loop was *rate-limited by the
  console* and the wanted lines were lost in the noise. `diff=8` proved the
  touches were captured; not one line carrying them arrived.
- **Silencing.** The fix attempted for the flood was
  `echo 1 > /proc/sys/kernel/printk`, which silenced the UART completely --
  including this port's own `<0>`-prefixed lines -- and produced a boot with no
  output at all. It was also unnecessary: the previous boot's end-of-loop
  `mark` line had come through the same flood intact, which already showed
  that logging *after* the loop works.

**How to apply:** log after the loop, not inside it; capture more bytes than
the field you are looking for; and change one thing at a time, especially when
the change is to the instrument rather than the experiment.

### THE COMMAND PATH WORKS (2026-09-09)

`spi-mode2-probe.sh`. CMD_IDENTIFY, sent in **mode 0**, answered in full:

	P0 r=a5 01 18 00 01 01 53 33 39 30 38 47 41 31 42 30 2d 31 35
	      2e 30 00 62 2f 44 00 00 04 5a

	a5              marker
	01              STATUS_OK
	18 00           24 payload bytes
	01              version 1
	01              mode 1, MODE_APPLICATION_FIRMWARE
	53 33 ...  00   "S3908GA1B0-15.0\0"
	62 2f 44 00     build 4468578
	00 04           max_write_size 1024
	5a              end of message

`quiet=yes`, so the part had provably reached padding before the command, and
`tries=0`, so it answered on the first poll. The ASCII part number cannot be
an artifact of anything the probe did not ask for. **A command was sent,
understood, and answered.**

**Two corrections from the same boot.** Mode 0 is right, matching Google's
`synaptics,spi-mode = <0>`. Mode 2 returns `a5 0e 00 00`,
**STATUS_NOT_IMPLEMENTED**, so it does reach the part but mangles the command
byte into something it declines -- which also means the CPOL gradient built
from the previous boot was an artifact, and the `a5 01 18 00` seen there from
modes 2 and 3 really were leftovers of the reset R0 caused. The bar that
caught it was insisting on the ASCII payload rather than accepting a plausible
header; keep that bar.

**What is not understood: why the same operation failed one boot earlier.**
`spi-setup-probe.sh` arms A and B were both mode 0 on a provably quiet part,
one with `spi_setup()` and one without, and neither answered. Here it answers.
The only visible difference is that the working command followed two commands
the part had already replied to. That hints at a priming step, but it is one
boot and a guess.

`spi-repeat-probe.sh` measures it rather than guessing: six identical
CMD_IDENTIFY in mode 0 from the first moment after boot, alternating whether
`spi_setup()` runs first, nothing else touched. It answers whether the *first*
command of a boot lands, whether they keep landing, and whether `spi_setup()`
matters. Read the status byte in the digest -- `01` OK, `0e` NOT_IMPLEMENTED,
`00` IDLE, `5a` never answered.

**Once it is reliable**, the rest is short and already written down: the
bring-up is `CMD_GET_APPLICATION_INFO` 0x20, `CMD_GET_TOUCH_REPORT_CONFIG`
0x25, then `CMD_ENABLE_REPORT` 0x05 with payload `REPORT_TOUCH` 0x11 -- on the
wire `05 01 00 11`.

### REFUTED: spi_setup() is not what produced the responses

`spi-setup-probe.sh`, 2026-09-09. Mode 0 fixed throughout; the only variable
was whether `spi_setup()` -- and so `hwinit()` -- ran before the command.

	h0 alive=0            a5 10 18 00   part alive, identify queued
	A  d=1 quiet=yes t=12 5a 5a 5a 5a   quiet part, plain command, nothing
	h1 alive=0            5a 5a 5a      still alive
	B  d=0 quiet=yes t=12 ff ff ff ff   quiet part, spi_setup, nothing
	h2 alive=8            ff ff ff ff   part no longer driving MISO
	C  d=12 quiet=no      ff ff ff ff   dead for the rest of the boot

Both arms reached padding before commanding -- `quiet=yes` -- so both are
clean, and neither answered. **A controller re-init immediately before the
command changes nothing**, and the responses in the mode sweep were not its
doing.

Two further things fall out. **Mode 0 fails on a provably quiet part**, now
three times across two boots, which is the cleanest statement of the original
problem this port has. And **two mode-0 commands ended the boot** -- the part
went to `0xff`, not driving MISO at all -- where four commands spread across
modes 0-3 in the previous boot left it healthy. That is weak but consistent
with mode 0 delivering something the part acts on badly.

**What is left is the mode**, and across the two boots it is a gradient:

	mode 0   CPOL 0 CPHA 0   nothing               three clean attempts
	mode 1   CPOL 0 CPHA 1   a5 00 00 00           STATUS_IDLE
	mode 2   CPOL 1 CPHA 0   a5 01 18 00           STATUS_OK, 24 bytes
	mode 3   CPOL 1 CPHA 1   a5 01 18 00           STATUS_OK, 24 bytes

Both answering modes have **CPOL = 1**, and mode 2 is the one that also reads
cleanly, mode 3 reads coming back shifted a bit. Note this contradicts
Google's own `synaptics,spi-mode = <0>`, so if it holds, understanding *why*
matters as much as the fix -- an inversion somewhere between the controller
and the pad would explain both it and why reads survive either polarity.

`spi-mode2-probe.sh` tests it directly and is built so a positive cannot be a
leftover: the drain reports whether it truly reached padding, two identical
mode-2 arms guard against an anecdote, a mode-0 control goes last, and the
reply is read back far enough to carry the ASCII part number. The bar for
success is a literal `a5 01 18 00 01 01 53 33 39 30 38` -- marker, STATUS_OK,
24 bytes, version, mode, then "S3908".

### FIRST COMMAND RESPONSES, and the mode control is real

`spi-modeval-probe.sh`, 2026-09-09. Read the caveats -- this is the most
important boot the touch work has had and also the least clean.

	m0 ch=0x00000000 bits=0 r=a5 10 18 00
	m1 ch=0x00000004 bits=1 r=a5 03 38 47
	m2 ch=0x00000008 bits=2 r=a5 03 ff ff
	m3 ch=0x0000000C bits=3 r=4a 1d ff ff

	R0 tries=12 attn=0x00000001 r=00 00 00 00
	R1 tries=0  attn=0x00000001 r=a5 00 00 00
	R2 tries=0  attn=0x00000000 r=a5 01 18 00
	R3 tries=0  attn=0x00000000 r=a5 01 18 00

**Settled: the mode control works.** `CH_CFG` bits [3:2] are `CPOL_L` and
`CPHA_B`, and they read back exactly the mode that was asked for -- 0x0, 0x4,
0x8, 0xC. So `echo mode N` really does reach the hardware, and the earlier
sweep it was doubted for did change something. Read this back after a
transfer, not after the store: `s3c64xx_spi_config()` applies `spi->mode` per
transfer.

**Settled: mode 3 reads are bit-shifted.** `0x4a` is `0xa5` shifted left one
bit, which is exactly what a wrong sampling edge produces. Modes 0, 1 and 2
all return a valid `a5` marker; `a5 03` is `STATUS_CONTINUED_READ`, the
correct header for reading on through a message already started, so m1 and m2
are healthy continuations rather than corruption. This retires the handover's
old "2 and 3 corrupt" as imprecise: only 3 is.

**The headline: `a5 01 18 00` appeared, twice.** `STATUS_OK` is **0x01** and
the identify payload is **24 bytes**, so that is a marker, a success status
and the exact length of the identification info -- the precise shape of an
answered command. `a5 00 00 00` at R1 is `STATUS_IDLE`. Before this boot no
command had ever produced anything but `5a` padding, and ATTN had never risen
after one; at R0 and R1 it reads 1.

**Why this is not yet a result, and must not be written up as one.** R0 sent
CMD_RESET in mode 0 and the part then read `00 00 00 00` with ATTN high for
390 ms, which is either a part mid-reset -- meaning the command *landed* -- or
the long-known wedged signature. Everything after R0 therefore ran on a part
in a changed state, and `D()` gives up silently after twelve tries, so a
"response" may be a message queued by an earlier arm rather than an answer to
this one. Do not claim commands work until one is produced from a part that
was provably quiet immediately before.

**And there is a second candidate that has nothing to do with the mode.**
`echo mode N` calls `spi_setup()` unconditionally -- even for the mode it is
already in -- and mainline's `s3c64xx_spi_setup()` calls
`pm_runtime_get_sync()`, which forces a resume and so runs
`s3c64xx_spi_hwinit()`: `INT_EN`, `MODE_CFG`, `PACKET_CNT` and `SWAP_CFG`
rewritten, pending interrupts cleared, `cur_speed = 0` so the next transfer
reconfigures the clock, and `s3c64xx_flush_fifo()`, a SW_RST of both FIFOs.
**So this boot ran a full controller re-init immediately before every command,
which no previous boot had done.** That, and not the mode, may be the whole
story -- and it would point at a driver fix rather than a device-tree one.

`spi-setup-probe.sh` separates them: mode 0 throughout, never changed, and the
only variable is whether `spi_setup()` runs first (A plain, B with, C plain
again to catch a part that merely warmed up). It uses CMD_IDENTIFY, not
CMD_RESET, so there is no reset window to confuse the next arm and the reply
is self-verifying -- `STATUS_OK`, 24 bytes, then `01 01` and the ASCII part
number. Its drain also reports whether it ever reached padding, which is the
gap that makes this boot ambiguous.

### The length test ran, and it was not the discriminator it claimed to be

`spi-lenbit-probe.sh`, 2026-09-09:

	h0 alive=0 attn=0 a5 10 18 00
	t1 02 00 00  drain=1 w=5a 5a 5a      h1 alive=0
	t2 02 ff ff  drain=0 w=5a 5a 5a      h2 alive=0
	t3 02 00 00  drain=0 w=5a 5a 5a      h3 alive=0

`t2` declared 65535 payload bytes and supplied none, and **the part stayed
healthy through it and everything after**. The probe was written up in advance
saying that outcome proves the part does not parse our length field.

**It does not prove that, and the claim should not be repeated.**
`max_write_size` from this part's own identify is **1024**, so 65535 is not
merely a large length, it is an invalid one. A firmware that validates the
field would reject the command and carry on unharmed -- which is exactly what
was observed. "Parses it and rejects it" and "never parsed it" predict the
same result, so the experiment does not separate them. This is the same
mistake as writing a hardware claim into a comment before measuring it, caught
one step earlier: the prediction was written down before the boot, which is
what made it checkable afterwards. Keep doing that; just check the prediction
against the part's own limits first.

What the boot does establish: `t1` drained one real message (`drain=1`, after
`h0` read `a5 10 18 00`), so the corrected drain works and the commands went
to a genuinely quiet part; and a fourth distinct command shape leaves the part
healthy and unanswering.

### REFUTED: chip select is not why commands fail

`spi-cs-probe.sh`, 2026-09-09. The hypothesis below was good, source-backed and
wrong, and the boot that killed it is worth keeping because the transfer it
measured is the cleanest this port has ever recorded.

	h0 alive=0 a5 10 18 00
	A drain=1 w=5a 5a 5a  tries=10 attn=0x00000000 r=5a 5a 5a
	h1 alive=0 5a 5a 5a 5a
	B drain=0 f=0x010000C0 s=0x03018002 done=1 rx=5a5a5a
	B tries=10 attn=0x00000000

`A` is the driver's CS_AUTO path: the part had its identify queued (`h0` reads
`a5 10 18 00`), the corrected drain consumed exactly one message (`drain=1`),
the write went to a quiet part (`w=5a 5a 5a`), and nothing came back.

`B` is the same three bytes driven by hand with chip select held in software
across the whole transfer, asserted a full devmem -- about a millisecond --
before the first clock edge, where mainline's `NSC_CNT_2` allows about 200 ns.
The status words say it was perfect:

	f = 0x010000C0   TX level 3          the FIFO took all three bytes
	s = 0x03018002   TX 0, RX 3, DONE 1  shifted out, three shifted in
	                 errors [5:2] = 0    no overrun or underrun either way

So the command left the controller, correctly framed, with chip select timed
the way the vendor times it -- and the part answered `5a 5a 5a`, padding, the
same nothing the driver path gets. **Chip select mode and CS-to-clock setup
are dead as suspects.**

**Read the caveat before trusting `B`'s poll, because half of it is void.**
The restore after `B` was wrong (see the SIG_INACT rule below), so every read
in `B`'s response poll failed with `-5` and `tcm_xfer` handed back the previous
buffer. `B ... r=5a 5a 5a` and `h2` are stale bytes, not fresh reads.

What survives is **ATTN**, which is a devmem read of gpn0 and owes nothing to
the SPI controller: it read 0 after the poll. Nothing consumed a message during
that poll -- the reads were all failing -- so a queued response would still have
been waiting with the line high. It was low. The part did not answer `B`.

The original reasoning is kept below because it is still the right way to have
found it, and because the honest weakness flagged in it is exactly the part
that turned out to be load-bearing: reads being byte-perfect really did mean
the part was sampling fine.



The section below enumerated "Google's four controller differences" off the
`spitouch` node's own properties and concluded none could matter. It never
looked at the **`controller-data` child node**, and that is where the
difference is:

	controller-data {
		samsung,spi-feedback-delay = <0>;
		samsung,spi-chip-select-mode = <0>;
		cs-clock-delay = <2>;
	};

In `soc-gs` `drivers/spi/spi-s3c64xx.c`, `s3c64xx_get_slave_ctrldata()` reads
those. `samsung,spi-chip-select-mode` of 1 is `AUTO_CS_MODE`, 2 is
`AUTO_CS_MODE_FORCE_QUIESCE`, and **anything else -- including 0 -- is
`MANUAL_CS_MODE`**. The default when the property is absent is `AUTO_CS_MODE`,
so this is a deliberate per-slave override, and only two devices in the whole
tegu tree take it: this touchscreen with `cs-clock-delay = <2>`, and the eSE
with `<18>`.

What MANUAL_CS_MODE with a non-zero delay does, in Google's driver:

	enable_cs()        SLAVE_SEL = 0            asserted, in software
	enable_datapath()  CH_CFG |= TXCH_ON
	                   udelay(cs->cs_delay)     <-- 2 us before any clock
	                   fill FIFO, write CH_CFG
	disable_cs()       SLAVE_SEL = SIG_INACT    released, in software

and note the ordering swap in `s3c64xx_spi_transfer_one()`: with a cs_delay
and no `cs_gpiod`, chip select is asserted *before* `enable_datapath()`, where
the auto path enables the datapath first.

Mainline's `gs101_spi_port_config` hardcodes `S3C64XX_SPI_QUIRK_CS_AUTO`, so
`s3c64xx_spi_set_cs()` writes `CS_AUTO | NSC_CNT_2` and lets the hardware
drive nSS off the packet counter -- two SCLK cycles of setup, about **200 ns**
at 10 MHz, against Google's **2 us**. `set_cs(false)` is a no-op entirely; the
hardware releases it. There is no mainline property that expresses either the
mode or the delay.

Two things make this worth a boot. It is the only unrefuted difference left --
`fifosize`, `dma-mode`, `dmas` and `swap-mode` are all dead (below), and
`spi-feedback-delay` is 0 on both. And this port has *already measured* the
auto path behaving in a way the vendor's would not: chip select dropping
between the transfers of one message, which restarted the part's message
mid-read. That is the same register, the same quirk, misbehaving in the one
direction that happened to be observable.

**What it does not explain, and this is the honest weakness.** Reads are
byte-perfect, and a part that samples MOSI too early ought to drive MISO too
early as well. If chip select setup were violated, the first read byte should
degrade and it does not. So the story needs the part to be more tolerant
outbound than inbound, which is plausible -- a queued message streams on any
clock, whereas a command has to be framed from the transaction start -- but is
not established.

`spi-cs-probe.sh` settles it in one boot, A/B on the same part:

	A  02 00 00 through the driver     CS_AUTO, ~200 ns setup
	B  02 00 00 driven by hand         chip select ours, ~1 ms setup

B reuses `spi-tx-probe.sh`'s proven hand-driven sequence -- the one that
echoed `a5 5a 0f f0` in loopback and drew `5a 5a 5a 5a` out of the part -- with
the test pattern replaced by a real command. **No command has ever been sent
that way.** Every command this port has tried went through `spi_sync()`, so
all of them share whatever the driver does and none of them isolate it.

If B answers, the fix is a zumapro port config without the quirk (plus a way
to get the pre-clock delay), and it is a clean mainline-shaped change. If B
says nothing, chip select timing is dead as a suspect and the fault is above
the wire.

### Google's four controller differences, checked against mainline

The stock node carries `dma-mode`, `dmas = <&pdma1 18 &pdma1 19>`,
`swap-mode = <1>` and `samsung,spi-fifosize = <0x40>`, and this port sets none
of them. **This list was incomplete -- it read the `spitouch` node's own
properties and not its `controller-data` child, where the chip-select mode
lives; see the section above.** Of the four here, none can explain a transmit
fault -- and the measurement above says
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
- **`CS_SIG_INACT` is sticky, and setting it ends the boot for this bus.**
  Under `S3C64XX_SPI_QUIRK_CS_AUTO`, `s3c64xx_spi_set_cs(true)` only *ORs*
  `CS_AUTO | NSC_CNT_2` into `CS_REG` -- it never clears bit 0 -- and
  `set_cs(false)` is a no-op entirely. So a probe that releases chip select by
  writing `CS_REG = 1` and does not put the register back holds chip select
  inactive for every transfer that follows: nSS never asserts, RX never fills,
  and `wait_for_pio` times out at ~147 ms each with
  `I/O Error: rx-1 tx-0 rx-f tx-p` and `-5`. This voided the second half of
  `spi-cs-probe.sh`'s first run. Save `CS_REG` alongside `CH_CFG` and `INT_EN`
  and restore all three.
- **hwinit does not rescue a botched restore.** The reasoning that dropped
  those restores was that `s3c64xx_spi_hwinit()` rewrites `MODE_CFG`,
  `INT_EN`, `PACKET_CNT` and `CS_REG` anyway. It does -- but only from
  `s3c64xx_spi_runtime_resume()`, which needs a runtime *suspend* first, and
  that is two seconds of idle. A probe's next read is milliseconds away, so
  hwinit never runs. Restore every register you touched, explicitly.
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

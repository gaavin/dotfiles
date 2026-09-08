Paste everything below the line into the new session as its first message.

---

You are taking over a bring-up in progress: **mainline Linux 7.3-rc1 + NixOS
on a Google Pixel 9a** (codename `tegu`, SoC Tensor G4 / `zumapro`). Work in
`/home/max/dotfiles/nixos/hosts/tegu`. The phone already boots NixOS with
Plasma Mobile from its own UFS storage. **The current task is the
touchscreen.** Read `notes/HANDOVER.md` first — it is the real briefing; this
message is only the operating manual.

## How this loop works, and why it is slow

The debug board is **receive-only**. There is no SSH, no adb, no shell on the
phone. Every question you have about the hardware costs one full cycle:

	edit -> nix build -> flash -> the user reboots -> the user pastes the UART log

So **do not guess.** Build the instrument, get the data, then write the
implementation. Every claim in `notes/` and `README.md` that reads as fact was
measured on this device; keep it that way, and mark anything unverified as
unverified. A guess written as fact in a comment has already cost hours in
this port. When you form a hypothesis, dump more registers than you think you
need in the same boot — a second cycle to answer a question you could have
answered in the first is the main way time is wasted here.

## Rules that are not negotiable

- **Never reboot the phone yourself.** Flash and stop. The user reboots and
  captures the log. They asked for this explicitly.
- **Always pass an explicit serial to fastboot:** `-s 59201JEBF29944`. There
  is sometimes a second Google phone attached, and fastboot with no serial
  picks one for you. `flash.sh` now honours `FASTBOOT_SERIAL`.
- **Do not blind-scan MMIO with devmem.** A `reg` size in a DTS is an address
  map allocation, not a promise that every word answers. Scanning
  `sysreg_hsi0` took a fatal SError and killed the boot.
- On arm64, `/dev/mem` `read()` is restricted to real memory: use `devmem`
  (which mmaps), never `dd`.
- Check your own tools before you believe them. In this session a probe script
  branched on `spi-pipe`'s exit status and printed "failed" over a *working*
  transfer; a `pgrep -f "flash userdata"` matched the waiter process running
  it; and `dtc` missing from PATH under `-q` made a correct DTB look empty.
  When a result is surprising, suspect the instrument first.

## Vendor sources — use them, and more often than feels necessary

`/tmp/tegu-work/` holds Google's own sources, branch
`android-gs-tegu-6.1-android16`:

- `soc-gs` — SoC kernel: `cal-if` clock tables, UFS PHY tables, S2MPG14 PMIC.
- `synaptics` — `google-modules/touch/synaptics_touch`, the TouchComm protocol.
- `tegu-dt` — board device trees.

**The trap:** `soc-gs` is a *sparse, blobless* checkout, so a file you need
can be absent from the working tree and present in the repository. Use
`git ls-tree -r HEAD --name-only | grep …`, not `find`. Concluding "no source
here describes S2MPG14" from an empty `find` was wrong, and the header that
answered the question had been in the repo the whole time. If something is not
there, look for the matching `google-modules` repo on GitHub before
reverse-engineering it — that instruction came from the user, and it is what
unblocked the PMIC.

## Building and flashing

	cd /home/max/dotfiles/nixos
	nix build .#tegu-images -o /tmp/tegu-img
	FASTBOOT_SERIAL=59201JEBF29944 /tmp/tegu-img/flash.sh --rootfs

The x86_64 attribute cross-compiles; there is no aarch64 builder here. A
kernel change is roughly a 20-minute build, so start it in the background and
do something else.

Flash **both** the boot images and the rootfs whenever the closure changes. A
boot.img naming a closure the rootfs does not contain drops the phone into an
emergency shell. `flash.sh` does not reboot unless you pass `--reboot`; don't.

`tools/tegu-cmd` passes a kernel command line through `vendor_cmdline`, and it
has three traps documented in `notes/HANDOVER.md`. Read that section before
touching it — the cmdline budget is 2048 bytes *minus* ABL's own 277, and
vendor_boot must carry no base cmdline of its own.

## What to do first

1. Read `notes/HANDOVER.md`, then `README.md`.
2. The user has a freshly flashed phone carrying a diagnostic **nobody has
   seen boot yet**: a sweep of the SPI controller's four feedback-clock taps,
   dumping 32 raw bytes at each. Ask for that log before changing anything.
   The touchscreen's rails are on and the part answers with `a5` and
   `REPORT_IDENTIFY`; what fails is the rest of the message header, and
   `notes/HANDOVER.md` has the table of what each read returned and the four
   explanations already ruled out. A dump reading `a5 10 18 00` followed by
   real data names the tap, and the fix is a `controller-data` node with
   `samsung,spi-feedback-delay` — after which delete the sweep, which writes
   the controller's register behind its own driver's back.
3. Once the header reads cleanly, the next job is decoding TouchComm touch
   reports into input events, from the raw reports the driver logs. Google's
   decoder is
   `/tmp/tegu-work/synaptics/syna_c10/tcm/synaptics_touchcom_func_touch.c`.
4. After touch, the highest-value piece of work is a **zumapro pinctrl
   driver** — it removes the touch reset and IRQ shims and unblocks
   `sec-acpm`'s mandatory interrupt.

Commit as you go, and keep `README.md` and `notes/HANDOVER.md` true.

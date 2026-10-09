# Sourced/run by kernel.nix's postPatch via the build shell; no shebang,
# because the Nix sandbox has no /usr/bin/env.
# Graft this port's remaining out-of-tree bits into the shared zumapro port
# tree (see ../kernel.nix for what that tree is and why we build from it).
#
# This used to be a dozen grafts and register-level patchers. All of them are
# gone: that tree has its own zumapro.dtsi, pinctrl and clock drivers, the
# S2MPG14/15 PMIC, UFS with the same fixes this port measured, and the
# Synaptics TouchComm driver on an s3c64xx that can hold a native chip select
# across a message. What is left is the boot framebuffer and the tegu device
# tree deltas.
#
# Nothing here introduces a Kconfig symbol. An option would have to exist when
# nixpkgs generates .config, which happens in a separate derivation that only
# sees kernelPatches, not postPatch. The driver is a few kilobytes and does
# nothing unless the zumapro_bootfb parameter is passed, so it is simply
# always built in.
set -euo pipefail

src="$1"     # directory holding zumapro-bootfb.c
dts="$2"     # directory holding this port's device tree deltas

board=arch/arm64/boot/dts/exynos/google/zumapro-tegu.dts

# --- device tree ---------------------------------------------------------
# Appended rather than patched in place: the shared tree owns this file, and
# a later property assignment is how dts overrides an earlier one.
test -f "$board"   # fail loudly if the shared tree renames the board file
cat "$dts"/zumapro-tegu-nixos.dtsi >> "$board"

# --- boot framebuffer driver --------------------------------------------
install -m444 "$src"/zumapro-bootfb.c drivers/video/zumapro-bootfb.c
printf 'obj-y += zumapro-bootfb.o\n' >> drivers/video/Makefile

# --- simplefb: name the channel order this bootloader hands over ---------
# The Pixel bootloader leaves a BGRA8888 buffer scanning out. simplefb has no
# name for that order, so without this the framebuffer has to be described
# inaccurately and the console renders with red and blue swapped. Alpha is
# meaningless for a scanout-only layer, so BGRX8888 is the honest description
# and DRM can already convert into it.
hdr=include/linux/platform_data/simplefb.h
anchor='DRM_FORMAT_ABGR8888'
if ! grep -q "$anchor" "$hdr"; then
	echo "apply.sh: no $anchor in $hdr; the format table moved upstream" >&2
	exit 1
fi
if grep -q b8g8r8x8 "$hdr"; then
	echo "apply.sh: upstream now defines b8g8r8x8; drop this hunk" >&2
	exit 1
fi
sed -i "/$anchor/a\\	{ \"b8g8r8x8\", 32, {8, 8}, {16, 8}, {24, 8}, {0, 0}, DRM_FORMAT_BGRX8888 }, \\\\" "$hdr"
grep -q b8g8r8x8 "$hdr" || { echo "apply.sh: simplefb edit did not apply" >&2; exit 1; }

# --- fuel gauge ----------------------------------------------------------
# The gauge is fine and the driver still refuses to read it. Status.POR is
# sticky -- nothing acknowledges it, so it stays set for the life of the boot
# -- and the driver treats it as "the model is not loaded", which makes
# capacity and state-of-charge return -ENODATA forever. Measured on the phone
# with that bit set: RepSOC (0x07) read 0x63f3, i.e. 99%, and the model
# registers at 0x80..0x9f were fully populated. So UPower saw a battery at 0%
# with warning-level "action", ran its CriticalPowerAction (HybridSleep), and
# the phone powered itself off ~25 s after userspace started, every boot.
#
# The patch gates on FStat.DNR instead -- the bit that actually means "the
# data is not ready" -- and turns the misleading probe warning into a report
# of Status/FStat/OCV0 that still catches a genuinely absent model.
fg=drivers/power/supply/max77779_fg.c
test -f "$fg"   # fail loudly if the shared tree moves or drops this driver
patch -p1 < "$src"/max77779-fg-portable-state.patch
grep -q "FStat.DNR says exactly that" "$fg" ||
	{ echo "apply.sh: fuel gauge patch did not apply" >&2; exit 1; }

# --- Wi-Fi: tegu's PCIe part is a BCM4383 --------------------------------
# The board's Wi-Fi is Broadcom's BCM4383, on PCIe channel 1, and mainline has
# never heard of it. The vendor's own bcmdhd module (Google's
# kernel/google-modules/wlan/bcmdhd/bcm4383) is where the three missing facts
# come from, and the shared tree's note -- "tegu uses a different part" -- is
# the same conclusion reached from the other side: its table carries 0x4438
# for the 4390 the other Zumapro boards use.
#
# Measured on the phone, in this order, each failure naming the next gap:
#
#   pci 0000:01:00.0: [14e4:4449] type 00 class 0x028000 PCIe Endpoint
#   brcmfmac: brcmf_chip_tcm_rambase: unknown chip: BCM4383/2
#   brcmfmac: brcmf_chip_get_raminfo: RAM base not provided with ARM CR4 core
#   brcmfmac: brcmf_pcie_probe: failed 14e4:4449      (-22, and no wlan0)
#
# so the patch adds, all of it from bcmdhd:
#
#   BCM4383_CHIP_ID          0x4383   (include/bcmdevs.h)
#   BCM4383_D11AX_ID         0x4449   (include/bcmdevs.h) -- the PCIe endpoint
#   CR4_4383_RAM_BASE        0x6e0000 (include/sbchipc.h)
#
# plus the firmware mapping the chip needs to make brcmfmac ask for the blob
# installed as brcmfmac4383a3-pcie.* (see ../wifi-firmware/README.md). The
# rev mask is all-revs: the vendor ships one firmware image for this part and
# the .clm_blob/.txcap_blob it pairs with it are named "..._4383_a3".
#
# WCC_SEED is the flow the rest of that family uses in this tree; note that
# neither the seed footers nor the OTP parse it enables can change anything
# here, because both are behind conditions this board does not meet (the
# seed footers are only written when a .txt NVRAM file is found, and
# brcmf_pcie_read_otp() has no 4383 case, so it returns early).
wifi=drivers/net/wireless/broadcom/brcm80211
patch -p1 < "$src"/brcmfmac-tegu-4383.patch
grep -q "BRCM_CC_4383_CHIP_ID" "$wifi/include/brcm_hw_ids.h" ||
	{ echo "apply.sh: brcmfmac chip id patch did not apply" >&2; exit 1; }
grep -q "BRCM_PCIE_4383_DEVICE_ID	0x4449" "$wifi/include/brcm_hw_ids.h" ||
	{ echo "apply.sh: brcmfmac pci id patch did not apply" >&2; exit 1; }
grep -q "BRCM_CC_4383_CHIP_ID:" "$wifi/brcmfmac/chip.c" ||
	{ echo "apply.sh: brcmfmac rambase patch did not apply" >&2; exit 1; }
grep -q "BRCM_CC_4383_CHIP_ID, 0xFFFFFFFF, 4383A3" "$wifi/brcmfmac/pcie.c" ||
	{ echo "apply.sh: brcmfmac firmware mapping patch did not apply" >&2; exit 1; }
grep -q "BRCM_PCIE_4383_DEVICE_ID, WCC_SEED" "$wifi/brcmfmac/pcie.c" ||
	{ echo "apply.sh: brcmfmac pci table patch did not apply" >&2; exit 1; }

# --- Wi-Fi: device->host DMA test knobs ----------------------------------
# Where the 4383 stops is the other direction: the dongle boots, then traps the
# moment msgbuf puts its rings and indices in host memory, and the buffers the
# host publishes are 64-bit coherent allocations (measured
# h2d_w_idx_hostaddr = 0x91e0aa000) while nothing in the PCIe node describes a
# device-initiated access to DRAM. Both knobs are read at probe time and the
# driver is built in, so once this is in the kernel the whole set of values can
# be swept from userspace -- write the parameter under
# /sys/module/brcmfmac/parameters/, re-bind the PCI device -- instead of
# rebuilding and reflashing for each one.
patch -p1 < "$src"/brcmfmac-tegu-dma-knobs.patch
grep -q "brcmf_pcie_dma_mask_bits" "$wifi/brcmfmac/pcie.c" ||
	{ echo "apply.sh: dma mask knob patch did not apply" >&2; exit 1; }
grep -q "brcmf_pcie_force_tcm_idx" "$wifi/brcmfmac/pcie.c" ||
	{ echo "apply.sh: tcm index knob patch did not apply" >&2; exit 1; }

# --- Wi-Fi: stop polling a TCM mailbox this firmware does not drive -------
# The shared tree added ctl-ring mailbox messages and gated the H2D *send*
# side on shared->mb_via_ctl, but left the D2H poll reading the TCM mailbox
# unconditionally. The BCM4383's firmware clears
# BRCMF_PCIE_SHARED_USE_MAILBOX (shared flags read 0x70050107), so mb_via_ctl
# is true and that word is not maintained: the host reads 0xffffffff, and
# brcmf_pcie_handle_mb_data() -- which asks only "is this bit set?" -- sees
# DS_ENTER_REQ, DS_EXIT, D3_ACK and FW_HALT all at once. The driver then
# "recovers" from a crash that never happened: it NAKs a deep-sleep request,
# dumps 2.2 MB of dongle RAM, and leaves the dongle trapped.
#
# Measured on the phone over the UART, one boot, same addresses:
#   shared RAM addr 0x00833234, dtoh_mb_data_addr 0x008a0b88
#   brcmf_pcie_handle_mb_data D2H_MB_DATA: 0xffffffff
#   AER: TLP Header: 0x00000001 0x0000000f 0x600a0b88   (backplane 0x8a0b88)
#   CONSOLE: err check: ... addr(0x00000000:008a0b88) / AXI timeout / TRAP 4
# and after the halt a devmem read of 0x8a0b88 returns 0, so the location is
# ordinary RAM, not a hole. In this mode the D2H word arrives over the ctl
# ring (brcmf_pcie_d2h_mb_rx, wired through msgbuf.c:1448 and bus.h), so the
# TCM poll is simply skipped.
patch -p1 < "$src"/brcmfmac-ctl-mb.patch
grep -q "which mailbox mechanism it drives" "$wifi/brcmfmac/pcie.c" ||
	{ echo "apply.sh: brcmfmac ctl-mailbox patch did not apply" >&2; exit 1; }

# --- Wi-Fi: stop a dead dongle's console from flooding the UART -----------
# brcmf_pcie_bus_console_read() loops "while (newidx != console->read_idx)"
# and wraps read_idx at bufsize, so it terminates only while the firmware's
# console write index is inside the buffer. Once the 4383 has trapped, that
# word reads back as all-ones -- the same value the mailbox read returns --
# which no wrapped read_idx can ever equal, so the loop re-reads and
# re-prints the whole 8 KB buffer forever. brcmf_pcie_isr_thread() calls it
# on every interrupt, so it then runs at the full line rate and never stops.
#
# This is what the ctl-mailbox fix above traded in. Before it, the driver
# answered the garbage mailbox word by tearing down the dead dongle
# (brcmf_pcie_remove at ~17 s), which stopped the poller; now the driver
# stays bound and the console is saturated. Per-boot UART capture size, same
# board and workload, is the measurement:
#   pre-patch  boots 11/12/13:  205900 /  63029 /  91929 bytes
#   post-patch boots 18/19/20: 7906197 / 2151401 / 1416745 bytes
# The cost is not just bytes: the flood drowns the serial-getty prompt, and
# with USB gadget access off the table that console is the only channel left
# once the dongle has trapped. The guard refuses only the impossible value --
# a stale but in-range write index still drains, bounded by a single wrap.
patch -p1 < "$src"/brcmfmac-console-idx.patch
grep -q "newidx >= console->bufsize" "$wifi/brcmfmac/pcie.c" ||
	{ echo "apply.sh: brcmfmac console-index patch did not apply" >&2; exit 1; }

# --- framebuffer: keep the panel blit inside the framebuffer --------------
# This is not a Wi-Fi change; it is what makes the serial console usable, and
# therefore what makes every later boot debuggable.
#
# SimplEdrm's plane update offsets the destination by the *clipped* damage rect
# but hands the blit helper the *unclipped* one, so the number of rows the blit
# walks comes from a rect that a client's damage clips are not required to keep
# inside the plane's destination. On tegu the damage can be one row taller than
# this panel's 1080x2424 mode, which puts the last row past the end of the
# framebuffer mapping ../kernel/zumapro-bootfb.c creates, and the write lands in
# the guard page one page beyond it:
#
#   Unable to handle kernel paging request at virtual address ffff8000829fd000
#     ESR = 0x0000000096000047   EC = 0x25 DABT   WnR = 1
#     FSC = 0x07: level 3 translation fault   pte=0000000000000000
#   memcpy_toio+0x44/0xc0 (P)
#   drm_fb_xrgb8888_to_bgrx8888+0x64/0xb0
#   drm_sysfb_plane_helper_atomic_update+0x160/0x1a0
#
# /proc/vmallocinfo puts the bootloader framebuffer's ioremap (phys 0xfac00000)
# at ffff800082000000-ffff8000829fe000, so ffff8000829fd000 is that mapping's
# last page -- the first one a one-row overflow reaches. Because the panic
# fires in the DRM commit worker, it takes the whole kernel down with it
# (panic_on_oops=1), which is why logging in on the serial console killed the
# phone twice during bring-up and why the console looked like it "hung".
#
# Hand the blit the same rect the destination was offset by, and say so once if
# the clip actually had to bite -- so a boot tells us whether the oversized
# damage is real rather than leaving us to infer it from a fault address.
fbmodeset=drivers/gpu/drm/sysfb/drm_sysfb_modeset.c
patch -p1 < "$src"/drm-sysfb-clip-damage.patch
grep -q "is not inside plane dst" "$fbmodeset" ||
	{ echo "apply.sh: drm_sysfb damage-clip patch did not apply" >&2; exit 1; }

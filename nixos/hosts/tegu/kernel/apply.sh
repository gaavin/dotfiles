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

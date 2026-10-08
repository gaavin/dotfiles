#!/usr/bin/env bash
# Enable the debug UART node in the vendor_kernel_boot DTB so the Samsung tty
# driver creates /dev/ttySAC0.
#
# Why this is needed:
#   The Pixel 9a's console UART is `uart@10870000`, aliased uart0/serial_0. In the
#   shipped DTB that node is `status = "disabled"`, so only the built-in
#   `earlycon` writes to it. Loading the exynos_tty module alone creates no tty,
#   because the driver has no device to bind to - verified on hardware: 18/18
#   console modules loaded, `ttySAC count: 0`.
#
# Why fdtput and not a dtc round-trip:
#   "okay" is shorter than "disabled", so libfdt can rewrite the property in
#   place with no need to grow the blob. That avoids any chance of a dtc
#   round-trip perturbing unrelated vendor properties.
#
# The rebuilt image reproduces every original header field exactly (verified by
# rebuilding from the unpatched parts and diffing the unpacked headers).
set -euo pipefail

TEJU="${TEJU:-/home/max/android/tegu}"
UNPACKED="$TEJU/unpacked/vendor_kernel_boot"
OUT="${OUT:-$TEJU/m1}"
NODE="/uart@10870000"
PART_SIZE=$((64 * 1024 * 1024))   # vendor_kernel_boot partition is 0x4000000

mkdir -p "$OUT"
WORK="${WORK:-/home/max/pixel9a-work/dtbpatch}"
rm -rf "$WORK"; mkdir -p "$WORK"

cp "$UNPACKED/dtb" "$WORK/dtb.patched"
cp "$UNPACKED/vendor_ramdisk00" "$WORK/ramdisk.v4"

echo "[dtb] before: status = $(fdtget -t s "$WORK/dtb.patched" "$NODE" status 2>&1)"
fdtput -t s "$WORK/dtb.patched" "$NODE" status okay
echo "[dtb] after : status = $(fdtget -t s "$WORK/dtb.patched" "$NODE" status 2>&1)"

# The vendor DTB region is far larger than the FDT itself (the blob's totalsize is
# ~386 KB while the image advertises dtb_size 1,546,258). That headroom is what
# lets the bootloader grow the blob while adding its androidboot.* fixups, so the
# rebuilt image must advertise the same dtb_size. Pad the patched FDT back to the
# original region size rather than letting mkbootimg shrink it.
PAD_TO=$(stat -c%s "$UNPACKED/dtb")
cp "$WORK/dtb.patched" "$WORK/dtb.final"
truncate -s "$PAD_TO" "$WORK/dtb.final"
echo "[dtb] FDT $(stat -c%s "$WORK/dtb.patched") B, padded to region size $(stat -c%s "$WORK/dtb.final") B"

echo "[dtb] rebuilding vendor_kernel_boot.img"
mkbootimg \
  --header_version 4 \
  --pagesize 2048 \
  --base 0x10000000 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --tags_offset 0x100 --dtb_offset 0x1f00000 \
  --vendor_boot "$OUT/vendor_kernel_boot.img" \
  --vendor_ramdisk "$WORK/ramdisk.v4" \
  --dtb "$WORK/dtb.final" \
  --board "" --vendor_cmdline ""

# Match the partition size so no stale bytes from the previous image remain.
truncate -s "$PART_SIZE" "$OUT/vendor_kernel_boot.img"

echo "[dtb] verifying"
unpack_bootimg --boot_img "$OUT/vendor_kernel_boot.img" --out "$WORK/verify" 2>&1 \
  | grep -E 'header version|page size|load address|dtb size|vendor ramdisk total'
echo "[dtb] dtb inside image: status = $(fdtget -t s "$WORK/verify/dtb" "$NODE" status 2>&1)"
ls -la "$OUT/vendor_kernel_boot.img"
echo "[dtb] done -> $OUT/vendor_kernel_boot.img"

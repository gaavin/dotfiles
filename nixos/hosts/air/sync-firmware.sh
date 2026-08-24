#!/usr/bin/env bash
# Sync vendorfw/firmware.cpio from the Asahi ESP into the flake and merge camera
# ISP calibration when needed. Safe to run from rebuild or the air installer.
set -euo pipefail

DISK=${DISK:-/dev/nvme0n1}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="$SCRIPT_DIR/firmware"
ESP_CPIO=""
UPDATE_ESP=1
NIX_EXTRA=(--extra-experimental-features "nix-command flakes")

usage() {
  cat <<EOF
Usage: sync-firmware.sh [options]

Options:
  --esp PATH     Source firmware.cpio (default: /efi/vendorfw/firmware.cpio)
  --no-esp-write Do not copy merged firmware back to the ESP
  -h, --help     Show this help
EOF
}

while (($# > 0)); do
  case $1 in
    --esp)
      ESP_CPIO=$2
      shift 2
      ;;
    --no-esp-write)
      UPDATE_ESP=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z $ESP_CPIO ]]; then
  for candidate in /efi/vendorfw/firmware.cpio /boot/vendorfw/firmware.cpio; do
    [[ -f $candidate ]] || continue
    ESP_CPIO=$candidate
    break
  done
fi

[[ -n $ESP_CPIO && -f $ESP_CPIO ]] || {
  echo "sync-firmware: firmware.cpio not found on ESP" >&2
  exit 1
}

mkdir -p "$FW_DIR"
cp "$ESP_CPIO" "$FW_DIR/firmware.cpio"

firmware_has_camera() {
  cpio -t --quiet <"$FW_DIR/firmware.cpio" 2>/dev/null |
    grep -qE '(^|\./)vendorfw/apple/isp_.*\.dat$'
}

cache_camerad() {
  local src=$1
  cp "$src" "$FW_DIR/appleh13camerad"
  chmod 600 "$FW_DIR/appleh13camerad"
}

find_camerad_in_cpio() {
  local tmp out member
  cpio -t --quiet <"$FW_DIR/firmware.cpio" 2>/dev/null | grep -q 'appleh13camerad' || return 1
  member=$(cpio -t --quiet <"$FW_DIR/firmware.cpio" | grep 'appleh13camerad' | head -1)
  tmp=$(mktemp -d)
  out="$tmp/appleh13camerad"
  (
    cd "$tmp"
    printf '%s\n' "$member" | cpio -id --no-absolute-filenames --quiet <"$FW_DIR/firmware.cpio"
    found=$(find . -name appleh13camerad -type f | head -1)
    [[ -n $found ]] || exit 1
    cp "$found" "$out"
  ) || {
    rm -rf "$tmp"
    return 1
  }
  printf '%s\n' "$out"
}

run_apfs_fuse() {
  if command -v apfs-fuse >/dev/null 2>&1; then
    apfs-fuse "$@"
  else
    nix shell "${NIX_EXTRA[@]}" nixpkgs#apfs-fuse --command apfs-fuse "$@"
  fi
}

prompt_macos_password() {
  local pass
  if [[ -n ${MACOS_PASSWORD:-} ]]; then
    printf '%s' "$MACOS_PASSWORD"
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi
  printf 'Unlock macOS volume for camera firmware (FileVault password): ' >/dev/tty
  IFS= read -rs pass </dev/tty || return 1
  printf '\n' >/dev/tty
  [[ -n $pass ]] || return 1
  printf '%s' "$pass"
}

mount_apfs_vol() {
  local dev=$1 mp=$2 vol=$3 pass=${4:-}
  umount "$mp" 2>/dev/null || true
  if [[ -n $pass ]]; then
    run_apfs_fuse -o uid=0,gid=0 -o "vol=$vol" -r "$pass" "$dev" "$mp" 2>/dev/null
  else
    run_apfs_fuse -o uid=0,gid=0 -o "vol=$vol" "$dev" "$mp" 2>/dev/null
  fi
}

search_camerad_on_apfs() {
  local dev=$1 pass=${2:-} mp vol
  mp=$(mktemp -d)
  for vol in $(seq 0 12); do
    if mount_apfs_vol "$dev" "$mp" "$vol" "$pass"; then
      if [[ -f $mp/usr/sbin/appleh13camerad ]]; then
        cache_camerad "$mp/usr/sbin/appleh13camerad"
        umount "$mp" 2>/dev/null || true
        rmdir "$mp" 2>/dev/null || true
        return 0
      fi
      umount "$mp" 2>/dev/null || true
    fi
  done
  rmdir "$mp" 2>/dev/null || true
  return 1
}

find_camerad_on_macos() {
  local line name size fstype type best_dev="" best_size=0 pass

  while IFS= read -r line; do
    NAME= SIZE= FSTYPE= TYPE=
    eval "$line"
    [[ ${TYPE:-} == part && ${FSTYPE:-} == apfs ]] || continue
    ((SIZE > best_size)) || continue
    best_size=$SIZE
    best_dev="/dev/${NAME}"
  done < <(lsblk -P -b -o NAME,SIZE,FSTYPE,TYPE "$DISK" 2>/dev/null)

  # Stub APFS containers are ~2.5 GiB; the macOS install is much larger.
  ((best_size > 5 * 1024 * 1024 * 1024)) || return 1
  [[ -n $best_dev && -b $best_dev ]] || return 1

  if search_camerad_on_apfs "$best_dev"; then
    return 0
  fi

  pass=$(prompt_macos_password) || return 1
  search_camerad_on_apfs "$best_dev" "$pass"
}

find_appleh13camerad() {
  local candidate tmp

  if [[ -n ${APPLEH13CAMERAD:-} && -f $APPLEH13CAMERAD ]]; then
    printf '%s\n' "$APPLEH13CAMERAD"
    return 0
  fi
  if [[ -f $FW_DIR/appleh13camerad ]]; then
    printf '%s\n' "$FW_DIR/appleh13camerad"
    return 0
  fi
  if tmp=$(find_camerad_in_cpio); then
    cache_camerad "$tmp"
    rm -rf "$(dirname "$tmp")"
    printf '%s\n' "$FW_DIR/appleh13camerad"
    return 0
  fi
  if find_camerad_on_macos; then
    printf '%s\n' "$FW_DIR/appleh13camerad"
    return 0
  fi
  return 1
}

merge_camera_firmware() {
  local cam tmp work
  cam=$(find_appleh13camerad) || return 1

  tmp=$(mktemp -d)
  work="$tmp/work"
  mkdir -p "$work"
  (
    cd "$work"
    cpio -id --no-absolute-filenames --quiet <"$FW_DIR/firmware.cpio"
    mkdir -p isp-in
    cp "$cam" isp-in/appleh13camerad
    nix shell "${NIX_EXTRA[@]}" nixpkgs#asahi-fwextract --command \
      python3 - isp-in vendorfw <<'PY'
import sys
from pathlib import Path
from asahi_firmware.isp import ISPFWCollection

source, dest = Path(sys.argv[1]), Path(sys.argv[2])
col = ISPFWCollection(str(source))
files = col.files()
if not files:
    raise SystemExit("no ISP calibration extracted from appleh13camerad")
for name, fwf in files:
    out = dest / name
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(fwf.data)
PY
    find vendorfw -print0 | cpio -o --null --quiet -H newc >firmware.cpio.new
    mv firmware.cpio.new "$FW_DIR/firmware.cpio"
  ) || {
    rm -rf "$tmp"
    echo "sync-firmware: failed to merge camera ISP calibration" >&2
    return 1
  }
  rm -rf "$tmp"
  cache_camerad "$cam"
  return 0
}

if firmware_has_camera; then
  exit 0
fi

if ! merge_camera_firmware; then
  echo "sync-firmware: warning: camera ISP missing (unlock macOS with FileVault password when prompted, or set MACOS_PASSWORD)" >&2
  exit 0
fi

if ((UPDATE_ESP == 1)); then
  cp "$FW_DIR/firmware.cpio" "$ESP_CPIO"
fi

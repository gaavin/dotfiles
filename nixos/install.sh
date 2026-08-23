#!/usr/bin/env bash
set -euo pipefail

DISK=/dev/nvme0n1
MAPPER=cryptroot
LUKS_PASSFILE=/tmp/dotfiles-luks
REPO_URL=https://github.com/gaavin/dotfiles.git
NIX_EXTRA=(--extra-experimental-features "nix-command flakes")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS=""
HOST=""
STEP_N=0
STEP_TOTAL=0

die() {
  if command -v gum >/dev/null 2>&1; then
    gum log --level error "$1"
  else
    echo "$1" >&2
  fi
  exit 1
}

cleanup() {
  if [[ -n ${SECRETS:-} && -d $SECRETS ]]; then
    rm -rf "$SECRETS"
  fi
  rm -f "$LUKS_PASSFILE" /mnt/root/chpasswd
}

nix_flake() {
  command nix "${NIX_EXTRA[@]}" "$@"
}

UI_WIDTH=50
UI_PAD_H=2
UI_PAD_V=1
NIXOS_VERSION="26.11 unstable"

theme() {
  export GUM_INPUT_CURSOR_FOREGROUND="39"
  export GUM_INPUT_PROMPT_FOREGROUND="39"
  export GUM_INPUT_HEADER_FOREGROUND="39"
  export GUM_INPUT_WIDTH="$UI_WIDTH"
  export GUM_INPUT_CHAR_LIMIT="512"
  export GUM_CONFIRM_PROMPT_FOREGROUND="39"
  export GUM_CONFIRM_SELECTED_FOREGROUND="15"
  export GUM_CONFIRM_SELECTED_BACKGROUND="39"
  export GUM_SPIN_SPINNER="dot"
  export GUM_SPIN_TITLE_FOREGROUND="39"
  export GUM_LOG_LEVEL="info"
}

host_arch() {
  case $(uname -m) in
    x86_64) echo "x86_64-linux" ;;
    aarch64) echo "aarch64-linux" ;;
    *) echo "$(uname -m)-linux" ;;
  esac
}

ui_faint() {
  printf '\033[2m%s\033[0m' "$1"
}

ui_banner() {
  local host=$1 label
  label="$host · $(host_arch)"
  gum style \
    --border rounded \
    --border-foreground 39 \
    --bold \
    --foreground 39 \
    --align center \
    --width "$UI_WIDTH" \
    --padding "$UI_PAD_V $UI_PAD_H" \
    --margin "1 0 0 0" \
    "NixOS" \
    "$(ui_faint "Version $NIXOS_VERSION")" \
    "$(ui_faint "$label")"
}

ui_heading() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    --bold \
    --foreground 39 \
    "$1"
}

ui_body() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --foreground 252 \
    "$@"
}

ui_installer() {
  local body=$1 line
  ui_heading "Installer"
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    line="${line#- }"
    ui_body "  • $line"
  done <<< "$body"
}

ui_ok() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --foreground 42 \
    "✓ $1"
}

ui_warn() {
  gum style \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --foreground 214 \
    "⚠ $1"
}

ui_step() {
  STEP_N=$((STEP_N + 1))
  ui_heading "$STEP_N/$STEP_TOTAL  $1"
}

ui_spin() {
  local title=$1
  shift
  gum spin --spinner dot --title "$title" --show-error -- "$@"
}

ui_box() {
  gum style \
    --border rounded \
    --border-foreground 245 \
    --width "$UI_WIDTH" \
    --padding "0 $UI_PAD_H" \
    --margin "1 0 0 0" \
    --foreground 252 \
    "$1"
}

ask_password() {
  local dest=$1 header=$2 pass pass2
  while true; do
    pass="$(gum input --password --header "$header" --placeholder "password" --prompt "▸ " --char-limit 0)" || exit 1
    if [[ -z $pass ]]; then
      ui_warn "Password cannot be empty"
      continue
    fi
    pass2="$(gum input --password --header "$header" --placeholder "confirm" --prompt "▸ " --char-limit 0)" || exit 1
    if [[ $pass != "$pass2" ]]; then
      ui_warn "Passwords do not match"
      continue
    fi
    printf '%s' "$pass" >"$dest"
    chmod 600 "$dest"
    unset pass pass2
    return
  done
}

confirm() {
  if [[ ${INSTALL_YES:-} == 1 ]]; then
    return
  fi
  gum confirm --default=false --affirmative "Continue" --negative "Cancel" "$1" || {
    ui_ok "Cancelled"
    exit 1
  }
}

detect_host() {
  if [[ -f /proc/device-tree/chosen/asahi,efi-system-partition ]]; then
    echo air
  elif [[ $(uname -m) == x86_64 ]]; then
    echo mina
  else
    die "unknown machine"
  fi
}

copy_repo() {
  mkdir -p /mnt/home/max
  rm -rf /mnt/home/max/dotfiles
  if [[ -f $REPO_ROOT/nixos/flake.nix ]]; then
    ui_spin "Copying configuration..." cp -a "$REPO_ROOT" /mnt/home/max/dotfiles
  elif command -v git >/dev/null 2>&1; then
    ui_spin "Cloning configuration..." git clone "$REPO_URL" /mnt/home/max/dotfiles
  else
    ui_spin "Cloning configuration..." \
      nix "${NIX_EXTRA[@]}" shell nixpkgs#git --command git clone "$REPO_URL" /mnt/home/max/dotfiles
  fi
}

luks_format_open() {
  local part=$1
  if ! cryptsetup luksFormat --type luks2 --sector-size 4096 --batch-mode --key-file "$SECRETS/luks" "$part"; then
    ui_warn "LUKS 4096-byte sectors not accepted, retrying with defaults"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$SECRETS/luks" "$part"
  fi
  cryptsetup open --key-file "$SECRETS/luks" "$part" "$MAPPER"
  rm -f "$SECRETS/luks"
}

disko_run() {
  if [[ $HOST == air && $1 == *destroy* ]]; then
    die "refusing Disko destroy on air"
  fi
  ui_spin "Formatting and mounting..." \
    nix "${NIX_EXTRA[@]}" run github:nix-community/disko/latest -- \
    --mode "$1" \
    "${@:2}" \
    --flake "path:$SCRIPT_DIR#$HOST"
}

air_part_state() {
  lsblk -n -b -r -o TYPE,PARTUUID,START,SIZE,FSTYPE,PARTLABEL "$DISK" |
    awk '$1 == "part" { print $2, $3, $4, $5, $6 }'
}

air_assert_preserved() {
  local before=$1 after=$2 line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if ! grep -Fxq "$line" <<<"$after"; then
      die "existing partition changed: $line"
    fi
  done <<<"$before"
}

air_assert_esp() {
  local esp_uuid=$1
  local esp=/dev/disk/by-partuuid/$esp_uuid
  [[ -b $esp ]] || die "ESP not found: $esp_uuid"
  [[ $(lsblk -n -o FSTYPE "$esp") == vfat ]] || die "ESP is not vfat: $esp_uuid"
}

set_passwords() {
  {
    printf 'root:%s\n' "$(cat "$SECRETS/root")"
    printf 'max:%s\n' "$(cat "$SECRETS/max")"
  } >"$SECRETS/chpasswd"
  chmod 600 "$SECRETS/chpasswd"
  mkdir -p /mnt/root
  cp "$SECRETS/chpasswd" /mnt/root/chpasswd
  chmod 600 /mnt/root/chpasswd
  ui_spin "Setting user passwords..." \
    nixos-enter --root /mnt -c 'chpasswd < /root/chpasswd && chown -R max:users /home/max'
  rm -f /mnt/root/chpasswd
}

install_system() {
  local flake=/mnt/home/max/dotfiles/nixos
  systemctl restart systemd-timesyncd || true
  ui_step "Install NixOS"
  if [[ $HOST == air ]]; then
    ui_ok "linux-asahi will compile; swap is on"
  else
    ui_ok "swap is on"
  fi
  nixos-install --no-root-password --no-channel-copy --root /mnt --flake "path:$flake#$HOST"
  set_passwords
}

install_mina() {
  command -v nixos-install >/dev/null || die "nixos-install not found"
  [[ -b $DISK ]] || die "$DISK not found"

  ui_step "Set up the disks (destructive)"
  ui_box "$(lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DISK" 2>/dev/null || true)"
  confirm "This WIPES $DISK."

  disko_run destroy,format,mount --yes-wipe-all-disks

  mountpoint -q /mnt || die "/mnt not mounted"
  copy_repo
  install_system
}

install_air() {
  local esp_uuid esp part fw candidate before after nixos_dev esp_dev
  command -v nixos-install >/dev/null || die "nixos-install not found"
  command -v cryptsetup >/dev/null && command -v sgdisk >/dev/null ||
    die "missing cryptsetup/sgdisk"
  [[ -b $DISK ]] || die "$DISK not found"
  [[ ! -e /dev/disk/by-partlabel/nixos ]] || die "/dev/disk/by-partlabel/nixos already exists; aborting"

  esp_uuid="$(tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition)"
  esp=/dev/disk/by-partuuid/$esp_uuid
  air_assert_esp "$esp_uuid"
  esp_dev="$(readlink -f "$esp")"

  ui_step "Create LUKS partition"
  ui_box "$(sgdisk -p "$DISK")"
  confirm "Create a LUKS partition in the free space on $DISK. iBoot, macOS, the ESP, and Recovery are left alone."

  before="$(air_part_state)"
  # 0:0:0 = first free number, first free start, end of that gap — existing slices stay
  ui_spin "Creating partition..." sgdisk "$DISK" -n 0:0:0 -t 0:8309 -c 0:nixos
  partprobe "$DISK"
  udevadm settle

  part=/dev/disk/by-partlabel/nixos
  for _ in {1..25}; do
    [[ -b $part ]] && break
    sleep 0.2
    udevadm settle || true
  done
  [[ -b $part ]] || die "new partition not found"
  nixos_dev="$(readlink -f "$part")"
  [[ $nixos_dev != "$esp_dev" ]] || die "refusing to format the ESP"

  after="$(air_part_state)"
  air_assert_preserved "$before" "$after"
  air_assert_esp "$esp_uuid"
  if [[ $(grep -c . <<<"$after") -ne $(($(grep -c . <<<"$before") + 1)) ]]; then
    die "expected exactly one new partition"
  fi

  ui_step "Encrypt disk"
  luks_format_open "$part"
  [[ $nixos_dev == "$(readlink -f "$part")" ]] || die "nixos partition moved"
  air_assert_preserved "$before" "$(air_part_state)"
  air_assert_esp "$esp_uuid"

  ui_step "Format and mount"
  disko_run format,mount
  mountpoint -q /mnt || die "/mnt not mounted"
  air_assert_preserved "$before" "$(air_part_state)"
  air_assert_esp "$esp_uuid"
  mkdir -p /mnt/efi
  ui_spin "Mounting original ESP..." mount "$esp" /mnt/efi
  mountpoint -q /mnt/efi || die "/mnt/efi not mounted"
  [[ $(readlink -f "$(findmnt -n -o SOURCE /mnt/efi)") == "$esp_dev" ]] || die "/mnt/efi is not the original ESP"
  for _ in {1..25}; do
    [[ -f /mnt/efi/vendorfw/firmware.cpio ]] && break
    sleep 0.2
  done

  ui_step "Copy firmware"
  copy_repo
  mkdir -p /mnt/home/max/dotfiles/nixos/hosts/air/firmware
  fw=""
  for candidate in /mnt/efi/vendorfw/firmware.cpio /efi/vendorfw/firmware.cpio /boot/vendorfw/firmware.cpio; do
    if [[ -f $candidate ]]; then
      fw=$candidate
      break
    fi
  done
  [[ -n $fw ]] || die "firmware.cpio not found on the ESP"
  ui_spin "Copying firmware..." cp "$fw" /mnt/home/max/dotfiles/nixos/hosts/air/firmware/

  cat >/mnt/home/max/dotfiles/nixos/hosts/air/hardware.nix <<EOF
{
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/${esp_uuid}";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
}
EOF

  install_system
}

finish() {
  local msg="reboot."
  if [[ $HOST == air ]]; then
    msg="reboot, then hold power for the Apple boot picker if you need macOS."
  fi
  gum style \
    --border rounded \
    --border-foreground 42 \
    --bold \
    --foreground 42 \
    --align center \
    --width "$UI_WIDTH" \
    --padding "$UI_PAD_V $UI_PAD_H" \
    --margin "1 0 0 0" \
    "Done." \
    "$(ui_faint "$msg")"
}

if [[ $EUID -ne 0 ]]; then
  exec sudo env \
    INSTALL_YES="${INSTALL_YES:-}" \
    TERM="${TERM:-}" \
    COLORTERM="${COLORTERM:-}" \
    "$0" "$@"
fi

export NIX_CONFIG="experimental-features = nix-command flakes"

if ! command -v gum >/dev/null 2>&1; then
  exec nix "${NIX_EXTRA[@]}" shell nixpkgs#gum --command env \
    INSTALL_YES="${INSTALL_YES:-}" \
    TERM="${TERM:-}" \
    COLORTERM="${COLORTERM:-}" \
    "$0" "$@"
fi

theme
trap cleanup EXIT

detected="$(detect_host)"
if [[ $# -gt 0 ]]; then
  [[ $1 == mina || $1 == air ]] || die "usage: $0 [mina|air]"
  HOST=$1
  [[ $HOST == "$detected" ]] || die "this machine is $detected, not $HOST"
else
  HOST=$detected
fi

ui_banner "$HOST"

SECRETS="$(mktemp -d /run/nixos-install.XXXXXX)"
chmod 700 "$SECRETS"

if [[ $HOST == air ]]; then
  STEP_TOTAL=6
else
  STEP_TOTAL=3
fi
STEP_N=0

if [[ $HOST == air ]]; then
  ui_installer "- Passwords
- Create LUKS partition
- Encrypt disk
- Format and mount
- Copy firmware
- Install NixOS"
else
  ui_installer "- Passwords
- Set up the disks (destructive)
- Install NixOS"
fi

ui_step "Passwords"
ask_password "$SECRETS/luks" "Disk encryption password"
cp "$SECRETS/luks" "$LUKS_PASSFILE"
chmod 600 "$LUKS_PASSFILE"
ask_password "$SECRETS/root" "root password"
ask_password "$SECRETS/max" "max password"
ui_ok "Passwords saved"

case $HOST in
  mina) install_mina ;;
  air) install_air ;;
esac

finish

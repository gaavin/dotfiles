#!/usr/bin/env bash
set -euo pipefail

DISK=/dev/nvme0n1
SWAP_SIZE=8G
MAPPER=cryptroot
LUKS_PASSFILE=/tmp/dotfiles-luks
REPO_URL=https://github.com/gaavin/dotfiles.git
NIX_EXTRA=(--extra-experimental-features "nix-command flakes")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS=""
HOST=""
VG=""

die() {
  echo "$1" >&2
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

git_cmd() {
  if command -v git >/dev/null 2>&1; then
    command git "$@"
  else
    nix_flake shell nixpkgs#git --command git "$@"
  fi
}

read_tty() {
  local prompt=$1 silent=${3:-} line
  if [[ $silent == silent ]]; then
    read -r -s -p "$prompt" line </dev/tty
    echo
  else
    read -r -p "$prompt" line </dev/tty
  fi
  printf -v "$2" '%s' "$line"
}

ask_password() {
  local dest=$1 pass pass2
  while true; do
    read_tty "Password: " pass silent
    read_tty "Confirm: " pass2 silent
    [[ -n $pass ]] || { echo "empty password"; continue; }
    [[ $pass == "$pass2" ]] || { echo "passwords do not match"; continue; }
    printf '%s' "$pass" >"$dest"
    chmod 600 "$dest"
    unset pass pass2
    return
  done
}

confirm() {
  local ok
  if [[ ${INSTALL_YES:-} == 1 ]]; then
    return
  fi
  read_tty "Continue? [y/N] " ok
  [[ $ok == y || $ok == Y ]] || exit 1
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
    cp -a "$REPO_ROOT" /mnt/home/max/dotfiles
  else
    git_cmd clone "$REPO_URL" /mnt/home/max/dotfiles
  fi
}

# LUKS2 cryptroot -> LVM VG=$HOST -> 8G swap + XFS root. Disko does this for mina.
luks_format_open() {
  local part=$1
  if ! cryptsetup luksFormat --type luks2 --sector-size 4096 --batch-mode --key-file "$SECRETS/luks" "$part"; then
    echo "LUKS 4096-byte sectors not accepted, retrying with defaults"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$SECRETS/luks" "$part"
  fi
  cryptsetup open --key-file "$SECRETS/luks" "$part" "$MAPPER"
  rm -f "$SECRETS/luks"
}

lvm_root_and_swap() {
  pvcreate -ff -y /dev/mapper/$MAPPER
  vgcreate "$VG" /dev/mapper/$MAPPER
  lvcreate -y -L "$SWAP_SIZE" -n swap "$VG"
  lvcreate -y -l 100%FREE -n root "$VG"
  udevadm settle
  mkswap -L swap /dev/mapper/${VG}-swap
  mkfs.xfs -f -L nixos /dev/mapper/${VG}-root
}

mount_lvm() {
  swapon /dev/mapper/${VG}-swap
  mount /dev/mapper/${VG}-root /mnt
  mkdir -p /mnt/efi /mnt/home/max
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
  nixos-enter --root /mnt -c 'chpasswd < /root/chpasswd && chown -R max:users /home/max'
  rm -f /mnt/root/chpasswd
}

install_system() {
  local flake=/mnt/home/max/dotfiles/nixos
  systemctl restart systemd-timesyncd || true
  echo
  if [[ $HOST == air ]]; then
    echo "Installing NixOS (linux-asahi will compile; swap is on)."
  else
    echo "Installing NixOS (swap is on)."
  fi
  nixos-install --no-root-password --no-channel-copy --root /mnt --flake "path:$flake#$HOST"
  set_passwords
}

install_mina() {
  command -v nixos-install >/dev/null || die "nixos-install not found"
  [[ -b $DISK ]] || die "$DISK not found"

  echo
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DISK" || true
  echo
  echo "This WIPES $DISK."
  confirm

  nix_flake run github:nix-community/disko/latest -- \
    --mode destroy,format,mount \
    --yes-wipe-all-disks \
    --flake "path:$SCRIPT_DIR#mina"

  mountpoint -q /mnt || die "/mnt not mounted"
  copy_repo
  install_system
}

install_air() {
  local esp_uuid part luks_uuid fw candidate
  command -v nixos-install >/dev/null || die "nixos-install not found"
  command -v cryptsetup >/dev/null && command -v sgdisk >/dev/null && command -v pvcreate >/dev/null ||
    die "missing cryptsetup/sgdisk/lvm"
  [[ -b $DISK ]] || die "$DISK not found"
  [[ ! -e /dev/disk/by-partlabel/nixos ]] || die "/dev/disk/by-partlabel/nixos already exists; aborting"

  esp_uuid="$(tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition)"
  [[ -b /dev/disk/by-partuuid/$esp_uuid ]] || die "ESP not found: $esp_uuid"

  echo
  sgdisk -p "$DISK"
  echo
  echo "This creates a LUKS partition in the free space on $DISK."
  echo "iBoot, macOS, the ESP, and Recovery are left alone."
  confirm

  sgdisk "$DISK" -n 0:0:0 -t 0:8309 -c 0:nixos
  partprobe "$DISK"
  udevadm settle

  part=/dev/disk/by-partlabel/nixos
  for _ in {1..25}; do
    [[ -b $part ]] && break
    sleep 0.2
    udevadm settle || true
  done
  [[ -b $part ]] || die "new partition not found"

  luks_format_open "$part"
  lvm_root_and_swap
  mount_lvm
  mount /dev/disk/by-partuuid/"$esp_uuid" /mnt/efi
  mountpoint -q /mnt/efi || die "/mnt/efi not mounted"
  for _ in {1..25}; do
    [[ -f /mnt/efi/vendorfw/firmware.cpio ]] && break
    sleep 0.2
  done

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
  cp "$fw" /mnt/home/max/dotfiles/nixos/hosts/air/firmware/

  luks_uuid="$(cryptsetup luksUUID "$part")"
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

  boot.initrd.services.lvm.enable = true;

  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-uuid/${luks_uuid}";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/${VG}-root";
    fsType = "xfs";
  };

  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/${esp_uuid}";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  swapDevices = [
    { device = "/dev/mapper/${VG}-swap"; }
  ];
}
EOF

  install_system
}

if [[ $EUID -ne 0 ]]; then
  exec sudo env INSTALL_YES="${INSTALL_YES:-}" "$0" "$@"
fi

export NIX_CONFIG="experimental-features = nix-command flakes"

trap cleanup EXIT

detected="$(detect_host)"
if [[ $# -gt 0 ]]; then
  [[ $1 == mina || $1 == air ]] || die "usage: $0 [mina|air]"
  HOST=$1
  [[ $HOST == "$detected" ]] || die "this machine is $detected, not $HOST"
else
  HOST=$detected
fi
VG=$HOST

SECRETS="$(mktemp -d /run/nixos-install.XXXXXX)"
chmod 700 "$SECRETS"

echo "$HOST"
echo
echo "Disk encryption password:"
ask_password "$SECRETS/luks"
cp "$SECRETS/luks" "$LUKS_PASSFILE"
chmod 600 "$LUKS_PASSFILE"
echo
echo "root password:"
ask_password "$SECRETS/root"
echo
echo "max password:"
ask_password "$SECRETS/max"

case $HOST in
  mina) install_mina ;;
  air) install_air ;;
esac

echo
if [[ $HOST == air ]]; then
  echo "Done. reboot, then hold power for the Apple boot picker if you need macOS."
else
  echo "Done. reboot."
fi

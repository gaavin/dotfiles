#!/usr/bin/env bash
set -euo pipefail

DISK=/dev/nvme0n1
VG=air
SWAP_SIZE=8G
MAPPER=cryptroot
REPO_URL=https://github.com/gaavin/dotfiles.git

die() {
  echo "$1" >&2
  exit 1
}

git_cmd() {
  if command -v git >/dev/null 2>&1; then
    command git "$@"
  else
    nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#git --command git "$@"
  fi
}

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f /proc/device-tree/chosen/asahi,efi-system-partition ]] || die "not an Asahi installer"
command -v cryptsetup >/dev/null && command -v sgdisk >/dev/null && command -v pvcreate >/dev/null || die "missing cryptsetup/sgdisk/lvm"

ESP_UUID="$(tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition)"
[[ -b /dev/disk/by-partuuid/$ESP_UUID ]] || die "ESP not found: $ESP_UUID"

if [[ -e /dev/disk/by-partlabel/nixos ]]; then
  die "/dev/disk/by-partlabel/nixos already exists; aborting"
fi

SECRETS=/run/air-install
FREE_GIB="$(sgdisk -p "$DISK" | awk '/Total free space/ { print $5 }')"
sgdisk -p "$DISK"
echo
echo "This creates a LUKS partition in the free space on $DISK (${FREE_GIB} available)."
echo "iBoot, macOS, the ESP, and Recovery are left alone."
echo

if [[ ${AIR_YES:-} == 1 ]]; then
  ok=y
else
  read -r -p "Continue? [y/N] " ok
fi
[[ $ok == y || $ok == Y ]] || exit 1

PASSFILE="$(mktemp)"
chmod 600 "$PASSFILE"
trap 'rm -f "$PASSFILE"' EXIT

if [[ -f $SECRETS/luks ]]; then
  cp "$SECRETS/luks" "$PASSFILE"
  chmod 600 "$PASSFILE"
else
  echo "Disk encryption password (you will type it at every boot):"
  read -r -s -p "Password: " pass
  echo
  read -r -s -p "Confirm: " pass2
  echo
  [[ -n $pass ]] || die "password is empty"
  [[ $pass == "$pass2" ]] || die "passwords do not match"
  printf '%s' "$pass" >"$PASSFILE"
  unset pass pass2
fi

sgdisk "$DISK" -n 0:0:0 -t 0:8309 -c 0:nixos
partprobe "$DISK"
udevadm settle

PART=/dev/disk/by-partlabel/nixos
[[ -b $PART ]] || die "new partition not found"

if ! cryptsetup luksFormat --type luks2 --sector-size 4096 --batch-mode --key-file "$PASSFILE" "$PART"; then
  echo "LUKS 4096-byte sectors not accepted, retrying with defaults"
  cryptsetup luksFormat --type luks2 --batch-mode --key-file "$PASSFILE" "$PART"
fi
cryptsetup open --key-file "$PASSFILE" "$PART" "$MAPPER"
rm -f "$PASSFILE"
trap - EXIT

pvcreate -ff -y /dev/mapper/$MAPPER
vgcreate "$VG" /dev/mapper/$MAPPER
lvcreate -y -L "$SWAP_SIZE" -n swap "$VG"
lvcreate -y -l 100%FREE -n root "$VG"
udevadm settle

mkswap -L swap /dev/mapper/${VG}-swap
mkfs.xfs -f -L nixos /dev/mapper/${VG}-root

swapon /dev/mapper/${VG}-swap
mount /dev/mapper/${VG}-root /mnt
mkdir -p /mnt/efi /mnt/home/max
mount /dev/disk/by-partuuid/"$ESP_UUID" /mnt/efi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if REPO="$(git_cmd -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  mkdir -p /mnt/home/max
  rm -rf /mnt/home/max/dotfiles
  cp -a "$REPO" /mnt/home/max/dotfiles
else
  git_cmd clone "$REPO_URL" /mnt/home/max/dotfiles
fi

FLAKE=/mnt/home/max/dotfiles/nixos
mkdir -p "$FLAKE/hosts/air/firmware"
cp /mnt/efi/vendorfw/firmware.cpio "$FLAKE/hosts/air/firmware/"

LUKS_UUID="$(cryptsetup luksUUID "$PART")"
cat >"$FLAKE/hosts/air/hardware.nix" <<EOF
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
    device = "/dev/disk/by-uuid/${LUKS_UUID}";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/${VG}-root";
    fsType = "xfs";
  };

  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/${ESP_UUID}";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  swapDevices = [
    { device = "/dev/mapper/${VG}-swap"; }
  ];
}
EOF

git_cmd -C /mnt/home/max/dotfiles add nixos/hosts/air/hardware.nix

systemctl restart systemd-timesyncd || true

echo
echo "Installing NixOS (linux-asahi will compile; swap is on)."
nixos-install --no-root-password --flake "path:$FLAKE#air"

if [[ -f $SECRETS/users ]]; then
  cp "$SECRETS/users" /mnt/root/chpasswd
  chmod 600 /mnt/root/chpasswd
  nixos-enter --root /mnt -c 'chpasswd < /root/chpasswd; shred -u /root/chpasswd || rm -f /root/chpasswd'
else
  echo "Set root password:"
  nixos-enter --root /mnt -c 'passwd root'
  echo "Set max password:"
  nixos-enter --root /mnt -c 'passwd max'
fi
chown -R 1000:1000 /mnt/home/max
rm -rf "$SECRETS"

echo
echo "Done. reboot, then hold power for the Apple boot picker if you need macOS."

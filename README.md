<div align="center">

**Declarative NixOS** · Flakes · Plasma 6 · mina (AMD) · air (Asahi)

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/nix-flakes-informational?logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![Plasma](https://img.shields.io/badge/KDE-Plasma%206-1D99F3?logo=kde&logoColor=white)](https://kde.org/plasma-desktop/)
[![License](https://img.shields.io/badge/license-personal-lightgrey)](https://github.com/gaavin/dotfiles)

</div>

---

| Layer | mina | air |
| --- | --- | --- |
| OS | NixOS unstable, flakes, Home Manager | same |
| Desktop | KDE Plasma 6, Breeze Dark, systemd-boot + Plymouth | same |
| Kernel / GPU | `linuxPackages_cachyos-lto`, mesa-git, amdgpu | `linux-asahi`, Mesa Asahi |
| Disk | Disko · GPT · 2G ESP (`/efi`) · XFS root | Asahi stub + ESP · XFS root in free space |
| Audio | PipeWire, 128/48000 low-latency | same, plus Asahi speaker safety |
| Apps | Steam/Battle.net/Epic, osu!, Firefox, Cursor, 1Password | Firefox, Cursor, 1Password (no x86-only gaming) |

```
mina nvme0n1                          air nvme0n1
├── ESP   2G    vfat   /efi           ├── iBootSystemContainer
└── root  rest  xfs    /              ├── macOS APFS
                                      ├── Asahi stub
                                      ├── ESP   ~500M  vfat  /efi
                                      ├── root  rest   xfs   /
                                      └── RecoveryOSContainer
```

Apple Silicon hardware support is documented on the [Asahi feature-support wiki](https://github.com/AsahiLinux/docs/wiki/Feature-Support).

---

## Install mina (AMD desktop)

Boot a generic NixOS installer, clone this repo, then run the commands from `dotfiles/nixos/` (the flake root).

> [!CAUTION]
> Disko `--mode destroy,format,mount` **wipes** `/dev/nvme0n1`. Confirm the disk before continuing. Never run this on the MacBook.

```bash
git clone https://github.com/gaavin/dotfiles.git
cd dotfiles/nixos
```

Partition, format, and mount:

```bash
sudo nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko/latest -- \
  --mode destroy,format,mount \
  --flake .#mina
```

Install the system:

```bash
sudo nixos-install --flake .#mina
```

Set the user password, then reboot:

```bash
sudo nixos-enter --root /mnt -c 'passwd max'
```

---

## Install air (M1 MacBook Air)

Do **not** use a generic NixOS ISO or Disko. Apple's iBoot and recovery partitions must stay intact. Follow the [nixos-apple-silicon UEFI guide](https://github.com/nix-community/nixos-apple-silicon/blob/main/docs/uefi-standalone.md) for the Asahi/U-Boot steps; this repo is the NixOS configuration once that environment exists.

### 1. UEFI environment from macOS

In Terminal.app, as an admin:

```bash
curl https://alx.sh | sh
```

- Resize macOS (`r`) so there is room for NixOS (at least ~20GB extra; more is better).
- Install an OS into free space (`f`) → **UEFI environment only**.
- Name it NixOS.
- Shut down, hold the power button into recovery, select NixOS, set a custom boot object and **permissive security**, then reboot into U-Boot.

Do not install a full Asahi distro; the stub + ESP is enough.

### 2. Installer ISO

Download the latest Apple Silicon installer ISO from [nixos-apple-silicon releases](https://github.com/nix-community/nixos-apple-silicon/releases) (not a generic NixOS ISO). `dd` it to a USB drive. Programs like unetbootin are not supported.

### 3. Boot the installer

Shut down, plug in the USB drive, power on. U-Boot should boot from USB. If something is already on the internal ESP, interrupt autoboot and run `bootmenu`, then choose `usb 0`. If that is missing: `setenv boot_targets "usb" ; setenv bootmeths "efi" ; boot`.

Get a root shell with `sudo su`. Use `iwctl` for Wi-Fi (`station wlan0 scan` / `connect`).

### 4. Partition (free space only)

> [!CAUTION]
> Do **not** run Disko, `wipefs` on the whole disk, or any automatic partitioner. Damaging `iBootSystemContainer` or `RecoveryOSContainer` can make the Mac unrecoverable without another computer.

Add a root partition in the remaining free space and format it XFS (same as mina; the upstream guide uses ext4):

```bash
sgdisk /dev/nvme0n1 -n 0:0 -s
sgdisk /dev/nvme0n1 -p
```

Use the new `8300` partition (typically second to last). Then:

```bash
mkfs.xfs -L nixos /dev/nvme0n1pN
```

### 5. Mount, firmware, and flake

```bash
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/efi /mnt/home/max
mount /dev/disk/by-partuuid/"$(tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition)" /mnt/efi

# linux-asahi has no binary cache; 8GB machines often OOM without this
fallocate -l 8G /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

git clone https://github.com/gaavin/dotfiles.git /mnt/home/max/dotfiles
cd /mnt/home/max/dotfiles/nixos

cp /mnt/efi/vendorfw/firmware.cpio hosts/air/firmware/
git add -f hosts/air/firmware/firmware.cpio

ESP_UUID="$(tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition)"
sed -i "s/00000000-0000-0000-0000-000000000000/${ESP_UUID}/" hosts/air/hardware.nix
```

`firmware.cpio` is non-redistributable Apple firmware. It is gitignored; `git add -f` is only so the flake can see it. Do not push it.

### 6. Install

```bash
nixos-install --flake /mnt/home/max/dotfiles/nixos#air
nixos-enter --root /mnt -c 'passwd max'
swapoff /mnt/swapfile
rm /mnt/swapfile
reboot
```

After reboot, hold the power button for the Apple boot picker. Option (Alt) + Always Use sets the default OS.

---

## Rebuild

After installation, apply configuration changes with:

```bash
rebuild
```

That alias updates the flake lock and switches the **current hostname** (`mina` or `air`):

```bash
nix flake update --flake ~/dotfiles/nixos && sudo nixos-rebuild switch --flake ~/dotfiles/nixos#$(hostname)
```

---

## Layout

```
nixos/
├── flake.nix                 # inputs and mkHost (mina, air)
├── configuration.nix         # shared system
├── home.nix                  # shared user; x86-only packages gated
├── hosts/mina/               # Disko, CachyOS kernel, Steam, AMD
├── hosts/air/                # Asahi kernel, iwd, firmware (local)
└── wallpaper.jpg
```

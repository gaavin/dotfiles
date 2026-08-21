<div align="center">

**Declarative NixOS desktop** · Flakes · Plasma 6 · AMD

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/nix-flakes-informational?logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![Plasma](https://img.shields.io/badge/KDE-Plasma%206-1D99F3?logo=kde&logoColor=white)](https://kde.org/plasma-desktop/)
[![License](https://img.shields.io/badge/license-personal-lightgrey)](https://github.com/gaavin/dotfiles)

</div>

---

| Layer | Choice |
| --- | --- |
| OS | NixOS unstable, flakes, Home Manager |
| Desktop | KDE Plasma 6, Breeze Dark, systemd-boot + Plymouth |
| Kernel / GPU | `linuxPackages_cachyos-lto`, mesa-git, amdgpu |
| Disk | Disko · GPT · 2G ESP (`/efi`) · XFS root on `nvme0n1` |
| Audio | PipeWire, 128/48000 low-latency |
| Apps | Steam/Battle.net (Proton CachyOS), osu! stable, Firefox, Cursor, 1Password |

```
nvme0n1
├── ESP   2G    vfat   /efi
└── root  rest  xfs    /
```

---

## Install

Boot a NixOS installer, clone this repo, then run the commands from `dotfiles/nixos/` (the flake root).

> [!CAUTION]
> Disko `--mode destroy,format,mount` **wipes** `/dev/nvme0n1`. Confirm the disk before continuing.

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

## Rebuild

After installation, you can apply any configuration changes with this command:

```bash
rebuild
```

That alias updates the flake lock and switches:

```bash
nix flake update --flake ~/dotfiles/nixos && sudo nixos-rebuild switch --flake ~/dotfiles/nixos#mina
```

---

## Layout

```
nixos/
├── flake.nix                 # inputs and mina host
├── configuration.nix         # system, disko, boot, services
├── hardware-configuration.nix
├── home.nix                  # user: Plasma, Firefox, git, tools
└── wallpaper.jpg
```

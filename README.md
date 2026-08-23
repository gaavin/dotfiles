<div align="center">

**NixOS** · Flakes · Plasma 6 · mina (AMD) · air (M1)

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/nix-flakes-informational?logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![Plasma](https://img.shields.io/badge/KDE-Plasma%206-1D99F3?logo=kde&logoColor=white)](https://kde.org/plasma-desktop/)
[![License](https://img.shields.io/badge/license-personal-lightgrey)](https://github.com/gaavin/dotfiles)

</div>

> [!WARNING]
> **This project was primarily written by an LLM (AI). Review the code yourself before running it. Use at your own risk.**

---

```
mina nvme0n1                          air nvme0n1
├── ESP   2G    vfat   /efi           ├── iBoot
└── root  rest  xfs    /              ├── macOS
                                      ├── Asahi stub
                                      ├── ESP     vfat   /efi
                                      ├── LUKS
                                      │   ├── root  xfs  /
                                      │   └── swap  8G
                                      └── Recovery
```

---

## Install mina

Boot a NixOS installer, clone this repo, run from `dotfiles/nixos/`.

> [!CAUTION]
> Disko `--mode destroy,format,mount` wipes `/dev/nvme0n1`.

```bash
git clone https://github.com/gaavin/dotfiles.git
cd dotfiles/nixos

sudo nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko/latest -- \
  --mode destroy,format,mount \
  --flake .#mina

sudo nixos-install --flake .#mina
sudo nixos-enter --root /mnt -c 'passwd max'
```

---

## Install air

Needs macOS 12.3+, an admin account, and a USB stick (≥512MB) you can erase.

Do not use a stock NixOS ISO. Do not run Disko. The first NVMe partition (`iBoot`) and the last (`Recovery`) must not be touched; if they are, the Mac will not boot without another computer and [idevicerestore](https://github.com/libimobiledevice/idevicerestore).

Upstream reference: [nixos-apple-silicon UEFI guide](https://github.com/nix-community/nixos-apple-silicon/blob/main/docs/uefi-standalone.md).

### 1. From macOS: Asahi UEFI stub

In Terminal.app (admin user):

```bash
curl https://alx.sh | sh
```

Go through the installer in this order:

1. Admin password. **Do not** enable expert mode.
2. Resize macOS: `r`. The new macOS size must be at least 20GB smaller than now (here 1GB = 1,000,000,000 bytes). Confirm. Leave it alone while it resizes (minutes). Press enter when it finishes.
3. Install into free space: `f` → **UEFI environment only** → name it `NixOS` (this is the boot picker label). Password again. Wait until the default boot volume is set. Read the last screen, press enter — the Mac shuts down.

Then, exactly as that last screen said:

1. Hold the power button until the boot picker appears. Choose **NixOS**.
2. Admin password. Wait for the local policy update.
3. Set a custom boot object and **permissive security**. Admin username (same account as the password) and password.
4. Reboot. You should get the Asahi and U-Boot logos. Hold the power button to shut down.

If you already have an old Asahi/UEFI stub, recreate it; old m1n1 often will not boot the current installer ISO.

### 2. Write the installer USB

Download the latest `*-apple-silicon-*.iso` from [nixos-apple-silicon releases](https://github.com/nix-community/nixos-apple-silicon/releases). `dd` it to the disk, not a partition. Not Etcher / unetbootin.

macOS (`diskutil list` → your USB, e.g. `disk4`; this erases it):

```bash
diskutil unmountDisk /dev/disk4
sudo dd if=nixos-*.iso of=/dev/rdisk4 bs=1m
```

Linux:

```bash
sudo dd if=nixos-*.iso of=/dev/sdX bs=4M status=progress oflag=direct
```

### 3. Boot the installer

Plug in the USB, power on. U-Boot should boot from USB.

If it boots the internal disk instead: hit a key to stop autoboot, then:

```
eficonfig
```

Change Boot Order → move `usb 0` to the top with `+` → Save → Quit → `boot`.

GRUB, then the NixOS installer. At the console:

```bash
sudo su
setfont ter-v32n
```

Wi-Fi:

```bash
nmtui
```

### 4. Install

Only uses the free space Asahi left. Prompts for the LUKS password (same one at every boot) and `max`'s login password.

```bash
nix --extra-experimental-features 'nix-command flakes' \
  shell nixpkgs#git --command \
  git clone https://github.com/gaavin/dotfiles.git
cd dotfiles
./nixos/hosts/air/install.sh
reboot
```

`firmware.cpio` is Apple's Wi-Fi firmware. It is gitignored; `path:` lets Nix see it anyway. Do not commit it.

After reboot you will be asked for the disk password, then you can log in. Hold power for the Apple boot picker. Option (Alt) + Always Use sets the default OS.

---

## Rebuild

```bash
rebuild
```

`rebuild` is a command, not a shell alias. Open a new terminal after the first switch (or run `unalias rebuild`) so the old alias is not used.

```bash
nix flake update --flake ~/dotfiles/nixos && sudo nixos-rebuild switch --flake path:$HOME/dotfiles/nixos#$(hostname)
```

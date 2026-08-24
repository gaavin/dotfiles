<div align="center">

**NixOS** · Flakes · Plasma 6 · mina (AMD) · air (M1)

[![NixOS](https://img.shields.io/badge/NixOS-unstable-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/nix-flakes-informational?logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![Plasma](https://img.shields.io/badge/KDE-Plasma%206-1D99F3?logo=kde&logoColor=white)](https://kde.org/plasma-desktop/)
[![License](https://img.shields.io/badge/license-personal-lightgrey)](https://github.com/gaavin/dotfiles)

</div>

> [!WARNING]
> **This project was primarily written by an LLM (AI). Review the code yourself before running it. Use at your own risk.**

## Install

Boot a NixOS installer, clone this repo, run the script.

<p align="center">
  <img src="assets/nixos-installer.gif" alt="NixOS installer TUI on mina" width="400">
</p>

> [!CAUTION]
> **Destructive** The script creates a LUKS partition in the largest free GPT gap. iBoot, macOS, the shared ESP, and Recovery are left alone; the Asahi ESP is mounted at `/efi`, never formatted. Partitions that do not belong to macos will be destroyed to make room for NixOS.

> **😪😪😪** First install is large (Plasma + `linux-asahi` from source; no Asahi binary cache). The live ISO only has a RAM-backed `/nix` store, so the installer formats the target disk first, then moves the writable nix store and build temp onto `/mnt` before fetching inputs or compiling. Expect a long build; sleep is inhibited for the whole run.


```bash
# if you need to connect to wifi
sudo nmtui

nix run nixpkgs#git -- clone https://github.com/gaavin/dotfiles.git
cd dotfiles
sudo ./nixos/install.sh
```

### Instructions for users with Apple Silicon running macOS

```bash
curl https://alx.sh | sh
```

1. Enter your password. **Do not** enable expert mode.
2. Resize macOS: `r`. New size must be at least 20GB smaller (here 1GB = 1,000,000,000 bytes). Confirm. Wait (minutes), then press enter.
3. Install into free space: `f` → **UEFI environment only** → name it `NixOS`. Password again. Wait until the default boot volume is set. Read the last screen, press enter — the Mac shuts down.
4. Hold power until the boot picker appears. Choose **NixOS**.
5. Admin password. Wait for the local policy update.
6. Set a custom boot object and **permissive security**. Same admin username and password.
7. Reboot. You should get the Asahi and U-Boot logos. Hold power to shut down.

Write the latest `*-apple-silicon-*.iso` from [nixos-apple-silicon releases](https://github.com/nix-community/nixos-apple-silicon/releases) to the **usb disk**, unfortunately other solutions such as Ventoy are not working.

(`diskutil list` → USB, e.g. `disk4`):

```bash
diskutil unmountDisk /dev/disk4
sudo dd if=nixos-*.iso of=/dev/rdisk4 bs=1m
```

Plug in the USB and power on. Then run **Install** above.

> **Webcam** Recent Asahi installs include camera ISP data in `vendorfw/firmware.cpio`. If yours predates that, copy `/usr/sbin/appleh13camerad` from macOS and set `APPLEH13CAMERAD=/path/to/it` before install; the script merges ISP calibration automatically.

---

## Rebuild

Updates the flake and runs `nixos-rebuild switch` for the current hostname. On air, also syncs firmware from `/efi` on asahi machines.

```bash
rebuild
```

<p align="center">
  <img src="assets/setup.png" alt="mina and air running NixOS Plasma" width="720">
</p>

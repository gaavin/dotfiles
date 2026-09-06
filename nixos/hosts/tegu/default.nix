# Google Pixel 9a (tegu) — NixOS on a mainline kernel.
#
# This host is built as Android boot images + an ext4 root image, not
# installed with nixos-install. See ./README.md for status and flashing.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "tegu";

  boot = {
    kernelPackages = pkgs.linuxPackagesFor (pkgs.callPackage ./kernel.nix { });

    # ABL (the Pixel bootloader) passes this from the boot image's cmdline;
    # images.nix prepends init=<toplevel>/init.
    kernelParams = [
      "console=ttySAC0,115200n8"
      "earlycon"
      # No clock driver for zumapro yet: never gate what the bootloader left on
      "clk_ignore_unused"
      "no_console_suspend"
      "printk.devkmsg=on"
      "boot.shell_on_fail"
    ];

    # No firmware-level bootloader to manage: the boot.img is the loader
    loader.grub.enable = false;

    initrd = {
      systemd = {
        enable = true;
        # Root cannot mount until UFS is described; land in a shell on the UART
        emergencyAccess = true;
      };
      # Everything the initrd needs is built in; a lean kernel has no modules
      # to pull from the usual x86-centric default list.
      includeDefaultModules = false;
      availableKernelModules = [ ];
      kernelModules = [ ];
    };

    # The root image is populated by make-ext4-fs, which leaves a store
    # registration file behind instead of a Nix database.
    postBootCommands = ''
      if [ -f /nix-path-registration ]; then
        ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration
        touch /etc/NIXOS
        ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
        rm -f /nix-path-registration
      fi
    '';
  };

  fileSystems."/" = {
    # Android's userdata partition, reused wholesale as the NixOS root
    device = "/dev/disk/by-partlabel/userdata";
    fsType = "ext4";
    options = [
      "noatime"
      "lazytime"
    ];
  };

  swapDevices = [ ];
  zramSwap.enable = true;

  hardware = {
    # Nothing is loaded from linux-firmware until a driver can use it
    enableRedistributableFirmware = false;
    graphics.enable = true;
    bluetooth.enable = false;
  };

  # Phone shell: Plasma Mobile on Wayland, auto-logged-in. nixpkgs has no
  # module for the mobile shell, only the package, so register its session
  # with SDDM directly.
  services = {
    desktopManager.plasma6.enable = true;
    displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      sessionPackages = [ pkgs.kdePackages.plasma-mobile ];
      defaultSession = "plasma-mobile";
      autoLogin = {
        enable = true;
        user = "max";
      };
    };
    openssh = {
      enable = true;
      settings.PasswordAuthentication = true;
    };
    pipewire = {
      enable = true;
      pulse.enable = true;
    };
    logind.settings.Login.HandlePowerKey = "ignore";
  };

  networking.networkmanager.enable = true;
  # Debug network over the USB-C port (10.42.0.1 on the phone) once the
  # DWC3 controller is described; fails harmlessly until then.
  systemd.services.usb-gadget-net = {
    description = "USB NCM gadget for host<->phone networking";
    wantedBy = [ "multi-user.target" ];
    after = [ "sys-kernel-config.mount" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      set -eu
      g=/sys/kernel/config/usb_gadget/nixos
      udc=$(ls /sys/class/udc | head -n1) || exit 0
      [ -n "$udc" ] || exit 0
      mkdir -p $g
      echo 0x18d1 > $g/idVendor
      echo 0x4ee1 > $g/idProduct
      mkdir -p $g/strings/0x409
      echo tegu > $g/strings/0x409/serialnumber
      echo NixOS > $g/strings/0x409/manufacturer
      echo "Pixel 9a" > $g/strings/0x409/product
      mkdir -p $g/configs/c.1/strings/0x409
      echo ncm > $g/configs/c.1/strings/0x409/configuration
      mkdir -p $g/functions/ncm.usb0
      ln -sf $g/functions/ncm.usb0 $g/configs/c.1/
      echo "$udc" > $g/UDC
      ${pkgs.iproute2}/bin/ip addr add 10.42.0.1/24 dev usb0
      ${pkgs.iproute2}/bin/ip link set usb0 up
    '';
  };

  users.users.max = {
    isNormalUser = true;
    description = "Max Power";
    extraGroups = [
      "wheel"
      "networkmanager"
      "dialout"
      "video"
      "audio"
    ];
    # First-boot credential on a device with no installer; change it once in
    initialPassword = "nixos";
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    kdePackages.plasma-mobile
    maliit-keyboard
    vim
    usbutils
    pciutils
    i2c-tools
    evtest
    htop
  ];

  documentation = {
    enable = false;
    nixos.enable = false;
  };

  i18n.defaultLocale = "en_CA.UTF-8";
  time.timeZone = "America/St_Johns";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  system.stateVersion = "26.05";
}

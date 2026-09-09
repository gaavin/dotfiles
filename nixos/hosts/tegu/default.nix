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

let
  # busybox's devmem applet on its own, so the rest of userspace keeps
  # coreutils. It matters that this is devmem and not dd: on arm64,
  # valid_phys_addr_range() restricts /dev/mem read() to real memory, so
  # reading MMIO with dd returns EFAULT no matter what STRICT_DEVMEM says.
  # devmem uses mmap(), which takes a different path in drivers/char/mem.c and
  # does reach MMIO.
  devmem = pkgs.runCommand "devmem" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.busybox}/bin/busybox $out/bin/devmem
  '';
in
{
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "tegu";

  boot = {
    # ./cross-kernel.nix overrides this with an x86_64-built kernel
    kernelPackages = lib.mkDefault (pkgs.linuxPackagesFor (pkgs.callPackage ./kernel.nix { }));

    # ABL (the Pixel bootloader) passes this from the boot image's cmdline;
    # images.nix prepends init=<toplevel>/init.
    kernelParams = [
      # Serial console stays for anyone with a debug cable; earlycon is a
      # no-op without one.
      "console=ttySAC0,115200n8"
      "earlycon"
      # Adopt the bootloader's framebuffer (kernel/zumapro-bootfb.c) and make
      # fbcon on it the primary console: the last console= wins /dev/console,
      # so the initrd emergency shell and systemd land on the panel.
      "zumapro_bootfb"
      "console=tty0"
      # 1080 px across at ~430 dpi; the 8x16 default is unreadable
      # Take the panel over immediately. fbcon defers handover on a firmware
      # framebuffer, waiting for a real display driver to replace it; on this
      # device that driver does not exist, so without nodefer the boot splash
      # stays on screen and nothing is ever printed. This was only masked
      # earlier because a kernel panic forces the handover anyway.
      # One fbcon= only: a second occurrence replaces the first rather
      # than adding to it, which silently discarded the font setting.
      "fbcon=font:TER16x32,nodefer"
      # No clock/power-domain drivers for zumapro yet: never gate what the
      # bootloader left on, or the panel goes dark
      "clk_ignore_unused"
      "pd_ignore_unused"
      "no_console_suspend"
      "printk.devkmsg=on"
      # Leave a crash on screen instead of rebooting into Android
      "panic=0"
      "boot.shell_on_fail"
    ];

    # No firmware-level bootloader to manage: the boot.img is the loader
    loader.grub.enable = false;

    # The panel is the only console, so print everything to it. NixOS
    # defaults to 4, which hides every pr_info and would leave the screen
    # blank through a successful boot.
    consoleLogLevel = 7;

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
    # Reports success without doing anything, and has always done so: with
    # no UDC (dwc3 does not probe on this SoC yet) the first line exits 0, so
    # "[  OK  ] Finished USB NCM gadget" in a boot log means nothing has
    # happened. It also needs USB_CONFIGFS, which ./kernel.nix does not set,
    # so /sys/kernel/config/usb_gadget would not exist even with a UDC.
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

    devmem

    # spi-pipe and spi-config, to talk to the touchscreen from a shell before
    # committing to a driver for it.
    spi-tools
  ];

  # Run whatever command the kernel command line carries. This is the write
  # half of the debug loop: the UART is receive-only and there is no USB
  # gadget yet, so without it the only way to change what the phone does is to
  # rebuild and reflash an 11 GB rootfs. vendor_boot is 24 KB and flashes in
  # milliseconds, and ABL appends its vendor_cmdline, so a command can ride in
  # there. See tools/tegu-cmd on the build host.
  systemd.services.tegu-cmd = {
    description = "Run a command passed on the kernel command line";
    wantedBy = [ "multi-user.target" ];
    after = [ "tegu-touch-probe.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.runtimeShell} ${./tegu-cmd.sh}";
    };
    # systemd.services.<name>.path REPLACES PATH rather than extending it, so
    # everything a probe script reaches has to be listed. NixOS prepends
    # coreutils/findutils/gnugrep/gnused itself, which is why od and tr work
    # here without being named. This has cost three rounds: a bare "sh", then
    # spi-pipe, then gzip once the command channel started compressing.
    path = [
      devmem
      pkgs.spi-tools
      pkgs.util-linux
      pkgs.gzip
    ];
  };

  # Read the touchscreen stack's registers at boot and put them in the kernel
  # log. There is no ssh on this phone and the only way off it is the UART, so
  # a boot-time dump is how hardware gets measured here. See touch-probe.sh for
  # why the regions are ordered the way they are.
  #
  # Retired from the boot path now that zumapro-touch owns the part. The probe
  # was written for a dead bus and it does not share: it drives a reset pulse
  # on gpp1-1 and puts a pull-up on the ATTN line, both of which belong to the
  # driver now. On the last boot that pulse landed while the driver was up and
  # cost it two reads --
  #
  #	zumapro-touch spi0.0: no marker in 2 reads of 60 bytes: 00 00 ...
  #
  # -- which is the probe resetting the part out from under it, not a bus
  # fault. Kept, not deleted: the register map and the reasoning in the script
  # are the notes for this SoC. Run it deliberately when the driver is unbound:
  #
  #	systemctl start tegu-touch-probe
  systemd.services.tegu-touch-probe = {
    description = "Dump touchscreen-related registers to the kernel log";
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.runtimeShell} ${./touch-probe.sh}";
    };
    # Both tools the probe uses. systemd replaces PATH for a unit when this
    # is set, so listing devmem alone here left spi-pipe invisible to the
    # script even though it was in systemPackages.
    path = [
      devmem
      pkgs.spi-tools
    ];
  };

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

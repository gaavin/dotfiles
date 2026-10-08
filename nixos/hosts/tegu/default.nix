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

  # Panthor's CSF firmware, and only that. linux-firmware carries it as
  #   lib/firmware/arm/mali/arch<major>.<minor>/mali_csffw.bin
  # with several of the arch directories symlinked to one blob, so -L is what
  # makes every arch a real file; the buildEnv behind hardware.firmware then
  # compresses each into the .zst that FW_LOADER_COMPRESS_ZSTD wants.
  #
  # Not the whole of linux-firmware: panthor is the only driver on this board
  # that can use firmware yet, and installing all of it would let unrelated
  # drivers probe further than the device tree describes.
  mali-firmware = pkgs.runCommand "mali-csf-firmware" { } ''
    mkdir -p $out/lib/firmware/arm
    cp -rL ${pkgs.linux-firmware}/lib/firmware/arm/mali $out/lib/firmware/arm/
  '';

  # Seeded into max's ~/.config (see below). It is a plain file in the store
  # rather than an environment.etc entry so that the copy made from it is a
  # plain file too -- see the note at systemd.services.tegu-kwinrc.
  tegu-kwinrc = pkgs.writeText "tegu-kwinrc" ''
    [Wayland]
    InputMethod=${pkgs.kdePackages.plasma-keyboard}/share/applications/org.kde.plasma.keyboard.desktop
  '';
in
{
  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "tegu";

  # linux-firmware is unfreeRedistributableFirmware. Only that one package is
  # wanted (see mali-firmware above), so allow it by name rather than turning
  # on hardware.enableRedistributableFirmware and pulling in the whole tree.
  nixpkgs.config.allowUnfreePredicate = pkg: lib.hasPrefix "linux-firmware" (lib.getName pkg);

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
      # Never gate or unpower what the bootloader left on. There are real
      # clock and power-domain drivers for this SoC now, which makes this
      # matter more rather than less: the panel is still the bootloader's
      # framebuffer, with no driver holding a reference to anything under it.
      "clk_ignore_unused"
      "pd_ignore_unused"
      # Same argument for the rails. The device tree now describes the whole
      # S2MPG14/15 pair, so at late_initcall the regulator framework would
      # switch off every LDO and buck no driver has claimed -- which on this
      # phone includes the panel's and, until a consumer appears, plenty that
      # the system is running on. The shared port tree passes this too.
      "regulator_ignore_unused"
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
        # There is no TPM here, and this pulls tpm-crb into the initrd's
        # module set -- which the shared port tree's config does not build, so
        # the initrd's module-shrinking step fails outright:
        #   modprobe: FATAL: Module tpm-crb not found
        tpm2.enable = false;
      };
      # Everything the initrd needs is built in; a lean kernel has no modules
      # to pull from the usual x86-centric default list.
      includeDefaultModules = false;
      availableKernelModules = [ ];
      kernelModules = [ ];

      # Panthor is built into the kernel and probes at device_initcall, i.e.
      # before the rootfs is mounted, so its firmware has to be in this
      # initramfs and not merely on the system. The paths are given without
      # the extension because modules-closure.sh tries ".zst" itself.
      extraFirmwarePaths = [
        "arm/mali/arch10.8/mali_csffw.bin"
        "arm/mali/arch10.10/mali_csffw.bin"
        "arm/mali/arch10.12/mali_csffw.bin"
        "arm/mali/arch11.8/mali_csffw.bin"
        "arm/mali/arch12.8/mali_csffw.bin"
        "arm/mali/arch13.8/mali_csffw.bin"
      ];
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
    # Panthor is the one driver here that can use firmware, so it gets exactly
    # its own blob and nothing else from linux-firmware. Without it the GPU
    # probe fails *after* panthor_devfreq_init() has registered a devfreq
    # cooling device, and the g3d-thermal zone's power_allocator then calls
    # devfreq_cooling_get_requested_power() on the freed devfreq -- a panic at
    # 5 s that panic=0 leaves spinning on the panel and UART.
    firmware = [ mali-firmware ];
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

  # The mobile shell's QML (org.kde.plasma.private.mobileshell, which draws the
  # home screen) imports org.kde.bluezqt for its Bluetooth indicator, but
  # plasmashell is started by startplasma-wayland from plasma-workspace, whose
  # wrapped environment only covers plasma-workspace's own closure. The module
  # is therefore not on the QML import path, so the folio home screen
  # containment fails to load -- the journal says
  #   module "org.kde.bluezqt" is not installed
  #   Could not set containment property on rootObject
  # and the phone sits on a blank screen once the initial setup finishes. (The
  # setup wizard is a standalone binary carrying its own environment, which is
  # why it worked.) startplasmamobile sources /etc/profile before starting the
  # shell, so a session variable reaches plasmashell.
  environment.sessionVariables.QML_IMPORT_PATH =
    lib.makeSearchPath "lib/qt-6/qml" [ pkgs.kdePackages.bluez-qt ];

  # The on-screen keyboard. KWin launches it from kwinrc's [Wayland]
  # InputMethod, and that value is a *path* to a desktop file whose Exec is the
  # keyboard command -- not the keyboard's name. Nothing set it, so the phone
  # came up with no on-screen keyboard at all: KWin reported available=false
  # (InputMethod::isAvailable() is just "is a command configured") and Plasma
  # Mobile's shell, which only asks KWin to show and hide the panel, had
  # nothing to show. plasma-keyboard is the Plasma 6 keyboard and carries
  # X-KDE-Wayland-VirtualKeyboard=true, which is the marker KWin's own
  # Virtual Keyboard KCM looks for; maliit-keyboard stays installed so it can
  # still be chosen there.
  #
  # It has to go in the *user's* kwinrc, which is what that KCM writes:
  # /etc/xdg/kwinrc does not reach KWin even though kreadconfig6 reports it
  # (KF6's KSharedConfig::openConfig no longer merges the system directories
  # the way the kreadconfig6 tool does), so it was set system-wide first and
  # measured not to work.
  #
  # Seeded by a boot-time unit rather than tmpfiles' "C": "C" copies a
  # symlinked source as a symlink, so the file it left in ~/.config pointed
  # into the read-only store and KConfig refused to save over it (measured:
  # kwriteconfig6 leaves a symlinked kwinrc untouched and writes fine to a
  # regular one), which would have left that KCM unable to keep a change.
  # Only written when absent, so a later choice made in the KCM survives.
  systemd.services.tegu-kwinrc = {
    description = "Seed max's kwinrc with the on-screen keyboard";
    wantedBy = [ "multi-user.target" ];
    before = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -e /home/max/.config/kwinrc ]; then
        install -d -m 0700 -o max -g users /home/max/.config
        cp ${tegu-kwinrc} /home/max/.config/kwinrc
        chown max:users /home/max/.config/kwinrc
        chmod 0600 /home/max/.config/kwinrc
      fi
    '';
  };

  systemd.tmpfiles.rules = [
    # /home/max itself is listed because tmpfiles creates any missing parent
    # directory as root, and this runs before the display manager -- without
    # it the home the phone logs in to would be root-owned.
    "d /home/max 0700 max users -"
    "d /home/max/.config 0700 max users -"
  ];

  # The bootloader's own A/B state, which nothing in this port maintained.
  #
  # ABL keeps per-slot state in the devinfo partition (Google's
  # devinfo_ab_slot_data_t: two 4-byte entries at offset 48 of the 128-byte
  # "DEVI" struct, the definition of which is published in AOSP as
  # device/google/zuma/interfaces/boot/aidl/DevInfo.h marked "taken from ABL
  # code"). Byte 0 of an entry is retry_count and byte 1 is a flag byte: bit 0
  # unbootable, bit 1 successful, bit 2 active, bit 3 fastboot_ok. On every
  # boot ABL decrements the *active* slot's retry_count unless that slot is
  # flagged successful -- its log calls this "AB Decision: decrement active
  # slot boot retry" -- and past zero it logs "decrement active slot boot
  # retry & force ABL into fastboot" and gives up instead of booting. Flashing
  # rewrites these flags, which is why a flash looked like it "reset the
  # counter". Nothing here ever marked a slot successful, so every boot burned
  # one of the three retries and the phone was permanently three boots from
  # being stuck in fastboot.
  #
  # Measured on the device before relying on it: with the successful bit
  # cleared, one boot took the active slot from retry 3 to 2 and left the
  # inactive slot alone; with the bit set, two consecutive boots left 3 and 3.
  # Android marks the slot from userspace once the system is up, so this does
  # the same on every boot (a flash clears the flags again), and marks both
  # slots so the state is right whichever one ABL is told to boot next.
  systemd.services.tegu-mark-slot-successful = {
    description = "Mark the A/B slots successful in the devinfo partition";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.python3 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      python3 - <<'PY'
      import os, time

      dev = "/dev/disk/by-partlabel/devinfo"
      deadline = time.monotonic() + 30
      while not os.path.exists(dev):
          if time.monotonic() > deadline:
              raise SystemExit(f"{dev} never appeared")
          time.sleep(1)

      fd = os.open(dev, os.O_RDWR)
      try:
          if os.pread(fd, 4, 0) != b"DEVI":
              raise SystemExit(f"{dev}: no DEVI magic, refusing to write")
          for i in (0, 1):
              off = 48 + i * 4
              entry = os.pread(fd, 4, off)
              if len(entry) != 4:
                  raise SystemExit(f"slot {i}: short read at offset {off}")
              # A full retry count (so a boot that fails before this runs still
              # has its retries), successful set, every other flag preserved.
              new = bytes([3, entry[1] | 0x02]) + entry[2:]
              if new != entry:
                  os.pwrite(fd, new, off)
              if os.pread(fd, 4, off) != new:
                  raise SystemExit(f"slot {i}: write did not stick")
          os.fsync(fd)
          print(f"devinfo slots marked successful: {new.hex()}")
      finally:
          os.close(fd)
      PY
    '';
  };

  networking.networkmanager.enable = true;
  # Debug network over the USB-C port (10.42.0.1 on the phone) once the
  # DWC3 controller is described; fails harmlessly until then.
  systemd.services.usb-gadget-net = {
    # This works as of 2026-09-09, on the first boot of the shared port tree:
    # dwc3 probes, the eUSB2 + USB-DP combo PHY comes up, and the host sees
    # 18d1:4ee1 "NixOS Pixel 9a" about 40 s after reset.
    #
    # It reported success without doing anything for the whole life of the
    # port before that, and the shape of the lie is worth keeping in mind: with
    # no UDC the first line exits 0, so "[  OK  ] Finished USB NCM gadget" in a
    # boot log meant nothing had happened.
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
      echo "ncm + acm" > $g/configs/c.1/strings/0x409/configuration

      mkdir -p $g/functions/ncm.usb0
      # Fixed MAC addresses on both ends. Without these the gadget invents a
      # random locally-administered address every boot, which leaves the build
      # host nothing stable to key a NetworkManager profile to -- see
      # hosts/mina/default.nix, which matches host_addr below.
      echo 02:1a:11:00:00:01 > $g/functions/ncm.usb0/dev_addr
      echo 02:1a:11:00:00:02 > $g/functions/ncm.usb0/host_addr
      ln -sf $g/functions/ncm.usb0 $g/configs/c.1/

      # A serial function beside it, because the UART on this phone is
      # receive-only: this is the first channel that can carry a keystroke
      # in. /dev/ttyGS0 here, /dev/ttyACM0 on the host, and the
      # serial-getty@ttyGS0 drop-in below puts a login on it.
      mkdir -p $g/functions/acm.GS0
      ln -sf $g/functions/acm.GS0 $g/configs/c.1/

      echo "$udc" > $g/UDC
      ${pkgs.iproute2}/bin/ip addr add 10.42.0.1/24 dev usb0
      ${pkgs.iproute2}/bin/ip link set usb0 up
    '';
  };

  # A login on the gadget serial port. Written as a drop-in, not as a service:
  # defining systemd.services."serial-getty@ttyGS0" outright would generate a
  # whole unit file and lose the template's ExecStart.
  systemd.services."serial-getty@ttyGS0" = {
    overrideStrategy = "asDropin";
    wantedBy = [ "multi-user.target" ];
    after = [ "usb-gadget-net.service" ];
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
    # First-boot credential on a device with no installer. initialPassword only
    # takes effect when the account is created, so this is what a freshly
    # flashed rootfs gets; for an account that already exists, set it with
    #   printf 'max:password\n' | sudo chpasswd
    initialPassword = "password";
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

  # Run whatever command the kernel command line carries. This was the write
  # half of the debug loop while the UART was receive-only and there was no USB
  # gadget: without it the only way to change what the phone did was to rebuild
  # and reflash an 11 GB rootfs. vendor_boot is 24 KB and flashes in
  # milliseconds, and ABL appends its vendor_cmdline, so a command can ride in
  # there. See tools/tegu-cmd on the build host.
  #
  # Superseded in practice now that the USB gadget works and sshd answers on
  # 10.42.0.1 -- but keep it: it is the channel that still works when userspace
  # does not come up far enough to bring the gadget with it.
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

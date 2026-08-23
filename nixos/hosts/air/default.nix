{
  imports = [
    ./hardware.nix
  ];

  networking = {
    hostName = "air";
    networkmanager.wifi.backend = "iwd";
  };

  disko.devices = {
    disk.nixos = {
      device = "/dev/disk/by-partlabel/nixos";
      type = "disk";
      destroy = false;
      content = {
        type = "luks";
        name = "cryptroot";
        extraFormatArgs = [
          "--type=luks2"
        ];
        settings = {
          allowDiscards = true;
        };
        # install.sh writes this before Disko formats; not used at boot
        passwordFile = "/tmp/dotfiles-luks";
        content = {
          type = "lvm_pv";
          vg = "air";
        };
      };
    };
    lvm_vg.air = {
      type = "lvm_vg";
      lvs = {
        swap = {
          size = "8G";
          content = {
            type = "swap";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = "/";
          };
        };
      };
    };
  };

  hardware.asahi = {
    enable = true;
    peripheralFirmwareDirectory = ./firmware;
  };

  boot = {
    extraModprobeConfig = ''
      options hid_apple iso_layout=0
    '';
    kernelParams = [ "appledrm.show_notch=1" ];
    loader.efi.canTouchEfiVariables = false;
  };
}

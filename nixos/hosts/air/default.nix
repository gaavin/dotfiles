{
  imports = [
    ./hardware.nix
  ];

  networking = {
    hostName = "air";
    # Live ISO already runs iwd under NetworkManager; keep that stack.
    wireless.iwd.enable = true;
    networkmanager.wifi.backend = "iwd";
  };

  disko.devices = {
    # Partition created by install.sh in free space only. destroy=false so Disko
    # never touches the GPT / macOS / ESP slices on the parent NVMe.
    disk.nixos = {
      device = "/dev/disk/by-partlabel/nixos";
      type = "disk";
      destroy = false;
      content = {
        type = "luks";
        name = "cryptroot";
        # APPLE SSD is 4096/4096 native; 512-byte LUKS sectors are wrong here.
        extraFormatArgs = [
          "--type=luks2"
          "--sector-size=4096"
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
    setupAsahiSound = true;
    peripheralFirmwareDirectory = ./firmware;
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  services.power-profiles-daemon.enable = true;

  services.logind.settings.Login = {
    IdleAction = "suspend";
    IdleActionSec = "30min";
  };

  boot = {
    kernelPatches = [
      {
        name = "asahi-gpu-busy-sysfs";
        patch = ../../patches/asahi-gpu-busy-sysfs.patch;
      }
    ];
    kernelParams = [
      # air only has 8G of RAM and leans on swap hard (kernel builds with
      # other apps open), so favor zstd's better ratio over raw speed and
      # give zswap a much bigger pool than mina gets.
      "zswap.compressor=zstd"
      "zswap.max_pool_percent=30"
    ];
    kernel.sysctl = {
      # Swap proactively to keep RAM free for the active build/workload.
      "vm.swappiness" = 130;
    };
    extraModprobeConfig = ''
      options hid_apple iso_layout=0
    '';
    # Shared Asahi ESP is ~500M (m1n1 + vendorfw). Keep generations small.
    loader = {
      efi.canTouchEfiVariables = false;
      systemd-boot.configurationLimit = 3;
    };
  };
}

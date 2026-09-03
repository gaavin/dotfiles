{ pkgs, steam-config-nix, ... }:

{
  imports = [
    ./hardware.nix
    steam-config-nix.nixosModules.default
  ];

  networking.hostName = "mina";

  virtualisation.virtualbox.host = {
    enable = true;
    enableExtensionPack = true;
  };

  users.extraGroups.vboxusers.members = [ "max" ];

  disko.devices = {
    disk.main = {
      device = "/dev/nvme0n1";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            type = "EF00";
            size = "2G";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/efi";
              mountOptions = [
                "umask=0077"
              ];
            };
          };
          nixos = {
            size = "100%";
            type = "8309";
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
                vg = "mina";
              };
            };
          };
        };
      };
    };
    lvm_vg.mina = {
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

  hardware = {
    uinput.enable = true;
    opentabletdriver.enable = true;
  };

  chaotic.mesa-git.enable = true;

  boot = {
    initrd.kernelModules = [ "amdgpu" ];
    kernelParams = [
      "amd_pstate=guided"
      "preempt=full"
    ];
    kernelPackages = pkgs.linuxPackages_cachyos-lto;
    kernelModules = [
      "uinput"
      "ntsync"
    ];
    loader.efi.canTouchEfiVariables = true;
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    config = {
      enable = true;
      onSteamRunning = "close";
      defaultCompatTool = pkgs.proton-cachyos_x86_64_v3;
      displayRatesAsBits = false;
      apps = {
        "730" = {
          name = "Counter-Strike 2";
          args = [
            "-vulkan"
            "-novid"
            "-nojoy"
          ];
        };
      };
    };
  };

  services.logind.settings.Login = {
    IdleAction = "ignore";
  };

  # air stays off this; it uses hardware.asahi.setupAsahiSound instead.
  services.pipewire = {
    extraConfig.pipewire."92-low-latency" = {
      "context.properties" = {
        "default.clock.rate" = 48000;
        "default.clock.quantum" = 128;
        "default.clock.min-quantum" = 128;
        "default.clock.max-quantum" = 128;
      };
    };
    extraConfig.pipewire-pulse."92-low-latency" = {
      "pulse.properties" = {
        "pulse.min.req" = "128/48000";
        "pulse.default.req" = "128/48000";
        "pulse.max.req" = "128/48000";
        "pulse.min.quantum" = "128/48000";
        "pulse.max.quantum" = "128/48000";
      };
      "stream.properties" = {
        "node.latency" = "128/48000";
        "resample.quality" = 1;
      };
    };
  };

  services.udev.extraRules = ''
    KERNEL=="ntsync", MODE="0666"
    # ADIOS I/O scheduler for NVMe and SSDs; BFQ for rotational HDDs
    ACTION=="add|change", KERNEL=="nvme[0-9]*|sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
  '';
}

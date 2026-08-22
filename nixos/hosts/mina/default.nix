{ pkgs, steam-config-nix, ... }:

{
  imports = [
    ./hardware.nix
    steam-config-nix.nixosModules.default
  ];

  networking.hostName = "mina";

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
    kernelModules = [ "uinput" ];
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
        "Counter-Strike 2" = {
          id = 730;
          args = [
            "-vulkan"
            "-novid"
            "-nojoy"
          ];
        };
      };
    };
  };

  services.udev.extraRules = ''
    # ADIOS I/O scheduler for NVMe and SSDs; BFQ for rotational HDDs
    ACTION=="add|change", KERNEL=="nvme[0-9]*|sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
  '';
}

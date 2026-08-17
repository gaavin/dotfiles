{ pkgs, steam-config-nix, ... }:

{
  imports = [
    ./hardware-configuration.nix
    steam-config-nix.nixosModules.default
  ];

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
    initrd = {
      systemd.enable = true;
      kernelModules = [ "amdgpu" ];
    };
    kernelParams = [
      "quiet"
      "boot.shell_on_fail"
      "splash"
      "loglevel=3"
      "amd_pstate=guided"
      "preempt=full"
    ];
    kernelPackages = pkgs.linuxPackages_cachyos-lto;
    kernelModules = [ "uinput" ];
    kernel.sysctl = {
      "vm.swappiness" = 180;
      "vm.watermark_boost_factor" = 0;
      "vm.watermark_scale_factor" = 125;
      "vm.page-cluster" = 0;
    };
    plymouth = {
      enable = true;
      theme = "breeze";
    };
    loader = {
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/efi";
      };
      systemd-boot = {
        enable = true;
      };
    };
  };

  zramSwap = {
    enable = true;
    priority = 100;
    algorithm = "lz4";
    memoryPercent = 100;
  };

  i18n.defaultLocale = "en_CA.UTF-8";
  time.timeZone = "America/St_Johns";

  users.users.max = {
      isNormalUser = true;
      description = "Max Power";
      extraGroups = [ "wheel" ];
  };

  networking = {
    hostName = "mina";
    networkmanager = {
      enable = true;
      dns = "systemd-resolved";
    };
    nameservers = [
      "1.1.1.1"
      "1.0.0.1"
    ];
  };

  programs = {
    _1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "max" ];
    };

    steam = {
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
            launchOptions = {
              args = [
                "-vulkan"
                "-novid"
                "-nojoy"
              ];
            };
          };
        };
      };
    };
  };

  fonts = {
    packages = with pkgs; [
      nerd-fonts.jetbrains-mono
    ];
    fontconfig.defaultFonts = {
      monospace = [ "JetBrainsMono Nerd Font" ];
    };
  };

  services = {
    desktopManager.plasma6.enable = true;
    displayManager.plasma-login-manager.enable = true;

    udev.extraRules = ''
      # ADIOS I/O scheduler for NVMe and SSDs; BFQ for rotational HDDs
      ACTION=="add|change", KERNEL=="nvme[0-9]*|sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
      ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    '';

    resolved = {
      enable = true;
      settings.Resolve = {
        DNSOverTLS = "true";
        DNSSEC = "true";
        Domains = [ "~." ];
      };
    };
    pipewire = {
      enable = true;
      pulse.enable = true;
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
  };

  security = {
    rtkit.enable = true;
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
  ];

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  nixpkgs.config.allowUnfree = true;
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
  system.stateVersion = "26.05"; # Did you read the comment?
}

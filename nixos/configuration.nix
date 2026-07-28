{
  pkgs,
  inputs,
  ...
}:

let
  wallpaper = ./wallpaper.jpg;
in

{
  imports = [
    ./hardware-configuration.nix
    inputs.steam-config-nix.nixosModules.default
    inputs.nix-gaming-edge.nixosModules.mesa-git
  ];

  drivers.mesa-git.enable = true;

  hardware = {
    opentabletdriver.enable = true;
    steam-hardware.enable = true;
    uinput.enable = true;
  };

  boot = {
    initrd = {
      systemd.enable = true;
      kernelModules = [ "amdgpu" ];
    };
    kernelParams = [
      "quiet"
      "splash"
      "loglevel=0"
      "amd_pstate=guided"
      "preempt=full"
    ];
    kernelModules = [ "uinput" ];
    kernel.sysctl = {
      "vm.swappiness" = 180;
      "vm.watermark_boost_factor" = 0;
      "vm.watermark_scale_factor" = 125;
      "vm.page-cluster" = 0;
    };
    plymouth = {
      enable = true;
      theme = "spinner";
    };
    loader = {
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/efi";
      };
      grub = {
        devices = [ "nodev" ];
        efiSupport = true;
        enable = true;
        extraEntries = ''
          menuentry "Windows 10 IoT Enterprise LTSC 2021" {
            insmod part_gpt
            insmod fat
            insmod search_fs_uuid
            insmod chain
            search --fs-uuid --set=root EE20-98A5
            chainloader /EFI/Microsoft/Boot/bootmgfw.efi
          }
        '';
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

  services = {
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
          "default.clock.quantum" = 64;
          "default.clock.min-quantum" = 64;
          "default.clock.max-quantum" = 64;
        };
      };
      extraConfig.pipewire-pulse."92-low-latency" = {
        "context.modules" = [
          {
            name = "libpipewire-module-protocol-pulse";
            args = {
              "pulse.min.req" = "64/48000";
              "pulse.default.req" = "64/48000";
              "pulse.max.req" = "64/48000";
              "pulse.min.quantum" = "64/48000";
              "pulse.max.quantum" = "64/48000";
            };
          }
        ];
        "stream.properties" = {
          "node.latency" = "64/48000";
          "resample.quality" = 1;
        };
      };
    };
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };

  security = {
    rtkit.enable = true;
    pam.loginLimits = [
      {
        domain = "@audio";
        type = "-";
        item = "rtprio";
        value = "95";
      }
      {
        domain = "@audio";
        type = "-";
        item = "memlock";
        value = "unlimited";
      }
    ];
  };

  programs = {
    steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      extraCompatPackages = with pkgs; [
        proton-cachyos-x86_64-v3
      ];
      config = {
        enable = true;
        onSteamRunning = "close";
        defaultCompatTool = pkgs.proton-cachyos-x86_64-v3;
        displayRatesAsBits = false;
      };
    };
    _1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "max" ];
    };
    dconf = {
      enable = true;
      profiles = {
        user = {
          databases = [
            {
              settings = {
                "org/gnome/desktop/interface" = {
                  clock-format = "12h";
                  color-scheme = "prefer-dark";
                  monospace-font-name = "JetBrainsMono Nerd Font 11";
                };
                "org/gnome/desktop/peripherals/mouse" = {
                  accel-profile = "flat";
                };
                "org/gnome/desktop/background" = {
                  picture-uri = "file://${wallpaper}";
                  picture-uri-dark = "file://${wallpaper}";
                };
                "org/gnome/desktop/screensaver" = {
                  picture-uri = "file://${wallpaper}";
                };
              };
            }
          ];
        };
        gdm = {
          databases = [
            {
              settings = {
                "org/gnome/desktop/interface" = {
                  clock-format = "12h";
                  color-scheme = "prefer-dark";
                  monospace-font-name = "JetBrainsMono Nerd Font 11";
                };
                "org/gnome/desktop/peripherals/mouse" = {
                  accel-profile = "flat";
                };
                "org/gnome/desktop/background" = {
                  picture-uri = "file://${wallpaper}";
                  picture-uri-dark = "file://${wallpaper}";
                };
                "org/gnome/desktop/screensaver" = {
                  picture-uri = "file://${wallpaper}";
                };
              };
            }
          ];
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

  environment = {
    systemPackages = with pkgs; [
      vim
      wget
    ];
    gnome.excludePackages = with pkgs; [
      epiphany
      gnome-maps
      gnome-music
      gnome-calendar
    ];
  };

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
    trusted-users = [
      "root"
      "@wheel"
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [
      "https://cache.nixos.org"
      "https://attic.xuyh0120.win/lantian"
      "https://nix-cache.tokidoki.dev/tokidoki"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
      "tokidoki:MD4VWt3kK8Fmz3jkiGoNRJIW31/QAm7l1Dcgz2Xa4hk="
    ];
  };
  system.stateVersion = "26.05"; # Did you read the comment?
}

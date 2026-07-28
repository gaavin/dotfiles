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
  ];

  hardware.opentabletdriver.enable = true;
  hardware.uinput.enable = true;

  boot = {
    initrd = {
      systemd = {
        enable = true;
      };
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

  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSOverTLS = "true";
      DNSSEC = "true";
      Domains = [ "~." ];
    };
  };

  i18n.defaultLocale = "en_CA.UTF-8";
  time.timeZone = "America/St_Johns";

  users.users.max = {
    isNormalUser = true;
    description = "Max Power";
    extraGroups = [ "wheel" ];
  };

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  environment.gnome.excludePackages = with pkgs; [
    epiphany
    gnome-maps
    gnome-music
    gnome-calendar
  ];

  programs.dconf = {
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

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  security.rtkit.enable = true;

  services.pipewire = {
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

  programs.steam = {
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

  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "max" ];
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  fonts.fontconfig.defaultFonts = {
    monospace = [ "JetBrainsMono Nerd Font" ];
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

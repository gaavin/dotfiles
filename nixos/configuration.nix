{ pkgs, ... }:

{
  boot = {
    initrd.systemd.enable = true;
    initrd.services.lvm.enable = true;
    kernelParams = [
      "quiet"
      "boot.shell_on_fail"
      "splash"
      "loglevel=3"
    ];
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
      efi.efiSysMountPoint = "/efi";
      systemd-boot.enable = true;
    };
  };

  fileSystems."/".options = [
    "relatime"
    "lazytime"
  ];

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
    networkmanager = {
      enable = true;
      dns = "systemd-resolved";
    };
    nameservers = [
      "1.1.1.1"
      "1.0.0.1"
    ];
  };

  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "max" ];
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

  security.rtkit.enable = true;

  environment = {
    plasma6.excludePackages = [ pkgs.kdePackages.discover ];
    systemPackages = with pkgs; [
      vim
      wget
    ];
  };

  nixpkgs = {
    config.allowUnfree = true;
    overlays = [
      (final: prev: {
        xdg-desktop-portal-gtk = prev.xdg-desktop-portal-gtk.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/xdg-desktop-portal-gtk-fc-monitor.patch
          ];
        });
      })
    ];
  };
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
  system.stateVersion = "26.05";
}

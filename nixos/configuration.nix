{
  pkgs,
  lib,
  config,
  ...
}:

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

  # Keep greeter + TTY on the same layout so typed passwords match what was set at install.
  console.keyMap = "us";

  users.mutableUsers = true;
  users.users.root.hashedPasswordFile = lib.mkIf (builtins.pathExists /run/nixos-install-passwords/root.hash) "/run/nixos-install-passwords/root.hash";
  users.users.max = {
    isNormalUser = true;
    description = "Max Power";
    extraGroups = [
      "wheel"
      "dialout"
      "audio"
      "pipewire"
    ];
    hashedPasswordFile = lib.mkIf (builtins.pathExists /run/nixos-install-passwords/max.hash) "/run/nixos-install-passwords/max.hash";
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
    xserver.xkb = {
      layout = "us";
      variant = "";
    };
    desktopManager.plasma6.enable = true;
    # SDDM + Wayland is the reliable Plasma 6 path; plasma-login-manager has
    # repeatedly shown "Login failed" / empty-session auth failures on unstable.
    displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    resolved = {
      enable = true;
      settings.Resolve = {
        DNSOverTLS = "true";
        DNSSEC = "true";
        Domains = [ "~." ];
      };
    };
    pipewire = lib.mkMerge [
      {
        enable = true;
        pulse.enable = true;
        extraConfig.pipewire."99-rtkit" = {
          "module.rt.args" = {
            "nice.level" = -11;
            "rt.prio" = 88;
            "rt.time.soft" = -1;
            "rt.time.hard" = -1;
          };
        };
        wireplumber.extraConfig."99-rtkit" = {
          "module.rt.args" = {
            "nice.level" = -11;
            "rt.prio" = 88;
            "rt.time.soft" = -1;
            "rt.time.hard" = -1;
          };
        };
      }
      # air uses hardware.asahi.setupAsahiSound (asahi-audio DSP + speakersafetyd).
      (lib.mkIf (config.networking.hostName != "air") {
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
      })
    ];
  };

  # rtkit defaults to max prio 20; raise the ceiling so PipeWire can take FIFO ~88.
  security.rtkit.enable = true;
  security.rtkit.args = [
    "--scheduling-policy=FIFO"
    "--our-realtime-priority=89"
    "--max-realtime-priority=88"
    "--min-nice-level=-19"
    "--rttime-usec-max=2000000"
    "--no-canary"
  ];

  # systemd --user units do not inherit PAM loginLimits.
  systemd.user.services = {
    pipewire.serviceConfig = {
      LimitRTPRIO = 95;
      LimitMEMLOCK = "infinity";
    };
    pipewire-pulse.serviceConfig = {
      LimitRTPRIO = 95;
      LimitMEMLOCK = "infinity";
    };
    wireplumber.serviceConfig = {
      LimitRTPRIO = 95;
      LimitMEMLOCK = "infinity";
    };
  };

  environment = {
    plasma6.excludePackages = with pkgs.kdePackages; [
      discover
      elisa
    ];
    systemPackages = with pkgs; [
      vim
      wget
      kdePackages.partitionmanager
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
        kdePackages = prev.kdePackages.overrideScope (
          kdeFinal: kdePrev: {
            ksystemstats = kdePrev.ksystemstats.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [
                ./patches/ksystemstats-asahi-gpu.patch
                ./patches/ksystemstats-network-early-register.patch
                ./patches/ksystemstats-skip-encrypted-used-space.patch
              ];
            });
          }
        );
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

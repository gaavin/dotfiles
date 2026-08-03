{
  config,
  lib,
  pkgs,
  firefox-addons,
  nix-osu-stable,
  ...
}:

let
  onePasswordPath = "${config.home.homeDirectory}/.1password/agent.sock";
in

{
  imports = [ nix-osu-stable.homeModules.osu-stable ];

  home = {
    username = "max";
    homeDirectory = "/home/max";
    stateVersion = "26.05";
    sessionVariables = {
      MOZ_ENABLE_WAYLAND = "1";
      SDL_VIDEO_DRIVER = "wayland";
      PROTON_ENABLE_WAYLAND = "1";
      SSH_AUTH_SOCK = onePasswordPath;
      EDITOR = "vim";
    };
    packages = with pkgs; [
      kdePackages.breeze-gtk
      nil
      nixfmt
      nodejs
      pnpm
      prismlauncher
      spotify
      fastfetch
    ];
  };

  qt = {
    enable = true;
    platformTheme.name = "kde";
    style.name = "breeze";
  };

  gtk = {
    enable = true;
    theme = {
      name = "Breeze-Dark";
      package = pkgs.kdePackages.breeze-gtk;
    };
    iconTheme = {
      name = "breeze-dark";
      package = pkgs.kdePackages.breeze-icons;
    };
  };

  programs = {
    plasma = {
      enable = true;
      overrideConfig = true;
      workspace = {
        lookAndFeel = "org.kde.breezedark.desktop";
        theme = "breeze-dark";
        colorScheme = "BreezeDark";
        iconTheme = "breeze-dark";
        wallpaper = ./wallpaper.jpg;
      };
      fonts.fixedWidth = {
        family = "JetBrainsMono Nerd Font";
        pointSize = 10;
      };
      kwin.effects.shakeCursor.enable = false;
      input.mice = [
        {
          enable = true;
          name = "Logitech PRO X";
          vendorId = "046d";
          productId = "4093";
          accelerationProfile = "none";
        }
        {
          enable = true;
          name = "Logitech PRO X Wireless";
          vendorId = "046d";
          productId = "c094";
          accelerationProfile = "none";
        }
      ];
    };

    bash = {
      enable = true;
      shellAliases = {
        rebuild = "nix flake update --flake ~/dotfiles/nixos && sudo nixos-rebuild switch --flake ~/dotfiles/nixos#mina";
      };
    };

    git = {
      enable = true;
      settings = {
        user.name = "Max Power";
        user.email = "me@gavinpower.dev";
        user.signingkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOU6IBq+aSTA/ZLBA4ePyXwJrm9LB0CcoxTAXlY+vexv";
        gpg.format = "ssh";
        gpg.ssh.program = "${pkgs._1password-gui}/share/1password/op-ssh-sign";
        commit.gpgsign = true;
      };
    };

    ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings."*" = {
        ForwardAgent = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        IdentityAgent = onePasswordPath;
      };
    };

    cursor = {
      enable = true;
      mutableExtensionsDir = true;
      profiles.default = {
        extensions = with pkgs.vscode-extensions; [
          jnoortheen.nix-ide
        ];
        userSettings = {
          "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'Courier New', monospace";
          "terminal.integrated.fontFamily" = "'JetBrainsMono Nerd Font'";
          "editor.fontLigatures" = true;
          "editor.formatOnSave" = true;
          "editor.formatOnPaste" = true;
          "nix.enableLanguageServer" = true;
          "nix.serverPath" = "${pkgs.nil}/bin/nil";
          "nix.serverSettings" = {
            nil.formatting.command = [ "${pkgs.nixfmt}/bin/nixfmt" ];
          };
          "[nix]" = {
            "editor.defaultFormatter" = "jnoortheen.nix-ide";
          };
        };
      };
    };

    firefox = {
      enable = true;
      configPath = "${config.xdg.configHome}/mozilla/firefox";
      nativeMessagingHosts = [
        pkgs.kdePackages.plasma-browser-integration
        pkgs._1password-gui
      ];
      policies = {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        DisablePocket = true;
        SearchBar = "unified";
        DisablePasswordCapture = true;
        EncryptedMediaExtensions = {
          Enabled = true;
        };
        AutofillAddressEnabled = false;
        AutofillCreditCardEnabled = false;
        BlockAboutProfiles = true;
        Preferences = {
          "browser.profiles.enabled" = {
            Value = false;
            Status = "locked";
          };
        };
        SearchEngines = {
          Default = "Google";
        };
        ExtensionSettings = {
          "uBlock0@raymondhill.net" = {
            installation_mode = "allowed";
            default_area = "menupanel";
          };
          "{d634138d-c276-4fc8-924b-40a0ea21d284}" = {
            installation_mode = "allowed";
            default_area = "navbar";
          };
        };
      };
      profiles = {
        default = {
          extensions.packages = with firefox-addons.packages.${pkgs.stdenv.hostPlatform.system}; [
            ublock-origin
            plasma-integration
            (onepassword-password-manager.overrideAttrs (oldAttrs: {
              meta = oldAttrs.meta // {
                license = lib.licenses.mit;
              };
            }))
          ];
          settings = {
            "extensions.autoDisableScopes" = 0;
            "browser.newtabpage.activity-stream.feeds.section.topstories" = false;
            "browser.aboutwelcome.enabled" = false;
            "browser.messaging-system.whatsNewPanel.enabled" = false;
            "browser.urlbar.trending.featureGate" = false;
            "browser.urlbar.suggest.searches" = false;
            "signon.management.page.breachAlertUrl" = "";
            "extensions.fxmonitor.enabled" = false;
            "browser.urlbar.suggest.link" = false;
            "browser.uiCustomization.state" = builtins.toJSON {
              placements = {
                widget-overflow-fixed-list = [ ];
                unified-extensions-area = [
                  "plasma-browser-integration_kde_org-browser-action"
                  "ublock0_raymondhill_net-browser-action"
                ];
                nav-bar = [
                  "back-button"
                  "forward-button"
                  "stop-reload-button"
                  "customizableui-special-spring1"
                  "vertical-spacer"
                  "urlbar-container"
                  "customizableui-special-spring2"
                  "downloads-button"
                  "reset-pbm-toolbar-button"
                  "_d634138d-c276-4fc8-924b-40a0ea21d284_-browser-action"
                  "unified-extensions-button"
                ];
                toolbar-menubar = [ "menubar-items" ];
                TabsToolbar = [
                  "tabbrowser-tabs"
                  "new-tab-button"
                  "alltabs-button"
                ];
                vertical-tabs = [ ];
                PersonalToolbar = [
                  "import-button"
                  "personal-bookmarks"
                ];
              };
              seen = [
                "reset-pbm-toolbar-button"
                "plasma-browser-integration_kde_org-browser-action"
                "_d634138d-c276-4fc8-924b-40a0ea21d284_-browser-action"
                "ublock0_raymondhill_net-browser-action"
                "developer-button"
                "screenshot-button"
              ];
              dirtyAreaCache = [
                "unified-extensions-area"
                "nav-bar"
                "vertical-tabs"
                "PersonalToolbar"
                "toolbar-menubar"
                "TabsToolbar"
              ];
              currentVersion = 24;
              newElementCount = 2;
            };
          };
        };
      };
    };

    osu-stable = {
      enable = true;
      package = nix-osu-stable.packages.${pkgs.stdenv.hostPlatform.system}.osu-wine;
      environment.WINE_ENABLE_ABS_TABLET_HACK = "2";
    };

    vesktop = {
      enable = true;
      settings.appBadge = false;
      settings.arRPC = true;
      vencord.settings = {
        autoUpdate = true;
        autoUpdateNotification = true;
        notifyAboutUpdates = true;
        plugins = {
          ClearURLs.enabled = true;
          FixYoutubeEmbeds.enabled = true;
        };
      };
    };

  };
}

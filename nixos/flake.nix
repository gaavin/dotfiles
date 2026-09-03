{
  description = "NixOS configurations for mina and air";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    steam-config-nix = {
      url = "github:different-name/steam-config-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-battle-net = {
      url = "github:gaavin/nix-battle-net";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-epic-games-launcher = {
      url = "github:gaavin/nix-epic-games-launcher";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-spotify-aarch64 = {
      url = "github:gaavin/nix-spotify-aarch64";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-osu-lazer-aarch64 = {
      url = "github:gaavin/nix-osu-lazer-aarch64";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-grok-build = {
      url = "github:gaavin/nix-grok-build";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    grok-bot-nix = {
      url = "github:d-513/grok-bot-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-apple-silicon.url = "github:nix-community/nixos-apple-silicon";

    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      chaotic,
      home-manager,
      plasma-manager,
      firefox-addons,
      steam-config-nix,
      nix-battle-net,
      nix-epic-games-launcher,
      nix-spotify-aarch64,
      nix-osu-lazer-aarch64,
      nix-grok-build,
      grok-bot-nix,
      disko,
      nixos-apple-silicon,
      claude-code,
      ...
    }:
    let
      mkHost =
        {
          hostname,
          system,
          extraModules ? [ ],
          extraSpecialArgs ? { },
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = extraSpecialArgs;
          modules = [
            ./configuration.nix
            ./hosts/${hostname}
            home-manager.nixosModules.home-manager
            { nixpkgs.overlays = [ claude-code.overlays.default ]; }
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit firefox-addons;
                  inherit grok-bot-nix;
                };
                users.max.imports = [
                  ./home.nix
                  ./hosts/${hostname}/home.nix
                ];
                sharedModules = [
                  plasma-manager.homeModules.plasma-manager
                  nix-grok-build.homeModules.grok-build
                ]
                ++ nixpkgs.lib.optionals (system == "x86_64-linux") [
                  nix-battle-net.homeModules.battle-net
                  nix-epic-games-launcher.homeModules.epic-games-launcher
                ]
                ++ nixpkgs.lib.optionals (system == "aarch64-linux") [
                  nix-spotify-aarch64.homeModules.nix-spotify-aarch64
                  nix-osu-lazer-aarch64.homeModules.nix-osu-lazer-aarch64
                ];
                backupFileExtension = "bak";
                overwriteBackup = true;
              };
            }
          ]
          ++ extraModules;
        };
    in
    {
      nixosConfigurations.mina = mkHost {
        hostname = "mina";
        system = "x86_64-linux";
        extraSpecialArgs = { inherit steam-config-nix; };
        extraModules = [
          disko.nixosModules.disko
          chaotic.nixosModules.default
        ];
      };

      nixosConfigurations.air = mkHost {
        hostname = "air";
        system = "aarch64-linux";
        extraModules = [
          disko.nixosModules.disko
          nixos-apple-silicon.nixosModules.apple-silicon-support
        ];
      };
    };
}

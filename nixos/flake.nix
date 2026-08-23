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

    nix-osu-stable = {
      url = "github:gaavin/nix-osu-stable";
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
      url = "path:/home/max/Projects/nix-spotify-aarch64";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-apple-silicon.url = "github:nix-community/nixos-apple-silicon";
  };

  outputs =
    {
      nixpkgs,
      chaotic,
      home-manager,
      plasma-manager,
      firefox-addons,
      steam-config-nix,
      nix-osu-stable,
      nix-battle-net,
      nix-epic-games-launcher,
      nix-spotify-aarch64,
      disko,
      nixos-apple-silicon,
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
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit firefox-addons;
                };
                users.max = import ./home.nix;
                sharedModules = [
                  plasma-manager.homeModules.plasma-manager
                ]
                ++ nixpkgs.lib.optionals (system == "x86_64-linux") [
                  nix-osu-stable.homeModules.osu-stable
                  nix-battle-net.homeModules.battle-net
                  nix-epic-games-launcher.homeModules.epic-games-launcher
                ]
                ++ nixpkgs.lib.optionals (system == "aarch64-linux") [
                  nix-spotify-aarch64.homeModules.nix-spotify-aarch64
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
          nixos-apple-silicon.nixosModules.apple-silicon-support
        ];
      };
    };
}

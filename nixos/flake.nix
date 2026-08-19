{
  description = "configuration for desktop";

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
      url = "github:gaavin/nix-osu-stable/feat/osu-offset";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      chaotic,
      home-manager,
      plasma-manager,
      firefox-addons,
      steam-config-nix,
      nix-osu-stable,
      disko,
      ...
    }:
    {
      nixosConfigurations.mina = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        specialArgs = { inherit steam-config-nix; };

        modules = [
          ./configuration.nix
          disko.nixosModules.disko
          chaotic.nixosModules.default
          home-manager.nixosModules.home-manager

          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = { inherit firefox-addons nix-osu-stable; };
              users.max = import ./home.nix;
              sharedModules = [ plasma-manager.homeModules.plasma-manager ];
              backupFileExtension = "bak";
              overwriteBackup = true;
            };
          }
        ];
      };
    };
}

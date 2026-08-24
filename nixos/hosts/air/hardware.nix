{
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # Asahi shared ESP (macOS + m1n1). Mount only — do not format.
  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/cdafe374-b526-4836-88a2-12887be02cf4";
    fsType = "vfat";
    options = [ "umask=0077" ];
    neededForBoot = true;
  };
}

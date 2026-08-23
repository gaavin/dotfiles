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

  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/c3f24abb-bf65-4ea1-a90c-aa4eecc3b2b0";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
}

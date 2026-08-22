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

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "xfs";
  };

  # Replace this partuuid at install from:
  #   tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition
  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/00000000-0000-0000-0000-000000000000";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  swapDevices = [ ];
}

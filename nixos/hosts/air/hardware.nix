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

  boot.initrd.services.lvm.enable = true;

  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-uuid/0b742a31-5a76-4d67-8f48-af86053f14ec";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/air-root";
    fsType = "xfs";
  };

  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/c3f24abb-bf65-4ea1-a90c-aa4eecc3b2b0";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  swapDevices = [
    { device = "/dev/mapper/air-swap"; }
  ];
}

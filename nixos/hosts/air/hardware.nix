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
    # filled by hosts/air/install.sh
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/air-root";
    fsType = "xfs";
  };

  # filled by hosts/air/install.sh from:
  #   tr -d '\0' < /proc/device-tree/chosen/asahi,efi-system-partition
  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/00000000-0000-0000-0000-000000000000";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  swapDevices = [
    { device = "/dev/mapper/air-swap"; }
  ];
}

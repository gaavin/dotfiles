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

  # MacBook Air M1 2020 (j313) — Asahi shared ESP (macOS + m1n1).
  # PARTUUID from /proc/device-tree/chosen/asahi,efi-system-partition.
  # install.sh rewrites this on install; mount only — never format.
  fileSystems."/efi" = {
    device = "/dev/disk/by-partuuid/cdafe374-b526-4836-88a2-12887be02cf4";
    fsType = "vfat";
    options = [ "umask=0077" ];
    neededForBoot = true;
  };
}

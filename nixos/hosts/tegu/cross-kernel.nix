# Build the tegu kernel on an x86_64 host with a cross toolchain instead of
# under aarch64 user emulation. The output is an ordinary aarch64-linux kernel
# derivation, so the aarch64 NixOS closure consumes it unchanged.
{ lib, pkgs, ... }:
let
  crossPkgs = import pkgs.path {
    localSystem = "x86_64-linux";
    crossSystem = "aarch64-linux";
  };
in
{
  boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor (crossPkgs.callPackage ./kernel.nix { }));
}

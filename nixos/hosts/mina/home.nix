{ pkgs, ... }:

{
  programs.plasma.powerdevil.AC.autoSuspend.action = "nothing";

  # Reverse-engineering tooling, here rather than in the shared home.nix
  # because it pulls in Ghidra and a JDK -- a lot to build on the aarch64
  # laptop for something that belongs on the workstation.
  home.packages = [ pkgs.ghidra-cli ];
}

{
  config,
  lib,
  pkgs,
  osConfig,
  firefox-addons,
  grok-bot-nix,
  ...
}:

let
  isX86 = pkgs.stdenv.hostPlatform.isx86_64;
  onePasswordPath = "${config.home.homeDirectory}/.1password/agent.sock";
  # FIFO 80: below PipeWire 88 / WirePlumber 84 so audio still wins.
  wrapFifo80 =
    pkg: bin:
    pkgs.symlinkJoin {
      name = "${pkg.pname or pkg.name}-fifo";
      paths = [ pkg ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm -f "$out/bin/${bin}"
        makeWrapper ${pkgs.util-linux}/bin/chrt "$out/bin/${bin}" \
          --add-flags --fifo \
          --add-flags 80 \
          --add-flags ${lib.escapeShellArg "${pkg}/bin/${bin}"}
      '';
    };
in

{
  home = {
    username = "max";
    homeDirectory = "/home/max";
    stateVersion = "26.05";
    sessionVariables = {
      MOZ_ENABLE_WAYLAND = "1";
      SDL_VIDEO_DRIVER = "wayland";
      PROTON_ENABLE_WAYLAND = "1";
      NIXOS_OZONE_WL = "1";
      SSH_AUTH_SOCK = onePasswordPath;
      EDITOR = "vim";
    };
    packages =
      with pkgs;
      [
        grok-bot-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
        python3
        python3Packages.tkinter
        arduino-cli
        kdePackages.breeze-gtk
        nil
        nixfmt
        nodejs
        pnpm
        prismlauncher
        qbittorrent
        fastfetch
        dysk
        gh
        (pkgs.writeShellScriptBin "rebuild" ''
          set -euo pipefail

          start_sleep_inhibit() {
            [[ -n ''${SLEEP_INHIBIT_PID:-} ]] && return 0
            command -v systemd-inhibit >/dev/null 2>&1 || return 0
            systemd-inhibit \
              --what=idle:sleep:handle-lid-switch:handle-suspend-key:handle-hibernate-key \
              --who="rebuild" \
              --why="NixOS rebuild in progress" \
              --mode=block \
              sleep infinity &
            SLEEP_INHIBIT_PID=$!
          }

          stop_sleep_inhibit() {
            if [[ -n ''${SLEEP_INHIBIT_PID:-} ]] && kill -0 "$SLEEP_INHIBIT_PID" 2>/dev/null; then
              kill "$SLEEP_INHIBIT_PID" 2>/dev/null || true
              wait "$SLEEP_INHIBIT_PID" 2>/dev/null || true
            fi
            SLEEP_INHIBIT_PID=""
          }

          start_sleep_inhibit
          trap stop_sleep_inhibit EXIT

          flake_dir="$HOME/dotfiles/nixos"
          host="${osConfig.networking.hostName}"
          if [ "$host" = air ]; then
            sudo bash "$flake_dir/hosts/air/sync-firmware.sh"
            sudo chown -R "$(id -u):$(id -g)" "$flake_dir/hosts/air/firmware"
          fi
          nix flake update --flake "$flake_dir"
          sudo nixos-rebuild switch --flake "path:$flake_dir#$host"
        '')
      ]
      ++ lib.optionals isX86 [
        arduino-ide
        (wrapFifo80 osu-lazer-bin "osu!")
        spotify
      ];
  };

{
  lib,
  pkgs,
  ...
}:

let
  isX86 = pkgs.stdenv.hostPlatform.isx86_64;
  osu = pkgs.osu-lazer-bin;

  # After exec the process is the stock binary. No LD_PRELOAD, no patched game files.
  osuLauncher = pkgs.writeShellScript "osu-lazer-launch" ''
    set -euo pipefail

    export SDL_VIDEODRIVER=wayland
    export SDL_VIDEO_DRIVER=wayland
    export SDL_VIDEO_WAYLAND_PREFER_LIBDECOR=0
    export SDL_VIDEO_WAYLAND_MODE_EMULATION=0
    export SDL_VIDEO_EGL_ALLOW_TRANSPARENCY=0
    export SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
    export vblank_mode=0
    export mesa_glthread=false

    ini="''${XDG_DATA_HOME:-$HOME/.local/share}/osu/framework.ini"
    mkdir -p "$(dirname "$ini")"
    set_ini() {
      local key="$1" val="$2"
      if [[ -f "$ini" ]] && ${pkgs.gnugrep}/bin/grep -q "^$key *=" "$ini"; then
        ${pkgs.gnused}/bin/sed -i "s/^$key *=.*/$key = $val/" "$ini"
      else
        printf '%s = %s\n' "$key" "$val" >> "$ini"
      fi
    }
    set_ini WindowMode Fullscreen
    set_ini FrameSync Unlimited
    set_ini Renderer OpenGL

    exec ${pkgs.util-linux}/bin/chrt --fifo 80 ${lib.escapeShellArg "${osu}/bin/osu!"} "$@"
  '';

  osuWrapped = pkgs.symlinkJoin {
    name = "${osu.pname}-low-latency";
    paths = [ osu ];
    postBuild = ''
      rm -f "$out/bin/osu!"
      ln -s ${osuLauncher} "$out/bin/osu!"
    '';
  };
in
{
  home.packages = lib.optionals isX86 [ osuWrapped ];

  programs.plasma = {
    # KWin only scanouts/tears a fullscreen client. AllowTearing is the
    # compositor permission; the window rule is what actually opens the gate.
    configFile.kwinrc.Compositing = {
      AllowTearing = true;
      LatencyPolicy = "ExtremelyLow";
    };
    window-rules = [
      {
        description = "osu!lazer low-latency scanout";
        match = {
          window-class = {
            value = "osu!";
            type = "substring";
            match-whole = false;
          };
          window-types = [ "normal" ];
        };
        apply = {
          fullscreen = {
            value = true;
            apply = "force";
          };
          tearing = {
            value = true;
            apply = "force";
          };
          noborder = {
            value = true;
            apply = "force";
          };
        };
      }
    ];
  };
}

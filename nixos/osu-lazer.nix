{
  lib,
  pkgs,
  ...
}:

let
  isX86 = pkgs.stdenv.hostPlatform.isx86_64;
  osu = pkgs.osu-lazer-bin;
  # execs the stock binary. No LD_PRELOAD, no patched game files.
  osuWrapped = pkgs.symlinkJoin {
    name = "${osu.pname}-scanout";
    paths = [ osu ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm -f "$out/bin/osu!"
      makeWrapper ${pkgs.util-linux}/bin/chrt "$out/bin/osu!" \
        --add-flags --fifo \
        --add-flags 80 \
        --add-flags ${lib.escapeShellArg "${osu}/bin/osu!"} \
        --set SDL_VIDEODRIVER wayland \
        --set SDL_VIDEO_WAYLAND_PREFER_LIBDECOR 0 \
        --set MESA_VK_WSI_PRESENT_MODE immediate \
        --set vblank_mode 0
    '';
  };
in
{
  home.packages = lib.optionals isX86 [ osuWrapped ];

  # Compositor-side: tearing-control ASYNC + no CSD so KWin can scan out the toplevel.
  programs.plasma.window-rules = [
    {
      description = "osu!lazer scanout";
      match = {
        window-class = {
          value = "osu!";
          type = "substring";
          match-whole = false;
        };
        window-types = [ "normal" ];
      };
      apply = {
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
}

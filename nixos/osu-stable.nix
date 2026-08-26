{ lib, pkgs, ... }:

lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 {
  programs.osu-stable = {
    enable = true;
    environment.WINE_ENABLE_ABS_TABLET_HACK = "2";
    offsetCalculator.enable = true;

    # Username / Password / SavePassword stay in the mutable osu!.$USERNAME.cfg only.
    # Only overrides vs factory defaults — re-export with: osu-wine --export-settings
    settings = {
      AudioDevice = "Speakers (Fosi Audio SK02 Analog Stereo)";
      AudioCompatibility = 1;
      ComboBurst = 0;
      CursorSize = 1.1;
      DimLevel = 100;
      EditorHitAnimations = 1;
      FrameSync = "Unlimited";
      IHateHavingFun = 1;
      IgnoreBeatmapSkins = 1;
      Offset = -40;
      PopupDuringGameplay = 0;
      Skin = "Shigetora's Skin";
      VolumeUniversal = 50;
      keyOsuLeft = "E";
      keyOsuRight = "R";
      keyOsuSmoke = "T";
    };

    beatmaps = [
      2281545
    ];

    skins = [ "https://circle-people.com/wp-content/Skins/Cookiezi/Cookiezi%2004.osk" ];
  };
}

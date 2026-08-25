{ lib, pkgs, ... }:

lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 {
  programs.osu-stable = {
    enable = true;
    environment.WINE_ENABLE_ABS_TABLET_HACK = "2";
    offsetCalculator.enable = true;

    # Password / SavePassword stay in the mutable osu!.<user>.cfg only.
    # Only overrides vs factory defaults — re-export with: osu-wine --export-settings
    settings = {
      max = {
        AudioCompatibility = true;
        ComboBurst = true;
        CursorSize = 1.1;
        DimLevel = 100;
        EditorHitAnimations = true;
        FrameSync = "Unlimited";
        IHateHavingFun = true;
        IgnoreBeatmapSkins = true;
        Offset = -40;
        PopupDuringGameplay = false;
        Skin = "Shigetora's Skin";
        VolumeUniversal = 50;
        keyOsuLeft = "E";
        keyOsuRight = "R";
        keyOsuSmoke = "T";
      };
    };

    beatmaps = [
      2281545
    ];

    skins = [ "https://circle-people.com/wp-content/Skins/Cookiezi/Cookiezi%2004.osk" ];
  };
}

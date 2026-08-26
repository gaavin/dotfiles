{ lib, pkgs, ... }:

lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 {
  programs.osu-stable = {
    enable = true;
    environment.WINE_ENABLE_ABS_TABLET_HACK = "2";
    offsetCalculator.enable = true;

    settings = {
      ChatChannels = "#osu #userlog";
      VolumeEffect = 60;
      AudioCompatibility = 1;
      AudioDevice = "Speakers (Fosi Audio SK02 Analog Stereo)";
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
      376552
      377930
      636839
      1898232
      2142914
      2198943
      2258243
      2281545
      2298941
      2432962
      2512831
      2527269
      2533966
    ];

    skins = [ "https://circle-people.com/wp-content/Skins/Cookiezi/Cookiezi%2004.osk" ];
  };
}

{ lib, pkgs, ... }:

lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 {
  programs.osu-stable = {
    enable = true;
    environment.WINE_ENABLE_ABS_TABLET_HACK = "2";
    offsetCalculator.enable = true;

    settings = {
      ChatChannels = "#osu #userlog";
      VolumeEffect = 60;
      CursorSize = 1.1;
      DimLevel = 100;
      EditorHitAnimations = 1;
      FrameSync = "Unlimited";
      IHateHavingFun = 1;
      IgnoreBeatmapSkins = 1;
      Offset = -5;
      PopupDuringGameplay = 0;
      Skin = "Shigetora's Skin";
      VolumeUniversal = 50;
      keyOsuLeft = "E";
      keyOsuRight = "R";
      keyOsuSmoke = "T";
    };

    beatmaps = [
      257407
      376552
      377930
      550126
      602119
      636839
      682281
      986223
      1137016
      1140744
      1165893
      1280853
      1346760
      1432093
      1449188
      1537313
      1552776
      1653606
      1683345
      1780060
      1889313
      1898232
      1968798
      1995184
      2033141
      2034706
      2135455
      2142914
      2173677
      2182833
      2198943
      2235131
      2254957
      2258243
      2281269
      2281545
      2289289
      2298941
      2302313
      2313879
      2322235
      2350791
      2354986
      2374105
      2377403
      2415756
      2432962
      2444077
      2460289
      2477885
      2488222
      2512831
      2514159
      2514378
      2525247
      2525365
      2527269
      2533966
      2544980
    ];

    skins = [ "https://circle-people.com/wp-content/Skins/Cookiezi/Cookiezi%2004.osk" ];
  };
}

{ ... }:

{
  programs.plasma.powerdevil = {
    AC.autoSuspend.action = "nothing";
    battery.autoSuspend.action = "sleep";
    battery.autoSuspend.idleTimeout = 1800;
    AC.keyboardBrightness = 25;
    battery.keyboardBrightness = 25;
    lowBattery.keyboardBrightness = 25;
  };
}

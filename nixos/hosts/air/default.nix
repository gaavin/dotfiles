{
  imports = [
    ./hardware.nix
  ];

  networking = {
    hostName = "air";
    networkmanager.wifi.backend = "iwd";
  };

  hardware.asahi = {
    enable = true;
    peripheralFirmwareDirectory = ./firmware;
  };

  boot = {
    extraModprobeConfig = ''
      options hid_apple iso_layout=0
    '';
    kernelParams = [ "appledrm.show_notch=1" ];
    loader.efi.canTouchEfiVariables = false;
  };
}

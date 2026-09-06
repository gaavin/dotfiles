# Flashable artefacts for the Pixel 9a: Android boot images wrapping the
# mainline kernel + NixOS initrd, and an ext4 image of the system closure for
# the userdata partition. `nix build .#tegu-images`.
{
  lib,
  stdenvNoCC,
  callPackage,
  path,
  android-tools,
  lz4,
  dtc,
  cpio,
  nixos,
}:

let
  cfg = nixos.config;
  toplevel = cfg.system.build.toplevel;
  kernel = cfg.boot.kernelPackages.kernel;
  initrd = "${cfg.system.build.initialRamdisk}/${cfg.system.boot.loader.initrdFile}";
  dtb = "${kernel}/dtbs/exynos/google/zumapro-tegu.dtb";
  cmdline = lib.concatStringsSep " " ([ "init=${toplevel}/init" ] ++ cfg.boot.kernelParams);

  rootfs = callPackage (path + "/nixos/lib/make-ext4-fs.nix") {
    storePaths = [ toplevel ];
    volumeLabel = "nixos";
    populateImageCommands = "";
  };
in
stdenvNoCC.mkDerivation {
  name = "tegu-images";
  nativeBuildInputs = [
    android-tools
    lz4
    dtc
    cpio
  ];
  dontUnpack = true;

  buildCommand = ''
    mkdir -p $out
    cd $out

    # ABL accepts a raw or lz4 (legacy frame) Image; stock Pixel kernels ship lz4.
    lz4 -l -9 ${kernel}/Image Image.lz4
    cp ${dtb} zumapro-tegu.dtb
    cp ${initrd} initrd.img

    # A vendor ramdisk must exist in the v4 vendor_boot header; ship an empty one.
    mkdir empty
    (cd empty && find . | cpio -o -H newc --quiet) > vendor_ramdisk.cpio

    mkbootimg --header_version 4 --pagesize 4096 \
      --os_version 16.0.0 --os_patch_level 2026-09 \
      --kernel Image.lz4 --ramdisk initrd.img \
      --cmdline ${lib.escapeShellArg cmdline} \
      -o boot.img

    # Pixel 8+ take the generic ramdisk from init_boot, not boot.img.
    mkbootimg --header_version 4 --pagesize 4096 \
      --os_version 16.0.0 --os_patch_level 2026-09 \
      --ramdisk initrd.img \
      -o init_boot.img

    # DTB + vendor cmdline live in vendor_boot; Pixel 8+ also carry a copy in
    # vendor_kernel_boot, and ABL prefers whichever it finds there.
    mkbootimg --header_version 4 --pagesize 4096 \
      --dtb zumapro-tegu.dtb --vendor_ramdisk vendor_ramdisk.cpio \
      --vendor_cmdline ${lib.escapeShellArg cmdline} \
      --vendor_boot vendor_boot.img
    cp vendor_boot.img vendor_kernel_boot.img

    # The stock dtbo targets downstream phandles; replace it with a no-op overlay.
    printf '/dts-v1/;\n/plugin/;\n/ { };\n' > empty.dts
    dtc -I dts -O dtb -q -o empty.dtbo empty.dts
    mkdtboimg create dtbo.img empty.dtbo

    # AVB verification disabled (flags=2); the bootloader must be unlocked.
    avbtool make_vbmeta_image --flags 2 --padding_size 4096 --output vbmeta.img

    ln -s ${rootfs} rootfs.img
    rm -rf empty empty.dts empty.dtbo vendor_ramdisk.cpio

    cat > flash.sh <<SH
    #!/bin/sh
    # Usage: flash.sh [--rootfs]   (phone in fastboot mode, bootloader unlocked)
    set -eu
    d=\$(dirname "\$(readlink -f "\$0")")
    fb=${android-tools}/bin/fastboot
    \$fb flash boot "\$d/boot.img"
    \$fb flash init_boot "\$d/init_boot.img"
    \$fb flash vendor_boot "\$d/vendor_boot.img"
    \$fb flash vendor_kernel_boot "\$d/vendor_kernel_boot.img"
    \$fb flash dtbo "\$d/dtbo.img"
    \$fb flash vbmeta "\$d/vbmeta.img" --disable-verity --disable-verification
    if [ "\''${1:-}" = "--rootfs" ]; then
      \$fb flash userdata "\$d/rootfs.img"
    fi
    \$fb reboot
    SH
    sed -i 's/^    //' flash.sh
    chmod +x flash.sh

    cat > cmdline.txt <<EOT
    ${cmdline}
    EOT
    sed -i 's/^    //' cmdline.txt
  '';

  passthru = {
    inherit kernel rootfs toplevel;
  };
}

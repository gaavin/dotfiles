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

    # An empty ramdisk, for the headers that must carry one but must not
    # contribute any files.
    mkdir empty
    (cd empty && find . | cpio -o -H newc --quiet) > vendor_ramdisk.cpio

    # boot.img carries the kernel only. Its ramdisk is never used: ABL says
    # "using init_boot ramdisk" and assembles the initramfs from the vendor
    # and init_boot images instead, so shipping one here only wastes space.
    mkbootimg --header_version 4 --pagesize 4096 \
      --os_version 16.0.0 --os_patch_level 2026-09 \
      --kernel Image.lz4 --ramdisk vendor_ramdisk.cpio \
      --cmdline ${lib.escapeShellArg cmdline} \
      -o boot.img

    # init_boot is where Android keeps the generic ramdisk, and it is where
    # ours would go if it fitted -- but the partition is only 8 MiB on this
    # phone (fastboot getvar partition-size:init_boot_a = 0x800000) and the
    # NixOS initrd is 25 MiB. Flashing the real thing here fails with
    # "not big enough". So this image exists purely to displace Android's
    # ramdisk, which is otherwise concatenated after ours and takes /init back.
    mkbootimg --header_version 4 --pagesize 4096 \
      --os_version 16.0.0 --os_patch_level 2026-09 \
      --ramdisk vendor_ramdisk.cpio \
      -o init_boot.img

    # ABL loads three ramdisks and concatenates them in this order:
    #
    #   vendor_kernel_boot, then vendor_boot, then init_boot
    #
    # so the real initrd goes in the first of them, where nothing that follows
    # can overwrite its /init. Both vendor images are 64 MiB partitions, with
    # room for a 25 MiB zstd initrd. The DTB and vendor cmdline are carried by
    # both, as before; ABL prefers vendor_kernel_boot's.
    # No --vendor_cmdline here. boot.img already carries the cmdline and ABL
    # concatenates both, so repeating it put a second init= on the command
    # line -- and the last init= wins. While the two agree that is merely
    # redundant, but vendor_boot is the one image small enough to reflash on
    # its own, so the moment it was flashed from a newer build than the
    # rootfs it pointed the initrd at a closure that was not on the phone:
    # "Failed to start Find NixOS closure", emergency shell. Leaving it out
    # makes vendor_boot incapable of contradicting the flashed system.
    mkbootimg --header_version 4 --pagesize 4096 \
      --dtb zumapro-tegu.dtb --vendor_ramdisk vendor_ramdisk.cpio \
      --vendor_boot vendor_boot.img

    mkbootimg --header_version 4 --pagesize 4096 \
      --dtb zumapro-tegu.dtb --vendor_ramdisk initrd.img \
      --vendor_cmdline ${lib.escapeShellArg cmdline} \
      --vendor_boot vendor_kernel_boot.img

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
    # Usage: flash.sh [--rootfs] [--reboot]   (phone in fastboot, unlocked)
    #
    # Does not reboot unless you ask it to.
    #
    # Set FASTBOOT_SERIAL whenever more than one Android device is attached.
    # fastboot with no serial silently picks one, and this port has already
    # aimed a flash at a second Google phone that happened to be plugged in.
    set -eu
    d=\$(dirname "\$(readlink -f "\$0")")
    fb=${android-tools}/bin/fastboot
    rootfs=0
    reboot=0
    for a in "\$@"; do
      case "\$a" in
        --rootfs) rootfs=1 ;;
        --reboot) reboot=1 ;;
        *) echo "flash.sh: unknown argument \$a" >&2; exit 1 ;;
      esac
    done
    if [ -n "\''${FASTBOOT_SERIAL:-}" ]; then
      set -- -s "\$FASTBOOT_SERIAL"
    else
      set --
    fi
    \$fb "\$@" flash boot "\$d/boot.img"
    \$fb "\$@" flash init_boot "\$d/init_boot.img"
    \$fb "\$@" flash vendor_boot "\$d/vendor_boot.img"
    \$fb "\$@" flash vendor_kernel_boot "\$d/vendor_kernel_boot.img"
    \$fb "\$@" flash dtbo "\$d/dtbo.img"
    # Non-fatal: fastboot rejects this image with "Failed to find AVB_MAGIC at
    # offset: 0" when patching the flags, and under set -e that aborted the
    # script before the rootfs was written -- leaving a phone whose boot.img
    # named a closure the rootfs did not have. Verification is already off on
    # an unlocked device that has been booting unsigned kernels all along.
    \$fb "\$@" flash vbmeta "\$d/vbmeta.img" --disable-verity --disable-verification || \
      echo "flash.sh: vbmeta rejected, continuing (verification already disabled)"
    if [ "\$rootfs" = 1 ]; then
      \$fb "\$@" flash userdata "\$d/rootfs.img"
    fi
    if [ "\$reboot" = 1 ]; then
      \$fb "\$@" reboot
    else
      echo "flash.sh: flashed, not rebooting (pass --reboot if you want that)"
    fi
    SH
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

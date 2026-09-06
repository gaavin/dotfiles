# Rescue/bring-up initramfs, built into the kernel image.
#
# This device discards the ramdisk carried in boot.img: on Pixel 8 and later
# the generic ramdisk lives in the separate init_boot partition, and that is
# what the bootloader hands the kernel. A "fastboot boot" of our own image
# therefore runs Android's init, which immediately aborts because this kernel
# has no SELinux. Embedding the initramfs in the kernel side-steps that
# without flashing anything: the built-in archive is unpacked first, and the
# entry point is named so the device's own ramdisk cannot shadow it.
{
  runCommand,
  pkgsStatic,
  cpio,
}:

runCommand "tegu-initramfs.cpio" { nativeBuildInputs = [ cpio ]; } ''
  # /tegu-bin, not /bin: the device's own ramdisk is unpacked over this one
  # and Android's root turns /bin into a symlink, which would hide everything
  # underneath it.
  mkdir -p root/tegu-bin root/proc root/sys root/dev

  cp ${pkgsStatic.busybox}/bin/busybox root/tegu-bin/busybox
  chmod +x root/tegu-bin/busybox
  ln -s busybox root/tegu-bin/sh

  cp ${./rescue-init} root/tegu-init
  chmod +x root/tegu-init

  (cd root && find . | cpio -o -H newc --quiet) > $out
''

# Kernel for the Google Pixel 9a (tegu, Tensor G4 / zumapro).
#
# This used to be plain torvalds 7.3-rc1 with this port's own device tree and a
# handful of grafted drivers. It is now built from the shared zumapro port tree
# (github.com/Trijal08/kernel-mainline, branch zumapro-google-caimito), which
# is mainline 7.3-rc2 plus ~400 commits of Tensor G4 work for the Pixel 9
# family -- and which already carries a zumapro-tegu.dts.
#
# Why the swap. That tree independently reached every hardware conclusion this
# port paid for -- PHY isolation at 0x3ec0, cal-done at TRSV 0x31d, no CDR
# wait, PCS 0x202 = 0x22 for the 38.4 MHz M-PHY reference, the four quirks the
# stock "fixed-prdt-req_list-ocs" property clears, the touch part on
# spi@111d0000 with native manual chip select and a 2 us CS setup delay -- and
# then kept going: full pinctrl and clock drivers for every CMU, secure power
# domains, System MMU v9, ACPM TMU thermal, cpufreq, MCT v3, the eUSB2 +
# USB-DP combo PHY, PCIe, the exynos9 DECON/DSIM display pipeline. Re-deriving
# any one of those here would cost weeks of boots; the register data is the
# same silicon either way.
#
# What this file still owns: the NixOS-shaped config (a built-in rescue
# initramfs, a console on the panel, /dev/mem left open for bring-up) and the
# tegu device-tree deltas in ./kernel/apply.sh.
#
# The previous, self-contained bring-up kernel -- its own zumapro.dtsi, the
# HSI0/HSI2 clock drivers, zumapro-touch.c, the UFS patchers -- is at commit
# 32c547c if it is ever needed again.
{
  lib,
  buildLinux,
  fetchFromGitHub,
  callPackage,
  ...
}@args:

let
  # Upstream base of that branch. Their Makefile says 7.3.0-rc2.
  version = "7.3-rc2";

  # Built into the image because the bootloader discards boot.img's ramdisk
  # on this device; see ./initramfs.nix.
  initramfs = callPackage ./initramfs.nix { };

  kernel = buildLinux (
    args
    // {
      # NOT built through ccacheStdenv. It was tried: the kernel probes the
      # assembler by invoking the compiler, the ccache wrapper does not pass
      # that through, and the config step dies with
      #   "unknown assembler invoked ... Sorry, this assembler is not supported"
      # Making it work would mean teaching the wrapper about -Wa probing;
      # until then a cache miss is cheaper than a broken build.

      inherit version;
      # 7.3.0-rc2 plus their defconfig's CONFIG_LOCALVERSION="-zumapro",
      # which is what "make kernelrelease" prints and therefore what names
      # the module directory. Overriding LOCALVERSION to empty from here is
      # not an option: nixpkgs renders freeform "" as CONFIG_LOCALVERSION="\"\"",
      # and the kernel then tags the release with two literal quote characters.
      modDirVersion = "7.3.0-rc2-zumapro";
      extraMeta.branch = "7.3";

      src = fetchFromGitHub {
        owner = "Trijal08";
        repo = "kernel-mainline";
        rev = "b00e05d92c9c9d4eb7188c979754a52930fb890d";
        hash = "sha256-emNnq0MKK5nBPIFFacIrBz/63h9ntqp9hwrEXQpUcK0=";
      };

      # Their own config for these phones. It is what their boots are tested
      # with, so this port diverges from it as little as possible: everything
      # in structuredExtraConfig below is either a NixOS requirement or a
      # bring-up instrument, not a second opinion about the hardware.
      defconfig = "zumapro_defconfig";
      # Don't let nixpkgs' generic "enable everything as a module" pass undo
      # the choices in that defconfig.
      autoModules = false;
      # The fragment deliberately turns off options that defconfig-selected
      # code re-enables; let the generator warn rather than fail.
      ignoreConfigErrors = true;

      # nixpkgs layers its own common-config.nix over defconfig; force every
      # choice here over that (it wants DEBUG_INFO, its own LOCALVERSION, ...).
      structuredExtraConfig =
        with lib.kernel;
        lib.mapAttrs (_: lib.mkForce) {
          # Their tag ("-zumapro") is kept, so keep it reproducible too: with
          # LOCALVERSION_AUTO the release would grow a "+" or a git hash and
          # modDirVersion above would stop matching.
          LOCALVERSION_AUTO = no;

          # Rescue userspace, linked into the image (see ./initramfs.nix).
          # This is not the NixOS initrd -- that arrives in vendor_kernel_boot
          # -- it is the fallback for a boot that never gets that far.
          BLK_DEV_INITRD = yes;
          INITRAMFS_SOURCE = freeform "${initramfs}";
          RD_GZIP = yes;

          # Console on the panel: ./kernel/zumapro-bootfb.c hands the
          # framebuffer the bootloader left scanning out to simpledrm, and
          # fbcon puts the kernel log on it. Their tree does the same job with
          # a simple-framebuffer node plus an mmio-init-helper writing the
          # DECON autorefresh bit; the driver here is kept because it reads
          # the geometry and format out of DECON instead of hard-coding them,
          # and reserves the buffer as NOMAP before memblock is up.
          DRM = yes;
          DRM_SIMPLEDRM = yes;
          DRM_FBDEV_EMULATION = yes;
          FB_CORE = yes;
          VT = yes;
          VT_CONSOLE = yes;
          FRAMEBUFFER_CONSOLE = yes;
          FRAMEBUFFER_CONSOLE_ROTATION = yes;
          FONTS = yes;
          FONT_8x16 = yes;
          FONT_TER16x32 = yes;
          LOGO = yes;
          LOGO_LINUX_CLUT224 = yes;

          # Debug UART (samsung_tty, google,gs101-uart binding + earlycon)
          SERIAL_SAMSUNG = yes;
          SERIAL_SAMSUNG_CONSOLE = yes;
          SERIAL_EARLYCON = yes;

          # Bring-up instrument: most of this SoC still has no driver, so
          # /dev/mem from userspace is how a block gets inspected.
          # STRICT_DEVMEM would refuse those reads and IO_STRICT_DEVMEM also
          # refuses any range a driver has claimed.
          DEVMEM = yes;
          STRICT_DEVMEM = no;
          IO_STRICT_DEVMEM = no;
          DEBUG_FS = yes;
          REGMAP_DEBUGFS = yes;

          # Root is the phone's own UFS, so none of this may be a module.
          SCSI = yes;
          BLK_DEV_SD = yes;
          SCSI_UFSHCD = yes;
          SCSI_UFSHCD_PLATFORM = yes;
          SCSI_UFS_EXYNOS = yes;
          PHY_SAMSUNG_UFS = yes;
          EXT4_FS = yes;
          SQUASHFS = yes;
          OVERLAY_FS = yes;

          # BL2 arms a 60s cluster watchdog on every boot; nothing petting it
          # is a reset on a timer. Their zumapro.dtsi has both cluster nodes
          # and pixel-common enables cl0 at 30s.
          WATCHDOG = yes;
          S3C2410_WATCHDOG = yes;
          WATCHDOG_SYSFS = yes;
          WATCHDOG_HANDLE_BOOT_ENABLED = yes;

          # cpufreq-dt is instantiated by cpufreq-dt-platdev, which publishes
          # no module alias, so as a module (=m in their defconfig) nothing
          # ever loads it and the CPUs stay at whatever the bootloader left.
          CPUFREQ_DT = yes;

          # The touchscreen. Their driver, on the SPI controller their s3c64xx
          # patches taught to hold a native chip select across a whole
          # message -- which is the thing this port's own driver worked around
          # by calling spi_setup() on both sides of every transfer.
          SPI = yes;
          SPI_MASTER = yes;
          SPI_S3C64XX = yes;
          EXYNOS_USI = yes;
          INPUT = yes;
          INPUT_EVDEV = yes;
          INPUT_TOUCHSCREEN = yes;
          TOUCHSCREEN_SYNA_TCM = yes;

          # NixOS's firewall shells out to iptables, which is iptables-nft --
          # it speaks to nf_tables, not to x_tables. Their defconfig enables
          # only the legacy x_tables path, so firewall.service died on every
          # boot with "Could not fetch rule set generation id: Invalid
          # argument". (The kernel this port built before the base swap had the
          # same gap; it took having a shell on the phone to notice.)
          NF_TABLES = yes;
          NF_TABLES_INET = yes;
          NFT_COMPAT = yes;
          NFT_CT = yes;
          NFT_LOG = yes;
          NFT_LIMIT = yes;
          NFT_MASQ = yes;
          NFT_NAT = yes;
          NFT_REJECT = yes;
          NFT_REJECT_INET = yes;

          # nf_tables alone was not enough: iptables-nft hands any match it
          # has no native translation for to nft_compat, which then needs the
          # x_tables module behind it. NixOS's firewall-start uses three
          # matches, and two of them had nothing to load --
          #
          #   ip46tables -A nixos-fw-log-refuse -m pkttype ! --pkt-type unicast ...
          #   ip46tables -t mangle -A nixos-fw-rpfilter -m rpfilter --validmark ...
          #
          # -- neither guarded by "|| true", so under the script's "set -e"
          # the first of them still ended the boot with
          # "[FAILED] Failed to start Firewall." Their defconfig already has
          # the conntrack and addrtype matches, which is why only these two
          # are here.
          NETFILTER_XT_MATCH_PKTTYPE = yes;
          IP_NF_MATCH_RPFILTER = yes;
          IP6_NF_MATCH_RPFILTER = yes;

          # Console log survives a crash in Android's ramoops window
          PSTORE = yes;
          PSTORE_RAM = yes;
          PSTORE_CONSOLE = yes;
          PSTORE_PMSG = yes;

          # Trimmed: nothing on this phone needs them and they are minutes of
          # build time each. Their defconfig turns them on because it is also
          # a development config.
          RUST = no;
          CORESIGHT = no;
          KVM = no;
          VIRTUALIZATION = no;
          XFS_FS = no;
          BTRFS_FS = no;
          NTFS_FS = no;

          # Keep the build lean; debug info alone would be gigabytes here.
          DEBUG_INFO_NONE = yes;
          DEBUG_INFO = no;
          DEBUG_INFO_REDUCED = no;
          DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT = no;
          DEBUG_INFO_BTF = no;
          MODULE_COMPRESS = no;
        };
    }
  );
in
kernel.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    bash ${./kernel/apply.sh} ${./kernel} ${./dts}
  '';
})

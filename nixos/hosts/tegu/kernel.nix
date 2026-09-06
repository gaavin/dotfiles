# Mainline Linux 7.3-rc1 for the Google Pixel 9a (tegu, Tensor G4 / zumapro).
#
# Upstream has no support for this SoC, so the device tree under ./dts is
# grafted into the tree at build time. The config is the arm64 defconfig with
# every other SoC family switched off and the subsystems this port cannot use
# yet (media, sound, WLAN, PCI ethernet...) trimmed, which keeps a native build
# on an 8 GiB machine tolerable.
{
  lib,
  buildLinux,
  fetchurl,
  ...
}@args:

let
  version = "7.3-rc1";

  # Every CONFIG_ARCH_*=y in arch/arm64/configs/defconfig for 7.3-rc1 except
  # ARCH_EXYNOS, which the Tensor line (gs101 and, here, zumapro) lives under.
  otherSocs = [
    "ARCH_ACTIONS"
    "ARCH_AIROHA"
    "ARCH_SUNXI"
    "ARCH_ALPINE"
    "ARCH_APPLE"
    "ARCH_ARTPEC"
    "ARCH_ASPEED"
    "ARCH_AXIADO"
    "ARCH_BCM"
    "ARCH_BCM2835"
    "ARCH_BCM_IPROC"
    "ARCH_BCMBCA"
    "ARCH_BRCMSTB"
    "ARCH_BERLIN"
    "ARCH_BLAIZE"
    "ARCH_BST"
    "ARCH_CIX"
    "ARCH_K3"
    "ARCH_LG1K"
    "ARCH_HISI"
    "ARCH_KEEMBAY"
    "ARCH_MEDIATEK"
    "ARCH_MESON"
    "ARCH_MICROCHIP"
    "ARCH_SPARX5"
    "ARCH_MVEBU"
    "ARCH_NXP"
    "ARCH_LAYERSCAPE"
    "ARCH_MXC"
    "ARCH_S32"
    "ARCH_MA35"
    "ARCH_NPCM"
    "ARCH_QCOM"
    "ARCH_REALTEK"
    "ARCH_RENESAS"
    "ARCH_ROCKCHIP"
    "ARCH_SEATTLE"
    "ARCH_INTEL_SOCFPGA"
    "ARCH_SOPHGO"
    "ARCH_STM32"
    "ARCH_SYNQUACER"
    "ARCH_TEGRA"
    "ARCH_TESLA_FSD"
    "ARCH_SPRD"
    "ARCH_THUNDER"
    "ARCH_THUNDER2"
    "ARCH_UNIPHIER"
    "ARCH_VEXPRESS"
    "ARCH_VISCONTI"
    "ARCH_XGENE"
    "ARCH_ZYNQMP"
  ];

  kernel = buildLinux (
    args
    // {
      inherit version;
      modDirVersion = "7.3.0-rc1";
      extraMeta.branch = "7.3";

      src = fetchurl {
        url = "https://git.kernel.org/torvalds/t/linux-${version}.tar.gz";
        sha256 = "0w62iaz3yfmv82h36dziqc26ah4q97w31k5s3vxcq1l9gkygndld";
      };

      defconfig = "defconfig";
      # Don't let nixpkgs' generic "enable everything as a module" pass undo
      # the trimming below.
      autoModules = false;
      # The fragment deliberately turns off options that defconfig-selected
      # code re-enables; let the generator warn rather than fail.
      ignoreConfigErrors = true;

      # nixpkgs layers its own common-config.nix over defconfig; force every
      # choice here over that (it wants DEBUG_INFO, sound, media, ... on).
      structuredExtraConfig =
        with lib.kernel;
        lib.mapAttrs (_: lib.mkForce) (
          (lib.genAttrs otherSocs (_: no))
          // {
            ARCH_EXYNOS = yes;

            # Debug UART (samsung_tty, google,gs101-uart binding + earlycon)
            SERIAL_SAMSUNG = yes;
            SERIAL_SAMSUNG_CONSOLE = yes;
            SERIAL_EARLYCON = yes;

            # Console log survives a crash in Android's ramoops window
            PSTORE = yes;
            PSTORE_RAM = yes;
            PSTORE_CONSOLE = yes;
            PSTORE_PMSG = yes;

            # Storage: UFS with the Exynos glue (ufs node still to be written)
            SCSI = yes;
            BLK_DEV_SD = yes;
            SCSI_UFSHCD = yes;
            SCSI_UFSHCD_PLATFORM = yes;
            SCSI_UFS_EXYNOS = yes;

            # USB: DWC3 + gadget side for NCM/ACM debugging over the C port
            USB = yes;
            USB_XHCI_HCD = yes;
            USB_DWC3 = yes;
            USB_DWC3_DUAL_ROLE = yes;
            USB_DWC3_EXYNOS = yes;
            USB_GADGET = yes;
            USB_CONFIGFS = yes;
            USB_CONFIGFS_NCM = yes;
            USB_CONFIGFS_ACM = yes;
            USB_CONFIGFS_RNDIS = yes;
            USB_CONFIGFS_MASS_STORAGE = yes;
            USB_ROLE_SWITCH = yes;

            # Display: only what a bootloader framebuffer could use, for now
            DRM = yes;
            DRM_SIMPLEDRM = yes;
            FRAMEBUFFER_CONSOLE = yes;
            DRM_PANEL = yes;

            # Filesystems used by the images
            EXT4_FS = yes;
            F2FS_FS = yes;
            SQUASHFS = yes;
            OVERLAY_FS = yes;

            # Nothing in these subsystems has a driver for this SoC yet;
            # dropping them roughly halves the build.
            MEDIA_SUPPORT = no;
            SOUND = no;
            WLAN = no;
            ETHERNET = no;
            INFINIBAND = no;
            MMC = no;
            IIO = no;
            STAGING = no;
            CRYPTO_HW = no;
            BLK_DEV_NVME = no;
            KVM = no;
            XEN = no;
            VIRTUALIZATION = no;
            NET_VENDOR_INTEL = no;
            NET_VENDOR_MELLANOX = no;

            # Keep the build lean; debug info alone would be gigabytes here.
            DEBUG_INFO_NONE = yes;
            DEBUG_INFO = no;
            DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT = no;
            DEBUG_INFO_BTF = no;
            KEXEC = no;
            KEXEC_FILE = no;
            MODULE_COMPRESS = no;
          }
        );
    }
  );
in
kernel.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    cp ${./dts}/zumapro.dtsi \
       ${./dts}/zumapro-pixel-common.dtsi \
       ${./dts}/zumapro-tegu.dts \
       arch/arm64/boot/dts/exynos/google/
    printf 'dtb-$(CONFIG_ARCH_EXYNOS) += zumapro-tegu.dtb\n' \
      >> arch/arm64/boot/dts/exynos/google/Makefile
  '';
})

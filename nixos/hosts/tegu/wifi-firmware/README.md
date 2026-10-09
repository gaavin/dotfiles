# Wi-Fi firmware for the Pixel 9a (tegu)

This board's Broadcom combo chip is driven by mainline `brcmfmac` over PCIe
(channel 1). The part is a **BCM4383 rev 2**: it reports chipcommon ID `0x4383`
and enumerates as PCIe endpoint `14e4:4449` -- the same numbers the vendor's
driver knows it by (`BCM4383_CHIP_ID` and `BCM4383_D11AX_ID` in Google's
`kernel/google-modules/wlan/bcmdhd/bcm4383`, `include/bcmdevs.h`). Mainline
`brcmfmac` has no 4383 support at all, so `../kernel/apply.sh` adds it (chip
ID, `CR4_4383_RAM_BASE`, and the firmware mapping); this directory is the
firmware half of that.

`linux-firmware` carries no firmware for it -- a current snapshot has no
`brcmfmac4383*` and no `brcmfmac4390b1-pcie*` either -- so these three files
are taken from the stock vendor image and renamed to the names brcmfmac's PCIe
driver asks for, per `BRCMF_FW_CLM_DEF(4383A3, "brcmfmac4383a3-pcie")`:

| file here | vendor source (`/vendor/firmware/`) | size |
| --- | --- | --- |
| `brcmfmac4383a3-pcie.bin` | `fw_bcmdhd.bin` | 1272701 |
| `brcmfmac4383a3-pcie.clm_blob` | `bcmdhd_clm.blob_4383_a3` | 24708 |
| `brcmfmac4383a3-pcie.txcap_blob` | `bcmdhd_txcap.blob_4383_a3` | 3035 |

The `a3` in the name is the vendor's own: the `.clm_blob`/`.txcap_blob` it
pairs with this firmware are named `..._4383_a3`, and its
`dhd_custom_cis.c` maps this chip's rev 2 to the board revision string `a3`.
The patch's rev mask is nevertheless all-revs (`0xFFFFFFFF`), because the
vendor ships exactly one firmware image for the part.

They were extracted with `debugfs` out of `vendor.img`, itself unpacked from the
device's own factory image `tegu-cp2a.260805.005-factory-a3582e12.zip`:

    debugfs -R "dump /firmware/fw_bcmdhd.bin ./brcmfmac4383a3-pcie.bin" vendor.img

Only the names had to change: mainline's PCIe loader hands the firmware file to
the dongle as a raw blob (`brcmf_pcie_download_fw_nvram`), and the TRX container
that brcmfmac knows how to unwrap is parsed in `brcmfmac/usb.c` only, so the
vendor's raw `fw_bcmdhd.bin` is already the right shape for the PCIe path.

The vendor's `fw_bcmdhd.bin` and its `_4383_a3` twin are byte-identical, and
the `.cal_*` files are for the out-of-tree `bcmdhd`/`dhd` driver, which reads
its NVRAM from OTP on this part, so neither is carried here. The Bluetooth
side of the same chip has its own firmware (`/vendor/firmware/brcm/*.hcd`),
which is not in this directory -- Bluetooth is still to do.

These are ~1.3 MB in total, so they live in git; that also keeps the flake
buildable without any vendor blob living outside it.

# Wi-Fi firmware for the Pixel 9a (tegu)

This board's Broadcom combo chip is driven by mainline `brcmfmac` over PCIe
(channel 1). `linux-firmware` carries no firmware for it -- a current snapshot
has no `brcmfmac4390b1-pcie*` at all -- so these three files are taken from the
stock vendor image and renamed to the names brcmfmac's PCIe driver asks for,
per `BRCMF_FW_CLM_DEF(4390B1, "brcmfmac4390b1-pcie")` in
`drivers/net/wireless/broadcom/brcm80211/brcmfmac/pcie.c`.

| file here | vendor source (`/vendor/firmware/`) | size |
| --- | --- | --- |
| `brcmfmac4390b1-pcie.bin` | `fw_bcmdhd.bin` | 1272701 |
| `brcmfmac4390b1-pcie.clm_blob` | `bcmdhd_clm.blob_4383_a3` | 24708 |
| `brcmfmac4390b1-pcie.txcap_blob` | `bcmdhd_txcap.blob_4383_a3` | 3035 |

They were extracted with `debugfs` out of `vendor.img`, itself unpacked from the
device's own factory image `tegu-cp2a.260805.005-factory-a3582e12.zip`:

    debugfs -R "dump /firmware/fw_bcmdhd.bin ./brcmfmac4390b1-pcie.bin" vendor.img

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

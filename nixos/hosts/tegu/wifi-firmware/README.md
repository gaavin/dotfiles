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
`brcmfmac4383*` and no `brcmfmac4390b1-pcie*` either -- so these files are
taken from the stock vendor image and renamed to the names brcmfmac's PCIe
driver asks for, per `BRCMF_FW_CLM_DEF(4383A3, "brcmfmac4383a3-pcie")`:

| file here | vendor source (`/vendor/firmware/`) | size |
| --- | --- | --- |
| `brcmfmac4383a3-pcie.bin` | `fw_bcmdhd.bin` | 1272701 |
| `brcmfmac4383a3-pcie.clm_blob` | `bcmdhd_clm.blob_4383_a3` | 24708 |
| `brcmfmac4383a3-pcie.txcap_blob` | `bcmdhd_txcap.blob_4383_a3` | 3035 |
| `brcmfmac4383a3-pcie.txt` | board NVRAM, from the `bcmdhd.cal*` family | 14692 |

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

The vendor's `fw_bcmdhd.bin` and its `_4383_a3` twin are byte-identical. The
Bluetooth side of the same chip has its own firmware
(`/vendor/firmware/brcm/*.hcd`), which is not in this directory -- Bluetooth is
still to do.

## The NVRAM (`.txt`)

`brcmfmac4383a3-pcie.txt` is the board NVRAM. brcmfmac asks for it by the same
stem it asks for the firmware, and without it the boot log says

    brcmf_pcie_download_fw_nvram No matching NVRAM file found
    brcm/brcmfmac4383a3-pcie.txt

so the host hands the dongle **no board parameters at all**. This file was
added on 2026-10-09 because that is the one input the driver names as missing,
and the failure it accompanies is deterministic: the dongle boots, attaches
`wl0`/`wl1`, then aborts at a fixed ~7.7 s of firmware uptime at `pc 72b34a`
with byte-identical registers on every boot, before it answers a single dcmd.
A deterministic abort is what a fixed path into an uninitialised resource looks
like, and absent NVRAM is exactly that.

An earlier revision of this file claimed this part "reads its NVRAM from OTP"
and carried no NVRAM. That claim is what the boot is now testing: the vendor's
`.cal*` files *are* its NVRAM (its driver calls them `.cal`), and `vendor.img`
does contain full NVRAM text for this exact part -- `devid=0x4449`,
`boardtype=0x0b07`, header `bcm4383A3 WLBGA iPA/iLNA - TG3`, board name
`bcm94383a3w1007TG4`. If the OTP claim were right, supplying the file should
change nothing; that is a cheap and decisive experiment.

Provenance: found by scanning `factory/vendor.img` for the NVRAM text, which
sits in two adjacent text blobs (`NVRAMRev=$Rev: 884954 $`). The exact member
names could not be recovered -- `debugfs` was not available and the blobs carry
no adjacent filename. Both are the same board and board revision (`boardrev`
`0x1204`, `boardtype` `0x0b07`, `devid` `0x4449`, `aa2g`/`aa5g` `2`,
`femctrl` `17`); they differ in 213 calibration lines -- `rxgains2gtrisoa*`,
`rssi_delta_*`, `powoffs*`, `phyts_5g*`, the `slice/1/proxd*` block, and one
field of `swctrlmap_2g`.

**Both were measured against the dongle, and neither is the fix.**

*Variant A* (first blob, `swctrlmap_2g` third field `0x00000000`) was flashed
on 2026-10-09 and booted. It is definitely consumed by the firmware -- a boot
with no NVRAM at all takes 231111/237421 us for "Firmware boot took", while
variant A takes 772571 us; `Reclaim section 0` grows from 664424 to 668644;
and the trap register set changes from the value that had been byte-identical
across the four preceding boots (`r6 6f7cab`, `r8 6e01b8`, `r9 7a2060`) to a
different one (`r6 424daf`, `r8 81a1a4`, `r9 4`), with the abort moving from
7.674 s to 7.009 s of firmware uptime. But the dongle still aborts at the same
instruction (`pc 72b34a`, `lr 72b33d`) and no `wlan0` appears. Variant A also
turned `Slice1: phy_radio_attach: RF Band Cap` from `2G:1 5G:1` into
`2G:1 5G:0`, which is why variant B is now the one installed.

*Variant B* (second blob, `swctrlmap_2g` third field `0x00000101`) is what this
file currently holds. A and B are both kept in `~/tegu-work/vendor-nvram/`
(`fallback-variant-A-bcm4383a3-nvram.txt`, `nvram-b.txt`) so either can be
restored without re-scanning the 900 MB image.

These are ~1.3 MB in total, so they live in git; that also keeps the flake
buildable without any vendor blob living outside it.

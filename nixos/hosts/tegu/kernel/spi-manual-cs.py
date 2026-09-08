#!/usr/bin/env python3
"""Drive the touch SPI's chip select manually, as Google's driver does.

Mainline hardcodes S3C64XX_SPI_QUIRK_CS_AUTO for google,gs101-spi, so nSS is
driven by the hardware from PACKET_CNT and there is no way to ask for
anything else. Google's own driver is not built that way: it reads
samsung,spi-chip-select-mode from the slave's controller-data and maps 0 to
MANUAL_CS_MODE (1 is auto, 2 is auto-with-quiesce), and tegu's touch node sets

        controller-data {
                samsung,spi-feedback-delay = <0>;
                samsung,spi-chip-select-mode = <0>;   /* manual */
                cs-clock-delay = <2>;
        };

so the panel has always been talked to with a host-held chip select, never a
hardware-timed one.

That difference is measurable here, not theoretical. A read split into two
transfers of one spi_message -- which the SPI core is supposed to cover with a
single chip select -- came back as

        split 4+12: a5 18 ff ff | a5 18 ff ff ff ff ff ff ff ff ff ff

with the device restarting its message on the second transfer, so it saw the
transaction end in the middle. And every read of any length returns one good
byte and then a line rising to its pull-up: two non-ff bytes at 9.98 MHz, one
at 213 kHz, which is a fixed-time release rather than fewer bits of data.

With the quirk gone, s3c64xx_spi_set_cs() writes CS_REG = 0 to assert and
SIG_INACT to release, which is manual mode, and the SPI core holds it for the
whole message. This controller has exactly one device on it -- the
touchscreen -- so nothing else is affected.
"""
import sys

p = "drivers/spi/spi-s3c64xx.c"
s = open(p).read()

anchor = """static const struct s3c64xx_spi_port_config gs101_spi_port_config = {"""
if anchor not in s:
    sys.exit("spi-manual-cs: gs101 port config anchor moved in %s" % p)

start = s.index(anchor)
end = s.index("};", start)
block = s[start:end]

quirk = "\t.quirks\t\t= S3C64XX_SPI_QUIRK_CS_AUTO,\n"
if quirk not in block:
    sys.exit("spi-manual-cs: gs101 port config no longer sets CS_AUTO")

s = s[:start] + block.replace(quirk, "") + s[end:]
open(p, "w").write(s)

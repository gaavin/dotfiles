#!/bin/sh
# Run a command handed to this phone on the kernel command line.
#
# The UART here is receive-only, there is no USB gadget yet (the DWC3 is
# described now but does not initialise without its eUSB/combo PHY), and no
# network. That left flashing an 11 GB
# rootfs as the only way to change what the phone does, which is four minutes
# a round trip.
#
# vendor_boot is 24 KB and flashes in about ten milliseconds, and ABL appends
# its vendor_cmdline to the kernel command line. So a command goes in there,
# base64'd to survive spaces and quoting, and the reply comes back on the UART
# with everything else.
#
# Take the LAST occurrence: boot.img and vendor_boot both carry a cmdline and
# the kernel concatenates them, so an older copy can still be present.
set -u

enc=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^tegu\.cmd=//p' | tail -n 1)
[ -n "$enc" ] || exit 0

cmd=$(printf '%s' "$enc" | base64 -d 2>/dev/null) || {
	echo "tegu-cmd: base64 decode failed" > /dev/kmsg
	exit 0
}

# /bin/sh by absolute path. systemd.services.<n>.path replaces PATH for the
# unit rather than adding to it, and while coreutils come along in
# /run/current-system/sw/bin, a bare "sh" does not exist there -- NixOS only
# provides /bin/sh. The first command sent down this channel died on exactly
# that.
echo "tegu-cmd: BEGIN <<$cmd>>" > /dev/kmsg
/bin/sh -c "$cmd" 2>&1 | while IFS= read -r line; do
	echo "tegu-cmd: $line" > /dev/kmsg
done
echo "tegu-cmd: END" > /dev/kmsg

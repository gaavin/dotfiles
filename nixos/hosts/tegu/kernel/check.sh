#!/usr/bin/env bash
# Compile one of this port's drivers, without building an image.
#
# The alternative was a full rebuild and flash to find out that a driver did
# not compile. The kernel these drivers ship in leaves its build tree in the
# store as the -dev output, and an out-of-tree module built against that tree
# is the same compiler, the same headers and the same config as the real
# build -- so it type-checks the driver for real, in seconds rather than an
# 11 GB rootfs.
#
# It builds them the way they ship: obj-y, one object, no module link. That
# matters beyond taste. As obj-m the compiler defines MODULE, and then
# arch_initcall() and late_initcall_sync() are not declared -- so two drivers
# that build correctly in the image fail here for a reason that is purely an
# artefact of asking the wrong question. Built-in is the question.
#
#	./check.sh                  # every driver here
#	./check.sh zumapro-touch.c  # just this one
#	W=1 ./check.sh              # with the kernel's extra warnings
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$here/../kernel.nix")
[ -n "$version" ] || { echo "check: no version in kernel.nix" >&2; exit 1; }

find_one() {
	# Newest match wins; a stale one from an older build is still fine to
	# compile against, but the current one is the one that ships.
	ls -d $1 2>/dev/null | tail -1
}

kdir=$(find_one "/nix/store/*-linux-aarch64-*-$version-dev/lib/modules/*/build")
cross=$(find_one "/nix/store/*-aarch64-unknown-linux-gnu-gcc-wrapper-*/bin")
make=$(find_one "/nix/store/*-gnumake-*/bin")

if [ -z "$kdir" ]; then
	cat >&2 <<-MSG
	check: no $version build tree in the store.

	It arrives with the kernel, so build the images once and it is there:

	    nix build ./nixos#packages.x86_64-linux.tegu-images

	A garbage collection removes it again.
	MSG
	exit 1
fi
[ -n "$cross" ] || { echo "check: no aarch64 cross gcc in the store" >&2; exit 1; }
[ -n "$make" ] || { echo "check: no gnumake in the store" >&2; exit 1; }

srcs=${*:-$(cd "$here" && echo *.c)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failed=""
for src in $srcs; do
	# A table, not a driver: it is #included by zuma-pinctrl's consumer
	# rather than compiled on its own.
	case $src in zuma-pinctrl-data.c) continue ;; esac

	cp "$here/$src" "$work/"
	echo "obj-y += ${src%.c}.o" > "$work/Makefile"

	echo "=== $src"
	if PATH="$make:$PATH" "$make/make" -C "$kdir" M="$work" ARCH=arm64 \
		CROSS_COMPILE="$cross/aarch64-unknown-linux-gnu-" \
		${W:+W=$W} "${src%.c}.o" 2>&1 |
		grep -v 'pahole\|kernel was built with\|You are using\|Entering directory\|Leaving directory'
	then :; else failed="$failed $src"; fi

	rm -f "$work"/*.c "$work"/*.o "$work"/Makefile "$work"/.*.cmd
done

if [ -n "$failed" ]; then
	echo "check: failed:$failed" >&2
	exit 1
fi
echo "check: ok"

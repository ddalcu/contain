#!/usr/bin/env bash
# Fetch the demo artifacts for `contain boot`: a static aarch64 busybox plus the
# default demo initramfs built from it. Requires only curl, gzip, tar.
#
# The guest KERNEL is no longer fetched here — `contain run`/`boot` auto-fetches
# it in-process the first time it's missing (pure-Zig HTTPS + xz/tar/gzip; see
# src/kernel_fetch.zig). So `contain run hello-world` just works with no setup.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts && cd artifacts

CDN=https://dl-cdn.alpinelinux.org/alpine

# --- static busybox (aarch64) ---
if [ ! -f busybox ]; then
  curl -fsSL "$CDN/v3.18/main/aarch64/busybox-static-1.36.1-r5.apk" -o bb.apk \
    || curl -fsSL "$CDN/latest-stable/main/aarch64/busybox-static-1.37.0-r31.apk" -o bb.apk
  gzip -dc bb.apk 2>/dev/null | tar -xf - bin/busybox.static 2>/dev/null || true
  mv bin/busybox.static busybox && rmdir bin 2>/dev/null || true
  rm -f bb.apk
fi

cd ..
./zig-out/bin/contain mkinitramfs artifacts/busybox artifacts/initramfs.cpio
echo
echo "built demo artifacts. The kernel (artifacts/kernel-contain-arm64) auto-fetches on first run."
echo
echo "Full demo (shell + 9p host mount + networking + persistent disk):"
echo "  mkdir -p artifacts/share; echo hello > artifacts/share/readme.txt"
echo "  head -c 16777216 /dev/zero > artifacts/disk.img"
echo "  ./zig-out/bin/contain boot artifacts/kernel-contain-arm64 artifacts/initramfs.cpio '' artifacts/disk.img artifacts/share"
echo
echo "For the x86 hardware backends (KVM on x86 Linux, WHP on Windows) build the x86 guest:"
echo "  ./tools/build_x86_kernel.sh   # -> artifacts/{kernel-contain-x86_64, initramfs-x86.cpio}"

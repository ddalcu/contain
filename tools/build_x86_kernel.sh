#!/usr/bin/env bash
# Build the x86-64 guest artifacts for contain's x86-microvm platform (the KVM and
# WHP backends): the PVH guest kernel + a busybox demo initramfs. Run on an x86-64
# Linux host (or WSL2). Produces:
#   artifacts/vmlinux-contain     - PVH kernel (linux, virtio-mmio + 9p + 8250)
#   artifacts/busybox-x86         - static x86-64 busybox
#   artifacts/initramfs-x86.cpio  - demo initramfs (busybox + the embedded /init)
#
# The kernel is built with the *simplest* mm init (no deferred struct-page init, no
# NUMA, no KASLR) to dodge an early PVH direct-map bootstrap fault, and with virtio
# blk/net/9p + the 8250 console. The firecracker CI kernels can't be used (their
# no-acpi build faults in early mm; the with-acpi build hangs in acpi_init).
set -euo pipefail

VER="${KVER:-6.6.58}"
# Newer GCCs default to gnu23 (false/bool keywords) which 6.6's realmode can't
# build; gcc-13 is the tested compiler. Override with CC=... HOSTCC=... .
CC="${CC:-gcc-13}"
HOSTCC="${HOSTCC:-$CC}"

cd "$(dirname "$0")/.."
REPO="$PWD"
mkdir -p artifacts
BUILD_DIR="${X86_KBUILD_DIR:-$REPO/.x86-kbuild}"
mkdir -p "$BUILD_DIR"

command -v "$CC" >/dev/null || { echo "need $CC (e.g. apt-get install gcc-13), or pass CC=..."; exit 1; }

# --- kernel ---
cd "$BUILD_DIR"
if [ ! -d "linux-$VER" ]; then
  echo "downloading linux-$VER ..."
  curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz" -o "linux-$VER.tar.xz"
  tar -xf "linux-$VER.tar.xz"
fi
cd "linux-$VER"
make CC="$CC" HOSTCC="$HOSTCC" x86_64_defconfig
make CC="$CC" HOSTCC="$HOSTCC" kvm_guest.config || true

cfg=scripts/config
$cfg --enable PVH                          # PVH boot entry (the ELF Xen note)
$cfg --enable BLK_DEV_INITRD
$cfg --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE   # ttyS0
$cfg --enable VIRTIO --enable VIRTIO_MMIO --enable VIRTIO_MMIO_CMDLINE_DEVICES
$cfg --enable VIRTIO_BLK --enable VIRTIO_NET
$cfg --enable HW_RANDOM --enable HW_RANDOM_VIRTIO
$cfg --enable NET_9P --enable NET_9P_VIRTIO --enable 9P_FS
$cfg --disable DEFERRED_STRUCT_PAGE_INIT   # the mm-bootstrap fault dodge
$cfg --disable NUMA
$cfg --disable RANDOMIZE_BASE --disable RANDOMIZE_MEMORY
$cfg --set-val NR_CPUS 1

make CC="$CC" HOSTCC="$HOSTCC" olddefconfig
echo "=== building vmlinux (takes a few minutes) ==="
make CC="$CC" HOSTCC="$HOSTCC" -j"$(nproc)" vmlinux
cp vmlinux "$REPO/artifacts/vmlinux-contain"
readelf -n vmlinux | grep -qi xen || { echo "ERROR: no PVH note (CONFIG_PVH missing)"; exit 1; }

# --- busybox + demo initramfs ---
cd "$REPO"
if [ ! -f artifacts/busybox-x86 ]; then
  CDN=https://dl-cdn.alpinelinux.org/alpine
  curl -fsSL "$CDN/v3.18/main/x86_64/busybox-static-1.36.1-r5.apk" -o /tmp/bbx.apk \
    || curl -fsSL "$CDN/latest-stable/main/x86_64/busybox-static-1.37.0-r31.apk" -o /tmp/bbx.apk
  gzip -dc /tmp/bbx.apk 2>/dev/null | tar -xf - -C /tmp bin/busybox.static 2>/dev/null
  mv /tmp/bin/busybox.static artifacts/busybox-x86 && rmdir /tmp/bin 2>/dev/null || true
fi
[ -x zig-out/bin/contain ] || zig build
./zig-out/bin/contain mkinitramfs artifacts/busybox-x86 artifacts/initramfs-x86.cpio

echo "DONE — artifacts/{vmlinux-contain, busybox-x86, initramfs-x86.cpio}"
echo "  boot:  ./zig-out/bin/contain boot artifacts/vmlinux-contain artifacts/initramfs-x86.cpio -"
echo "  run:   ./zig-out/bin/contain run alpine cat /etc/os-release"

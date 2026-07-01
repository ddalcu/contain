#!/usr/bin/env bash
# Build contain's x86 guest kernel NATIVELY on a Linux x86_64 host (e.g. WSL2
# Ubuntu) — no Docker, no cross-compiler. Mirrors the x86 path in
# tools/build_kernel.sh but adds CONFIG_FUSE_FS + CONFIG_VIRTIO_FS so the guest
# can mount its rootfs over virtio-fs (the memory-lean, POSIX-complete replacement
# for the 9p share). Requires: gcc, make, flex, bison, bc, libelf-dev, libssl-dev,
# cpio (all preinstalled on a typical dev box).
#
# Output: $OUT/vmlinux-contain-fuse  (raw PVH ELF, do NOT strip)
set -euo pipefail

VER="${KVER:-6.6.58}"
KBUILD="${KBUILD:-$HOME/.contain-kbuild}"
OUT="${OUT:-/mnt/c/Users/ddalcu/code/contain/artifacts}"
J="$(nproc)"
mkdir -p "$KBUILD" "$OUT"

# Linux 6.6's x86 realmode + EFI stub don't build under gcc-14+ (C23 makes
# bool/true/false keywords, clashing with the kernel's own typedefs). Pin a
# gcc that still defaults to gnu17. Override with CC=... if needed.
CC="${CC:-$(command -v gcc-13 || command -v gcc-12 || command -v gcc)}"
export CC
echo "=== using CC=$CC ($($CC --version | head -1)) ==="
MK() { make ARCH=x86_64 O=build-x86 CC="$CC" HOSTCC="$CC" "$@"; }

SRC="$KBUILD/linux-$VER"
if [ ! -d "$SRC" ]; then
  echo "=== downloading linux-$VER source ==="
  curl -fSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz" -o "$KBUILD/linux-$VER.tar.xz"
  tar -xf "$KBUILD/linux-$VER.tar.xz" -C "$KBUILD"
  rm -f "$KBUILD/linux-$VER.tar.xz"
fi
cd "$SRC"

echo "=== configuring x86 kernel (linux-$VER) + FUSE/VIRTIO_FS ==="
MK x86_64_defconfig
MK kvm_guest.config || true
m() { ./scripts/config --file build-x86/.config "$@"; }
m --enable  PVH --enable BLK_DEV_INITRD
m --enable  SERIAL_8250 --enable SERIAL_8250_CONSOLE
m --enable  VIRTIO --enable VIRTIO_MMIO --enable VIRTIO_MMIO_CMDLINE_DEVICES
m --enable  VIRTIO_BLK --enable VIRTIO_NET
m --enable  HW_RANDOM --enable HW_RANDOM_VIRTIO
m --enable  NET_9P --enable NET_9P_VIRTIO --enable 9P_FS
# --- virtio-fs / FUSE (the new bit) ---
m --enable  FUSE_FS --enable VIRTIO_FS
m --disable FUSE_DAX          # non-DAX: no shared-memory window needed
m --disable DEFERRED_STRUCT_PAGE_INIT --disable NUMA
m --disable RANDOMIZE_BASE --disable RANDOMIZE_MEMORY
m --set-val NR_CPUS 1
for o in NETFILTER DRM SOUND SND MEDIA_SUPPORT WLAN WIRELESS INFINIBAND \
         BT NFC HID IIO STAGING; do m --disable "$o"; done
m --disable DEBUG_INFO
MK olddefconfig

# Assert the config actually took (olddefconfig can silently drop a symbol whose
# deps aren't met — better to fail loudly than ship a 9p-only kernel again).
for sym in CONFIG_FUSE_FS CONFIG_VIRTIO_FS; do
  grep -q "^$sym=y" build-x86/.config || { echo "ERROR: $sym is not =y after olddefconfig"; grep "$sym" build-x86/.config || true; exit 1; }
done
echo "=== FUSE/VIRTIO_FS confirmed =y; compiling ($J jobs) ==="
MK -j"$J" vmlinux

install -m644 build-x86/vmlinux "$OUT/vmlinux-contain-fuse"
readelf -n "$OUT/vmlinux-contain-fuse" | grep -qi xen || { echo "ERROR: shipped vmlinux has no PVH note"; exit 1; }
echo "=== DONE: $OUT/vmlinux-contain-fuse ==="
ls -l "$OUT/vmlinux-contain-fuse"

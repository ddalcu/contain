#!/usr/bin/env bash
# Build contain's own lightweight guest kernels for BOTH arches inside a Linux
# Docker container, ready to host as GitHub release assets. Building a Linux
# kernel needs a Linux toolchain, so we do it in a container: on Apple Silicon
# the arm64 kernel builds natively, and the x86 kernel is cross-compiled with
# x86_64-linux-gnu-gcc in the same container.
#
# Produces (stripped + gzip'd, for hosting) under artifacts/release/, and drops
# the raw kernels in artifacts/ for an immediate local boot:
#   artifacts/release/Image-arm64.gz            -> artifacts/Image-arm64      (arm64 Image)
#   artifacts/release/vmlinux-contain-x86_64.gz -> artifacts/vmlinux-contain  (x86 PVH ELF)
#   artifacts/release/SHA256SUMS
#
# These are the assets src/kernel_fetch.zig downloads from the GitHub release.
#
# Usage:
#   tools/build_kernel.sh             # both arches
#   tools/build_kernel.sh arm64       # just arm64
#   tools/build_kernel.sh x86_64      # just x86
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

VER="${KVER:-6.6.58}"
WHICH="${1:-both}"
IMG="contain-kbuild:bookworm"
KBUILD="$REPO/.kbuild"          # source + object cache (gitignored)
OUT="$REPO/artifacts"
mkdir -p "$KBUILD" "$OUT/release"

command -v docker >/dev/null || { echo "need Docker (this script builds the kernel in a Linux container)"; exit 1; }

# --- one-time builder image (bookworm gcc-12 defaults to gnu17, which 6.6's x86
#     realmode needs; gnu23 from gcc-14+ fails to build it) ---
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "=== building kernel-builder image ($IMG) ==="
  docker build -t "$IMG" - <<'DOCKERFILE'
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev \
      xz-utils curl ca-certificates gcc-x86-64-linux-gnu cpio kmod \
  && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

# Fetch + extract the kernel source on the HOST. We do this here (not in the
# container) because the container may sit behind a TLS-intercepting proxy whose
# root CA it lacks, while the host trusts it.
fetch_src() {
  [ -d "$KBUILD/linux-$VER" ] && return 0
  echo "=== downloading linux-$VER source (host) ==="
  curl -fSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz" -o "$KBUILD/linux-$VER.tar.xz"
  tar -xf "$KBUILD/linux-$VER.tar.xz" -C "$KBUILD"
  rm -f "$KBUILD/linux-$VER.tar.xz"
}

# The in-container build (no network — source is already mounted). $1 = arch.
run_build() {
  local arch="$1"
  fetch_src
  echo "=== building $arch kernel (linux-$VER) ==="
  docker run --rm -i -v "$KBUILD:/b" -v "$OUT:/out" -e VER="$VER" -e ARCH_SEL="$arch" \
    -w /b "$IMG" bash -euo pipefail <<'INNER'
cd "/b/linux-$VER"
cfg=scripts/config
J="$(nproc)"

if [ "$ARCH_SEL" = arm64 ]; then
  # defconfig already boots our virt machine (PL011 + GICv2 + arch timer +
  # virtio + 9p are all =y). We only add virtio-rng / 9p-fs and trim big unused
  # subsystems + modules, keeping the boot path defconfig already proves.
  make ARCH=arm64 O=build-arm64 defconfig
  m() { ./scripts/config --file build-arm64/.config "$@"; }
  m --disable MODULES
  m --enable  VIRTIO --enable VIRTIO_MMIO --enable VIRTIO_MMIO_CMDLINE_DEVICES
  m --enable  VIRTIO_BLK --enable VIRTIO_NET
  m --enable  HW_RANDOM --enable HW_RANDOM_VIRTIO
  m --enable  NET_9P --enable NET_9P_VIRTIO --enable 9P_FS
  m --enable  SERIAL_AMBA_PL011 --enable SERIAL_AMBA_PL011_CONSOLE
  m --enable  BLK_DEV_INITRD
  # Trim defconfig hard for a headless virtio guest: no ACPI (we boot from a
  # DTB), no SoC/vendor driver zoo, no filesystem zoo, nothing non-virtio for
  # storage / net / display / input. Keep ext4 + 9p + overlay + tmpfs and the
  # arm64 virt core (GICv2, arch timer, PSCI, PL011, virtio-mmio).
  for o in ACPI DRM SOUND MEDIA_SUPPORT WLAN WIRELESS USB_SUPPORT INFINIBAND \
           SCSI ATA NVME_CORE MMC MTD MD BT NFC NETFILTER ETHERNET \
           HID IIO STAGING COMEDI NEW_LEDS HWMON THERMAL WATCHDOG POWER_SUPPLY \
           SND REGULATOR MEDIA_SUPPORT_FILTER CRYPTO_HW KEXEC CRASH_DUMP PROFILING \
           XFS_FS BTRFS_FS F2FS_FS GFS2_FS OCFS2_FS NILFS2_FS JFS_FS REISERFS_FS \
           NFS_FS NFSD CIFS CEPH_FS FAT_FS NTFS_FS HFS_FS HFSPLUS_FS UBIFS_FS \
           JFFS2_FS NUMA RANDOMIZE_BASE; do m --disable "$o"; done
  # Re-assert the must-haves disabling a parent menu may have dropped.
  m --enable EXT4_FS --enable OVERLAY_FS --enable TMPFS
  m --enable NETDEVICES --enable VIRTIO_NET
  make ARCH=arm64 O=build-arm64 olddefconfig
  make ARCH=arm64 O=build-arm64 -j"$J" Image
  install -m644 build-arm64/arch/arm64/boot/Image /out/Image-arm64
  gzip -9 -c build-arm64/arch/arm64/boot/Image > /out/release/Image-arm64.gz
  ls -l /out/Image-arm64 /out/release/Image-arm64.gz

elif [ "$ARCH_SEL" = x86_64 ]; then
  # Mirror tools/build_x86_kernel.sh: simplest mm init (no deferred page init,
  # NUMA, KASLR) to dodge the early-PVH direct-map fault, PVH boot entry, virtio
  # + 9p + the 8250 console. Cross-compiled from the (arm64) container.
  X=x86_64-linux-gnu-
  make ARCH=x86_64 CROSS_COMPILE=$X O=build-x86 x86_64_defconfig
  make ARCH=x86_64 CROSS_COMPILE=$X O=build-x86 kvm_guest.config || true
  m() { ./scripts/config --file build-x86/.config "$@"; }
  m --enable  PVH --enable BLK_DEV_INITRD
  m --enable  SERIAL_8250 --enable SERIAL_8250_CONSOLE
  m --enable  VIRTIO --enable VIRTIO_MMIO --enable VIRTIO_MMIO_CMDLINE_DEVICES
  m --enable  VIRTIO_BLK --enable VIRTIO_NET
  m --enable  HW_RANDOM --enable HW_RANDOM_VIRTIO
  m --enable  NET_9P --enable NET_9P_VIRTIO --enable 9P_FS
  m --disable DEFERRED_STRUCT_PAGE_INIT --disable NUMA
  m --disable RANDOMIZE_BASE --disable RANDOMIZE_MEMORY
  m --set-val NR_CPUS 1
  # Trim subsystems a headless virtio/PVH guest never uses. NETFILTER off also
  # dodges an out-of-tree (O=) Kbuild break on net/netfilter/xt_TCPMSS.o. Keep
  # ACPI (the x86 boot relies on it, falling back to the MP table) unlike arm64.
  for o in NETFILTER DRM SOUND SND MEDIA_SUPPORT WLAN WIRELESS INFINIBAND \
           BT NFC HID IIO STAGING; do m --disable "$o"; done
  m --disable DEBUG_INFO   # keep vmlinux small WITHOUT stripping (strip drops the PVH note)
  make ARCH=x86_64 CROSS_COMPILE=$X O=build-x86 olddefconfig
  make ARCH=x86_64 CROSS_COMPILE=$X O=build-x86 -j"$J" vmlinux
  # Ship vmlinux as-is — do NOT strip: `strip` removes the `.note.Xen` PT_NOTE
  # that PVH (PHYS32_ENTRY) boot requires. Assert the note on the shipped file.
  install -m644 build-x86/vmlinux /out/vmlinux-contain
  readelf -n /out/vmlinux-contain | grep -qi xen || { echo "ERROR: shipped vmlinux has no PVH note"; exit 1; }
  gzip -9 -c /out/vmlinux-contain > /out/release/vmlinux-contain-x86_64.gz
  ls -l /out/vmlinux-contain /out/release/vmlinux-contain-x86_64.gz
fi
INNER
  # Belt-and-suspenders: a failing in-container build hasn't always propagated a
  # non-zero exit through `docker run`, so verify the asset was actually produced.
  local want; [ "$arch" = arm64 ] && want="$OUT/release/Image-arm64.gz" || want="$OUT/release/vmlinux-contain-x86_64.gz"
  [ -f "$want" ] || { echo "BUILD FAILED: $want was not produced (see output above)"; exit 1; }
}

case "$WHICH" in
  arm64)  run_build arm64 ;;
  x86_64|x86|amd64) run_build x86_64 ;;
  both)   run_build arm64; run_build x86_64 ;;
  *) echo "usage: $0 [arm64|x86_64|both]"; exit 1 ;;
esac

# Refresh the checksum manifest for whatever release assets now exist.
( cd "$OUT/release" && ls *.gz >/dev/null 2>&1 && shasum -a 256 *.gz > SHA256SUMS && cat SHA256SUMS ) || true

echo
echo "DONE. Release assets in artifacts/release/ — upload them to the GitHub release"
echo "tag that src/kernel_fetch.zig points at. The raw kernels are in artifacts/ for"
echo "an immediate local boot:  ./zig-out/bin/contain run hello-world"

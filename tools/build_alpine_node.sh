#!/usr/bin/env bash
# Build a small Alpine aarch64 rootfs containing Node.js 24 LTS (+ npm, bash,
# curl, ca-certificates) and pack it as an initramfs for `contain boot`.
#
# By default the cpio is left UNCOMPRESSED so the kernel skips the gzip-inflate
# step at boot (a small saving). The kernel auto-detects the format, so contain
# needs no
# change. Set GZIP=1 to produce the smaller .cpio.gz instead (for distribution).
#
# The whole rootfs lives in the guest's initramfs (a RAM tmpfs), so it is a
# "proper" Alpine userspace: apk works, files are writable, etc.
#
# Requirements: curl, tar, gzip, cpio, and either root (apk.static must create
# device nodes / chown) or fakeroot. On WSL the easy path is:
#     wsl -d <distro> -u root tools/build_alpine_node.sh
#
# Output: artifacts/alpine-node.cpio  (or .cpio.gz with GZIP=1)
#
# Boot it, e.g.:
#     contain boot artifacts/kernel-contain-arm64 artifacts/alpine-node.cpio tty - - 8080
# then inside the guest run your app on 0.0.0.0:8080; reach it from the host at
# http://127.0.0.1:8080  (see the `ports` arg / README).
set -euo pipefail
cd "$(dirname "$0")/.."

CDN=${ALPINE_CDN:-https://dl-cdn.alpinelinux.org/alpine}
BRANCH=${ALPINE_BRANCH:-edge}          # 'edge' currently carries nodejs 24
ARCH=aarch64
APKTOOLS_VER=${APKTOOLS_VER:-3.0.6-r0}
WORK=artifacts/alpine-build
ROOT="$WORK/rootfs"
# Uncompressed by default (skips the kernel's gzip-inflate at boot); GZIP=1 -> .gz.
OUT=artifacts/alpine-node.cpio${GZIP:+.gz}

# Run privileged commands directly as root, else via fakeroot.
if [ "$(id -u)" = "0" ]; then PRIV=""; else
  command -v fakeroot >/dev/null 2>&1 || { echo "need root or fakeroot"; exit 1; }
  PRIV=fakeroot
fi

mkdir -p "$WORK" artifacts
if [ ! -x "$WORK/apk.static" ]; then
  echo "[*] fetching apk.static ($APKTOOLS_VER)"
  curl -fsSL "$CDN/latest-stable/main/x86_64/apk-tools-static-$APKTOOLS_VER.apk" -o "$WORK/apkts.apk"
  tar -xzf "$WORK/apkts.apk" -C "$WORK" sbin/apk.static
  mv "$WORK/sbin/apk.static" "$WORK/apk.static"; rmdir "$WORK/sbin" 2>/dev/null || true
fi

echo "[*] bootstrapping Alpine $BRANCH/$ARCH rootfs into $ROOT"
$PRIV rm -rf "$ROOT"; mkdir -p "$ROOT"
$PRIV "$WORK/apk.static" --arch "$ARCH" \
  -X "$CDN/$BRANCH/main" -X "$CDN/$BRANCH/community" \
  -U --allow-untrusted --root "$ROOT" --initdb --no-scripts \
  add alpine-baselayout busybox musl apk-tools \
      ca-certificates curl bash nodejs npm

echo "[*] node version: $(grep -A3 '^P:nodejs$' "$ROOT/lib/apk/db/installed" | sed -n 's/^V://p' | head -1)"

# --no-scripts skips the post-install that creates the npm/npx wrappers; add them.
if [ -f "$ROOT/usr/lib/node_modules/npm/bin/npm-cli.js" ]; then
  $PRIV ln -sf ../lib/node_modules/npm/bin/npm-cli.js "$ROOT/usr/bin/npm"
  $PRIV ln -sf ../lib/node_modules/npm/bin/npx-cli.js "$ROOT/usr/bin/npx"
fi
# npm-cli.js (and most node CLI tools / package bin scripts) start with
# `#!/usr/bin/env node`. busybox --install only populates /bin, so /usr/bin/env
# is missing and the shebang fails with "npm: not found". Symlink it to busybox
# (which dispatches its `env` applet on argv[0]) so all such shebangs resolve.
$PRIV ln -sf /bin/busybox "$ROOT/usr/bin/env"

# Minimal init: mounts, busybox applets, NAT networking, then a shell (or /app).
$PRIV tee "$ROOT/init" >/dev/null <<'INIT'
#!/bin/sh
/bin/busybox mkdir -p /proc /sys /dev /tmp /run /etc
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox --install -s /bin
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=linux
# contain's userspace NAT: 10.0.2.15/24, gateway/DNS 10.0.2.2/10.0.2.3
ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
ip link set eth0 up 2>/dev/null
ip route add default via 10.0.2.2 2>/dev/null
echo "nameserver 10.0.2.3" > /etc/resolv.conf
echo "contain: Alpine $(cat /etc/alpine-release 2>/dev/null) guest, node $(node --version 2>/dev/null)"
# Serial consoles have no window size, so node's REPL (and other readline UIs)
# get columns=0 and render garbled. Give the tty a sane default size.
stty rows 24 cols 80 2>/dev/null
# Run /app/start.sh if present, else give an interactive shell.
if [ -x /app/start.sh ]; then
  cd /app && exec ./start.sh
fi
# Run the shell as a CHILD of init (not exec) so typing `exit` returns here and
# powers off cleanly instead of killing PID 1 (which panics the kernel).
setsid -c /bin/sh
sync; poweroff -f
INIT
$PRIV chmod +x "$ROOT/init"
$PRIV mknod -m 600 "$ROOT/dev/console" c 5 1 2>/dev/null || true
$PRIV mknod -m 666 "$ROOT/dev/null" c 1 3 2>/dev/null || true

echo "[*] packing $OUT"
if [ -n "${GZIP:-}" ]; then
    ( cd "$ROOT" && $PRIV find . | $PRIV cpio -o -H newc --quiet | gzip -1 ) > "$OUT"
else
    ( cd "$ROOT" && $PRIV find . | $PRIV cpio -o -H newc --quiet ) > "$OUT"
fi
echo "[*] done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "    boot: contain boot artifacts/kernel-contain-arm64 $OUT tty - - 8080"

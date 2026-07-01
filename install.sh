#!/bin/sh
# contain installer — downloads the latest release binary for your OS/arch and
# installs it to PREFIX (default /usr/local/bin). One command:
#
#   curl -fsSL https://raw.githubusercontent.com/ddalcu/contain/main/install.sh | sh
#
# Override the install dir:  PREFIX=$HOME/.local/bin  (then ensure it's on PATH)
# Windows isn't covered here — grab contain-windows-x86_64.exe from the Releases
# page (it runs as-is).
set -eu

REPO="ddalcu/contain"
PREFIX="${PREFIX:-/usr/local/bin}"

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Linux)  os=linux ;;
  Darwin) os=macos ;;
  *) echo "Unsupported OS '$os'. On Windows, download contain-windows-x86_64.exe from" >&2
     echo "  https://github.com/$REPO/releases" >&2; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64)  arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
esac

# contain currently ships linux/x86_64 and macos/aarch64 prebuilt binaries.
case "$os-$arch" in
  linux-x86_64)  asset="contain-linux-x86_64.tar.gz" ;;
  macos-aarch64) asset="contain-macos-aarch64.tar.gz" ;;
  *) echo "No prebuilt binary for $os/$arch. Build from source (needs Zig 0.16):" >&2
     echo "  git clone https://github.com/$REPO && cd contain && zig build -Doptimize=ReleaseFast" >&2
     exit 1 ;;
esac

echo "Finding the latest contain release ($asset)..."
# The repo also hosts kernel releases (kernels-vN) with no binary assets, so pick
# the newest release that actually contains this asset (releases are newest-first).
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" \
      | grep '"browser_download_url"' \
      | grep -F "/$asset\"" \
      | head -1 \
      | sed -E 's/.*"(https:[^"]+)".*/\1/')
[ -n "$url" ] || { echo "Could not find a release asset '$asset'. See https://github.com/$REPO/releases" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $url"
curl -fsSL "$url" -o "$tmp/contain.tar.gz"
tar -xzf "$tmp/contain.tar.gz" -C "$tmp"
# A curl|sh install isn't quarantined, but strip the flag anyway so a re-run over a
# browser-downloaded copy still runs without a Gatekeeper prompt (macOS only).
[ "$os" = macos ] && xattr -d com.apple.quarantine "$tmp/contain" 2>/dev/null || true

if [ -w "$PREFIX" ] || [ "$(id -u)" = 0 ]; then
  install -m755 "$tmp/contain" "$PREFIX/contain"
else
  echo "Installing to $PREFIX (needs sudo)..."
  sudo install -m755 "$tmp/contain" "$PREFIX/contain"
fi

echo "Installed contain -> $PREFIX/contain"
echo "Try:  contain run alpine cat /etc/os-release"

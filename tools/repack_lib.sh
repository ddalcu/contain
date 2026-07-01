#!/bin/sh
# Re-pack a Zig-produced static archive so Apple's ld (Xcode/Swift) accepts it.
#
# Zig's archiver writes mach-o archive members that the classic Apple linker
# rejects with "not 8-byte aligned". macOS `libtool -static` rewrites the archive
# with the alignment + symbol table Apple's ld wants. Run on macOS only; elsewhere
# the Zig archive links fine as-is.
#
# Usage: tools/repack_lib.sh <path-to-libcontain.a>
set -e
ar_path="$1"
[ -f "$ar_path" ] || { echo "repack_lib: no archive at $ar_path" >&2; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Extract members (Zig stores them mode 0, so make them readable for libtool).
( cd "$tmp" && ar x "$ar_path" && chmod u+rw ./*.o )
libtool -static -o "$ar_path" "$tmp"/*.o
echo "repack_lib: re-packed $ar_path for Apple ld"

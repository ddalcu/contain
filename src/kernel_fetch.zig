//! In-process guest-kernel auto-fetch. When `contain boot`/`run` finds the guest
//! kernel missing, this downloads contain's own lightweight prebuilt kernel for
//! the host arch from the project's GitHub release and gunzips it into place —
//! reusing the same std HTTP/TLS + gzip blocks as the OCI pull, no external tools.
//!
//! The kernels are built by `tools/build_kernel.sh` (one per arch: an arm64
//! `Image` and an x86 PVH `vmlinux`) and hosted as release assets, so the fetch
//! is a plain HTTPS GET + gunzip — a couple MB, versus the old Kata bundle's
//! ~158 MB `.tar.xz`. Both arm64 and x86 hosts auto-fetch.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const flate = std.compress.flate;

// contain's kernel release — a pinned, separately-published release of the guest
// kernels (they change rarely, so they're decoupled from the per-commit binary
// releases). Assets are public, so the download needs no auth. Bump this only
// when you actually rebuild + republish the kernels (tools/build_kernel.sh).
const release_base = "https://github.com/ddalcu/contain/releases/download";
const release_tag = "kernels-v2";

const Asset = struct { url_name: []const u8, local_path: []const u8 };

/// The release asset (gzip'd) + the local path it installs to, for the host arch;
/// null if this arch has no prebuilt kernel.
fn hostAsset() ?Asset {
    return switch (builtin.cpu.arch) {
        .aarch64 => .{ .url_name = "kernel-contain-arm64.gz", .local_path = "artifacts/kernel-contain-arm64" },
        .x86_64 => .{ .url_name = "kernel-contain-x86_64.gz", .local_path = "artifacts/kernel-contain-x86_64" },
        else => null,
    };
}

pub const Error = error{ UnsupportedHostArch, HttpStatus };

/// The canonical guest-kernel path for the host arch. `cmdRunOci` uses this, and
/// `cmdBoot` only auto-fetches when the requested kernel equals it (never a
/// user's custom `boot <kernel>` path).
pub fn defaultKernelPath() []const u8 {
    return if (hostAsset()) |a| a.local_path else "artifacts/kernel-contain-arm64";
}

/// Resolve the guest-kernel path **independent of the current directory**, so the
/// binary finds (or fetches to) a stable kernel no matter where it's launched from.
/// Search order (first that exists wins):
///   1. `artifacts/<kernel>` relative to the CWD — a dev running from the repo root.
///   2. `<exe_dir>/artifacts/<kernel>` — a kernel installed next to the binary.
///   3. `<exe_dir>/../artifacts` and `../../artifacts` — a repo checkout run as
///      `<repo>/zig-out/bin/contain` (this is the case that used to mis-fetch a
///      stale kernel into `zig-out/bin/artifacts` because the path was CWD-relative).
/// If none exist, returns `<exe_dir>/artifacts/<kernel>` as the CWD-independent
/// target for `ensureKernel` to fetch into. The returned slice is caller-owned.
pub fn resolveKernelPath(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    const rel = defaultKernelPath(); // e.g. "artifacts/kernel-contain-x86_64"
    if (fileExists(io, rel)) return alloc.dupe(u8, rel);
    const exe = std.process.executablePathAlloc(io, alloc) catch return alloc.dupe(u8, rel);
    defer alloc.free(exe);
    const exe_dir = std.fs.path.dirname(exe) orelse return alloc.dupe(u8, rel);
    // Preferred install/fetch location: next to the binary.
    const primary = try std.fs.path.join(alloc, &.{ exe_dir, rel });
    if (fileExists(io, primary)) return primary;
    for ([_][]const u8{ "..", "../.." }) |up| {
        const cand = try std.fs.path.join(alloc, &.{ exe_dir, up, rel });
        if (fileExists(io, cand)) {
            alloc.free(primary);
            return cand;
        }
        alloc.free(cand);
    }
    return primary; // nothing exists yet — fetch here (CWD-independent)
}

/// Ensure the guest kernel exists at `path`. No-op returning false if present;
/// otherwise downloads + installs the host-arch kernel and returns true.
pub fn ensureKernel(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    if (fileExists(io, path)) return false;
    const asset = hostAsset() orelse return error.UnsupportedHostArch;

    const url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ release_base, release_tag, asset.url_name });
    defer gpa.free(url);
    std.debug.print("[kernel] guest kernel '{s}' not found; fetching {s} ...\n", .{ path, asset.url_name });

    const gz = try download(gpa, io, url);
    defer gpa.free(gz);
    const raw = try inflateGzipIfNeeded(gpa, gz);
    defer gpa.free(raw);

    // Install via a `.part` temp + rename so an interrupted fetch never leaves a
    // truncated kernel behind.
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    const tmp = try std.fmt.allocPrint(gpa, "{s}.part", .{path});
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = raw });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    std.debug.print("[kernel] installed {s} ({d} bytes)\n", .{ path, raw.len });
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// GET `url` into memory, following redirects (GitHub release → its asset CDN).
fn download(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();
    // No extra headers: std.http.Client already sends a default User-Agent, and
    // adding a second one makes GitHub's asset CDN reject the request with 400.
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
    });
    if (res.status != .ok) {
        std.debug.print("[kernel] GET {s} -> HTTP {d}\n", .{ url, @intFromEnum(res.status) });
        return error.HttpStatus;
    }
    return aw.toOwnedSlice();
}

/// If `data` begins with the gzip magic, inflate it; otherwise return a copy
/// unchanged. Release kernels are gzip'd; a raw kernel still passes through.
fn inflateGzipIfNeeded(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < 2 or data[0] != 0x1f or data[1] != 0x8b) return gpa.dupe(u8, data);
    var in = std.Io.Reader.fixed(data);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var dec = flate.Decompress.init(&in, .gzip, window);
    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();
    _ = try dec.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests — the network path isn't unit-tested; these cover the pure pieces.

const testing = std.testing;

fn gzipInto(out: []u8, data: []const u8) ![]u8 {
    var fw = std.Io.Writer.fixed(out);
    var cbuf: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&fw, &cbuf, .gzip, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return fw.buffered();
}

test "hostAsset: arm64/x86 map to the right asset + local path" {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            const a = hostAsset().?;
            try testing.expectEqualStrings("kernel-contain-arm64.gz", a.url_name);
            try testing.expectEqualStrings("artifacts/kernel-contain-arm64", a.local_path);
        },
        .x86_64 => {
            const a = hostAsset().?;
            try testing.expectEqualStrings("kernel-contain-x86_64.gz", a.url_name);
            try testing.expectEqualStrings("artifacts/kernel-contain-x86_64", a.local_path);
        },
        else => try testing.expect(hostAsset() == null),
    }
    // defaultKernelPath always resolves to a non-empty path.
    try testing.expect(defaultKernelPath().len > 0);
}

test "inflateGzipIfNeeded: inflates gzip, passes non-gzip through unchanged" {
    const plain = "raw-kernel-Image-bytes-" ** 64;
    var gzbuf: [4096]u8 = undefined;
    const gz = try gzipInto(&gzbuf, plain);

    const inflated = try inflateGzipIfNeeded(testing.allocator, gz);
    defer testing.allocator.free(inflated);
    try testing.expectEqualSlices(u8, plain, inflated);

    const not_gz = "ELF\x7f-not-gzip";
    const passthrough = try inflateGzipIfNeeded(testing.allocator, not_gz);
    defer testing.allocator.free(passthrough);
    try testing.expectEqualSlices(u8, not_gz, passthrough);
}

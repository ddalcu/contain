//! Minimal OCI / Docker-Hub image puller + unpacker, from scratch (no skopeo /
//! umoci / external deps). Supports anonymous pulls of public images from Docker
//! Hub: the registry v2 token dance (no credentials), multi-arch manifest index
//! selection, config + gzip'd-tar layers, and overlay-style unpack (with `.wh.`
//! whiteouts) into a host rootfs directory.
//!
//! Built on the Zig std building blocks: `std.http.Client` (TLS), `std.json`,
//! `std.compress.flate` (gzip), `std.tar`. Scope is deliberately small — public
//! images, linux/amd64 + linux/arm64, no auth, no signatures.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const flate = std.compress.flate;
const tar = std.tar;

const registry_host = "registry-1.docker.io";
const auth_url_fmt = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{s}:pull";

const accept_manifests =
    "application/vnd.oci.image.index.v1+json," ++
    "application/vnd.docker.distribution.manifest.list.v2+json," ++
    "application/vnd.oci.image.manifest.v1+json," ++
    "application/vnd.docker.distribution.manifest.v2+json";

pub const Arch = enum {
    amd64,
    arm64,
    pub fn hostDefault() Arch {
        return switch (builtin.cpu.arch) {
            .x86_64 => .amd64,
            .aarch64 => .arm64,
            else => .amd64,
        };
    }
    pub fn str(self: Arch) []const u8 {
        return @tagName(self);
    }
};

/// Parsed OCI image config (the runtime knobs we care about). All slices are
/// owned by the `arena` passed to `pull`.
pub const ImageConfig = struct {
    entrypoint: []const []const u8 = &.{},
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    working_dir: []const u8 = "",
    user: []const u8 = "",
};

const Ref = struct { repo: []u8, tag: []u8 };

/// Parse an image reference into a Docker Hub repo + tag. Bare names get the
/// `library/` namespace; the default tag is `latest`. (No registry-host prefix
/// support — Docker Hub only.)
fn parseRef(gpa: std.mem.Allocator, ref: []const u8) !Ref {
    // Split off the tag at the last ':' that is after the last '/'.
    var name = ref;
    var tag: []const u8 = "latest";
    if (std.mem.lastIndexOfScalar(u8, ref, ':')) |c| {
        if (std.mem.indexOfScalarPos(u8, ref, c, '/') == null) {
            name = ref[0..c];
            tag = ref[c + 1 ..];
        }
    }
    const repo = if (std.mem.indexOfScalar(u8, name, '/') == null)
        try std.fmt.allocPrint(gpa, "library/{s}", .{name})
    else
        try gpa.dupe(u8, name);
    return .{ .repo = repo, .tag = try gpa.dupe(u8, tag) };
}

/// GET `url` and return the body (owned by `gpa`). `accept` / `token` add the
/// Accept and (privileged, stripped-on-redirect) Authorization headers.
// A pull fires ~20 sequential requests (token, manifest, config, N layers) with
// long unpack gaps between them. Retry a few times so a transient network drop —
// or a server closing an idle connection during those gaps — doesn't abort the pull.
const http_max_attempts = 5;

fn httpGet(client: *http.Client, gpa: std.mem.Allocator, url: []const u8, accept: ?[]const u8, token: ?[]const u8) ![]u8 {
    var extra: [2]http.Header = undefined;
    var extra_n: usize = 0;
    if (accept) |a| {
        extra[extra_n] = .{ .name = "accept", .value = a };
        extra_n += 1;
    }
    var authbuf: [4096]u8 = undefined;
    if (token) |t| {
        const auth = try std.fmt.bufPrint(&authbuf, "Bearer {s}", .{t});
        extra[extra_n] = .{ .name = "authorization", .value = auth };
        extra_n += 1;
    }

    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        var aw = std.Io.Writer.Allocating.init(gpa);
        // keep_alive = false: never pool the connection. A pooled keep-alive can be
        // closed by the server while we spend seconds unpacking the previous layer,
        // stranding the next request with error.HttpConnectionClosing. A fresh
        // connection per request costs one handshake — negligible against the blob.
        const res = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = extra[0..extra_n],
            .response_writer = &aw.writer,
            .keep_alive = false,
        }) catch |err| {
            aw.deinit();
            if (attempt < http_max_attempts) {
                std.debug.print("[oci] GET {s} failed ({s}); retry {d}/{d}\n", .{ url, @errorName(err), attempt, http_max_attempts });
                continue;
            }
            return err;
        };
        if (res.status == .ok) return aw.toOwnedSlice();
        aw.deinit();
        // 429 (rate-limited) and 5xx are transient; other statuses are terminal.
        const code = @intFromEnum(res.status);
        if (attempt < http_max_attempts and (code == 429 or code >= 500)) {
            std.debug.print("[oci] GET {s} -> HTTP {d}; retry {d}/{d}\n", .{ url, code, attempt, http_max_attempts });
            continue;
        }
        std.debug.print("[oci] GET {s} -> HTTP {d}\n", .{ url, code });
        return error.HttpStatus;
    }
}

fn jsonStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Pull `image_ref` from Docker Hub for `arch`, unpack its rootfs into
/// `dest_dir` (created if absent), and return the image config (arena-owned).
pub const PullOptions = struct {
    /// Directory for the content-addressed blob cache (layer + config blobs keyed
    /// by their sha256 digest). null disables blob caching (every blob re-downloaded).
    cache_dir: ?[]const u8 = null,
    /// When set, the raw image config JSON is written here so a later cached-rootfs
    /// run can rebuild the guest /init fully offline (no network round-trip).
    config_out: ?[]const u8 = null,
};

pub fn pull(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, image_ref: []const u8, dest_dir: []const u8, arch: Arch, opts: PullOptions) !ImageConfig {
    const ref = try parseRef(gpa, image_ref);
    defer {
        gpa.free(ref.repo);
        gpa.free(ref.tag);
    }
    std.debug.print("[oci] pulling {s}:{s} ({s}) from Docker Hub\n", .{ ref.repo, ref.tag, arch.str() });

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // 1. Anonymous bearer token.
    const auth_url = try std.fmt.allocPrint(gpa, auth_url_fmt, .{ref.repo});
    defer gpa.free(auth_url);
    const tok_body = try httpGet(&client, gpa, auth_url, null, null);
    defer gpa.free(tok_body);
    const tok_parsed = try std.json.parseFromSlice(std.json.Value, gpa, tok_body, .{});
    defer tok_parsed.deinit();
    const token = try gpa.dupe(u8, jsonStr(tok_parsed.value.object.get("token") orelse return error.NoToken));
    defer gpa.free(token);

    // 2. Manifest (resolve an index/list to the arch-specific image manifest).
    const man_url = try std.fmt.allocPrint(gpa, "https://{s}/v2/{s}/manifests/{s}", .{ registry_host, ref.repo, ref.tag });
    defer gpa.free(man_url);
    var man_body = try httpGet(&client, gpa, man_url, accept_manifests, token);

    var man_parsed = try std.json.parseFromSlice(std.json.Value, gpa, man_body, .{});
    if (man_parsed.value.object.get("manifests")) |list| {
        // It's an index: find the linux/<arch> entry and re-fetch by digest.
        var digest: ?[]const u8 = null;
        for (list.array.items) |entry| {
            const plat = entry.object.get("platform") orelse continue;
            const a = jsonStr(plat.object.get("architecture") orelse continue);
            const o = jsonStr(plat.object.get("os") orelse continue);
            if (std.mem.eql(u8, a, arch.str()) and std.mem.eql(u8, o, "linux")) {
                digest = jsonStr(entry.object.get("digest") orelse continue);
                break;
            }
        }
        const d = digest orelse return error.ArchNotFound;
        const by_digest = try std.fmt.allocPrint(gpa, "https://{s}/v2/{s}/manifests/{s}", .{ registry_host, ref.repo, d });
        defer gpa.free(by_digest);
        const img_body = try httpGet(&client, gpa, by_digest, accept_manifests, token);
        man_parsed.deinit();
        gpa.free(man_body);
        man_body = img_body;
        man_parsed = try std.json.parseFromSlice(std.json.Value, gpa, man_body, .{});
    }
    defer {
        man_parsed.deinit();
        gpa.free(man_body);
    }

    // 3. Config blob -> entrypoint/env/cmd/cwd/user.
    const config_digest = jsonStr((man_parsed.value.object.get("config") orelse return error.NoConfig).object.get("digest") orelse return error.NoConfig);
    const cfg_url = try std.fmt.allocPrint(gpa, "https://{s}/v2/{s}/blobs/{s}", .{ registry_host, ref.repo, config_digest });
    defer gpa.free(cfg_url);
    const cfg_body = try getBlob(&client, gpa, io, cfg_url, token, opts.cache_dir, config_digest);
    defer gpa.free(cfg_body);
    const config = try parseConfig(arena, gpa, cfg_body);

    // Persist the raw config so a later cached-rootfs run rebuilds /init offline
    // AND so contain_start can apply the image's ENV/WORKDIR. `config_out` may
    // live inside dest_dir, so ensure the dir exists first (idempotent).
    if (opts.config_out) |co| {
        std.Io.Dir.cwd().createDirPath(io, dest_dir) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = co, .data = cfg_body }) catch |err|
            std.debug.print("[oci] warn: could not cache image config: {s}\n", .{@errorName(err)});
    }

    // 3b. Fail fast if the resolved image isn't the requested architecture. The
    // index step above filters a multi-arch manifest LIST, but a tag can point
    // directly at a single-arch manifest (no list to filter) — Docker Hub then
    // serves e.g. the amd64 image for an amd64-only repo regardless of `arch`.
    // Without this check that wrong-arch rootfs is unpacked and later panics the
    // guest with a cryptic ENOEXEC ("/bin/sh exists but couldn't execute it
    // (error -8)" / "No working init found"). Checking here also avoids
    // downloading the (large) layers for an image we can't run.
    if (imageArchFromConfig(gpa, cfg_body)) |img_arch| {
        defer gpa.free(img_arch);
        if (!std.mem.eql(u8, img_arch, arch.str())) {
            std.debug.print("[oci] {s}:{s} is {s}, not the requested {s} — this image/tag has no {s} build\n", .{ ref.repo, ref.tag, img_arch, arch.str(), arch.str() });
            return error.ArchMismatch;
        }
    }

    // 4. Unpack each layer (gzip'd tar) into dest_dir, in order.
    try std.Io.Dir.cwd().createDirPath(io, dest_dir);
    var root = try std.Io.Dir.cwd().openDir(io, dest_dir, .{ .iterate = true });
    defer root.close(io);

    const layers = (man_parsed.value.object.get("layers") orelse return error.NoLayers).array.items;
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    for (layers, 0..) |layer, i| {
        const ldigest = jsonStr(layer.object.get("digest") orelse return error.BadLayer);
        const lurl = try std.fmt.allocPrint(gpa, "https://{s}/v2/{s}/blobs/{s}", .{ registry_host, ref.repo, ldigest });
        defer gpa.free(lurl);
        const gz = try getBlob(&client, gpa, io, lurl, token, opts.cache_dir, ldigest);
        defer gpa.free(gz);
        std.debug.print("[oci] layer {d}/{d} {s} ({d} bytes gz)\n", .{ i + 1, layers.len, ldigest[0..@min(19, ldigest.len)], gz.len });
        try extractLayer(io, root, gpa, gz, window);
    }
    std.debug.print("[oci] unpacked {d} layer(s) into {s}\n", .{ layers.len, dest_dir });
    return config;
}

// Per-blob read cap for the cache (the largest single layer we expect to reuse).
const max_blob_bytes: usize = 4 * 1024 * 1024 * 1024;

/// Fetch a content-addressed blob, using `cache_dir` as a read-through / write-back
/// cache when set. Blobs are immutable (keyed by their sha256 digest), so a cache
/// hit is always valid. The write goes via a ".part" temp + rename so a killed run
/// never leaves a truncated blob to be served later.
fn getBlob(client: *http.Client, gpa: std.mem.Allocator, io: std.Io, url: []const u8, token: ?[]const u8, cache_dir: ?[]const u8, digest: []const u8) ![]u8 {
    const cd = cache_dir orelse return httpGet(client, gpa, url, null, token);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, cd) catch {};
    const path = try blobPath(gpa, cd, digest);
    defer gpa.free(path);
    if (cwd.readFileAlloc(io, path, gpa, .limited(max_blob_bytes))) |data| {
        std.debug.print("[oci] cache hit {s}\n", .{digest[0..@min(19, digest.len)]});
        return data;
    } else |_| {}
    const data = try httpGet(client, gpa, url, null, token);
    errdefer gpa.free(data);
    const part = try std.fmt.allocPrint(gpa, "{s}.part", .{path});
    defer gpa.free(part);
    if (cwd.writeFile(io, .{ .sub_path = part, .data = data })) |_| {
        cwd.rename(part, cwd, path, io) catch cwd.deleteFile(io, part) catch {};
    } else |_| {}
    return data;
}

/// A blob's on-disk cache path: `<cache_dir>/<digest with ':' and '/' -> '-'>`.
fn blobPath(gpa: std.mem.Allocator, cache_dir: []const u8, digest: []const u8) ![]u8 {
    const safe = try gpa.dupe(u8, digest);
    defer gpa.free(safe);
    for (safe) |*c| {
        if (c.* == ':' or c.* == '/') c.* = '-';
    }
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ cache_dir, safe });
}

/// Read + parse a persisted image config JSON (written by pull's `config_out`),
/// so a cached-rootfs run can rebuild /init without hitting the network.
pub fn parseConfigFile(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ImageConfig {
    const body = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024));
    defer gpa.free(body);
    return parseConfig(arena, gpa, body);
}

/// The cache entry directory for an image ref + arch:
/// `<base>/images/<repo>/<tag>@<arch>` (repo may itself contain '/'). Caller owns.
pub fn cacheEntryPath(gpa: std.mem.Allocator, base: []const u8, image_ref: []const u8, arch: Arch) ![]u8 {
    const ref = try parseRef(gpa, image_ref);
    defer {
        gpa.free(ref.repo);
        gpa.free(ref.tag);
    }
    return std.fmt.allocPrint(gpa, "{s}/images/{s}/{s}@{s}", .{ base, ref.repo, ref.tag, arch.str() });
}

fn parseConfig(arena: std.mem.Allocator, gpa: std.mem.Allocator, body: []const u8) !ImageConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    var cfg = ImageConfig{};
    const c = parsed.value.object.get("config") orelse return cfg;
    if (c.object.get("Entrypoint")) |v| cfg.entrypoint = try dupStrArray(arena, v);
    if (c.object.get("Cmd")) |v| cfg.cmd = try dupStrArray(arena, v);
    if (c.object.get("Env")) |v| cfg.env = try dupStrArray(arena, v);
    if (c.object.get("WorkingDir")) |v| cfg.working_dir = try arena.dupe(u8, jsonStr(v));
    if (c.object.get("User")) |v| cfg.user = try arena.dupe(u8, jsonStr(v));
    return cfg;
}

/// Filename `contain_pull_image` writes the raw image config to, INSIDE the
/// unpacked rootfs dir, so `session.start` can apply the image's ENV/WORKDIR to
/// the guest (the library boot path has no other channel for image ENV — the
/// CLI passes it directly). It rides along into the initramfs harmlessly.
pub const embedded_config_name = ".contain-oci-config.json";

/// Read the image config `contain_pull_image` persisted inside `rootfs_dir`
/// (`embedded_config_name`), or null if it's absent/unreadable. Caller owns the
/// returned config's slices (allocated from `arena`).
pub fn readEmbeddedConfig(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, rootfs_dir: []const u8) ?ImageConfig {
    const path = std.fs.path.join(gpa, &.{ rootfs_dir, embedded_config_name }) catch return null;
    defer gpa.free(path);
    return parseConfigFile(arena, gpa, io, path) catch return null;
}

/// The top-level `architecture` field of an OCI image config blob (e.g.
/// "amd64", "arm64"), owned by `gpa`, or null if absent/unparseable. Used to
/// verify a pulled image actually matches the requested arch: a tag can point
/// straight at a single (non-index) manifest, which the index arch-selection in
/// `pull` can't filter — so an amd64-only image requested as arm64 would
/// otherwise be pulled and then panic the guest with ENOEXEC ("No working init").
pub fn imageArchFromConfig(gpa: std.mem.Allocator, cfg_body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, cfg_body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const a = parsed.value.object.get("architecture") orelse return null;
    if (a != .string) return null;
    return gpa.dupe(u8, a.string) catch null;
}

fn dupStrArray(arena: std.mem.Allocator, v: std.json.Value) ![]const []const u8 {
    if (v != .array) return &.{};
    var out = try arena.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, i| out[i] = try arena.dupe(u8, jsonStr(item));
    return out;
}

/// Unpack one gzip'd-tar layer over `root`, applying `.wh.` whiteouts.
fn extractLayer(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, gz: []const u8, window: []u8) !void {
    var in = std.Io.Reader.fixed(gz);
    var dec = flate.Decompress.init(&in, .gzip, window);

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Passing diagnostics makes std.tar *skip* header types it can't represent
    // (hard links, device nodes, FIFOs, sparse files) instead of failing the whole
    // pull with error.TarUnsupportedHeader. Debian/Ubuntu-based images (node:*-slim,
    // python:*-slim, …) contain these; we summarize what was skipped below.
    var diag: tar.Diagnostics = .{ .allocator = gpa };
    defer diag.deinit();
    var iter = tar.Iterator.init(&dec.reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
        .diagnostics = &diag,
    });

    // Windows cannot create on-disk symlinks without privilege, so record them in a
    // sidecar (path\ttarget\n) that packRootfs replays into the cpio (which does
    // support symlinks). Linux creates real symlinks the rootfs walker handles.
    var win_links: std.ArrayListUnmanaged(u8) = .empty;
    defer win_links.deinit(gpa);

    var io_buf: [64 * 1024]u8 = undefined;
    while (try iter.next()) |entry| {
        const path = std.mem.trimStart(u8, entry.name, "./");
        if (path.len == 0) continue;
        const base = std.fs.path.basename(path);

        // Overlay whiteouts: ".wh.<name>" deletes <name>; ".wh..wh..opq" clears a dir.
        if (std.mem.startsWith(u8, base, ".wh.")) {
            if (!std.mem.eql(u8, base, ".wh..wh..opq")) {
                const parent = std.fs.path.dirname(path);
                const target = if (parent) |p|
                    try std.fmt.allocPrint(gpa, "{s}/{s}", .{ p, base[".wh.".len..] })
                else
                    try gpa.dupe(u8, base[".wh.".len..]);
                defer gpa.free(target);
                root.deleteTree(io, target) catch {};
            }
            continue;
        }

        switch (entry.kind) {
            .directory => root.createDirPath(io, path) catch {},
            .sym_link => {
                if (std.fs.path.dirname(path)) |d| root.createDirPath(io, d) catch {};
                root.deleteFile(io, path) catch {};
                root.symLink(io, entry.link_name, path, .{}) catch {};
                if (builtin.os.tag == .windows) {
                    try win_links.appendSlice(gpa, path);
                    try win_links.append(gpa, '\t');
                    try win_links.appendSlice(gpa, entry.link_name);
                    try win_links.append(gpa, '\n');
                }
            },
            .file => {
                if (std.fs.path.dirname(path)) |d| root.createDirPath(io, d) catch {};
                // A lower layer may have left a dir/symlink here; replace it on retry.
                var f = root.createFile(io, path, .{ .truncate = true }) catch retry: {
                    root.deleteTree(io, path) catch {};
                    break :retry root.createFile(io, path, .{ .truncate = true }) catch continue;
                };
                defer f.close(io);
                var fw = f.writer(io, &io_buf);
                try iter.streamRemaining(entry, &fw.interface); // resets unread_file_bytes
                try fw.end();
                if (builtin.os.tag != .windows) {
                    f.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(entry.mode & 0o7777))) catch {};
                }
            },
        }
    }

    // std.tar's Iterator can't represent every header type. Device/FIFO skips are
    // harmless (the guest's devtmpfs provides /dev). Hard links, though, mean a file
    // name didn't land — recover them below rather than silently dropping them.
    if (diag.errors.items.len != 0) {
        var hard: usize = 0;
        var special: usize = 0;
        for (diag.errors.items) |e| switch (e) {
            .unsupported_file_type => |u| switch (u.file_type) {
                .hard_link => hard += 1,
                else => special += 1,
            },
            else => {},
        };
        if (hard != 0) try recoverHardLinks(io, root, gpa, gz, window, hard);
        if (special != 0) std.debug.print("[oci] note: skipped {d} device/special file(s) (guest devtmpfs provides /dev)\n", .{special});
    }

    // Append this layer's symlinks to the sidecar (read-modify-write accumulates
    // across layers). Only on Windows, where real symlinks could not be created.
    if (builtin.os.tag == .windows and win_links.items.len != 0) {
        const prior = root.readFileAlloc(io, ".contain-symlinks", gpa, .limited(8 * 1024 * 1024)) catch &[_]u8{};
        defer if (prior.len != 0) gpa.free(prior);
        var all: std.ArrayListUnmanaged(u8) = .empty;
        defer all.deinit(gpa);
        try all.appendSlice(gpa, prior);
        try all.appendSlice(gpa, win_links.items);
        root.writeFile(io, .{ .sub_path = ".contain-symlinks", .data = all.items }) catch {};
    }
}

/// A hard-link tar entry: the link's path and the target it should share content
/// with. Both are raw archive names (the caller normalizes the leading "./").
pub const HardLink = struct { path: []u8, target: []u8 };

pub fn freeHardLinks(gpa: std.mem.Allocator, links: *std.ArrayListUnmanaged(HardLink)) void {
    for (links.items) |hl| {
        gpa.free(hl.path);
        gpa.free(hl.target);
    }
    links.deinit(gpa);
}

/// Re-scan a layer for the hard links std.tar dropped and materialize each one.
/// A tar hard-link entry references a regular file archived earlier in the same
/// layer, so the target already exists on disk from the main extraction pass —
/// we just copy its content (permissions and all) to the link path.
fn recoverHardLinks(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, gz: []const u8, window: []u8, expected: usize) !void {
    var in = std.Io.Reader.fixed(gz);
    var dec = flate.Decompress.init(&in, .gzip, window);
    var links = collectHardLinks(gpa, &dec.reader) catch |err| {
        std.debug.print("[oci] warn: hard-link recovery failed ({s}); {d} file(s) may be missing\n", .{ @errorName(err), expected });
        return;
    };
    defer freeHardLinks(gpa, &links);

    var linked: usize = 0;
    for (links.items) |hl| {
        const p = std.mem.trimStart(u8, hl.path, "./");
        const t = std.mem.trimStart(u8, hl.target, "./");
        if (p.len == 0 or t.len == 0) continue;
        root.copyFile(t, root, p, io, .{ .make_path = true, .replace = true }) catch |err| {
            std.debug.print("[oci] warn: hard link {s} -> {s}: {s}\n", .{ p, t, @errorName(err) });
            continue;
        };
        linked += 1;
    }
    if (linked != 0) std.debug.print("[oci] linked {d} hard link(s)\n", .{linked});
}

/// Scan a decompressed tar stream and collect every hard-link entry's (path,
/// target) — the fields std.tar's Iterator drops (it records only the path in
/// diagnostics, never the target). Handles the ustar name+prefix split, GNU
/// 'L'/'K' long-name/-link prefix entries, and pax 'x' path=/linkpath= overrides.
/// Names are returned verbatim; the caller normalizes them to match the main pass.
pub fn collectHardLinks(gpa: std.mem.Allocator, reader: *std.Io.Reader) !std.ArrayListUnmanaged(HardLink) {
    var out: std.ArrayListUnmanaged(HardLink) = .empty;
    errdefer freeHardLinks(gpa, &out);

    // Overrides carried from a preceding meta header ('L'/'K'/'x'); each applies to
    // the next real entry, then is cleared.
    var ov_name: ?[]u8 = null;
    var ov_link: ?[]u8 = null;
    defer {
        if (ov_name) |b| gpa.free(b);
        if (ov_link) |b| gpa.free(b);
    }

    const max_meta: u64 = 1 << 20; // 1 MB cap on a long-name / pax data block
    var hdr: [512]u8 = undefined;
    var name_buf: [512]u8 = undefined;
    while (true) {
        reader.readSliceAll(&hdr) catch |err| switch (err) {
            error.EndOfStream => break, // clean end (also covers trailing zero blocks)
            else => return err,
        };
        if (tarIsZeroBlock(&hdr)) break; // end-of-archive marker

        const typeflag = hdr[156];
        const size = tarNumeric(hdr[124..136]);
        const pad = std.mem.alignForward(u64, size, 512) - size;

        switch (typeflag) {
            'L' => { // GNU long name for the next entry
                const raw = try tarReadMeta(gpa, reader, size, max_meta);
                defer gpa.free(raw);
                try reader.discardAll64(pad);
                if (ov_name) |b| gpa.free(b);
                ov_name = try gpa.dupe(u8, tarNullStr(raw));
            },
            'K' => { // GNU long link target for the next entry
                const raw = try tarReadMeta(gpa, reader, size, max_meta);
                defer gpa.free(raw);
                try reader.discardAll64(pad);
                if (ov_link) |b| gpa.free(b);
                ov_link = try gpa.dupe(u8, tarNullStr(raw));
            },
            'x', 'X' => { // pax extended header: path=/linkpath= for the next entry
                const raw = try tarReadMeta(gpa, reader, size, max_meta);
                defer gpa.free(raw);
                try reader.discardAll64(pad);
                if (tarPaxValue(raw, "path")) |v| {
                    if (ov_name) |b| gpa.free(b);
                    ov_name = try gpa.dupe(u8, v);
                }
                if (tarPaxValue(raw, "linkpath")) |v| {
                    if (ov_link) |b| gpa.free(b);
                    ov_link = try gpa.dupe(u8, v);
                }
            },
            'g' => try reader.discardAll64(size + pad), // pax global header: not name-related
            '1' => { // hard link
                const path = if (ov_name) |b| b else tarUstarName(&hdr, &name_buf);
                const target = if (ov_link) |b| b else tarNullStr(hdr[157..257]);
                if (path.len != 0 and target.len != 0) {
                    try out.append(gpa, .{ .path = try gpa.dupe(u8, path), .target = try gpa.dupe(u8, target) });
                }
                if (ov_name) |b| gpa.free(b);
                ov_name = null;
                if (ov_link) |b| gpa.free(b);
                ov_link = null;
                try reader.discardAll64(size + pad); // hard links carry no data, but be safe
            },
            else => { // file / dir / symlink / device / sparse: skip data, drop overrides
                if (ov_name) |b| gpa.free(b);
                ov_name = null;
                if (ov_link) |b| gpa.free(b);
                ov_link = null;
                try reader.discardAll64(size + pad);
            },
        }
    }
    return out;
}

fn tarIsZeroBlock(b: *const [512]u8) bool {
    for (b) |x| if (x != 0) return false;
    return true;
}

/// Break a fixed tar field on its first NUL.
fn tarNullStr(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

/// Parse a tar numeric field: octal ASCII, or GNU base-256 when the leading byte
/// has its high bit set. Mirrors std.tar's size handling.
fn tarNumeric(raw: []const u8) u64 {
    if (raw.len == 0) return 0;
    if (raw[0] & 0x80 != 0) {
        var v: u64 = 0;
        for (raw, 0..) |b, i| v = (v << 8) | @as(u64, if (i == 0) b & 0x7f else b);
        return v;
    }
    const t = std.mem.trimEnd(u8, std.mem.trimStart(u8, raw, "0 "), " \x00");
    if (t.len == 0) return 0;
    return std.fmt.parseInt(u64, t, 8) catch 0;
}

/// The ustar name for a header: name(0,100), prefixed by prefix(345,155) joined
/// with '/' when the POSIX ustar magic is present and the prefix is set.
fn tarUstarName(hdr: *const [512]u8, out: *[512]u8) []const u8 {
    const name = tarNullStr(hdr[0..100]);
    const magic = hdr[257..263];
    const is_ustar = std.mem.eql(u8, magic[0..5], "ustar") and (magic[5] == 0 or magic[5] == ' ');
    const prefix = if (is_ustar) tarNullStr(hdr[345..500]) else "";
    if (prefix.len == 0) {
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = '/';
    @memcpy(out[prefix.len + 1 ..][0..name.len], name);
    return out[0 .. prefix.len + 1 + name.len];
}

/// Read a meta header's `size`-byte data block (GNU long name / pax records).
fn tarReadMeta(gpa: std.mem.Allocator, reader: *std.Io.Reader, size: u64, max: u64) ![]u8 {
    if (size == 0) return gpa.alloc(u8, 0);
    if (size > max) return error.TarMetaTooBig;
    const buf = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(buf);
    try reader.readSliceAll(buf);
    return buf;
}

/// Look up a pax record value by key. Records are `"<len> <key>=<value>\n"`,
/// where <len> counts the whole record (length digits, space, key, value, LF).
fn tarPaxValue(data: []const u8, key: []const u8) ?[]const u8 {
    var rest = data;
    while (rest.len != 0) {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse break;
        const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch break;
        if (len <= sp or len > rest.len) break;
        const kv = rest[sp + 1 .. len]; // "key=value\n"
        rest = rest[len..];
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) return std.mem.trimEnd(u8, kv[eq + 1 ..], "\n");
    }
    return null;
}

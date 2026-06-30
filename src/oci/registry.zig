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
fn httpGet(client: *http.Client, gpa: std.mem.Allocator, url: []const u8, accept: ?[]const u8, token: ?[]const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();

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

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = extra[0..extra_n],
        .response_writer = &aw.writer,
    });
    if (res.status != .ok) {
        std.debug.print("[oci] GET {s} -> HTTP {d}\n", .{ url, @intFromEnum(res.status) });
        return error.HttpStatus;
    }
    return aw.toOwnedSlice();
}

fn jsonStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Pull `image_ref` from Docker Hub for `arch`, unpack its rootfs into
/// `dest_dir` (created if absent), and return the image config (arena-owned).
pub fn pull(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, image_ref: []const u8, dest_dir: []const u8, arch: Arch) !ImageConfig {
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
    const cfg_body = try httpGet(&client, gpa, cfg_url, null, token);
    defer gpa.free(cfg_body);
    const config = try parseConfig(arena, gpa, cfg_body);

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
        const gz = try httpGet(&client, gpa, lurl, null, token);
        defer gpa.free(gz);
        std.debug.print("[oci] layer {d}/{d} {s} ({d} bytes gz)\n", .{ i + 1, layers.len, ldigest[0..@min(19, ldigest.len)], gz.len });
        try extractLayer(io, root, gpa, gz, window);
    }
    std.debug.print("[oci] unpacked {d} layer(s) into {s}\n", .{ layers.len, dest_dir });
    return config;
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
    var iter = tar.Iterator.init(&dec.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });

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

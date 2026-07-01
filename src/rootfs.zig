//! Rootfs -> initramfs packing, shared by the CLI (`contain run`) and the library
//! (`src/session.zig`). The OCI unpack writes an image's rootfs to a host
//! directory; this packs that tree (plus a generated `/init`) into a newc cpio the
//! guest boots as its initramfs root. The library packs **in memory** (no temp
//! `.cpio` on disk) so a sandboxed embedder touches as few files as possible.

const std = @import("std");
const builtin = @import("builtin");
const cpio = @import("cpio.zig");

/// Power off the guest from PID 1, robustly across images. Debian/Ubuntu *-slim
/// images ship no `poweroff`/`halt`/`reboot` binary, so fall back to SysRq 'o'
/// (contain's kernel enables CONFIG_MAGIC_SYSRQ; /proc/sys/kernel/sysrq defaults
/// to 1). Any of these routes to PSCI SYSTEM_OFF -> a clean host-side exit. If
/// none work, PID 1 simply exits and panic=-1 turns that into a clean exit too.
pub const poweroff_seq =
    \\sync
    \\poweroff -f 2>/dev/null
    \\halt -f 2>/dev/null
    \\reboot -f 2>/dev/null
    \\echo o > /proc/sysrq-trigger 2>/dev/null
    \\
;

/// Options for the persistent agentic-shell init (`buildShellInit`).
pub const ShellInitOpts = struct {
    /// If set, mount the host 9p share at this guest path (e.g. "/workspace").
    share_guest_path: ?[]const u8 = null,
    /// Extra "KEY=VALUE" environment entries exported before the shell starts.
    env: []const []const u8 = &.{},
    /// Working directory the shell starts in (best-effort `cd`).
    workdir: ?[]const u8 = null,
};

/// Build the `/init` for a long-lived sandbox session: mount the kernel
/// filesystems, bring up NAT networking, optionally mount the host share, apply
/// env + workdir, then exec a shell on the console that **stays alive**. Unlike
/// the CLI's one-shot OCI init (run-command-then-poweroff), this is the model an
/// AI harness drives over the raw console: write commands in, read output back,
/// and power off via `contain_stop`. If the shell itself exits, the guest powers
/// off. Both `ip`(iproute2) and `ifconfig`(busybox) forms are tried so the script
/// works across arbitrary image rootfses.
pub fn buildShellInit(arena: std.mem.Allocator, opts: ShellInitOpts) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.writeAll(
        \\#!/bin/sh
        \\export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=linux
        \\mkdir -p /proc /sys /dev 2>/dev/null
        \\mount -t proc proc /proc 2>/dev/null
        \\mount -t sysfs sysfs /sys 2>/dev/null
        \\mount -t devtmpfs devtmpfs /dev 2>/dev/null
        \\ip addr add 127.0.0.1/8 dev lo 2>/dev/null; ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null
        \\ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
        \\ip link set eth0 up 2>/dev/null
        \\ip route add default via 10.0.2.2 2>/dev/null || route add default gw 10.0.2.2 2>/dev/null
        \\echo "nameserver 10.0.2.3" > /etc/resolv.conf 2>/dev/null
        \\
    );
    if (opts.share_guest_path) |gp|
        try w.print("mkdir -p {s} 2>/dev/null\nmount -t virtiofs host {s} 2>/dev/null || mount -t 9p -o trans=virtio,version=9p2000.L host {s} 2>/dev/null\n", .{ gp, gp, gp });
    for (opts.env) |e| try w.print("export \"{s}\"\n", .{e});
    if (opts.workdir) |d| try w.print("cd {s} 2>/dev/null\n", .{d});
    // setsid -c gives the shell the console as its controlling terminal (job
    // control). When it exits, power off so the run loop returns.
    //
    // We deliberately run /bin/sh (dash), NOT interactive bash. A host driver
    // feeding commands over the console + matching an exit-code sentinel needs a
    // clean, predictable byte stream, and interactive bash fights that on two
    // fronts: (1) readline emits terminal-control escapes (bracketed-paste
    // \e[?2004h, cursor moves \e[C) that corrupt the sentinel — fixable with
    // --noediting; but (2) bash's job control juggles the terminal foreground
    // process group and, over the console, stops reading input after the first
    // command (SIGTTIN) — commands 2..N are never received. dash has neither
    // line editor nor job control, so it Just Works. A command that genuinely
    // needs bash can invoke `bash -c '…'` explicitly.
    try w.writeAll("setsid -c /bin/sh\n");
    try w.writeAll(poweroff_seq);
    return aw.written();
}

/// Pack `rootfs_dir` (plus the supplied `/init`) into a newc cpio entirely in
/// memory and return owned bytes (caller frees). No temporary file is written.
pub fn buildInitramfs(gpa: std.mem.Allocator, io: std.Io, rootfs_dir: []const u8, init_script: []const u8) ![]u8 {
    var cw = cpio.Writer.init(gpa);
    defer cw.deinit();
    var root = try std.Io.Dir.cwd().openDir(io, rootfs_dir, .{ .iterate = true });
    defer root.close(io);
    try packDir(io, &cw, gpa, root);
    try cw.addFile("init", cpio.MODE_FILE, init_script);
    try cw.finish();
    return gpa.dupe(u8, cw.bytes());
}

/// Recursively pack a host directory tree into the cpio (rootfs -> initramfs).
/// Modes are set executable for all files (over-permissive but functional);
/// symlinks and the directory layout are preserved. Device nodes are skipped
/// (devtmpfs provides /dev).
pub fn packDir(io: std.Io, cw: *cpio.Writer, gpa: std.mem.Allocator, root: std.Io.Dir) !void {
    // Windows can't create on-disk symlinks, so the OCI unpack recorded them in a
    // `.contain-symlinks` sidecar (path\ttarget) and left an empty placeholder file
    // at each path. Load it so we can (a) skip those placeholders during the walk
    // and (b) emit real symlinks into the cpio (which supports them).
    var links: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer links.deinit(gpa);
    const sidecar: []const u8 = if (builtin.os.tag == .windows)
        (root.readFileAlloc(io, ".contain-symlinks", gpa, .limited(8 * 1024 * 1024)) catch &[_]u8{})
    else
        &[_]u8{};
    defer if (sidecar.len != 0) gpa.free(sidecar);
    {
        var it = std.mem.tokenizeScalar(u8, sidecar, '\n');
        while (it.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            try links.put(gpa, line[0..tab], line[tab + 1 ..]);
        }
    }

    var walker = try root.walk(gpa);
    defer walker.deinit();
    var lbuf: [4096]u8 = undefined;
    var pbuf: [4096]u8 = undefined;
    while (try walker.next(io)) |entry| {
        // Normalize to forward slashes (the cpio + guest use '/'); the Windows
        // walker yields backslash paths.
        const p = normPath(&pbuf, entry.path);
        if (std.mem.eql(u8, p, ".contain-symlinks")) continue;
        if (links.contains(p)) continue; // a symlink placeholder, emitted below
        switch (entry.kind) {
            .directory => cw.addDir(p) catch {},
            .sym_link => {
                const n = root.readLink(io, entry.path, &lbuf) catch continue;
                cw.addSymlink(p, lbuf[0..n]) catch {};
            },
            .file => {
                const data = root.readFileAlloc(io, entry.path, gpa, .limited(512 * 1024 * 1024)) catch continue;
                defer gpa.free(data);
                cw.addFile(p, cpio.MODE_FILE, data) catch {};
            },
            else => {}, // device/fifo/socket: skipped
        }
    }

    var lit = links.iterator();
    while (lit.next()) |e| cw.addSymlink(e.key_ptr.*, e.value_ptr.*) catch {};
}

/// Copy `path` into `buf` with backslashes turned into forward slashes.
fn normPath(buf: []u8, path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const n = @min(buf.len, path.len);
    for (path[0..n], 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    return buf[0..n];
}

//! C ABI for embedding `contain` as a library (e.g. in a sandboxed Swift app
//! running an AI coding agent). A thin translation layer over `src/session.zig`:
//! it converts C strings/structs to Zig and never throws across the boundary —
//! errors become a null handle or a negative status. See `include/contain.h`.
//!
//! Lifecycle: contain_start -> {contain_write / contain_is_finished}* ->
//! contain_stop -> contain_free. The two fetch helpers (kernel + image) take an
//! explicit destination path so a sandboxed embedder controls where bytes land.

const std = @import("std");
const session = @import("session.zig");
const kernel_fetch = @import("kernel_fetch.zig");
const registry = @import("oci/registry.zig");
const console = @import("console.zig");

// Connection/socket teardown at the boundary is normal; don't dump stack traces.
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

// One process-wide thread-safe allocator: the guest's NAT reader threads, the
// run thread and the caller's thread all allocate, so it must be MT-safe.
const gpa = std.heap.smp_allocator;

/// Mirrors `contain_config` in include/contain.h — field order MUST match.
const CConfig = extern struct {
    kernel_path: ?[*:0]const u8,
    rootfs_dir: ?[*:0]const u8,
    initramfs_path: ?[*:0]const u8,
    disk_path: ?[*:0]const u8,
    share_path: ?[*:0]const u8,
    share_guest_path: ?[*:0]const u8,
    ports: ?[*:0]const u8,
    env: ?[*:null]const ?[*:0]const u8, // NULL-terminated array of "KEY=VALUE"
    workdir: ?[*:0]const u8,
    ram_bytes: u64,
    accel: ?[*:0]const u8,
    out_fn: ?*const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void,
    out_ctx: ?*anyopaque,
    exit_fn: ?*const fn (ctx: ?*anyopaque, code: c_int) callconv(.c) void,
    exit_ctx: ?*anyopaque,
};

fn optStr(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |s| std.mem.span(s) else null;
}

fn sessionFrom(vm: ?*anyopaque) ?*session.Session {
    return @ptrCast(@alignCast(vm orelse return null));
}

/// Boot a guest. Returns an opaque handle (contain_vm*) or null on failure.
export fn contain_start(cfg_ptr: ?*const CConfig) ?*anyopaque {
    const cfg = cfg_ptr orelse return null;
    const kpath = optStr(cfg.kernel_path) orelse return null; // kernel is required

    // The env array is consumed synchronously inside start() (baked into the init
    // script), so this temporary list only needs to outlive the start() call.
    var env_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer env_list.deinit(gpa);
    if (cfg.env) |arr| {
        var i: usize = 0;
        while (arr[i]) |s| : (i += 1) env_list.append(gpa, std.mem.span(s)) catch return null;
    }

    const scfg = session.Config{
        .kernel_path = kpath,
        .rootfs_dir = optStr(cfg.rootfs_dir),
        .initramfs_path = optStr(cfg.initramfs_path),
        .disk_path = optStr(cfg.disk_path),
        .share_path = optStr(cfg.share_path),
        .share_guest_path = optStr(cfg.share_guest_path) orelse "/workspace",
        .ports = optStr(cfg.ports),
        .env = env_list.items,
        .workdir = optStr(cfg.workdir),
        .ram_bytes = cfg.ram_bytes,
        .accel_override = optStr(cfg.accel),
        .out = .{ .ctx = cfg.out_ctx, .write_fn = cfg.out_fn },
        .exit_ctx = cfg.exit_ctx,
        .exit_fn = cfg.exit_fn,
    };

    const s = session.Session.start(gpa, scfg) catch return null;
    return @ptrCast(s);
}

/// Feed bytes to the guest console (host->guest), as if typed at the terminal.
export fn contain_write(vm: ?*anyopaque, data: ?[*]const u8, len: usize) void {
    const s = sessionFrom(vm) orelse return;
    const d = data orelse return;
    s.writeInput(d[0..len]);
}

/// Non-zero once the guest has powered off (or been stopped) on its own.
export fn contain_is_finished(vm: ?*anyopaque) c_int {
    const s = sessionFrom(vm) orelse return 1;
    return @intFromBool(s.isFinished());
}

/// Stop a running guest and join its run thread (idempotent). The handle is still
/// valid afterwards; call contain_free to release it.
export fn contain_stop(vm: ?*anyopaque) void {
    const s = sessionFrom(vm) orelse return;
    s.stop();
}

/// Stop (if needed), tear down, and free the handle. Do not use it afterwards.
export fn contain_free(vm: ?*anyopaque) void {
    const s = sessionFrom(vm) orelse return;
    s.deinit();
}

/// Download the host-arch guest kernel to `dest_path` (a sandbox-writable path) if
/// it is not already there. Returns 0 on success (present or fetched), -1 on error.
export fn contain_fetch_kernel(dest_path: ?[*:0]const u8) c_int {
    const path = optStr(dest_path) orelse return -1;
    var tio = std.Io.Threaded.init(gpa, .{});
    defer tio.deinit();
    _ = kernel_fetch.ensureKernel(gpa, tio.io(), path) catch return -1;
    return 0;
}

/// Pull a public OCI/Docker image and unpack its rootfs into `dest_dir` (a
/// sandbox-writable directory). `arch` is "amd64"/"arm64" or null for the host.
/// Returns 0 on success, -1 on error.
export fn contain_pull_image(image_ref: ?[*:0]const u8, dest_dir: ?[*:0]const u8, arch: ?[*:0]const u8) c_int {
    const ref = optStr(image_ref) orelse return -1;
    const dest = optStr(dest_dir) orelse return -1;
    const a: registry.Arch = blk: {
        const s = optStr(arch) orelse break :blk registry.Arch.hostDefault();
        if (std.mem.eql(u8, s, "amd64")) break :blk .amd64;
        if (std.mem.eql(u8, s, "arm64")) break :blk .arm64;
        break :blk registry.Arch.hostDefault();
    };
    var tio = std.Io.Threaded.init(gpa, .{});
    defer tio.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Persist the image config INSIDE the rootfs so contain_start can apply the
    // image's ENV/WORKDIR to the guest (images behave as authored). Best-effort:
    // a null path just skips it (env falls back to caller-provided only).
    const cfg_out = std.fs.path.join(gpa, &.{ dest, registry.embedded_config_name }) catch null;
    defer if (cfg_out) |c| gpa.free(c);
    _ = registry.pull(gpa, arena.allocator(), tio.io(), ref, dest, a, .{ .config_out = cfg_out }) catch return -1;
    return 0;
}

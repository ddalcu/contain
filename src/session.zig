//! Library boot orchestration — the non-CLI counterpart of `main.zig`'s
//! `cmdBoot`/`bootX86`. A `Session` boots a guest on a background thread and
//! exposes a small lifecycle (`start` / `writeInput` / `stop` / `deinit`) plus a
//! console output callback, so `contain` can be embedded (e.g. a sandboxed Swift
//! app driving an AI coding agent) instead of only run as a CLI.
//!
//! Crucially it does NOT touch the host terminal and does NOT call
//! `std.process.exit` — it tears down cleanly (disk writeback + NAT join +
//! Machine.deinit) so the host process keeps running and can start more VMs. The
//! C ABI in `src/capi.zig` is a thin translation layer over this type.

const std = @import("std");
const builtin = @import("builtin");
const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const accel = @import("accel/accel.zig");
const fdt = @import("fdt.zig");
const rootfs = @import("rootfs.zig");
const registry = @import("oci/registry.zig");
const console = @import("console.zig");

/// 2 GB default. Guest RAM is demand-zeroed, so host RSS still tracks only the
/// pages the guest touches — this is just the ceiling.
pub const default_ram: usize = 2 * 1024 * 1024 * 1024;

pub const Error = error{ AccelUnsupported, NoRootfs };

/// How to boot and where guest I/O goes. Paths are borrowed for the duration of
/// `start` (read into guest RAM there); the ones needed later — disk and share —
/// are duped and owned by the Session.
pub const Config = struct {
    /// Guest kernel image (arm64 `Image` or x86 `vmlinux` ELF). Required.
    kernel_path: []const u8,
    /// Pack this host directory (an unpacked OCI rootfs) into an in-memory
    /// initramfs and boot it. Mutually preferred over `initramfs_path`.
    rootfs_dir: ?[]const u8 = null,
    /// OR boot a prebuilt cpio initramfs from this path.
    initramfs_path: ?[]const u8 = null,
    /// virtio-blk backing file: loaded at boot, written back on stop.
    disk_path: ?[]const u8 = null,
    /// Host directory shared into the guest over virtio-9p.
    share_path: ?[]const u8 = null,
    /// Where the share is mounted in the guest (when `rootfs_dir` builds the init).
    share_guest_path: []const u8 = "/workspace",
    /// host->guest TCP forwards, e.g. "8080" or "8080:3000" or "8080,5173:5173".
    ports: ?[]const u8 = null,
    /// Extra "KEY=VALUE" env exported in the guest (rootfs_dir init only).
    env: []const []const u8 = &.{},
    /// Guest working directory (rootfs_dir init only).
    workdir: ?[]const u8 = null,
    /// Guest RAM in bytes; 0 selects the default. Rounded up to the HVF granule.
    ram_bytes: usize = 0,
    /// "hvf"|"kvm"|"whp" to override the host-default backend; null = auto.
    accel_override: ?[]const u8 = null,
    /// Guest console output sink (bytes -> embedder). Null fn => host stdout.
    out: console.OutSink = .{},
    /// Optional one-shot notification that the guest run loop returned (powered
    /// off or stopped). Called on the run thread; must not call back into stop/free.
    exit_ctx: ?*anyopaque = null,
    exit_fn: ?*const fn (ctx: ?*anyopaque, code: c_int) callconv(.c) void = null,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    tio: std.Io.Threaded,
    m: *Machine,
    kind: accel.Kind,
    run_thread: ?std.Thread = null,
    finished: std.atomic.Value(bool),
    exit_ctx: ?*anyopaque,
    exit_fn: ?*const fn (ctx: ?*anyopaque, code: c_int) callconv(.c) void,
    // Owned copies kept alive for the Machine's lifetime / for writeback.
    disk_path: ?[]u8,
    share_path: ?[]u8,

    /// Boot the guest and return a running Session. The guest executes on a
    /// background thread; this returns as soon as it is launched.
    pub fn start(gpa: std.mem.Allocator, cfg: Config) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.tio = std.Io.Threaded.init(gpa, .{});
        errdefer self.tio.deinit();
        self.run_thread = null;
        self.finished = .init(false);
        self.exit_ctx = cfg.exit_ctx;
        self.exit_fn = cfg.exit_fn;
        self.disk_path = if (cfg.disk_path) |d| try gpa.dupe(u8, d) else null;
        errdefer if (self.disk_path) |d| gpa.free(d);
        self.share_path = if (cfg.share_path) |s| try gpa.dupe(u8, s) else null;
        errdefer if (self.share_path) |s| gpa.free(s);

        const io = self.tio.io();

        const kernel = try std.Io.Dir.cwd().readFileAlloc(io, cfg.kernel_path, gpa, .limited(128 * 1024 * 1024));
        defer gpa.free(kernel); // copied into guest RAM by bootLinux/bootPvh below

        // Build the initramfs: pack the rootfs dir in memory (preferred) or read a
        // prebuilt cpio. Freed after the kernel boot copies it into guest RAM.
        const initrd: ?[]u8 = blk: {
            if (cfg.rootfs_dir) |dir| {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const aa = arena.allocator();

                // Apply the pulled image's ENV + WORKDIR (persisted inside the
                // rootfs by contain_pull_image) so images behave as authored —
                // the library boot path has no other channel for image ENV. The
                // caller's env is appended LAST so it overrides the image's.
                var env_list: std.ArrayListUnmanaged([]const u8) = .empty;
                var eff_workdir = cfg.workdir;
                if (registry.readEmbeddedConfig(aa, gpa, io, dir)) |img| {
                    for (img.env) |e| try env_list.append(aa, e);
                    if (cfg.workdir == null and img.working_dir.len != 0) eff_workdir = img.working_dir;
                }
                for (cfg.env) |e| try env_list.append(aa, e);

                const init_script = try rootfs.buildShellInit(aa, .{
                    .share_guest_path = if (self.share_path != null) cfg.share_guest_path else null,
                    .env = env_list.items,
                    .workdir = eff_workdir,
                });
                break :blk try rootfs.buildInitramfs(gpa, io, dir, init_script);
            } else if (cfg.initramfs_path) |p| {
                // ~1 GB cap: a full distro rootfs rides in the initramfs (must fit in
                // guest RAM alongside the tmpfs the kernel extracts it into).
                break :blk try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1024 * 1024 * 1024));
            } else break :blk null;
        };
        defer if (initrd) |ir| gpa.free(ir);

        const ram = ramSize(cfg.ram_bytes);
        var rng_seed: [64]u8 = undefined;
        if (builtin.os.tag == .macos) std.c.arc4random_buf(&rng_seed, rng_seed.len) else @memset(&rng_seed, 0);

        // An ELF kernel is a `vmlinux` -> the x86-microvm platform (KVM/WHP); else
        // an arm64 Linux Image -> the virt machine (HVF/KVM).
        const is_elf = kernel.len >= 4 and std.mem.eql(u8, kernel[0..4], "\x7fELF");
        if (is_elf) {
            const host_default: accel.Kind = if (builtin.os.tag == .windows) .whp else .kvm;
            const want = accel.fromEnvOrDefault(cfg.accel_override);
            const kind: accel.Kind = switch (want) {
                .kvm, .whp => want,
                else => host_default,
            };
            if (!accel.supported(kind)) return Error.AccelUnsupported;
            self.kind = kind;
            const m = try Machine.initX86(gpa, io, ram, self.share_path, null, true, rng_seed[0..32].*, kind == .whp);
            errdefer m.deinit();
            self.m = m;
            try m.bootPvh(kernel, initrd);
            m.input = "";
        } else {
            const kind = accel.fromEnvOrDefault(cfg.accel_override);
            if (!accel.supported(kind)) return Error.AccelUnsupported;
            self.kind = kind;
            const m = try Machine.init(gpa, io, ram, self.share_path, null, true, rng_seed[0..32].*);
            errdefer m.deinit();
            self.m = m;
            const have_seed = builtin.os.tag == .macos;
            const dtb = try fdt.buildVirtDtb(gpa, .{
                .ram_base = machine_mod.ram_base,
                .ram_size = ram,
                .rng_seed = if (have_seed) &rng_seed else null,
                // panic=-1: a panicking guest (e.g. shell-less image) reboots ->
                // PSCI -> the run thread returns cleanly instead of spinning.
                .bootargs = "console=ttyAMA0 earlycon=pl011,0x9000000 rdinit=/init contain.interactive panic=-1",
                .initrd_start = if (initrd != null) machine_mod.initrd_load else null,
                .initrd_end = if (initrd) |ir| machine_mod.initrd_load + ir.len else null,
                .num_virtio = m.num_virtio,
            });
            defer gpa.free(dtb); // copied into guest RAM by bootLinux
            try m.bootLinux(kernel, dtb, initrd);
            m.input = ""; // host->guest console is driven live via writeInput
        }

        loadDisk(io, gpa, self.m, self.disk_path);
        if (cfg.ports) |ps| setupForwards(self.m, ps);

        // Route guest console output to the embedder instead of host stdout.
        self.m.uart.sink = cfg.out;
        if (self.m.uart16550) |u| u.sink = cfg.out;

        self.run_thread = std.Thread.spawn(.{}, runLoop, .{self}) catch |err| {
            self.m.deinit();
            return err;
        };
        return self;
    }

    /// The guest run loop, on its own thread. Returns when the guest powers off or
    /// a stop is requested; then writes the disk back and notifies the embedder.
    fn runLoop(self: *Session) void {
        accel.run(self.kind, self.m) catch |err| {
            std.debug.print("[contain] accel {s} failed: {s}\n", .{ @tagName(self.kind), @errorName(err) });
        };
        writebackDisk(self.tio.io(), self.m, self.disk_path);
        self.finished.store(true, .release);
        if (self.exit_fn) |f| f(self.exit_ctx, 0);
    }

    /// Feed bytes to the guest console (host->guest), as if typed at the terminal.
    /// Thread-safe. Note the UART RX ring is small (256 bytes); a sender pushing
    /// faster than the guest drains may drop overflow — pace large inputs.
    pub fn writeInput(self: *Session, bytes: []const u8) void {
        if (self.m.uart16550) |u| {
            for (bytes) |b| u.pushRx(b);
        } else {
            for (bytes) |b| self.m.uart.pushRx(b);
        }
    }

    /// Whether the guest run loop has already returned (powered off on its own).
    pub fn isFinished(self: *Session) bool {
        return self.finished.load(.acquire);
    }

    /// Stop the guest (if still running) and join the run thread. Idempotent.
    pub fn stop(self: *Session) void {
        self.m.requestStop();
        if (self.run_thread) |t| {
            t.join();
            self.run_thread = null;
        }
    }

    /// Stop, tear everything down, and free the Session.
    pub fn deinit(self: *Session) void {
        self.stop();
        self.m.deinit();
        self.tio.deinit();
        if (self.disk_path) |d| self.gpa.free(d);
        if (self.share_path) |s| self.gpa.free(s);
        self.gpa.destroy(self);
    }
};

/// Round a requested RAM size up to the 16 KB HVF granule (the arm64 backend
/// asserts 16 KB alignment of the guest-RAM mapping); 0 selects the default.
pub fn ramSize(req: usize) usize {
    const r = if (req == 0) default_ram else req;
    return std.mem.alignForward(usize, r, 0x4000);
}

/// Load a host disk image into the virtio-blk store (missing file = silent; the
/// disk is created on writeback).
fn loadDisk(io: std.Io, gpa: std.mem.Allocator, m: *Machine, disk: ?[]const u8) void {
    const dp = disk orelse return;
    if (std.Io.Dir.cwd().readFileAlloc(io, dp, gpa, .limited(@intCast(m.disk.len + 4096)))) |data| {
        defer gpa.free(data);
        @memcpy(m.disk[0..@min(data.len, m.disk.len)], data[0..@min(data.len, m.disk.len)]);
    } else |_| {}
}

/// Write the virtio-blk store back to the host file; warn (don't silently lose
/// data) on failure.
fn writebackDisk(io: std.Io, m: *Machine, disk: ?[]const u8) void {
    const dp = disk orelse return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dp, .data = m.disk }) catch |err| {
        std.debug.print("[contain] WARN: disk writeback '{s}' failed: {s}\n", .{ dp, @errorName(err) });
    };
}

/// Parse a host->guest port-forward spec and register each forward.
fn setupForwards(m: *Machine, spec: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |tok| {
        const colon = std.mem.indexOfScalar(u8, tok, ':');
        const host_s = if (colon) |c| tok[0..c] else tok;
        const guest_s = if (colon) |c| tok[c + 1 ..] else tok;
        const host = std.fmt.parseInt(u16, host_s, 10) catch continue;
        const guest = std.fmt.parseInt(u16, guest_s, 10) catch continue;
        m.addHostForward(host, guest) catch continue;
    }
}

test "ramSize: default when zero, rounds up to the 16 KB HVF granule" {
    try std.testing.expectEqual(default_ram, ramSize(0));
    try std.testing.expectEqual(@as(usize, 0x4000), ramSize(1));
    try std.testing.expectEqual(@as(usize, 0x4000), ramSize(0x4000));
    try std.testing.expectEqual(@as(usize, 0x8000), ramSize(0x4001));
}

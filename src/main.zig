//! contain: a host-safe Linux/OCI sandbox that runs the guest on the host's
//! hardware virtualization (HVF/KVM/WHP). See `usage()` for the CLI.

const std = @import("std");
const builtin = @import("builtin");
const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const accel = @import("accel/accel.zig");
const fdt = @import("fdt.zig");
const cpio = @import("cpio.zig");
const registry = @import("oci/registry.zig");
const rootfs = @import("rootfs.zig");
const kernel_fetch = @import("kernel_fetch.zig");
const build_mod = @import("build.zig");
const compose_mod = @import("compose.zig");
const Pl011 = @import("devices/uart_pl011.zig").Pl011;
const Uart16550 = @import("devices/uart_16550.zig").Uart16550;

// Don't dump a stack trace when a host socket returns an unusual status: a
// connection being aborted/reset at teardown is normal and is handled where it
// occurs (the NAT reader threads). Keeps the guest console clean in all builds.
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

// --- interactive terminal handling: feed the host keyboard into the guest UART ---
const win = struct {
    extern "kernel32" fn GetStdHandle(id: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetConsoleMode(h: ?*anyopaque, mode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(h: ?*anyopaque, mode: u32) callconv(.winapi) i32;
    const STD_INPUT: u32 = 0xFFFF_FFF6; // (DWORD)-10
    const STD_OUTPUT: u32 = 0xFFFF_FFF5; // (DWORD)-11
};

var saved_console_mode: ?u32 = null;
const Termios = if (builtin.os.tag == .windows) void else std.posix.termios;
var saved_termios: ?Termios = null;

/// Put the host terminal in raw mode so keystrokes reach the guest unbuffered
/// and the guest (not the host) handles echo/line editing. No-op if stdin is
/// not a console (e.g. piped input).
fn enterRawTerminal() void {
    if (builtin.os.tag == .windows) {
        const hin = win.GetStdHandle(win.STD_INPUT) orelse return;
        var mode: u32 = 0;
        if (win.GetConsoleMode(hin, &mode) == 0) return; // not a console
        saved_console_mode = mode;
        // clear ENABLE_PROCESSED_INPUT|LINE_INPUT|ECHO_INPUT, add VIRTUAL_TERMINAL_INPUT.
        _ = win.SetConsoleMode(hin, (mode & ~@as(u32, 0x0007)) | 0x0200);
        const hout = win.GetStdHandle(win.STD_OUTPUT) orelse return;
        var om: u32 = 0;
        if (win.GetConsoleMode(hout, &om) != 0)
            _ = win.SetConsoleMode(hout, om | std.os.windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    } else {
        // POSIX (macOS/Linux): put the tty in raw mode via termios. Without this
        // the host terminal does its own echo + line buffering, fighting the
        // guest's line editor (doubled characters, line-at-a-time input).
        const fd = std.posix.STDIN_FILENO;
        var t = std.posix.tcgetattr(fd) catch return; // not a tty -> leave as is
        saved_termios = t;
        t.iflag.BRKINT = false;
        t.iflag.ICRNL = false; // pass CR to the guest unchanged
        t.iflag.INPCK = false;
        t.iflag.ISTRIP = false;
        t.iflag.IXON = false; // Ctrl-S/Q go to the guest
        t.oflag.OPOST = false; // guest already emits CRLF; don't re-process
        t.lflag.ECHO = false; // guest echoes
        t.lflag.ECHONL = false;
        t.lflag.ICANON = false; // char-at-a-time
        t.lflag.ISIG = false; // Ctrl-C/Z go to the guest
        t.lflag.IEXTEN = false;
        std.posix.tcsetattr(fd, .FLUSH, t) catch {};
    }
}

fn restoreTerminal() void {
    if (builtin.os.tag == .windows) {
        if (saved_console_mode) |m| {
            const hin = win.GetStdHandle(win.STD_INPUT) orelse return;
            _ = win.SetConsoleMode(hin, m);
        }
    } else {
        if (saved_termios) |t| std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, t) catch {};
    }
}

const StdinCtx = struct { uart: *Pl011, io: std.Io, stop: *std.atomic.Value(bool), m: *Machine };

// Consecutive Ctrl-C presses that force-quit the VM (a single Ctrl-C is still
// forwarded to the guest, so guest programs can be interrupted normally).
const force_quit_ctrlc = 3;

/// Background thread: read host stdin and push each byte into the guest UART.
/// Cursor-position reports (CSI `ESC [ ... R`) that the *host* terminal emits in
/// reply to the guest's `ESC[6n` query are filtered out here — the emulated UART
/// supplies its own single, consistent reply, and letting the host's duplicate
/// through confuses the guest's line editor (wrong width -> staircased input)
/// and leaks the raw report (e.g. `^[[48;5R`) as visible text.
fn stdinReader(ctx: *StdinCtx) void {
    var sin = std.Io.File.stdin();
    var rbuf: [64]u8 = undefined;
    var r = sin.reader(ctx.io, &rbuf);
    var seq: [24]u8 = undefined;
    var seq_len: usize = 0; // >0 while buffering a possible escape sequence
    var ctrlc: u8 = 0; // consecutive Ctrl-C count (force-quit escape hatch)
    const flush = struct {
        fn f(u: *Pl011, s: []const u8) void {
            for (s) |c| u.pushRx(c);
        }
    }.f;
    while (!ctx.stop.load(.acquire)) {
        const b = r.interface.takeByte() catch break;
        if (ctx.stop.load(.acquire)) break;

        if (seq_len == 0) {
            if (b == 0x03) { // Ctrl-C: forward to the guest; N in a row force-quit
                ctx.uart.pushRx(b);
                ctrlc += 1;
                if (ctrlc >= force_quit_ctrlc) {
                    ctx.m.requestStop();
                    break;
                }
                continue;
            }
            ctrlc = 0;
            if (b == 0x1b) {
                seq[0] = b;
                seq_len = 1;
            } else ctx.uart.pushRx(b);
            continue;
        }
        seq[seq_len] = b;
        seq_len += 1;
        if (seq_len == 2) {
            if (b != '[') { // ESC not followed by '[' -> not a CSI, pass through
                flush(ctx.uart, seq[0..seq_len]);
                seq_len = 0;
            }
            continue;
        }
        // In CSI parameters; a byte in 0x40..0x7e is the final byte.
        if (b >= 0x40 and b <= 0x7e) {
            if (b != 'R') flush(ctx.uart, seq[0..seq_len]); // drop only CPR (...R)
            seq_len = 0;
        } else if (seq_len >= seq.len) { // runaway -> flush what we have
            flush(ctx.uart, seq[0..seq_len]);
            seq_len = 0;
        }
    }
}

const default_init =
    \\#!/bin/busybox sh
    \\echo CONTAIN_USERSPACE_OK
    \\/bin/busybox mkdir -p /proc /sys /dev /bin /tmp /etc /host
    \\/bin/busybox mount -t proc proc /proc
    \\/bin/busybox mount -t sysfs sysfs /sys
    \\/bin/busybox mount -t devtmpfs devtmpfs /dev
    \\/bin/busybox --install -s /bin
    \\export PATH=/bin:/sbin:/usr/bin:/usr/sbin HOME=/root TERM=linux
    \\for m in /virtio_mmio.ko /virtio_blk.ko /netfs.ko /fscache.ko /9pnet.ko /9pnet_virtio.ko /9p.ko; do [ -f $m ] && insmod $m 2>/dev/null; done
    \\# bring up the host directory mount and networking for whoever uses the guest.
    \\# virtio-fs is the default transport; fall back to 9p if only that device exists.
    \\mount -t virtiofs host /host 2>/dev/null || mount -t 9p -o trans=virtio,version=9p2000.L host /host 2>/dev/null
    \\ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
    \\route add default gw 10.0.2.2 2>/dev/null
    \\echo "nameserver 10.0.2.3" > /etc/resolv.conf 2>/dev/null
    \\if grep -q contain.interactive /proc/cmdline; then \
    \\  echo ""; echo "=================================================="; \
    \\  echo "  contain interactive shell. Host dir at /host (if shared),"; \
    \\  echo "  networking via NAT. Type 'poweroff -f' (or exit) to leave."; \
    \\  echo "=================================================="; \
    \\  setsid -c /bin/sh; sync; poweroff -f; \
    \\fi
    \\echo ""
    \\echo "=================================================="
    \\echo "  CONTAIN: aarch64 Linux guest is alive"
    \\echo "=================================================="
    \\uname -a
    \\echo "--- / ---"; ls /
    \\echo "--- /proc/cpuinfo ---"; head -6 /proc/cpuinfo
    \\echo "--- /proc/meminfo ---"; head -3 /proc/meminfo
    \\echo "--- fork/exec/pipe test ---"; echo one two three | wc -w
    \\echo "--- arithmetic ---"; echo "6 * 7 = $((6 * 7))"
    \\echo "--- write a file & read back ---"; echo persisted-data > /tmp/f; cat /tmp/f
    \\echo "--- virtio-blk /dev/vda ---"
    \\if [ -b /dev/vda ]; then echo "/dev/vda present, $(cat /sys/block/vda/size) sectors"; \
    \\  echo "sector 0 on entry: [$(dd if=/dev/vda bs=32 count=1 2>/dev/null | tr -d '\0')]"; \
    \\  echo CONTAIN_PERSIST_MARKER_42 | dd of=/dev/vda bs=64 count=1 conv=notrunc 2>/dev/null; sync; \
    \\  echo "wrote marker; sector 0 now: [$(dd if=/dev/vda bs=32 count=1 2>/dev/null | tr -d '\0')]"; \
    \\  else echo "no /dev/vda (virtio module not loaded)"; fi
    \\echo "--- host directory mount (virtio-fs / 9p) ---"
    \\if mount | grep -q /host; then \
    \\  echo "mounted host dir at /host via $(mount | grep /host | awk '{print $5}'):"; ls -la /host; \
    \\  for f in /host/*; do [ -f "$f" ] && echo "--- $f ---" && cat "$f"; done; \
    \\  echo "writing /host/from_guest.txt..."; echo "written by the contain guest" > /host/from_guest.txt 2>/dev/null && echo "wrote ok"; \
    \\  else echo "host mount failed"; fi
    \\echo "--- network (virtio-net + NAT) ---"
    \\ping -c 2 -W 2 10.0.2.2 2>&1 | head -3
    \\echo "--- DNS lookup (example.com) ---"; nslookup example.com 2>&1 | head -8
    \\echo "--- HTTP fetch over TCP ---"; wget -T 15 -O /tmp/page http://example.com/ 2>&1 | tail -2; echo "--- first bytes ---"; head -c 160 /tmp/page 2>/dev/null; echo
    \\echo CONTAIN_DEMO_DONE
    \\if [ -f /run.sh ]; then echo "--- running /run.sh ---"; sh /run.sh; fi
    \\echo "--- powering off ---"; sync; poweroff -f
    \\
;

// 2 GB. Guest RAM is demand-zeroed (OS-backed), so idle RSS still tracks only
// touched pages — this just raises the ceiling so larger OCI images (whose rootfs
// rides in the initramfs) have headroom for the tmpfs copy + the workload.
pub const default_ram: usize = 2 * 1024 * 1024 * 1024;

/// Default guest RAM when the rootfs is mounted over virtio-fs (demand-paged) —
/// the image is NOT resident in RAM, so this is pure workload headroom, not
/// image+headroom. A smaller window also caps the guest page cache (which grows
/// to fill free RAM and, being host-resident once touched, would otherwise inflate
/// host RSS toward the full window). Overridable with -m / CONTAIN_MEM.
pub const default_ram_virtiofs: usize = 1024 * 1024 * 1024; // 1 GB

// Ceiling on a directly-`boot`ed initramfs file read. Auto-sized guest RAM (see
// ramForInitrd) lets a multi-GB rootfs ride in the initramfs, so the read cap has
// to clear that; the OCI `run` path skips the file entirely (boots from memory).
const max_initrd_bytes: usize = 8 * 1024 * 1024 * 1024;

/// Guest RAM for a boot whose rootfs rides in an `initrd_len`-byte initramfs. The
/// kernel unpacks the cpio into a ramfs root, so mid-unpack BOTH are resident: the
/// initrd image (reserved until unpack finishes) AND the extracted tree. The extract
/// is bigger than the cpio — ramfs rounds every file up to a page, so a file-heavy
/// image (many small files: node_modules, site-packages) inflates well past its
/// packed size. Budget ~3× the initrd for that peak plus 1 GB of workload headroom,
/// rounded up to 2 MB, floored at the 2 GB default. (Guest RAM is demand-zeroed, so
/// over-provisioning costs host RSS only for pages actually touched.) `-m`/CONTAIN_MEM
/// override when this heuristic is off for a given image.
pub fn ramForInitrd(initrd_len: usize) usize {
    const headroom: usize = 1024 * 1024 * 1024; // 1 GB for the workload after unpack
    const needed = (initrd_len *| 3) +| headroom;
    const two_mb: usize = 2 * 1024 * 1024;
    const rounded = (needed +| (two_mb - 1)) / two_mb * two_mb;
    return @max(default_ram, rounded);
}

/// Resolve the on-disk cache base: `CONTAIN_CACHE`, else `$XDG_CACHE_HOME/contain`,
/// else `$HOME/.cache/contain` (`$USERPROFILE\.contain-cache` on Windows), else a
/// `oci-cache` dir in the cwd. Allocated from `arena` (or a static fallback).
fn resolveCacheDir(arena: std.mem.Allocator, env: anytype) []const u8 {
    if (env.get("CONTAIN_CACHE")) |c| if (c.len != 0) return c;
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len != 0) return std.fmt.allocPrint(arena, "{s}/contain", .{x}) catch "oci-cache";
    if (env.get("HOME")) |h| if (h.len != 0) return std.fmt.allocPrint(arena, "{s}/.cache/contain", .{h}) catch "oci-cache";
    if (env.get("USERPROFILE")) |u| if (u.len != 0) return std.fmt.allocPrint(arena, "{s}/.contain-cache", .{u}) catch "oci-cache";
    return "oci-cache";
}

/// True if `path` exists (best-effort; any access error reads as "absent").
fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Parse a docker-style `--pull` value. Returns null for anything else (so a bare
/// `--pull` followed by the image name is treated as `.always`, not consumed).
pub fn parsePullPolicy(s: []const u8) ?PullPolicy {
    if (std.mem.eql(u8, s, "always")) return .always;
    if (std.mem.eql(u8, s, "missing")) return .missing;
    if (std.mem.eql(u8, s, "never")) return .never;
    return null;
}

/// Parse a docker-style memory size: a plain byte count, or a number with a K/M/G
/// suffix (powers of 1024, case-insensitive). Returns null on anything malformed
/// (empty, non-numeric, fractional) so the caller can report a usage error.
pub fn parseMemSize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var end = s.len;
    var mult: usize = 1;
    switch (s[s.len - 1]) {
        'g', 'G' => mult = 1024 * 1024 * 1024,
        'm', 'M' => mult = 1024 * 1024,
        'k', 'K' => mult = 1024,
        else => {},
    }
    if (mult != 1) end -= 1;
    const n = std.fmt.parseInt(usize, s[0..end], 10) catch return null;
    return n *| mult;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        usage();
        return;
    }

    // CONTAIN_ACCEL selects the vCPU backend (hvf|kvm|whp); unset = host default.
    const accel_override = init.environ_map.get("CONTAIN_ACCEL");
    // CONTAIN_MEM overrides the auto-sized guest RAM (e.g. "4G"); `run -m` beats it.
    const mem_override = init.environ_map.get("CONTAIN_MEM");
    // CONTAIN_SHARE_FS=9p forces the legacy 9p transport for host-directory shares
    // (default is virtio-fs on x86). Set the process-wide flag machine.zig reads.
    if (init.environ_map.get("CONTAIN_SHARE_FS")) |v|
        machine_mod.Machine.share_9p_override = std.mem.eql(u8, v, "9p");
    // CONTAIN_ROOTFS=initramfs forces the legacy rootfs-in-initramfs pack instead of
    // rootfs-over-virtiofs (default on x86). Read here where the env map is available.
    force_initramfs_root = if (init.environ_map.get("CONTAIN_ROOTFS")) |v| std.mem.eql(u8, v, "initramfs") else false;

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "boot")) {
        if (args.len < 3) {
            usage();
            return;
        }
        try cmdBoot(gpa, io, args[2], if (args.len > 3) args[3] else null, if (args.len > 4) args[4] else null, if (args.len > 5) args[5] else null, if (args.len > 6) args[6] else null, if (args.len > 7) args[7] else null, accel_override, mem_override, null, null);
    } else if (std.mem.eql(u8, cmd, "mkinitramfs")) {
        if (args.len < 4) {
            usage();
            return;
        }
        try cmdMkinitramfs(gpa, io, args[2], args[3], args[4..]);
    } else if (std.mem.eql(u8, cmd, "stripbtf")) {
        if (args.len < 4) {
            usage();
            return;
        }
        try cmdStripBtf(gpa, io, args[2], args[3]);
    } else if (std.mem.eql(u8, cmd, "pull")) {
        if (args.len < 3) {
            usage();
            return;
        }
        try cmdPull(gpa, args[2], if (args.len > 3) args[3] else null, if (args.len > 4) args[4] else null);
    } else if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) {
            usage();
            return;
        }
        const opts = (try parseRunArgs(init.arena.allocator(), args[2..], accel_override, mem_override)) orelse {
            usage();
            return;
        };
        const cache_base = resolveCacheDir(init.arena.allocator(), init.environ_map);
        try cmdRunOci(gpa, io, opts, cache_base);
    } else if (std.mem.eql(u8, cmd, "build")) {
        const cache_base = resolveCacheDir(init.arena.allocator(), init.environ_map);
        try cmdBuild(gpa, io, args[2..], cache_base);
    } else if (std.mem.eql(u8, cmd, "compose")) {
        const cache_base = resolveCacheDir(init.arena.allocator(), init.environ_map);
        try cmdCompose(gpa, io, args[2..], cache_base);
    } else {
        usage();
    }
}

fn cmdMkinitramfs(gpa: std.mem.Allocator, io: std.Io, busybox_path: []const u8, out_path: []const u8, extras: []const [:0]const u8) !void {
    const bb = std.Io.Dir.cwd().readFileAlloc(io, busybox_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("contain: cannot read busybox '{s}': {s}\n", .{ busybox_path, @errorName(err) });
        return;
    };
    defer gpa.free(bb);

    var w = cpio.Writer.init(gpa);
    defer w.deinit();
    try w.addDir("bin");
    try w.addDir("dev");
    try w.addDir("proc");
    try w.addDir("sys");
    try w.addDir("tmp");
    try w.addFile("bin/busybox", cpio.MODE_FILE, bb);
    try w.addFile("init", cpio.MODE_FILE, default_init);
    // Bundle any extra files (e.g. kernel modules) at their basename in /.
    for (extras) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch |err| {
            std.debug.print("contain: cannot read extra '{s}': {s}\n", .{ path, @errorName(err) });
            return;
        };
        defer gpa.free(data);
        const base = std.fs.path.basename(path);
        try w.addFile(base, cpio.MODE_FILE, data);
        std.debug.print("  + {s} ({d} bytes)\n", .{ base, data.len });
    }
    try w.finish();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = w.bytes() });
    std.debug.print("[contain] wrote {s} ({d} bytes)\n", .{ out_path, w.bytes().len });
}

/// Disable module BTF validation by zeroing the .BTF/.BTF.ext sections of a
/// kernel .ko (the in-emulator BTF validation trips on the distro modules).
fn cmdStripBtf(gpa: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8) !void {
    const buf = std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("contain: cannot read '{s}': {s}\n", .{ in_path, @errorName(err) });
        return;
    };
    defer gpa.free(buf);
    if (buf.len < 64 or !std.mem.eql(u8, buf[0..4], "\x7fELF")) {
        std.debug.print("contain: '{s}' is not an ELF file\n", .{in_path});
        return;
    }
    const shoff = std.mem.readInt(u64, buf[40..48], .little);
    const shentsize = std.mem.readInt(u16, buf[58..60], .little);
    const shnum = std.mem.readInt(u16, buf[60..62], .little);
    const shstrndx = std.mem.readInt(u16, buf[62..64], .little);
    const strhdr = shoff + @as(u64, shstrndx) * shentsize;
    const stroff = std.mem.readInt(u64, buf[@intCast(strhdr + 24) ..][0..8], .little);

    var stripped: u32 = 0;
    var i: u16 = 0;
    while (i < shnum) : (i += 1) {
        const h = shoff + @as(u64, i) * shentsize;
        const name_off = std.mem.readInt(u32, buf[@intCast(h) ..][0..4], .little);
        const name = std.mem.sliceTo(buf[@intCast(stroff + name_off)..], 0);
        if (std.mem.eql(u8, name, ".BTF") or std.mem.eql(u8, name, ".BTF.ext")) {
            // Mark the section SHT_NULL so the kernel's find_sec(".BTF") skips it
            // (find_sec ignores SHT_NULL) and BTF validation is bypassed.
            std.mem.writeInt(u32, buf[@intCast(h + 4)..][0..4], 0, .little); // sh_type = SHT_NULL
            stripped += 1;
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf });
    std.debug.print("[contain] {s}: stripped {d} BTF section(s) -> {s}\n", .{ in_path, stripped, out_path });
}

/// A positional arg is "not provided" if empty or the "-" skip sentinel.
fn isNone(p: []const u8) bool {
    return p.len == 0 or std.mem.eql(u8, p, "-");
}

fn usage() void {
    std.debug.print(
        \\contain - host-safe Linux sandbox (hardware virt: HVF/KVM/WHP)
        \\
        \\Usage:
        \\  contain run [OPTIONS] IMAGE [COMMAND] [ARG...]
        \\                                pull a Docker Hub image and run it on the
        \\                                host's hardware backend (a drop-in for
        \\                                `docker run`).
        \\    -i, -t, -it, --interactive, --tty   attach an interactive shell
        \\    -p, --publish host:guest            forward a TCP port (repeatable)
        \\    -v, --volume  host:/path            mount a host dir in the guest (9p)
        \\    -e, --env     KEY=VALUE             set an env var (repeatable)
        \\    -w, --workdir DIR                   working dir for the command
        \\    -m, --memory  SIZE                  guest RAM (e.g. 4G, 512M); default
        \\                                        auto-sized to the image
        \\    --pull        always|missing|never  refetch policy (default: missing =
        \\                                        reuse the cached image if present)
        \\    --entrypoint  CMD                   override the image entrypoint
        \\    --rm, --name, -u/--user             accepted for docker-compat (ignored)
        \\    -d, --detach                        unsupported (runs in foreground)
        \\
        \\  contain build [-t NAME[:TAG]] [-f DOCKERFILE] CONTEXT
        \\                                build an image from a Dockerfile (FROM/RUN/
        \\                                COPY/ADD/ENV/WORKDIR/CMD/ENTRYPOINT/ARG);
        \\                                run it with `contain run NAME` (x86 only)
        \\  contain compose [-f FILE] up|build|config [SERVICE...]
        \\                                run a multi-service compose.yaml (each
        \\                                service is a guest; published ports only)
        \\  contain pull <image> [dir] [arch]   unpack an image's rootfs to <dir>
        \\                                      (default: ./<image>-rootfs)
        \\  contain boot <kernel> [initramfs] [input] [disk] [share] [ports]
        \\                                boot a Linux kernel (arm64 Image or x86
        \\                                vmlinux ELF -> x86-microvm)
        \\  contain mkinitramfs <busybox> <out.cpio> [extra-file ...]
        \\
        \\  input: "tty" for an interactive console, a file to script stdin,
        \\         or "-" to skip. ports / -p: host->guest TCP forwards, e.g.
        \\         "8080" or "8080:3000" or "8080,5173:5173" (use "-" to skip).
        \\  CONTAIN_ACCEL=hvf|kvm|whp overrides the auto-selected backend.
        \\  CONTAIN_MEM=4G overrides the auto-sized guest RAM (run -m wins over it).
        \\  CONTAIN_CACHE=<dir> sets the image cache (default ~/.cache/contain); a
        \\  cached image runs offline with no re-download or re-unpack.
        \\
    , .{});
}

/// Parse a host->guest port-forward spec ("8080", "8080:3000", or a
/// comma-separated list) and register each forward on the machine.
fn setupForwards(m: *Machine, spec: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |tok| {
        const colon = std.mem.indexOfScalar(u8, tok, ':');
        const host_s = if (colon) |c| tok[0..c] else tok;
        const guest_s = if (colon) |c| tok[c + 1 ..] else tok;
        const host = std.fmt.parseInt(u16, host_s, 10) catch continue;
        const guest = std.fmt.parseInt(u16, guest_s, 10) catch continue;
        m.addHostForward(host, guest) catch |err| {
            std.debug.print("[contain] port-forward {d}->{d} failed: {s}\n", .{ host, guest, @errorName(err) });
            continue;
        };
        std.debug.print("[contain] forwarding host 127.0.0.1:{d} -> guest :{d}\n", .{ host, guest });
    }
}

const X86StdinCtx = struct { uart: *Uart16550, io: std.Io, stop: *std.atomic.Value(bool), m: *Machine };

/// Background thread: feed host stdin into the guest's 16550 (x86 console).
fn x86StdinReader(ctx: *X86StdinCtx) void {
    var sin = std.Io.File.stdin();
    var rbuf: [64]u8 = undefined;
    var r = sin.reader(ctx.io, &rbuf);
    var ctrlc: u8 = 0;
    while (!ctx.stop.load(.acquire)) {
        const b = r.interface.takeByte() catch break;
        if (ctx.stop.load(.acquire)) break;
        ctx.uart.pushRx(b);
        if (b == 0x03) { // Ctrl-C: N consecutive presses force-quit the VM
            ctrlc += 1;
            if (ctrlc >= force_quit_ctrlc) {
                ctx.m.requestStop();
                break;
            }
        } else ctrlc = 0;
    }
}

// ---- shared boot orchestration (used by both bootX86 and cmdBoot) ----

/// Host entropy for the guest CRNG (virtio-rng) and, on arm64, the DTB rng-seed.
/// macOS links libc, so use its CSPRNG; elsewhere the virtio-rng device seeds
/// itself from the host at init, so a zero array here is fine.
fn seedRng() [64]u8 {
    var seed: [64]u8 = undefined;
    if (builtin.os.tag == .macos) std.c.arc4random_buf(&seed, seed.len) else @memset(&seed, 0);
    return seed;
}

/// Load a host disk image into the virtio-blk backing store. A missing file is
/// intentionally silent (first run: the disk is created on writeback).
fn loadDisk(io: std.Io, gpa: std.mem.Allocator, m: *Machine, disk: ?[]const u8) void {
    const dp = disk orelse return;
    if (std.Io.Dir.cwd().readFileAlloc(io, dp, gpa, .limited(@intCast(m.disk.len + 4096)))) |data| {
        defer gpa.free(data);
        @memcpy(m.disk[0..@min(data.len, m.disk.len)], data[0..@min(data.len, m.disk.len)]);
        std.debug.print("[contain] loaded disk '{s}' ({d} bytes)\n", .{ dp, data.len });
    } else |_| {}
}

/// Write the virtio-blk store back to the host file; warn (don't silently lose
/// data) on failure.
fn writebackDisk(io: std.Io, m: *Machine, disk: ?[]const u8) void {
    const dp = disk orelse return;
    if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dp, .data = m.disk })) {
        std.debug.print("[contain] wrote disk back to '{s}'\n", .{dp});
    } else |err| {
        std.debug.print("[contain] WARN: disk writeback '{s}' failed: {s}\n", .{ dp, @errorName(err) });
    }
}

/// Attach the host terminal to the guest console: raw mode + a detached reader
/// thread feeding host stdin into the guest UART. `ctx` must outlive the run
/// (it lives in the caller's frame, which never unwinds before process exit).
fn startStdinReader(readerFn: anytype, ctx: anytype) void {
    enterRawTerminal();
    std.debug.print("[contain] interactive: press Ctrl-C {d}x to force-quit the VM\n", .{force_quit_ctrlc});
    if (std.Thread.spawn(.{}, readerFn, .{ctx})) |t| t.detach() else |_| {
        std.debug.print("[contain] warn: interactive input unavailable (thread spawn failed)\n", .{});
    }
}

/// Undo `startStdinReader`: stop the reader and restore the terminal.
fn stopStdinReader(interactive: bool, stop: *std.atomic.Value(bool)) void {
    if (!interactive) return;
    stop.store(true, .release);
    restoreTerminal();
}

/// Run the guest under `kind`, timing the run; returns wall-clock seconds.
fn runMachineTimed(io: std.Io, kind: accel.Kind, m: *Machine) f64 {
    const t0_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    accel.run(kind, m) catch |err| {
        std.debug.print("[contain] accel {s} failed: {s}\n", .{ @tagName(kind), @errorName(err) });
    };
    const t1_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    return @as(f64, @floatFromInt(@as(i128, @intCast(t1_ns - t0_ns)))) / 1e9;
}

/// Boot an x86-64 `vmlinux` on the x86-microvm platform via a hardware backend.
fn bootX86(gpa: std.mem.Allocator, io: std.Io, vmlinux: []const u8, initrd: ?[]const u8, input: []const u8, disk: ?[]const u8, share: ?[]const u8, rootfs_share: ?[]const u8, ports_spec: ?[]const u8, accel_override: ?[]const u8, interactive: bool, ram_size: usize) !void {
    // x86-microvm only runs on a hardware backend: WHP on Windows, KVM elsewhere.
    // An explicit CONTAIN_ACCEL=kvm|whp overrides the host default.
    const host_default: accel.Kind = if (builtin.os.tag == .windows) .whp else .kvm;
    const want = accel.fromEnvOrDefault(accel_override);
    const kind: accel.Kind = switch (want) {
        .kvm, .whp => want,
        else => host_default,
    };
    if (!accel.supported(kind)) {
        std.debug.print("[contain] x86-microvm needs an x86 hardware backend (kvm/whp); '{s}' is unavailable on this host ({s}/{s}). Build + run on x86 Linux (KVM) or Windows (WHP).\n", .{ @tagName(kind), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
        return;
    }

    var rng_seed: [64]u8 = undefined;
    if (builtin.os.tag == .macos) std.c.arc4random_buf(&rng_seed, rng_seed.len) else @memset(&rng_seed, 0);

    var m = try Machine.initX86(gpa, io, ram_size, share, rootfs_share, true, rng_seed[0..32].*, kind == .whp);
    defer m.deinit();
    m.input = input;

    std.debug.print("[contain] platform=x86-microvm accel={s}, guest RAM {d} MB\n[contain] cmdline: {s}\n", .{ @tagName(kind), ram_size / (1024 * 1024), m.x86_cmdline.? });
    try m.bootPvh(vmlinux, initrd);
    std.debug.print("[contain] vmlinux={d} bytes, initrd={?d} bytes, PVH entry=0x{x}, start_info=0x{x}, virtio devs={d}\n", .{ vmlinux.len, if (initrd) |ir| ir.len else null, m.x86_entry, m.x86_start_info, m.num_virtio });

    loadDisk(io, gpa, m, disk);
    if (ports_spec) |ps| if (!isNone(ps)) setupForwards(m, ps);

    var stop = std.atomic.Value(bool).init(false);
    var stdin_ctx: X86StdinCtx = .{ .uart = m.uart16550.?, .io = io, .stop = &stop, .m = m };
    if (interactive) startStdinReader(x86StdinReader, &stdin_ctx);

    const secs = runMachineTimed(io, kind, m);

    stopStdinReader(interactive, &stop);
    writebackDisk(io, m, disk);

    std.debug.print("\n[contain] stopped (x86-microvm, accel={s}): run {d:.3}s wall\n", .{ @tagName(kind), secs });
    std.process.exit(0);
}

/// Boot a rootfs dir over virtio-fs, run its `/.contain-init`, and RETURN cleanly
/// (unlike bootX86, which process.exit()s). Used by `contain build` to execute a
/// sequence of RUN steps in one process — each step mounts the shared build rootfs
/// rw so its changes persist. x86 only (build targets the host arch; the arm64 FUSE
/// kernel isn't released yet). Returns error.BackendUnavailable if no x86 backend.
fn bootBuildStep(gpa: std.mem.Allocator, io: std.Io, vmlinux: []const u8, rootfs_dir: []const u8) !void {
    const host_default = accel.autoDefault();
    const want = accel.fromEnvOrDefault(null);
    const kind: accel.Kind = switch (want) {
        .kvm, .whp => want,
        else => host_default,
    };
    if (!accel.supported(kind)) return error.BackendUnavailable;

    var rng_seed: [64]u8 = undefined;
    if (builtin.os.tag == .macos) std.c.arc4random_buf(&rng_seed, rng_seed.len) else @memset(&rng_seed, 0);

    var m = try Machine.initX86(gpa, io, default_ram_virtiofs, null, rootfs_dir, true, rng_seed[0..32].*, kind == .whp);
    defer m.deinit(); // clean teardown (no process.exit) so the next RUN step can boot
    m.input = "";
    try m.bootPvh(vmlinux, null);
    _ = runMachineTimed(io, kind, m);
}

fn cmdBoot(gpa: std.mem.Allocator, io: std.Io, image_path: []const u8, initrd_path: ?[]const u8, input_path: ?[]const u8, disk_path: ?[]const u8, share_path: ?[]const u8, ports_spec: ?[]const u8, accel_override: ?[]const u8, mem_override: ?[]const u8, initrd_override: ?[]const u8, rootfs_share: ?[]const u8) !void {
    // Auto-fetch the guest kernel when the canonical default is missing (arm64
    // only — x86 builds it from source). Scoped to the default path so a custom
    // `boot <kernel>` never gets silently overwritten with the Kata kernel.
    if (std.mem.eql(u8, image_path, kernel_fetch.defaultKernelPath())) {
        _ = kernel_fetch.ensureKernel(gpa, io, image_path) catch |err| {
            std.debug.print("contain: kernel auto-fetch failed: {s}\n", .{@errorName(err)});
            std.debug.print("  build it locally instead: ./tools/build_kernel.sh\n", .{});
        };
    }

    const image = std.Io.Dir.cwd().readFileAlloc(io, image_path, gpa, .limited(128 * 1024 * 1024)) catch |err| {
        std.debug.print("contain: cannot read kernel '{s}': {s}\n", .{ image_path, @errorName(err) });
        return;
    };
    defer gpa.free(image);

    // "tty" as the input slot means: attach my real terminal interactively.
    const interactive = if (input_path) |p| std.mem.eql(u8, p, "tty") else false;

    const input: []u8 = blk: {
        const p = input_path orelse break :blk try gpa.dupe(u8, "");
        if (isNone(p) or interactive) break :blk try gpa.dupe(u8, "");
        break :blk std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1024 * 1024)) catch |err| {
            std.debug.print("contain: cannot read input '{s}': {s}\n", .{ p, @errorName(err) });
            return;
        };
    };
    defer gpa.free(input);

    // The OCI `run` path already holds the packed cpio in memory and passes it via
    // initrd_override — boot straight from it (no temp file, no read-back). Otherwise
    // read the `boot <initrd>` file. A full distro rootfs rides in the initramfs, so
    // the cap is generous (up to max_initrd_bytes); guest RAM is auto-sized to fit.
    var owned_initrd: ?[]u8 = null;
    defer if (owned_initrd) |ir| gpa.free(ir);
    const initrd: ?[]const u8 = if (initrd_override) |ov|
        ov
    else if (initrd_path) |p| blk: {
        const buf = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_initrd_bytes)) catch |err| {
            std.debug.print("contain: cannot read initramfs '{s}': {s}\n", .{ p, @errorName(err) });
            return;
        };
        owned_initrd = buf;
        break :blk buf;
    } else null;

    // Auto-size guest RAM to the unpack peak (see ramForInitrd); an explicit
    // -m/--memory or CONTAIN_MEM overrides it.
    const ram_size: usize = if (mem_override) |ms|
        parseMemSize(ms) orelse {
            std.debug.print("contain: invalid memory size '{s}' (use e.g. 4G, 512M, or a byte count)\n", .{ms});
            return;
        }
    else if (rootfs_share != null)
        default_ram_virtiofs // demand-paged root: size to the workload, not the image
    else
        ramForInitrd(if (initrd) |ir| ir.len else 0);

    const initrd_start = machine_mod.initrd_load;
    const initrd_end = if (initrd) |ir| initrd_start + ir.len else null;

    // Treat empty-string or "-" positional args as "not provided" (PowerShell
    // drops empty '' arguments to native programs, so "-" is the portable skip).
    const disk = if (disk_path) |p| (if (isNone(p)) null else p) else null;
    const share = if (share_path) |p| (if (isNone(p)) null else p) else null;

    // An ELF kernel image means a `vmlinux` -> the x86-microvm platform (PVH boot,
    // in-kernel irqchip, 16550 console). Only the hardware backends can run it.
    if (image.len >= 4 and std.mem.eql(u8, image[0..4], "\x7fELF")) {
        try bootX86(gpa, io, image, initrd, input, disk, share, rootfs_share, ports_spec, accel_override, interactive, ram_size);
        return;
    }

    // Resolve the vCPU backend (CONTAIN_ACCEL, else the host default). An arm64
    // Linux Image can only run under HVF (macOS) or KVM (arm64 Linux); bail with a
    // clear message on a host that has neither.
    const accel_kind = accel.fromEnvOrDefault(accel_override);
    if (!accel.supported(accel_kind)) {
        std.debug.print("[contain] accel {s} unavailable on this host ({s}/{s}); an arm64 Linux guest needs HVF (Apple Silicon) or KVM (arm64 Linux).\n", .{ @tagName(accel_kind), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
        return;
    }
    std.debug.print("[contain] accel backend: {s}, guest RAM {d} MB\n", .{ @tagName(accel_kind), ram_size / (1024 * 1024) });

    // Host entropy: seeds both the virtio-rng device (guest CRNG) and the DTB
    // /chosen/rng-seed. Without it the guest stalls seconds on getrandom().
    const rng_seed = seedRng();
    const have_seed = builtin.os.tag == .macos;

    var m = try Machine.init(gpa, io, ram_size, share, rootfs_share, true, rng_seed[0..32].*); // networking on
    defer m.deinit();

    const dtb = try fdt.buildVirtDtb(gpa, .{
        .ram_base = machine_mod.ram_base,
        .ram_size = ram_size,
        .rng_seed = if (have_seed) &rng_seed else null,
        // CRNG seeding is handled by the virtio-rng device (the DT rng-seed below
        // is also credited on kernels built with CONFIG_RANDOM_TRUST_BOOTLOADER).
        // panic=-1: on any kernel panic (e.g. an image with no /bin/sh, so /init
        // can't exec) reboot immediately -> PSCI SYSTEM_RESET -> the run loop exits
        // cleanly instead of the vCPU spinning forever with no way out.
        .bootargs = if (interactive)
            "console=ttyAMA0 earlycon=pl011,0x9000000 rdinit=/init contain.interactive panic=-1"
        else
            "console=ttyAMA0 earlycon=pl011,0x9000000 rdinit=/init panic=-1",
        .initrd_start = if (initrd != null) initrd_start else null,
        .initrd_end = initrd_end,
        .num_virtio = m.num_virtio,
    });
    defer gpa.free(dtb);

    std.debug.print("[contain] kernel={d} bytes, initrd={?d} bytes, dtb={d} bytes, virtio devs={d}\n", .{
        image.len, if (initrd) |ir| ir.len else null, dtb.len, m.num_virtio,
    });

    try m.bootLinux(image, dtb, initrd);
    m.input = input;

    // Optional host-backed disk: loaded into the virtio-blk store and written
    // back to the host file after the run.
    loadDisk(io, gpa, m, disk);

    // Optional host->guest port forwards (e.g. expose a guest web app).
    if (ports_spec) |ps| if (!isNone(ps)) setupForwards(m, ps);

    // Interactive: attach the host terminal to the guest console.
    var stop = std.atomic.Value(bool).init(false);
    var stdin_ctx: StdinCtx = .{ .uart = m.uart, .io = io, .stop = &stop, .m = m };
    if (interactive) startStdinReader(stdinReader, &stdin_ctx);

    const secs = runMachineTimed(io, accel_kind, m);

    stopStdinReader(interactive, &stop);
    writebackDisk(io, m, disk);

    // In interactive mode the detached stdin reader may still be blocked on a
    // host read; exit the process directly rather than tearing down state it
    // could touch.
    if (interactive) {
        std.debug.print("\n[contain] guest powered off.\n", .{});
        std.process.exit(0);
    }

    // Hardware backends run the guest natively — no host instruction count.
    std.debug.print("\n[contain] stopped (accel={s}): run {d:.3}s wall\n", .{ @tagName(accel_kind), secs });

    // The NAT's background reader threads can still be blocked on host sockets;
    // tearing down (joining) them can hang. The disk has already been written
    // back above, so just exit — the OS reclaims everything. (The interactive
    // path above does the same for the same reason.)
    std.process.exit(0);
}

/// Build the guest init for `contain run`. The unpacked image rootfs IS the
/// initramfs root (no 9p, no chroot), so this just mounts the kernel
/// filesystems, brings up NAT networking, applies the image env + workdir, runs
/// the entrypoint, and powers off when it exits.
/// Write `arg` single-quoted (POSIX) followed by a space, so the guest shell
/// treats it as one literal word. Embedded single quotes become '\''.
fn shellQuote(w: *std.Io.Writer, arg: []const u8) !void {
    try w.writeByte('\'');
    for (arg) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeAll("' ");
}

fn buildOciInit(arena: std.mem.Allocator, cfg: registry.ImageConfig, opts: RunOpts, epoch: i64) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print(
        \\#!/bin/sh
        \\export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=linux
        \\mkdir -p /proc /sys /dev 2>/dev/null
        \\mount -t proc proc /proc 2>/dev/null
        \\mount -t sysfs sysfs /sys 2>/dev/null
        \\mount -t devtmpfs devtmpfs /dev 2>/dev/null
        \\# Reattach PID 1's stdio to the console. In rootfs-over-virtiofs mode the
        \\# image's /dev has no console at exec time (unlike the kernel's initramfs),
        \\# so without this every command's output would be lost.
        \\exec </dev/console >/dev/console 2>&1
        \\# Set a sane clock from the host (the guest has no working RTC), so TLS
        \\# certificate validation works for apk/pip/npm over HTTPS.
        \\date -s @{d} >/dev/null 2>&1 || date -u -s "@{d}" >/dev/null 2>&1
        \\
    , .{ epoch, epoch });
    try w.writeAll(
        \\ip addr add 127.0.0.1/8 dev lo 2>/dev/null; ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null
        \\ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
        \\ip link set eth0 up 2>/dev/null || ifconfig eth0 up 2>/dev/null
        \\ip route add default via 10.0.2.2 2>/dev/null || route add default gw 10.0.2.2 2>/dev/null
        \\echo "nameserver 10.0.2.3" > /etc/resolv.conf 2>/dev/null
        \\
    );
    // -v host:container -> mount the shared host directory at the container path.
    if (opts.volume_host != null)
        try w.print("mkdir -p {s} 2>/dev/null\nmount -t virtiofs host {s} 2>/dev/null || mount -t 9p -o trans=virtio,version=9p2000.L host {s} 2>/dev/null\n", .{ opts.volume_guest, opts.volume_guest, opts.volume_guest });
    // Image env first, then -e/--env (so a user -e overrides the image's value).
    for (cfg.env) |e| try w.print("export \"{s}\"\n", .{e});
    for (opts.env) |e| try w.print("export \"{s}\"\n", .{e});
    // -w/--workdir overrides the image's WorkingDir.
    const workdir: ?[]const u8 = opts.workdir orelse (if (cfg.working_dir.len != 0) cfg.working_dir else null);
    if (workdir) |d| try w.print("cd {s} 2>/dev/null\n", .{d});
    // Interactive with no command and no entrypoint override: drop into a shell.
    if (opts.interactive and opts.command.len == 0 and opts.entrypoint == null) {
        try w.writeAll("setsid -c /bin/sh\n");
        try w.writeAll(rootfs.poweroff_seq);
        return aw.written();
    }
    try w.writeAll("echo \"=== contain: running OCI image ===\"\n");
    // Single-quote each argv entry so shell metacharacters in the command (e.g.
    // `node -e 'for(...)'`) are passed verbatim, not re-parsed by the guest shell.
    // --entrypoint overrides the image entrypoint; the positional command becomes
    // its args. Otherwise: image entrypoint + (positional command or image Cmd).
    if (opts.entrypoint) |ep| {
        try shellQuote(w, ep);
    } else {
        for (cfg.entrypoint) |a| try shellQuote(w, a);
    }
    const args = if (opts.command.len != 0) opts.command else (if (opts.entrypoint != null) &[_][]const u8{} else cfg.cmd);
    for (args) |a| try shellQuote(w, a);
    try w.writeAll("\necho \"=== contain: entrypoint exited, powering off ===\"\n");
    try w.writeAll(rootfs.poweroff_seq);
    return aw.written();
}

/// The parsed surface of `contain run` — mirrors `docker run`.
pub const RunOpts = struct {
    image: []const u8,
    command: []const []const u8 = &.{}, // positional COMMAND [ARG...] after IMAGE
    env: []const []const u8 = &.{}, // -e/--env KEY=VAL (in addition to the image env)
    ports: ?[]const u8 = null, // -p/--publish, comma-joined for setupForwards
    volume_host: ?[]const u8 = null, // -v/--volume host part (a host directory)
    volume_guest: []const u8 = "/mnt", // -v/--volume container mount path
    workdir: ?[]const u8 = null, // -w/--workdir (overrides the image WorkingDir)
    entrypoint: ?[]const u8 = null, // --entrypoint (overrides the image entrypoint)
    interactive: bool = false, // -i/-t/-it/--interactive/--tty
    accel_override: ?[]const u8 = null,
    mem: ?[]const u8 = null, // -m/--memory (docker-style size, e.g. "4G"); else CONTAIN_MEM
    pull_policy: PullPolicy = .missing, // --pull [always|missing|never]
};

/// When to (re)pull an image vs. reuse the on-disk cache. `.missing` (the default)
/// reuses a cached image and only hits the network on a cache miss — a moved tag
/// is not noticed until `--pull always` or the cache is cleared. `.never` requires
/// a cached image (fully offline). `.always` forces a fresh pull.
pub const PullPolicy = enum { missing, always, never };

/// Split a `-v host:container[:ro]` spec. A bare `host` (no colon) mounts at
/// /mnt (lenient). NOTE: splits on the first colon, so a Windows `C:\...` host
/// path is not supported here (POSIX hosts are the norm for `-v`).
fn parseVolume(opts: *RunOpts, spec: []const u8) void {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse {
        opts.volume_host = spec;
        opts.volume_guest = "/mnt";
        return;
    };
    opts.volume_host = spec[0..colon];
    const rest = spec[colon + 1 ..];
    // Drop a trailing :ro/:rw mode (the 9p mount is read-write regardless).
    opts.volume_guest = if (std.mem.indexOfScalar(u8, rest, ':')) |c2| rest[0..c2] else rest;
}

/// Recognize a short bool-flag cluster of i/t/d (e.g. `-it`, `-itd`). Returns
/// null if `a` isn't such a cluster (so value flags like `-p` fall through).
fn shortBoolFlags(a: []const u8) ?struct { interactive: bool, detach: bool } {
    if (a.len < 2 or a[0] != '-' or a[1] == '-') return null;
    var interactive = false;
    var detach = false;
    for (a[1..]) |c| switch (c) {
        'i', 't' => interactive = true,
        'd' => detach = true,
        else => return null,
    };
    return .{ .interactive = interactive, .detach = detach };
}

/// Parse `contain run [docker-style OPTIONS] IMAGE [COMMAND] [ARG...]`. Mirrors
/// the `docker run` surface: option flags precede the image; everything after
/// the image is the command verbatim (no `--` needed, though a leading `--` is
/// tolerated). Returns null (caller prints usage) if no image is given or an
/// unsupported flag is hit.
pub fn parseRunArgs(arena: std.mem.Allocator, args: []const [:0]const u8, accel_override: ?[]const u8, mem_env: ?[]const u8) !?RunOpts {
    var opts: RunOpts = .{ .image = "", .accel_override = accel_override, .mem = mem_env };
    var ports: std.ArrayListUnmanaged([]const u8) = .empty;
    var env: std.ArrayListUnmanaged([]const u8) = .empty;
    var nvol: u32 = 0;

    const next = struct {
        fn f(a: []const [:0]const u8, i: *usize) ?[]const u8 {
            if (i.* + 1 >= a.len) return null;
            i.* += 1;
            return a[i.*];
        }
    }.f;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        const eq = std.mem.eql;
        if (eq(u8, a, "-p") or eq(u8, a, "--publish")) {
            if (next(args, &i)) |v| try ports.append(arena, v);
        } else if (eq(u8, a, "-v") or eq(u8, a, "--volume")) {
            if (next(args, &i)) |v| {
                if (nvol > 0) std.debug.print("[contain] note: multiple -v given; only the last is mounted (single-volume support)\n", .{});
                parseVolume(&opts, v);
                nvol += 1;
            }
        } else if (eq(u8, a, "-e") or eq(u8, a, "--env")) {
            if (next(args, &i)) |v| try env.append(arena, v);
        } else if (eq(u8, a, "-m") or eq(u8, a, "--memory")) {
            if (next(args, &i)) |v| opts.mem = v; // overrides the CONTAIN_MEM fallback
        } else if (eq(u8, a, "--pull")) {
            // docker-style: --pull always|missing|never. A bare --pull means always.
            const val: ?PullPolicy = if (i + 1 < args.len) parsePullPolicy(args[i + 1]) else null;
            if (val) |p| {
                opts.pull_policy = p;
                i += 1;
            } else opts.pull_policy = .always;
        } else if (eq(u8, a, "-w") or eq(u8, a, "--workdir")) {
            opts.workdir = next(args, &i);
        } else if (eq(u8, a, "--entrypoint")) {
            opts.entrypoint = next(args, &i);
        } else if (eq(u8, a, "--name") or eq(u8, a, "-u") or eq(u8, a, "--user")) {
            _ = next(args, &i); // accepted for docker-compat; ignored (guest runs as root)
        } else if (eq(u8, a, "--rm")) {
            // no-op: a contain guest is always ephemeral.
        } else if (eq(u8, a, "--interactive") or eq(u8, a, "--tty")) {
            opts.interactive = true;
        } else if (eq(u8, a, "--detach")) {
            std.debug.print("[contain] note: -d/--detach is unsupported; running in the foreground\n", .{});
        } else if (shortBoolFlags(a)) |sf| {
            if (sf.interactive) opts.interactive = true;
            if (sf.detach) std.debug.print("[contain] note: -d/--detach is unsupported; running in the foreground\n", .{});
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("[contain] run: unsupported flag '{s}'\n", .{a});
            return null;
        } else {
            // First positional = IMAGE; everything after it is the command.
            opts.image = a;
            var rest = args[i + 1 ..];
            if (rest.len > 0 and std.mem.eql(u8, rest[0], "--")) rest = rest[1..];
            const cmd = try arena.alloc([]const u8, rest.len);
            for (rest, 0..) |t, k| cmd[k] = t;
            opts.command = cmd;
            break;
        }
    }

    if (opts.image.len == 0) return null;
    opts.env = try env.toOwnedSlice(arena);
    opts.ports = if (ports.items.len == 0) null else try std.mem.join(arena, ",", ports.items);
    return opts;
}

/// `contain run [opts] <image> [cmd...]` — pull a Docker Hub image and run it in
/// the guest. The unpacked rootfs is packed straight into the initramfs (rootfs
/// as root), so the image's own shell/loader/binaries run directly. The host-arch
/// kernel is chosen automatically (x86 -> vmlinux-contain, arm64 -> Image-arm64).
///
/// The image is cached under `cache_base` keyed by ref+arch: an unpacked `rootfs/`,
/// its `config.json`, and a `.complete` marker written only after a full pull. A
/// later run of the same ref reuses the cache with no network and no re-unpack
/// (`--pull always` forces a refresh; `--pull never` requires the cache). Layer/
/// config blobs are also cached by digest under `<cache_base>/blobs`.
/// `contain compose [-f FILE] [-p PROJECT] SUBCOMMAND [SERVICE...]` — a docker-
/// compose-style multi-service runner. SUBCOMMANDs: up (run services), build (build
/// services that declare `build:`), config (print the parsed model), down (stop —
/// see note). Each service becomes a `contain run` (or `contain build`) subprocess,
/// reusing the whole pipeline. NOTE: inter-service networking (reaching another
/// service by name) is NOT modeled — each service has its own userspace NAT and
/// host port-forwards; use published ports for host access.
fn cmdCompose(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8, cache_base: []const u8) !void {
    _ = cache_base;
    var file: ?[]const u8 = null;
    var project: []const u8 = "contain";
    var sub: []const u8 = "up";
    var only: std.ArrayListUnmanaged([]const u8) = .empty;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var i: usize = 0;
    var got_sub = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i < args.len) file = args[i];
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--project-name")) {
            i += 1;
            if (i < args.len) project = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            // ignore other global flags (e.g. -d) for now
        } else if (!got_sub) {
            sub = a;
            got_sub = true;
        } else {
            try only.append(arena, a);
        }
    }

    const cwd = std.Io.Dir.cwd();
    const path = file orelse findComposeFile(io) orelse {
        std.debug.print("contain compose: no compose file found (compose.yaml / docker-compose.yml)\n", .{});
        return;
    };
    const src = cwd.readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("contain compose: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(src);
    var comp = compose_mod.parse(gpa, src) catch |err| {
        std.debug.print("contain compose: parse error in '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer comp.deinit();

    // Order services so a service starts after the ones it depends_on.
    const order = try orderServices(arena, comp.services);

    const exe = try std.process.executablePathAlloc(io, arena);

    if (std.mem.eql(u8, sub, "config")) {
        for (comp.services) |*s| printService(s);
        return;
    }
    if (std.mem.eql(u8, sub, "down")) {
        std.debug.print("[compose] `up` runs in the foreground; stop it with Ctrl-C to bring the project down.\n", .{});
        return;
    }
    const do_build = std.mem.eql(u8, sub, "build");
    const do_up = std.mem.eql(u8, sub, "up");
    if (!do_build and !do_up) {
        std.debug.print("contain compose: unknown subcommand '{s}' (use: up | build | config | down)\n", .{sub});
        return;
    }

    // Build phase: every service that declares `build:` (both for `build` and as a
    // prerequisite of `up`).
    for (order) |idx| {
        const s = &comp.services[idx];
        if (!wanted(only.items, s.name)) continue;
        if (s.build) |ctx| {
            const tag = try std.fmt.allocPrint(arena, "{s}_{s}:latest", .{ project, s.name });
            std.debug.print("[compose] building service '{s}' -> {s}\n", .{ s.name, tag });
            var bargv: std.ArrayListUnmanaged([]const u8) = .empty;
            try bargv.appendSlice(arena, &.{ exe, "build", "-t", tag, ctx });
            const term = try spawnWait(io, arena, bargv.items);
            if (term != .exited or term.exited != 0) {
                std.debug.print("contain compose: build of '{s}' failed\n", .{s.name});
                return;
            }
        }
    }
    if (do_build) {
        std.debug.print("[compose] build complete.\n", .{});
        return;
    }

    // Up phase: spawn each service's `contain run`, then wait on them all. Output is
    // inherited (interleaved). Ctrl-C on the compose process tears down the group.
    var children: std.ArrayListUnmanaged(std.process.Child) = .empty;
    for (order) |idx| {
        const s = &comp.services[idx];
        if (!wanted(only.items, s.name)) continue;
        const image = if (s.build != null)
            try std.fmt.allocPrint(arena, "{s}_{s}:latest", .{ project, s.name })
        else
            (s.image orelse {
                std.debug.print("contain compose: service '{s}' has neither image nor build\n", .{s.name});
                continue;
            });
        var rargv: std.ArrayListUnmanaged([]const u8) = .empty;
        try rargv.appendSlice(arena, &.{ exe, "run", "--name", s.name });
        for (s.ports.items) |p| try rargv.appendSlice(arena, &.{ "-p", p });
        for (s.volumes.items) |v| try rargv.appendSlice(arena, &.{ "-v", v });
        for (s.env.items) |e| try rargv.appendSlice(arena, &.{ "-e", e });
        try rargv.append(arena, image);
        if (s.command) |c| for (try shellSplit(arena, c)) |w| try rargv.append(arena, w);

        std.debug.print("[compose] starting service '{s}' ({s})\n", .{ s.name, image });
        const child = std.process.spawn(io, .{ .argv = rargv.items }) catch |err| {
            std.debug.print("contain compose: failed to start '{s}': {s}\n", .{ s.name, @errorName(err) });
            continue;
        };
        try children.append(arena, child);
    }

    for (children.items) |*ch| _ = ch.wait(io) catch {};
    std.debug.print("[compose] all services exited.\n", .{});
}

fn wanted(only: []const []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    for (only) |o| if (std.mem.eql(u8, o, name)) return true;
    return false;
}

fn spawnWait(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8) !std.process.Child.Term {
    _ = arena;
    var child = try std.process.spawn(io, .{ .argv = argv });
    return child.wait(io);
}

/// Topologically order services so dependencies precede dependents (best effort;
/// falls back to declaration order on a cycle).
fn orderServices(arena: std.mem.Allocator, services: []compose_mod.Service) ![]usize {
    const n = services.len;
    var started = try arena.alloc(bool, n);
    @memset(started, false);
    var order: std.ArrayListUnmanaged(usize) = .empty;
    var progress = true;
    while (order.items.len < n and progress) {
        progress = false;
        for (services, 0..) |*s, idx| {
            if (started[idx]) continue;
            var ready = true;
            for (s.depends_on.items) |dep| {
                // Is the dependency already ordered?
                var found = false;
                for (order.items) |oi| {
                    if (std.mem.eql(u8, services[oi].name, dep)) found = true;
                }
                // Only block on deps that actually exist in this compose file.
                var exists = false;
                for (services) |*t| if (std.mem.eql(u8, t.name, dep)) {
                    exists = true;
                };
                if (exists and !found) ready = false;
            }
            if (ready) {
                started[idx] = true;
                try order.append(arena, idx);
                progress = true;
            }
        }
    }
    // Cycle fallback: append whatever's left in declaration order.
    for (0..n) |idx| if (!started[idx]) try order.append(arena, idx);
    return order.items;
}

fn findComposeFile(io: std.Io) ?[]const u8 {
    const candidates = [_][]const u8{ "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml" };
    for (candidates) |c| {
        if (std.Io.Dir.cwd().statFile(io, c, .{})) |_| return c else |_| {}
    }
    return null;
}

fn printService(s: *const compose_mod.Service) void {
    std.debug.print("service {s}:\n", .{s.name});
    if (s.image) |im| std.debug.print("  image: {s}\n", .{im});
    if (s.build) |b| std.debug.print("  build: {s}\n", .{b});
    if (s.command) |c| std.debug.print("  command: {s}\n", .{c});
    for (s.ports.items) |p| std.debug.print("  port: {s}\n", .{p});
    for (s.volumes.items) |v| std.debug.print("  volume: {s}\n", .{v});
    for (s.env.items) |e| std.debug.print("  env: {s}\n", .{e});
    for (s.depends_on.items) |d| std.debug.print("  depends_on: {s}\n", .{d});
}

/// Split a command string into whitespace-separated words (no quote handling; the
/// guest re-parses anyway via the run pipeline's shell quoting).
fn shellSplit(a: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |w| try list.append(a, try a.dupe(u8, w));
    return list.toOwnedSlice(a);
}

fn cmdRunOci(gpa: std.mem.Allocator, io: std.Io, opts: RunOpts, cache_base: []const u8) !void {
    var tio = std.Io.Threaded.init(gpa, .{});
    defer tio.deinit();
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const arch = registry.Arch.hostDefault();
    const entry = try registry.cacheEntryPath(arena, cache_base, opts.image, arch);
    const rootfs_dir = try std.fmt.allocPrint(arena, "{s}/rootfs", .{entry});
    const cfg_path = try std.fmt.allocPrint(arena, "{s}/config.json", .{entry});
    const complete = try std.fmt.allocPrint(arena, "{s}/.complete", .{entry});
    const blobs_dir = try std.fmt.allocPrint(arena, "{s}/blobs", .{cache_base});
    const cwd = std.Io.Dir.cwd();

    // A cache hit needs the `.complete` marker (only written after a full pull), so
    // a crashed/partial unpack is never mistaken for a usable image.
    const cached = opts.pull_policy != .always and pathExists(io, complete);
    var cfg: registry.ImageConfig = undefined;
    if (cached) {
        cfg = registry.parseConfigFile(arena, gpa, io, cfg_path) catch |err| {
            std.debug.print("contain: cached image config unreadable ({s}); refetch with `--pull always`\n", .{@errorName(err)});
            return;
        };
        std.debug.print("[oci] using cached image '{s}' ({s})\n", .{ opts.image, entry });
    } else if (opts.pull_policy == .never) {
        std.debug.print("contain: image '{s}' not cached and `--pull never`; run it once online first\n", .{opts.image});
        return;
    } else {
        // Fresh pull: drop any stale/partial entry so two images never merge.
        cwd.deleteTree(io, entry) catch {};
        cwd.createDirPath(io, rootfs_dir) catch {};
        cfg = registry.pull(gpa, arena, tio.io(), opts.image, rootfs_dir, arch, .{
            .cache_dir = blobs_dir,
            .config_out = cfg_path,
        }) catch |err| {
            std.debug.print("contain: pull failed: {s}\n", .{@errorName(err)});
            return;
        };
        cwd.writeFile(io, .{ .sub_path = complete, .data = "" }) catch {};
        std.debug.print("[oci] cached image at {s}\n", .{entry});
    }

    const init_script = try buildOciInit(arena, cfg, opts, hostEpochSecs(io));
    const kernel = kernel_fetch.defaultKernelPath();
    const input: []const u8 = if (opts.interactive) "tty" else "-";

    // Two ways to give the guest its root filesystem:
    //
    //  (a) rootfs-over-virtiofs (DEFAULT on x86): mount `rootfs_dir` as the guest's
    //      real root over virtio-fs and demand-page it. The whole image never has to
    //      be resident in guest RAM — a huge memory win over packing it into an
    //      in-RAM initramfs. The generated init is written into the rootfs as
    //      `/.contain-init` (the kernel's `init=`). No cpio, no read-back.
    //
    //  (b) legacy initramfs pack (arm64, or CONTAIN_ROOTFS=initramfs): pack the
    //      rootfs + `/init` into one cpio and boot it as the initramfs root. Used
    //      until the arm64 FUSE guest kernel ships (its release kernel has no
    //      CONFIG_VIRTIO_FS), and as an escape hatch on x86.
    if (useVirtiofsRoot()) {
        // Unique init filename so concurrent guests sharing this cached image rootfs
        // (e.g. `contain compose up` of two containers off the same image) don't
        // clobber each other's init file on disk.
        const guest_init = try std.fmt.allocPrint(arena, "/.contain-init-{x}", .{pidToken()});
        machine_mod.rootfs_init_path = guest_init;
        const init_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ rootfs_dir, guest_init });
        try cwd.writeFile(io, .{ .sub_path = init_path, .data = init_script });
        std.debug.print("[contain] rootfs-over-virtiofs: booting '{s}' (demand-paged root, no initramfs)\n", .{opts.image});
        try cmdBoot(gpa, io, kernel, null, input, null, opts.volume_host, opts.ports, opts.accel_override, opts.mem, null, rootfs_dir);
        return;
    }

    // Legacy: pack the rootfs + generated /init into one initramfs cpio.
    std.debug.print("[contain] packing rootfs into initramfs...\n", .{});
    var cw = cpio.Writer.init(gpa);
    defer cw.deinit();
    var root = try std.Io.Dir.cwd().openDir(io, rootfs_dir, .{ .iterate = true });
    defer root.close(io);
    try rootfs.packDir(io, &cw, gpa, root);
    try cw.addFile("init", cpio.MODE_FILE, init_script);
    try cw.finish();
    std.debug.print("[contain] initramfs {d} bytes; booting OCI image '{s}'\n", .{ cw.bytes().len, opts.image });
    try cmdBoot(gpa, io, kernel, null, input, null, opts.volume_host, opts.ports, opts.accel_override, opts.mem, cw.bytes(), null);
}

/// Set from CONTAIN_ROOTFS=initramfs in main() (where the env map is available).
var force_initramfs_root: bool = false;

/// Whether `contain run` mounts the image rootfs over virtio-fs (demand-paged,
/// memory-lean) vs. packing it into an in-RAM initramfs. Default: yes on x86
/// (ships a FUSE guest kernel); arm64 falls back until its FUSE kernel is released.
/// CONTAIN_ROOTFS=initramfs forces the legacy pack.
fn useVirtiofsRoot() bool {
    if (force_initramfs_root) return false;
    return builtin.cpu.arch == .x86_64;
}

/// Accumulated build state -> the output image config.
const BuildConfig = struct {
    env: std.ArrayListUnmanaged([]const u8) = .empty,
    workdir: []const u8 = "",
    cmd: []const []const u8 = &.{},
    entrypoint: []const []const u8 = &.{},
    user: []const u8 = "",
    exposed: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// `contain build [-t NAME[:TAG]] [-f DOCKERFILE] CONTEXT` — build an image from a
/// Dockerfile using the core instruction set (FROM/RUN/COPY/ADD/ENV/WORKDIR/CMD/
/// ENTRYPOINT/ARG/…); no BuildKit. Each RUN executes inside a contain guest with
/// the build rootfs mounted rw over virtio-fs so steps compose; COPY/ADD copy from
/// the build context host-side; metadata accumulates into the output config. The
/// result is stored in the image cache under NAME so `contain run NAME` runs it.
fn cmdBuild(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8, cache_base: []const u8) !void {
    if (builtin.cpu.arch != .x86_64) {
        std.debug.print("contain build: only x86 hosts are supported for now (the arm64 FUSE guest kernel isn't released yet)\n", .{});
        return;
    }
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Parse docker-style args: -t/--tag, -f/--file, positional CONTEXT.
    var tag: []const u8 = "contain-build:latest";
    var dockerfile: ?[]const u8 = null;
    var context: []const u8 = ".";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--tag")) {
            i += 1;
            if (i < args.len) tag = args[i];
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i < args.len) dockerfile = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            // Unknown flags (e.g. --no-cache, --build-arg) are accepted-and-ignored
            // so common invocations don't hard-fail. --build-arg takes a value.
            if (std.mem.eql(u8, a, "--build-arg")) i += 1;
        } else {
            context = a;
        }
    }

    const cwd = std.Io.Dir.cwd();
    const df_path = dockerfile orelse try std.fmt.allocPrint(arena, "{s}/Dockerfile", .{context});
    const df_src = cwd.readFileAlloc(io, df_path, gpa, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("contain build: cannot read Dockerfile '{s}': {s}\n", .{ df_path, @errorName(err) });
        return;
    };
    defer gpa.free(df_src);

    var df = build_mod.parse(gpa, df_src) catch |err| {
        std.debug.print("contain build: Dockerfile parse error: {s}\n", .{@errorName(err)});
        return;
    };
    defer df.deinit();
    if (df.instructions.len == 0 or df.instructions[0].op != .from) {
        std.debug.print("contain build: the first instruction must be FROM\n", .{});
        return;
    }

    const arch = registry.Arch.hostDefault();
    const entry = try registry.cacheEntryPath(arena, cache_base, tag, arch);
    const rootfs_dir = try std.fmt.allocPrint(arena, "{s}/rootfs", .{entry});
    const cfg_path = try std.fmt.allocPrint(arena, "{s}/config.json", .{entry});
    const complete = try std.fmt.allocPrint(arena, "{s}/.complete", .{entry});
    const blobs_dir = try std.fmt.allocPrint(arena, "{s}/blobs", .{cache_base});

    // Prepare + read the guest kernel once for all RUN steps.
    const kernel_path = kernel_fetch.defaultKernelPath();
    _ = kernel_fetch.ensureKernel(gpa, io, kernel_path) catch {};
    const vmlinux = cwd.readFileAlloc(io, kernel_path, gpa, .limited(128 * 1024 * 1024)) catch |err| {
        std.debug.print("contain build: cannot read guest kernel '{s}': {s}\n", .{ kernel_path, @errorName(err) });
        return;
    };
    defer gpa.free(vmlinux);

    var bc = BuildConfig{};

    var step: usize = 0;
    for (df.instructions) |ins| {
        switch (ins.op) {
            .from => {
                const base = build_mod.fromImage(ins.args);
                std.debug.print("[build] FROM {s}\n", .{base});
                cwd.deleteTree(io, entry) catch {};
                cwd.createDirPath(io, rootfs_dir) catch {};
                var tio = std.Io.Threaded.init(gpa, .{});
                defer tio.deinit();
                const base_cfg = registry.pull(gpa, arena, tio.io(), base, rootfs_dir, arch, .{
                    .cache_dir = blobs_dir,
                }) catch |err| {
                    std.debug.print("contain build: pulling base '{s}' failed: {s}\n", .{ base, @errorName(err) });
                    return;
                };
                // Seed the output config from the base image.
                for (base_cfg.env) |e| try bc.env.append(arena, try arena.dupe(u8, e));
                bc.workdir = try arena.dupe(u8, base_cfg.working_dir);
                bc.cmd = base_cfg.cmd;
                bc.entrypoint = base_cfg.entrypoint;
                bc.user = try arena.dupe(u8, base_cfg.user);
            },
            .run => {
                step += 1;
                const parsed = try build_mod.parseExecOrShell(arena, ins.args);
                const shell_cmd = if (parsed.is_exec) try joinArgv(arena, parsed.argv) else parsed.argv[0];
                std.debug.print("[build] RUN {s}\n", .{shell_cmd});
                const init_script = try buildStepInit(arena, bc.env.items, nullIfEmpty(bc.workdir), shell_cmd, hostEpochSecs(io));
                const init_path = try std.fmt.allocPrint(arena, "{s}/.contain-init", .{rootfs_dir});
                try cwd.writeFile(io, .{ .sub_path = init_path, .data = init_script });
                const status_path = try std.fmt.allocPrint(arena, "{s}/.contain-build-status", .{rootfs_dir});
                cwd.deleteFile(io, status_path) catch {};
                bootBuildStep(gpa, io, vmlinux, rootfs_dir) catch |err| {
                    std.debug.print("contain build: RUN step failed to boot: {s}\n", .{@errorName(err)});
                    return;
                };
                const st = cwd.readFileAlloc(io, status_path, gpa, .limited(64)) catch {
                    std.debug.print("contain build: RUN did not report an exit status (guest crashed?)\n", .{});
                    return;
                };
                defer gpa.free(st);
                const code = std.fmt.parseInt(u32, std.mem.trim(u8, st, " \t\r\n"), 10) catch 1;
                if (code != 0) {
                    std.debug.print("contain build: RUN '{s}' exited with status {d}\n", .{ shell_cmd, code });
                    return;
                }
            },
            .copy, .add => {
                const words = try build_mod.splitWords(arena, ins.args);
                // Drop any --from=/--chown= flags (BuildKit/COPY options we don't model).
                var srcs: std.ArrayListUnmanaged([]const u8) = .empty;
                var dest: []const u8 = "";
                for (words) |w| {
                    if (w.len > 0 and w[0] == '-') continue;
                    try srcs.append(arena, w);
                }
                if (srcs.items.len < 2) {
                    std.debug.print("contain build: {s} needs at least a source and a destination\n", .{@tagName(ins.op)});
                    return;
                }
                dest = srcs.items[srcs.items.len - 1];
                const sources = srcs.items[0 .. srcs.items.len - 1];
                copyIntoRootfs(io, gpa, arena, context, rootfs_dir, sources, dest) catch |err| {
                    std.debug.print("contain build: {s} failed: {s}\n", .{ @tagName(ins.op), @errorName(err) });
                    return;
                };
                std.debug.print("[build] {s} {d} path(s) -> {s}\n", .{ @tagName(ins.op), sources.len, dest });
            },
            .env => {
                const pairs = try build_mod.parseEnv(arena, ins.args);
                for (pairs) |p| try bc.env.append(arena, try arena.dupe(u8, p));
            },
            .workdir => {
                bc.workdir = try arena.dupe(u8, std.mem.trim(u8, ins.args, " \t"));
                // Create the workdir in the rootfs so a later `cd` succeeds.
                const wd_abs = try std.fmt.allocPrint(arena, "{s}{s}", .{ rootfs_dir, bc.workdir });
                cwd.createDirPath(io, wd_abs) catch {};
            },
            .cmd => {
                const parsed = try build_mod.parseExecOrShell(arena, ins.args);
                bc.cmd = if (parsed.is_exec) parsed.argv else try shellArgv(arena, parsed.argv[0]);
            },
            .entrypoint => {
                const parsed = try build_mod.parseExecOrShell(arena, ins.args);
                bc.entrypoint = if (parsed.is_exec) parsed.argv else try shellArgv(arena, parsed.argv[0]);
            },
            .user => bc.user = try arena.dupe(u8, std.mem.trim(u8, ins.args, " \t")),
            .expose => try bc.exposed.append(arena, try arena.dupe(u8, ins.args)),
            .arg, .label => {}, // accepted, not acted on (ARG defaults/LABEL metadata)
            .unsupported => std.debug.print("[build] (skipping unsupported instruction at line {d})\n", .{ins.line}),
        }
    }

    // Write the output image config (OCI image-config JSON) + the .complete marker,
    // and drop the transient build init so it doesn't ship in the image.
    cwd.deleteFile(io, try std.fmt.allocPrint(arena, "{s}/.contain-init", .{rootfs_dir})) catch {};
    cwd.deleteFile(io, try std.fmt.allocPrint(arena, "{s}/.contain-build-status", .{rootfs_dir})) catch {};
    const cfg_json = try renderImageConfig(arena, arch, bc);
    try cwd.writeFile(io, .{ .sub_path = cfg_path, .data = cfg_json });
    // Also drop it inside the rootfs (embedded config) for the library boot path.
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rootfs_dir, registry.embedded_config_name }), .data = cfg_json });
    try cwd.writeFile(io, .{ .sub_path = complete, .data = "" });
    std.debug.print("[build] built image '{s}'  ->  run it with: contain run {s}\n", .{ tag, tag });
}

fn nullIfEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

/// The host's current wall-clock time in Unix seconds. Baked into the guest init
/// (`date -s @<epoch>`) because the x86 guest has no working RTC (the emulated CMOS
/// presents a fixed time and the kernel's rtc_cmos probe fails), leaving the guest
/// clock near the epoch — which makes TLS certificate validation fail (apk/pip/npm
/// over HTTPS report "certificate not trusted"). Setting a sane clock fixes it.
fn hostEpochSecs(io: std.Io) i64 {
    const ns = std.Io.Clock.now(.real, io).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

/// This process's OS process id — a per-process unique token (used to name each
/// run's guest init file so concurrent guests off one shared image rootfs don't
/// collide). Each `contain run` is its own process, incl. `compose`'s children.
fn pidToken() u32 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

/// Wrap a shell-form command string as `["/bin/sh","-c",cmd]` (Docker's CMD/
/// ENTRYPOINT shell form).
fn shellArgv(a: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, 3);
    out[0] = "/bin/sh";
    out[1] = "-c";
    out[2] = try a.dupe(u8, cmd);
    return out;
}

/// Join an exec-form argv into a single shell command string (best-effort; args are
/// space-joined — adequate for the common RUN ["sh","-c","…"] shape).
fn joinArgv(a: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (argv, 0..) |arg, idx| {
        if (idx != 0) try buf.append(a, ' ');
        try buf.appendSlice(a, arg);
    }
    return buf.items;
}

/// The `/.contain-init` a RUN step boots: bring up mounts/console/networking, apply
/// the accumulated ENV + WORKDIR, run the command, record its exit status to a
/// host-readable file, and power off.
fn buildStepInit(arena: std.mem.Allocator, env: []const []const u8, workdir: ?[]const u8, command: []const u8, epoch: i64) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print(
        \\#!/bin/sh
        \\export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=linux
        \\mkdir -p /proc /sys /dev 2>/dev/null
        \\mount -t proc proc /proc 2>/dev/null
        \\mount -t sysfs sysfs /sys 2>/dev/null
        \\mount -t devtmpfs devtmpfs /dev 2>/dev/null
        \\exec </dev/console >/dev/console 2>&1
        \\date -s @{d} >/dev/null 2>&1 || date -u -s "@{d}" >/dev/null 2>&1
        \\
    , .{ epoch, epoch });
    try w.writeAll(
        \\ip addr add 127.0.0.1/8 dev lo 2>/dev/null; ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up 2>/dev/null
        \\ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
        \\ip link set eth0 up 2>/dev/null
        \\ip route add default via 10.0.2.2 2>/dev/null || route add default gw 10.0.2.2 2>/dev/null
        \\echo "nameserver 10.0.2.3" > /etc/resolv.conf 2>/dev/null
        \\
    );
    for (env) |e| try w.print("export \"{s}\"\n", .{e});
    if (workdir) |d| try w.print("mkdir -p {s} 2>/dev/null; cd {s} 2>/dev/null\n", .{ d, d });
    // Run the RUN command through /bin/sh; record its status for the host.
    try w.writeAll("/bin/sh -c ");
    try shellQuote(w, command);
    try w.writeAll("\n__st=$?\n");
    try w.writeAll("echo $__st > /.contain-build-status 2>/dev/null\nsync\n");
    try w.writeAll(rootfs.poweroff_seq);
    return aw.written();
}

/// Copy build-context `sources` (relative to `context`) into `dest` inside
/// `rootfs_dir`. If dest ends in '/' or there are multiple sources, dest is a
/// directory; otherwise a file rename. Recursive for directories.
fn copyIntoRootfs(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, context: []const u8, rootfs_dir: []const u8, sources: []const []const u8, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const dest_is_dir = dest.len == 0 or dest[dest.len - 1] == '/' or sources.len > 1 or std.mem.eql(u8, dest, ".");
    var dclean = dest;
    while (dclean.len > 0 and dclean[0] == '/') dclean = dclean[1..];
    const dest_abs_base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rootfs_dir, dclean });
    if (dest_is_dir) cwd.createDirPath(io, dest_abs_base) catch {};
    for (sources) |src| {
        const src_abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ context, src });
        const base = std.fs.path.basename(src);
        const dst_abs = if (dest_is_dir)
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest_abs_base, base })
        else
            dest_abs_base;
        try copyTree(io, gpa, arena, src_abs, dst_abs);
    }
}

/// Recursively copy a host file or directory tree from `src` to `dst`.
fn copyTree(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, src, .{}) catch |err| {
        std.debug.print("contain build: cannot stat '{s}': {s}\n", .{ src, @errorName(err) });
        return err;
    };
    if (st.kind == .directory) {
        cwd.createDirPath(io, dst) catch {};
        var dir = try cwd.openDir(io, src, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            const child_src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src, e.name });
            const child_dst = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dst, e.name });
            try copyTree(io, gpa, arena, child_src, child_dst);
        }
    } else {
        // Ensure the destination's parent directory exists (e.g. COPY x /a/b/x
        // where /a/b isn't in the base image yet).
        if (std.fs.path.dirname(dst)) |parent| cwd.createDirPath(io, parent) catch {};
        const data = try cwd.readFileAlloc(io, src, gpa, .limited(2 * 1024 * 1024 * 1024));
        defer gpa.free(data);
        try cwd.writeFile(io, .{ .sub_path = dst, .data = data });
    }
}

/// Serialize the accumulated build config as an OCI image-config JSON (the shape
/// registry.parseConfig reads back). Includes `architecture`/`os` so the pull-side
/// arch check is satisfied if this image is ever inspected that way.
fn renderImageConfig(arena: std.mem.Allocator, arch: registry.Arch, bc: BuildConfig) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print("{{\"architecture\":\"{s}\",\"os\":\"linux\",\"config\":{{", .{arch.str()});
    try w.writeAll("\"Env\":");
    try writeJsonStrArray(w, bc.env.items);
    try w.writeAll(",\"Cmd\":");
    try writeJsonStrArray(w, bc.cmd);
    try w.writeAll(",\"Entrypoint\":");
    try writeJsonStrArray(w, bc.entrypoint);
    try w.print(",\"WorkingDir\":", .{});
    try writeJsonString(w, bc.workdir);
    try w.writeAll(",\"User\":");
    try writeJsonString(w, bc.user);
    try w.writeAll("}}");
    return aw.written();
}

fn writeJsonStrArray(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeByte('[');
    for (items, 0..) |s, idx| {
        if (idx != 0) try w.writeByte(',');
        try writeJsonString(w, s);
    }
    try w.writeByte(']');
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Derive a default rootfs dir from an image ref: the name after the last '/',
/// with the ':tag' stripped, plus "-rootfs". e.g. "node:22-alpine" -> "node-rootfs",
/// "library/alpine" -> "alpine-rootfs".
fn defaultRootfsDir(arena: std.mem.Allocator, image_ref: []const u8) ![]const u8 {
    var name = image_ref;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |s| name = name[s + 1 ..];
    if (std.mem.indexOfScalar(u8, name, ':')) |c| name = name[0..c];
    if (name.len == 0) name = "image";
    return std.fmt.allocPrint(arena, "{s}-rootfs", .{name});
}

/// `contain pull <image> [dest-dir] [arch]` — pull a public Docker Hub image and
/// unpack its rootfs (from-scratch registry client; no external tools). dest-dir
/// defaults to ./<image>-rootfs (docker-style `pull <image>`).
fn cmdPull(gpa: std.mem.Allocator, image_ref: []const u8, dest_arg: ?[]const u8, arch_arg: ?[]const u8) !void {
    // A dedicated threaded Io for the host network + TLS (like the NAT uses).
    var tio = std.Io.Threaded.init(gpa, .{});
    defer tio.deinit();
    const pio = tio.io();

    const arch: registry.Arch = if (arch_arg) |a|
        (if (std.mem.eql(u8, a, "amd64")) .amd64 else if (std.mem.eql(u8, a, "arm64")) .arm64 else registry.Arch.hostDefault())
    else
        registry.Arch.hostDefault();

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();

    const dest = dest_arg orelse try defaultRootfsDir(arena_inst.allocator(), image_ref);
    std.debug.print("[contain] unpacking '{s}' rootfs to ./{s}\n", .{ image_ref, dest });

    const cfg = registry.pull(gpa, arena_inst.allocator(), pio, image_ref, dest, arch, .{}) catch |err| {
        std.debug.print("contain: pull failed: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("\n[oci] image config:\n  entrypoint:", .{});
    for (cfg.entrypoint) |e| std.debug.print(" {s}", .{e});
    std.debug.print("\n  cmd:       ", .{});
    for (cfg.cmd) |e| std.debug.print(" {s}", .{e});
    std.debug.print("\n  workdir:   {s}\n  user:      {s}\n  env:\n", .{ cfg.working_dir, cfg.user });
    for (cfg.env) |e| std.debug.print("    {s}\n", .{e});
}

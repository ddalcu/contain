const std = @import("std");
const main = @import("main.zig");
const registry = @import("oci/registry.zig");
const Gicv2 = @import("devices/gicv2.zig").Gicv2;
const IrqLine = @import("devices/gicv2.zig").IrqLine;
const Uart16550 = @import("devices/uart_16550.zig").Uart16550;
const Pl011 = @import("devices/uart_pl011.zig").Pl011;
const Machine = @import("machine.zig").Machine;
const pvh = @import("x86/pvh.zig");
const nat = @import("net/nat.zig");

const ram_base: u64 = 0x4000_0000;

// x86-microvm emulated devices (used by the WHP backend).
test {
    _ = @import("devices/ioapic.zig");
    _ = @import("devices/i8259.zig");
    _ = @import("devices/cmos.zig");
    _ = @import("kernel_fetch.zig");
    _ = @import("session.zig");
}

test "run args: docker-style flags, positional image + command, volume/env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // contain run -it -p 8080:80 -p 5173:5173 -v ./code:/app -e FOO=bar -w /app \
    //   --rm --name x -u root --entrypoint /bin/sh node:22-alpine -c "echo hi"
    const args = [_][:0]const u8{
        "-it",            "-p",          "8080:80", "-p",           "5173:5173",
        "-v",             "./code:/app", "-e",      "FOO=bar",      "-w",
        "/app",           "--rm",        "--name",  "x",            "-u",
        "root",           "--entrypoint", "/bin/sh", "node:22-alpine", "-c",
        "echo hi",
    };
    const opts = (try main.parseRunArgs(a, &args, null, null)).?;
    try std.testing.expectEqualStrings("node:22-alpine", opts.image);
    try std.testing.expect(opts.interactive);
    try std.testing.expectEqualStrings("8080:80,5173:5173", opts.ports.?); // both -p, comma-joined
    try std.testing.expectEqualStrings("./code", opts.volume_host.?);
    try std.testing.expectEqualStrings("/app", opts.volume_guest); // mounts at the container path
    try std.testing.expectEqual(@as(usize, 1), opts.env.len);
    try std.testing.expectEqualStrings("FOO=bar", opts.env[0]);
    try std.testing.expectEqualStrings("/app", opts.workdir.?);
    try std.testing.expectEqualStrings("/bin/sh", opts.entrypoint.?);
    // Everything after the image is the command (flags after the image are NOT options).
    try std.testing.expectEqual(@as(usize, 2), opts.command.len);
    try std.testing.expectEqualStrings("-c", opts.command[0]);
    try std.testing.expectEqualStrings("echo hi", opts.command[1]);
}

test "run args: bare image, no command; missing image -> null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = [_][:0]const u8{"alpine"};
    const o = (try main.parseRunArgs(a, &one, null, null)).?;
    try std.testing.expectEqualStrings("alpine", o.image);
    try std.testing.expectEqual(@as(usize, 0), o.command.len);
    try std.testing.expect(!o.interactive);
    try std.testing.expect(o.volume_host == null);

    const none = [_][:0]const u8{"-it"}; // no image
    try std.testing.expect((try main.parseRunArgs(a, &none, null, null)) == null);

    const bad = [_][:0]const u8{ "--bogus", "alpine" }; // unsupported flag
    try std.testing.expect((try main.parseRunArgs(a, &bad, null, null)) == null);
}

test "mem: parseMemSize accepts byte counts and K/M/G suffixes" {
    try std.testing.expectEqual(@as(?usize, 2048), main.parseMemSize("2048"));
    try std.testing.expectEqual(@as(?usize, 512 * 1024), main.parseMemSize("512K"));
    try std.testing.expectEqual(@as(?usize, 512 * 1024 * 1024), main.parseMemSize("512M"));
    try std.testing.expectEqual(@as(?usize, 4 * 1024 * 1024 * 1024), main.parseMemSize("4G"));
    try std.testing.expectEqual(@as(?usize, 4 * 1024 * 1024 * 1024), main.parseMemSize("4g")); // lowercase
    try std.testing.expectEqual(@as(?usize, null), main.parseMemSize("")); // empty
    try std.testing.expectEqual(@as(?usize, null), main.parseMemSize("big")); // not a number
    try std.testing.expectEqual(@as(?usize, null), main.parseMemSize("1.5G")); // no fractions
}

test "mem: ramForInitrd sizes for the unpack peak, floored at the default" {
    // Small/no initramfs -> never below the 2 GB default.
    try std.testing.expectEqual(main.default_ram, main.ramForInitrd(0));
    try std.testing.expectEqual(main.default_ram, main.ramForInitrd(64 * 1024 * 1024));
    // A 1.5 GB rootfs needs room for the reserved initrd + its page-inflated extract.
    const big: usize = 1_570_922_600; // the ddalcu/agent-orcha initramfs
    const ram = main.ramForInitrd(big);
    try std.testing.expect(ram >= big * 3); // reserved initrd + inflated ramfs extract
    try std.testing.expect(ram > main.default_ram); // and it grew past the floor
}

test "run args: -m/--memory sets opts.mem; env is the fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_flag = [_][:0]const u8{ "-m", "4G", "alpine" };
    const of = (try main.parseRunArgs(a, &with_flag, null, "2G")).?; // flag wins over env
    try std.testing.expectEqualStrings("4G", of.mem.?);

    const no_flag = [_][:0]const u8{"alpine"};
    const oe = (try main.parseRunArgs(a, &no_flag, null, "2G")).?; // env fallback
    try std.testing.expectEqualStrings("2G", oe.mem.?);

    const oz = (try main.parseRunArgs(a, &no_flag, null, null)).?; // neither -> null
    try std.testing.expect(oz.mem == null);
}

test "pull: parsePullPolicy maps the docker-style values" {
    try std.testing.expectEqual(main.PullPolicy.always, main.parsePullPolicy("always").?);
    try std.testing.expectEqual(main.PullPolicy.missing, main.parsePullPolicy("missing").?);
    try std.testing.expectEqual(main.PullPolicy.never, main.parsePullPolicy("never").?);
    try std.testing.expect(main.parsePullPolicy("alpine") == null); // not a policy -> not consumed
}

test "run args: --pull policy (value, bare, and default)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def = [_][:0]const u8{"alpine"};
    try std.testing.expectEqual(main.PullPolicy.missing, (try main.parseRunArgs(a, &def, null, null)).?.pull_policy);

    const always = [_][:0]const u8{ "--pull", "always", "alpine" };
    const oa = (try main.parseRunArgs(a, &always, null, null)).?;
    try std.testing.expectEqual(main.PullPolicy.always, oa.pull_policy);
    try std.testing.expectEqualStrings("alpine", oa.image); // "always" consumed, not the image

    const never = [_][:0]const u8{ "--pull", "never", "alpine" };
    try std.testing.expectEqual(main.PullPolicy.never, (try main.parseRunArgs(a, &never, null, null)).?.pull_policy);

    // Bare --pull (next token is the image) means "always"; the image is preserved.
    const bare = [_][:0]const u8{ "--pull", "alpine" };
    const ob = (try main.parseRunArgs(a, &bare, null, null)).?;
    try std.testing.expectEqual(main.PullPolicy.always, ob.pull_policy);
    try std.testing.expectEqualStrings("alpine", ob.image);
}

test "pvh: ABI struct sizes match the Xen start_info layout" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(pvh.HvmStartInfo));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(pvh.HvmModlistEntry));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(pvh.HvmMemmapEntry));
}

test "pvh: find the PHYS32_ENTRY in an ELF note blob" {
    // A non-PVH note first (name "GNU", type 1), then the PVH note.
    var notes: [64]u8 = undefined;
    var n: usize = 0;
    const put32 = struct {
        fn f(buf: []u8, i: *usize, v: u32) void {
            std.mem.writeInt(u32, buf[i.*..][0..4], v, .little);
            i.* += 4;
        }
    }.f;
    // GNU note: namesz=4 descsz=4 type=1 name="GNU\0" desc=0xdeadbeef
    put32(&notes, &n, 4);
    put32(&notes, &n, 4);
    put32(&notes, &n, 1);
    @memcpy(notes[n..][0..4], "GNU\x00");
    n += 4;
    put32(&notes, &n, 0xdeadbeef);
    // Xen PVH note: namesz=4 descsz=4 type=18 name="Xen\0" desc=0x00100000
    put32(&notes, &n, 4);
    put32(&notes, &n, 4);
    put32(&notes, &n, 18);
    @memcpy(notes[n..][0..4], "Xen\x00");
    n += 4;
    put32(&notes, &n, 0x0010_0000);

    try std.testing.expectEqual(@as(?u32, 0x0010_0000), pvh.findPvhEntryInNotes(notes[0..n]));
    try std.testing.expectEqual(@as(?u32, null), pvh.findPvhEntryInNotes(notes[0..12])); // header only
}

test "pvh: buildStartInfo writes magic, cmdline, memmap and module" {
    const ram = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    const si_pa = pvh.buildStartInfo(ram, .{
        .ram_base = ram_base,
        .ram_size = 512 * 1024 * 1024,
        .cmdline = "console=ttyS0 rdinit=/init",
        .initrd_paddr = 0x4800_0000,
        .initrd_size = 0x1000,
    });
    try std.testing.expectEqual(ram_base + pvh.Layout.start_info, si_pa);

    const si: *align(1) pvh.HvmStartInfo = @ptrCast(&ram[pvh.Layout.start_info]);
    try std.testing.expectEqual(pvh.XEN_HVM_START_MAGIC, si.magic);
    try std.testing.expectEqual(@as(u32, 1), si.nr_modules);
    try std.testing.expectEqual(ram_base + pvh.Layout.cmdline, si.cmdline_paddr);
    try std.testing.expectEqual(ram_base + pvh.Layout.memmap, si.memmap_paddr);
    try std.testing.expectEqual(ram_base + pvh.Layout.modlist, si.modlist_paddr);
    try std.testing.expectEqual(@as(u32, 1), si.memmap_entries);

    const cmd = std.mem.sliceTo(ram[pvh.Layout.cmdline..], 0);
    try std.testing.expectEqualStrings("console=ttyS0 rdinit=/init", cmd);

    const mod: *align(1) pvh.HvmModlistEntry = @ptrCast(&ram[pvh.Layout.modlist]);
    try std.testing.expectEqual(@as(u64, 0x4800_0000), mod.paddr);
    try std.testing.expectEqual(@as(u64, 0x1000), mod.size);
}

test "pvh: loadKernel places PT_LOAD at p_paddr (not the high p_vaddr)" {
    // A Linux vmlinux's PT_LOAD has a high kernel-virtual p_vaddr
    // (0xffffffff81000000) but a low physical p_paddr (0x100000). loadKernel must
    // honor p_paddr; reading p_vaddr by mistake puts the segment out of RAM range.
    const ram_base_lo: u64 = 0;
    const paddr: u64 = 0x10_0000; // 1 MB physical
    const vaddr: u64 = 0xffff_ffff_8100_0000; // high kernel-virtual
    const entry: u32 = 0x10_0040;

    // ELF layout: [ehdr 64][phdr0 PT_LOAD 56][phdr1 PT_NOTE 56][note 20][seg 8]
    const ph_off: u64 = 64;
    const note_off: u64 = 64 + 56 * 2;
    const seg_off: u64 = note_off + 20;
    var img: [256]u8 = [_]u8{0} ** 256;

    @memcpy(img[0..4], "\x7fELF");
    img[4] = 2; // ELFCLASS64
    std.mem.writeInt(u64, img[32..40], ph_off, .little); // e_phoff
    std.mem.writeInt(u16, img[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 2, .little); // e_phnum

    // PT_LOAD: p_vaddr != p_paddr; 8 bytes of payload.
    const seg = [8]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04 };
    const lp = ph_off;
    std.mem.writeInt(u32, img[@intCast(lp)..][0..4], 1, .little); // p_type=PT_LOAD
    std.mem.writeInt(u64, img[@intCast(lp + 8)..][0..8], seg_off, .little); // p_offset
    std.mem.writeInt(u64, img[@intCast(lp + 16)..][0..8], vaddr, .little); // p_vaddr (decoy)
    std.mem.writeInt(u64, img[@intCast(lp + 24)..][0..8], paddr, .little); // p_paddr
    std.mem.writeInt(u64, img[@intCast(lp + 32)..][0..8], seg.len, .little); // p_filesz
    std.mem.writeInt(u64, img[@intCast(lp + 40)..][0..8], seg.len, .little); // p_memsz
    @memcpy(img[@intCast(seg_off)..][0..seg.len], &seg);

    // PT_NOTE with the PVH entry.
    const np = ph_off + 56;
    std.mem.writeInt(u32, img[@intCast(np)..][0..4], 4, .little); // p_type=PT_NOTE
    std.mem.writeInt(u64, img[@intCast(np + 8)..][0..8], note_off, .little); // p_offset
    std.mem.writeInt(u64, img[@intCast(np + 32)..][0..8], 20, .little); // p_filesz
    // note: namesz=4 descsz=4 type=18 "Xen\0" entry
    std.mem.writeInt(u32, img[@intCast(note_off)..][0..4], 4, .little);
    std.mem.writeInt(u32, img[@intCast(note_off + 4)..][0..4], 4, .little);
    std.mem.writeInt(u32, img[@intCast(note_off + 8)..][0..4], 18, .little);
    @memcpy(img[@intCast(note_off + 12)..][0..4], "Xen\x00");
    std.mem.writeInt(u32, img[@intCast(note_off + 16)..][0..4], entry, .little);

    const ram = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    const got = try pvh.loadKernel(ram, ram_base_lo, &img);
    try std.testing.expectEqual(entry, got);
    // Payload must land at p_paddr, not anywhere near p_vaddr.
    try std.testing.expectEqualSlices(u8, &seg, ram[@intCast(paddr)..][0..seg.len]);
}

test "mptable: floating pointer + config table checksums, signatures, routing" {
    const mptable = @import("x86/mptable.zig");
    const ram = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    mptable.build(ram, 0, 1);

    const mpf_off: usize = @intCast(mptable.mptable_start);
    // Floating pointer: "_MP_", checksum byte makes the 16 bytes sum to 0.
    try std.testing.expectEqualSlices(u8, "_MP_", ram[mpf_off .. mpf_off + 4]);
    var sum: u8 = 0;
    for (ram[mpf_off .. mpf_off + 16]) |b| sum +%= b;
    try std.testing.expectEqual(@as(u8, 0), sum);

    const physptr = std.mem.readInt(u32, ram[mpf_off + 4 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, mptable.mptable_start + 16), physptr);

    // Config table: "PCMP", length covers it, whole-table checksum is 0.
    try std.testing.expectEqualSlices(u8, "PCMP", ram[physptr .. physptr + 4]);
    const len = std.mem.readInt(u16, ram[physptr + 4 ..][0..2], .little);
    var csum: u8 = 0;
    for (ram[physptr .. physptr + len]) |b| csum +%= b;
    try std.testing.expectEqual(@as(u8, 0), csum);

    // 1 cpu + 1 bus + 1 ioapic + 24 intsrc + 2 lintsrc = 29 entries.
    const oemcount = std.mem.readInt(u16, ram[physptr + 34 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 29), oemcount);

    // The timer (ISA IRQ0) must have an identity route to IOAPIC pin 0, and the
    // first virtio GSI (5) to pin 5 — the pins we inject on via KVM_IRQ_LINE.
    // intsrc entries start after the 44-byte header + 20-byte cpu + 8-byte bus +
    // 8-byte ioapic.
    const intsrc0 = physptr + 44 + 20 + 8 + 8;
    try std.testing.expectEqual(@as(u8, 3), ram[intsrc0]); // MP_INTSRC type
    try std.testing.expectEqual(@as(u8, 0), ram[intsrc0 + 5]); // srcbusirq 0
    try std.testing.expectEqual(@as(u8, 0), ram[intsrc0 + 7]); // dstirq 0 (timer)
    const intsrc5 = intsrc0 + 5 * 8;
    try std.testing.expectEqual(@as(u8, 5), ram[intsrc5 + 5]); // srcbusirq 5
    try std.testing.expectEqual(@as(u8, 5), ram[intsrc5 + 7]); // dstirq 5 (virtio)
}

test "16550 uart: divisor latch, RX data-ready, RX + TX interrupts" {
    var irq = IrqLine{};
    var gic = Gicv2.init(&irq);
    // io is only used by THR-to-stdout writes, which this test never triggers.
    var u = Uart16550.init(undefined, &gic, 4);

    // DLAB selects the divisor latch at offsets 0/1.
    u.write(3, 0x80, 1); // LCR: DLAB=1
    u.write(0, 0x0c, 1); // DLL
    u.write(1, 0x00, 1); // DLM
    try std.testing.expectEqual(@as(u64, 0x0c), u.read(0, 1));
    u.write(3, 0x03, 1); // LCR: DLAB=0, 8N1

    // No RX yet: LSR has no DR bit; reads return 0.
    try std.testing.expectEqual(@as(u64, 0), u.read(5, 1) & 0x01);

    // Enable RX interrupt, push a byte -> DR set, line + IIR report RX-available.
    u.write(1, 0x01, 1); // IER: RX-available
    u.pushRx('A');
    try std.testing.expectEqual(@as(u64, 0x01), u.read(5, 1) & 0x01); // LSR.DR
    try std.testing.expect(u.irqPending());
    try std.testing.expectEqual(@as(u64, 0x04), u.read(2, 1)); // IIR = RX-available
    try std.testing.expectEqual(@as(u64, 'A'), u.read(0, 1)); // read the byte
    try std.testing.expect(!u.irqPending()); // drained

    // Enable TX-holding-empty interrupt -> asserts until IIR is read.
    u.write(1, 0x02, 1); // IER: THR-empty
    try std.testing.expect(u.irqPending());
    try std.testing.expectEqual(@as(u64, 0x02), u.read(2, 1)); // IIR = THR-empty
    try std.testing.expect(!u.irqPending()); // cleared by the IIR read
}

// A tiny C-ABI output sink that captures the bytes a UART emits, mirroring how a
// library embedder (the Swift host / AI harness) receives guest console output
// instead of it going to the process stdout.
const OutCapture = struct {
    buf: [32]u8 = undefined,
    n: usize = 0,
    fn cb(ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
        const s: *OutCapture = @ptrCast(@alignCast(ctx));
        var i: usize = 0;
        while (i < len and s.n < s.buf.len) : (i += 1) {
            s.buf[s.n] = data[i];
            s.n += 1;
        }
    }
    fn captured(s: *OutCapture) []const u8 {
        return s.buf[0..s.n];
    }
};

test "rootfs: buildShellInit mounts the share, applies env, and drops to a shell" {
    const rootfs = @import("rootfs.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const script = try rootfs.buildShellInit(arena.allocator(), .{
        .share_guest_path = "/workspace",
        .env = &[_][]const u8{"FOO=bar"},
        .workdir = "/workspace",
    });
    try std.testing.expect(std.mem.startsWith(u8, script, "#!/bin/sh"));
    try std.testing.expect(std.mem.indexOf(u8, script, "/workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "9p2000.L") != null); // 9p share mount
    try std.testing.expect(std.mem.indexOf(u8, script, "FOO=bar") != null); // env applied
    try std.testing.expect(std.mem.indexOf(u8, script, "/bin/sh") != null); // exec a shell
    // Runs dash (/bin/sh), NOT interactive bash: bash's readline escapes + job
    // control corrupt / stall the host's console sentinel (see buildShellInit).
    try std.testing.expect(std.mem.indexOf(u8, script, "setsid -c /bin/sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/bin/bash") == null);

    // With no share configured, the 9p mount line is omitted.
    const no_share = try rootfs.buildShellInit(arena.allocator(), .{});
    try std.testing.expect(std.mem.indexOf(u8, no_share, "9p2000.L") == null);
}

test "oci: readEmbeddedConfig round-trips ENV + WorkingDir for the guest init" {
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(alloc, .{});
    defer tio.deinit();
    const io = tio.io();
    const cwd = std.Io.Dir.cwd();

    const dir = "zig-ociconf-tmp";
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};

    // A minimal OCI image config as pull's config_out would persist it.
    const body =
        \\{"architecture":"arm64","os":"linux","config":{
        \\ "Env":["PIP_BREAK_SYSTEM_PACKAGES=1","LANG=C.UTF-8"],
        \\ "WorkingDir":"/app","Cmd":["/bin/bash"]}}
    ;
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/" ++ registry.embedded_config_name, .data = body });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = registry.readEmbeddedConfig(arena.allocator(), alloc, io, dir) orelse
        return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 2), cfg.env.len);
    try std.testing.expectEqualStrings("PIP_BREAK_SYSTEM_PACKAGES=1", cfg.env[0]);
    try std.testing.expectEqualStrings("/app", cfg.working_dir);

    // A dir without the persisted config → null (fall back to caller env).
    const empty = "zig-ociconf-empty";
    cwd.deleteTree(io, empty) catch {};
    try cwd.createDirPath(io, empty);
    defer cwd.deleteTree(io, empty) catch {};
    try std.testing.expect(registry.readEmbeddedConfig(arena.allocator(), alloc, io, empty) == null);
}

test "machine: requestStop sets the flag and fires the registered accel kick" {
    // No networking (avoids NAT threads) and a tiny RAM window: this exercises the
    // pure stop/kick wiring without a hypervisor. io is unused with no share/net.
    const alloc = std.testing.allocator;
    const m = try Machine.init(alloc, undefined, 64 * 1024, null, false, [_]u8{0} ** 32);
    defer m.deinit();
    try std.testing.expect(!m.stop_requested.load(.acquire));

    const Kick = struct {
        var got: u64 = 0;
        fn k(vcpu: u64) void {
            got = vcpu;
        }
    };
    Kick.got = 0;
    m.accel_vcpu = 7;
    m.accel_kick = Kick.k;
    m.requestStop();
    try std.testing.expect(m.stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(u64, 7), Kick.got); // the backend kick was invoked
}

test "pl011: guest console output routes to the OutSink callback when set" {
    // io is only touched by the stdout fallback, which a set sink bypasses.
    var u = Pl011.init(undefined);
    var cap = OutCapture{};
    u.sink = .{ .ctx = &cap, .write_fn = OutCapture.cb };
    u.write(0x000, 'H', 1); // DR (data register)
    u.write(0x000, 'i', 1);
    try std.testing.expectEqualStrings("Hi", cap.captured());
}

test "16550: guest console output routes to the OutSink callback when set" {
    var irq = IrqLine{};
    var gic = Gicv2.init(&irq);
    var u = Uart16550.init(undefined, &gic, 4);
    var cap = OutCapture{};
    u.sink = .{ .ctx = &cap, .write_fn = OutCapture.cb };
    u.write(3, 0x03, 1); // LCR: DLAB=0, 8N1
    u.write(0, 'O', 1); // THR
    u.write(0, 'k', 1);
    try std.testing.expectEqualStrings("Ok", cap.captured());
}

test "gicv2 inject hook routes setIrq to an in-kernel irqchip backend" {
    var irq = IrqLine{};
    var gic = Gicv2.init(&irq);
    const Sink = struct {
        intid: u32 = 0,
        level: bool = false,
        calls: u32 = 0,
        fn inject(ctx: *anyopaque, intid: u32, level: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.intid = intid;
            s.level = level;
            s.calls += 1;
        }
    };
    var sink = Sink{};
    gic.inject_ctx = &sink;
    gic.inject_fn = Sink.inject;

    // Rising edge -> injected to the backend, emulated distributor untouched.
    gic.setIrq(48, true);
    try std.testing.expectEqual(@as(u32, 1), sink.calls);
    try std.testing.expectEqual(@as(u32, 48), sink.intid);
    try std.testing.expect(sink.level);
    try std.testing.expect(!irq.pending); // emulated line bypassed

    // No edge -> no extra injection.
    gic.setIrq(48, true);
    try std.testing.expectEqual(@as(u32, 1), sink.calls);

    // Falling edge -> level=false forwarded.
    gic.setIrq(48, false);
    try std.testing.expectEqual(@as(u32, 2), sink.calls);
    try std.testing.expect(!sink.level);
}

const test_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

fn ethArp(buf: []u8, oper: u16, sip: [4]u8, tip: [4]u8) usize {
    @memset(buf[0..42], 0);
    @memcpy(buf[0..6], &[6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    @memcpy(buf[6..12], &test_mac);
    std.mem.writeInt(u16, buf[12..14], 0x0806, .big);
    const a = buf[14..];
    std.mem.writeInt(u16, a[0..2], 1, .big);
    std.mem.writeInt(u16, a[2..4], 0x0800, .big);
    a[4] = 6;
    a[5] = 4;
    std.mem.writeInt(u16, a[6..8], oper, .big);
    @memcpy(a[8..14], &test_mac);
    @memcpy(a[14..18], &sip);
    @memcpy(a[24..28], &tip);
    return 42;
}

test "nat answers ARP for the gateway" {
    var n = nat.Nat.init(std.testing.allocator, test_mac);
    defer n.deinit();
    var f: [64]u8 = undefined;
    const len = ethArp(&f, 1, nat.guest_ip, nat.gateway_ip);
    n.input(f[0..len]);
    var out: [128]u8 = undefined;
    _ = n.poll(&out) orelse return error.NoReply;
    try std.testing.expectEqual(@as(u16, 0x0806), std.mem.readInt(u16, out[12..14], .big));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[20..22], .big)); // ARP reply
    try std.testing.expectEqualSlices(u8, &nat.gw_mac, out[22..28]); // sender HW = gateway
    try std.testing.expectEqualSlices(u8, &nat.gateway_ip, out[28..32]); // sender IP
    try std.testing.expectEqualSlices(u8, &test_mac, out[0..6]); // delivered to guest
}

test "nat does not answer ARP for unrelated IP" {
    var n = nat.Nat.init(std.testing.allocator, test_mac);
    defer n.deinit();
    var f: [64]u8 = undefined;
    const len = ethArp(&f, 1, nat.guest_ip, .{ 8, 8, 8, 8 });
    n.input(f[0..len]);
    var out: [128]u8 = undefined;
    try std.testing.expect(n.poll(&out) == null);
}

test "nat echoes ICMP ping to the gateway" {
    var n = nat.Nat.init(std.testing.allocator, test_mac);
    defer n.deinit();
    var f: [64]u8 = undefined;
    @memset(&f, 0);
    @memcpy(f[0..6], &nat.gw_mac);
    @memcpy(f[6..12], &test_mac);
    std.mem.writeInt(u16, f[12..14], 0x0800, .big);
    const ip = f[14..];
    ip[0] = 0x45;
    std.mem.writeInt(u16, ip[2..4], 20 + 8, .big);
    ip[8] = 64;
    ip[9] = 1; // ICMP
    @memcpy(ip[12..16], &nat.guest_ip);
    @memcpy(ip[16..20], &nat.gateway_ip);
    const icmp = ip[20..];
    icmp[0] = 8; // echo request
    std.mem.writeInt(u16, icmp[4..6], 0x1234, .big); // id
    n.input(f[0 .. 14 + 28]);
    var out: [128]u8 = undefined;
    const r = n.poll(&out) orelse return error.NoReply;
    _ = r;
    const oip = out[14..];
    try std.testing.expectEqual(@as(u8, 0), oip[20]); // ICMP echo reply
    try std.testing.expectEqualSlices(u8, &nat.gateway_ip, oip[12..16]); // src = gateway
    try std.testing.expectEqualSlices(u8, &nat.guest_ip, oip[16..20]); // dst = guest
}

test "nat offers a DHCP lease" {
    var n = nat.Nat.init(std.testing.allocator, test_mac);
    defer n.deinit();
    var f: [400]u8 = undefined;
    @memset(&f, 0);
    @memcpy(f[0..6], &[6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    @memcpy(f[6..12], &test_mac);
    std.mem.writeInt(u16, f[12..14], 0x0800, .big);
    const ip = f[14..];
    ip[0] = 0x45;
    ip[9] = 17; // UDP
    const udp = ip[20..];
    std.mem.writeInt(u16, udp[0..2], 68, .big);
    std.mem.writeInt(u16, udp[2..4], 67, .big);
    const bp = udp[8..];
    bp[0] = 1; // BOOTREQUEST
    @memcpy(bp[236..240], &[4]u8{ 99, 130, 83, 99 });
    bp[240] = 53;
    bp[241] = 1;
    bp[242] = 1; // DISCOVER
    bp[243] = 255;
    n.input(f[0 .. 14 + 20 + 8 + 244]);
    var out: [700]u8 = undefined;
    const r = n.poll(&out) orelse return error.NoReply;
    const oip = out[14..r];
    try std.testing.expectEqual(@as(u8, 17), oip[9]); // UDP
    const obp = oip[20 + 8 ..];
    try std.testing.expectEqual(@as(u8, 2), obp[0]); // BOOTREPLY
    try std.testing.expectEqualSlices(u8, &nat.guest_ip, obp[16..20]); // yiaddr
    try std.testing.expectEqual(@as(u8, 2), obp[242]); // OFFER
}

// Sum the TCP payload bytes across all frames currently queued for the guest.
fn drainTcpPayload(n: *nat.Nat) usize {
    var total: usize = 0;
    var out: [2048]u8 = undefined;
    while (n.poll(&out)) |len| {
        if (len > 54) total += len - 54; // eth(14)+ip(20)+tcp(20) headers
    }
    return total;
}

test "nat tcp send respects the guest receive window" {
    var n = nat.Nat.init(std.testing.allocator, test_mac);
    defer n.deinit();
    var t: nat.Tcb = .{};
    defer t.sndbuf.deinit(std.testing.allocator);
    t.snd_una = 1000;
    t.snd_nxt = 1000;
    t.snd_wnd = 4000; // only 4000 bytes may be in flight
    try t.sndbuf.appendNTimes(std.testing.allocator, 0xAB, 10000);

    // 10000 bytes available but window is 4000: must send exactly 4000.
    n.tcpOutput(&t, .{ 1, 1, 1, 1 }, 80, 1234, 5000);
    try std.testing.expectEqual(@as(usize, 4000), drainTcpPayload(&n));
    try std.testing.expectEqual(@as(u32, 5000), t.snd_nxt); // 1000 + 4000

    // Guest ACKs all 4000 and opens the window to 8000: the rest must flow.
    n.tcpAck(&t, 5000, 8000, 0, .{ 1, 1, 1, 1 }, 80, 1234, 5000);
    try std.testing.expectEqual(@as(u32, 5000), t.snd_una);
    try std.testing.expectEqual(@as(usize, 6000), drainTcpPayload(&n)); // remaining
    try std.testing.expectEqual(@as(u32, 11000), t.snd_nxt); // 5000 + 6000
}

test "nat tcp retransmits unacked data after the RTO" {
    var n = nat.Nat.init(std.testing.allocator, test_mac);
    defer n.deinit();
    try n.tcp.append(std.testing.allocator, .{
        .id = 1,
        .sport = 1234,
        .dst = .{ 1, 1, 1, 1 },
        .dport = 80,
        .stream = undefined,
        .state = .established,
        .recv_next = 5000,
        .tcb = .{ .snd_una = 1000, .snd_nxt = 1000, .snd_wnd = 65535 },
    });
    const c = &n.tcp.items[0];
    n.now_ns = 0;
    try c.tcb.sndbuf.appendNTimes(std.testing.allocator, 0xCD, 1000);
    n.tcpOutput(&c.tcb, c.dst, c.dport, c.sport, c.recv_next);
    try std.testing.expectEqual(@as(usize, 1000), drainTcpPayload(&n));
    try std.testing.expect(c.tcb.rtx_pending);

    // No ACK arrives; advance the clock past the deadline -> retransmit.
    n.now_ns = c.tcb.rtx_deadline + 1;
    n.rtxCheck();
    try std.testing.expectEqual(@as(usize, 1000), drainTcpPayload(&n)); // resent
    try std.testing.expectEqual(@as(u32, 2000), c.tcb.snd_nxt); // 1000 + 1000

    // The conn owns a heap sndbuf; free it before deinit (dummy stream is never closed).
    var popped = n.tcp.pop().?;
    popped.tcb.sndbuf.deinit(std.testing.allocator);
}

test "nat parses the guest window scale from its SYN" {
    try std.testing.expectEqual(@as(u6, 7), nat.parseWscale(&[_]u8{ 3, 3, 7 }));
    // MSS option (2), then NOP (1), then window scale 4.
    try std.testing.expectEqual(@as(u6, 4), nat.parseWscale(&[_]u8{ 2, 4, 0x05, 0xb4, 1, 3, 3, 4 }));
    try std.testing.expectEqual(@as(u6, 0), nat.parseWscale(&[_]u8{ 2, 4, 0x05, 0xb4 }));
    try std.testing.expectEqual(@as(u6, 14), nat.parseWscale(&[_]u8{ 3, 3, 30 })); // capped at 14
}

// --- OCI hard-link recovery ------------------------------------------------

// Write a ustar-format tar header block for `name`/`typeflag` into `out`.
fn tarHeader(out: *[512]u8, name: []const u8, typeflag: u8, link: []const u8, size: u64) void {
    @memset(out, 0);
    @memcpy(out[0..name.len], name);
    // mode / uid / gid: valid octal (parser ignores them, but keep it realistic).
    @memcpy(out[100..108], "0000644\x00");
    out[156] = typeflag;
    if (link.len != 0) @memcpy(out[157..][0..link.len], link);
    // size: 11 octal digits + NUL (0 for links/dirs).
    var sbuf: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&sbuf, "{o:0>11}\x00", .{size}) catch unreachable;
    @memcpy(out[124..136], sbuf[0..12]);
    @memcpy(out[257..263], "ustar\x00");
    @memcpy(out[263..265], "00");
}

test "oci: collectHardLinks recovers (path, target) pairs std.tar drops" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    var blk: [512]u8 = undefined;
    // A regular file with 3 bytes of content (padded to a 512 block).
    tarHeader(&blk, "app/bin/tool", '0', "", 3);
    try buf.appendSlice(a, &blk);
    var data: [512]u8 = [_]u8{0} ** 512;
    @memcpy(data[0..3], "ELF");
    try buf.appendSlice(a, &data);
    // A directory (must be ignored, not collected).
    tarHeader(&blk, "app/bin", '5', "", 0);
    try buf.appendSlice(a, &blk);
    // A hard link -> the earlier regular file (the entry std.tar skips).
    tarHeader(&blk, "app/bin/tool2", '1', "app/bin/tool", 0);
    try buf.appendSlice(a, &blk);
    // Two trailing zero blocks (end of archive).
    try buf.appendSlice(a, &[_]u8{0} ** 1024);

    var r = std.Io.Reader.fixed(buf.items);
    var links = try registry.collectHardLinks(a, &r);
    defer registry.freeHardLinks(a, &links);

    try std.testing.expectEqual(@as(usize, 1), links.items.len);
    try std.testing.expectEqualStrings("app/bin/tool2", links.items[0].path);
    try std.testing.expectEqualStrings("app/bin/tool", links.items[0].target);
}

test "oci: collectHardLinks resolves GNU long-name/-link prefix entries" {
    const a = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);

    const long_path = "app/" ++ ("p" ** 120); // > 100 bytes -> needs a 'L' entry
    const long_target = "app/" ++ ("t" ** 120); // > 100 bytes -> needs a 'K' entry

    var blk: [512]u8 = undefined;
    // GNU 'L': next entry's name; data is the name string (padded to a block).
    tarHeader(&blk, "././@LongLink", 'L', "", long_path.len);
    try buf.appendSlice(a, &blk);
    var nameblk: [512]u8 = [_]u8{0} ** 512;
    @memcpy(nameblk[0..long_path.len], long_path);
    try buf.appendSlice(a, &nameblk);
    // GNU 'K': next entry's link target.
    tarHeader(&blk, "././@LongLink", 'K', "", long_target.len);
    try buf.appendSlice(a, &blk);
    var linkblk: [512]u8 = [_]u8{0} ** 512;
    @memcpy(linkblk[0..long_target.len], long_target);
    try buf.appendSlice(a, &linkblk);
    // The hard-link header itself (its 100-byte name/link fields are truncated
    // placeholders; the 'L'/'K' overrides win).
    tarHeader(&blk, long_path[0..100], '1', long_target[0..100], 0);
    try buf.appendSlice(a, &blk);
    try buf.appendSlice(a, &[_]u8{0} ** 1024);

    var r = std.Io.Reader.fixed(buf.items);
    var links = try registry.collectHardLinks(a, &r);
    defer registry.freeHardLinks(a, &links);

    try std.testing.expectEqual(@as(usize, 1), links.items.len);
    try std.testing.expectEqualStrings(long_path, links.items[0].path);
    try std.testing.expectEqualStrings(long_target, links.items[0].target);
}

test "oci: imageArchFromConfig reads the config architecture (guards wrong-arch pull)" {
    const a = std.testing.allocator;
    // amd64 image config.
    if (registry.imageArchFromConfig(a, "{\"architecture\":\"amd64\",\"os\":\"linux\"}")) |arch| {
        defer a.free(arch);
        try std.testing.expectEqualStrings("amd64", arch);
    } else return error.TestUnexpectedNull;
    // arm64 image config.
    if (registry.imageArchFromConfig(a, "{\"os\":\"linux\",\"architecture\":\"arm64\"}")) |arch| {
        defer a.free(arch);
        try std.testing.expectEqualStrings("arm64", arch);
    } else return error.TestUnexpectedNull;
    // Missing field / not an object → null (don't over-block; the pull only
    // rejects on a definite mismatch).
    try std.testing.expect(registry.imageArchFromConfig(a, "{\"os\":\"linux\"}") == null);
    try std.testing.expect(registry.imageArchFromConfig(a, "not json") == null);
}

// --- virtio-9p advisory locking (9P2000.L Tlock/Tgetlock) ------------------
const Virtio9p = @import("devices/virtio_9p.zig").Virtio9p;
const V9pFid = @import("devices/virtio_9p.zig").Fid;

// Minimal Virtio9p with just a fids map — enough to drive dispatch() for the
// lock opcodes, which touch only self.fids (never the bus/gic/io/base fields).
fn lockTestDevice(alloc: std.mem.Allocator, fid: u32) !Virtio9p {
    var dev: Virtio9p = undefined;
    dev.fids = std.AutoHashMap(u32, V9pFid).init(alloc);
    try dev.fids.put(fid, .{ .path = try alloc.dupe(u8, "") });
    return dev;
}
fn freeLockTestDevice(alloc: std.mem.Allocator, dev: *Virtio9p) void {
    var it = dev.fids.iterator();
    while (it.next()) |e| alloc.free(e.value_ptr.path);
    dev.fids.deinit();
}

test "9p: Tlock on a valid fid returns Rlock success" {
    const alloc = std.testing.allocator;
    var dev = try lockTestDevice(alloc, 5);
    defer freeLockTestDevice(alloc, &dev);

    // size[4] type=52 tag[2] fid[4] type[1] flags[4] start[8] length[8] proc[4] id[s]
    var t = [_]u8{0} ** 40;
    t[4] = 52; // Tlock
    std.mem.writeInt(u16, t[5..7], 1, .little); // tag
    std.mem.writeInt(u32, t[7..11], 5, .little); // fid
    t[11] = 1; // F_WRLCK

    var reply: [64]u8 = undefined;
    const n = dev.dispatch(t[0..], &reply);
    try std.testing.expect(n >= 8);
    try std.testing.expectEqual(@as(u8, 53), reply[4]); // Rlock
    try std.testing.expectEqual(@as(u8, 0), reply[7]); // P9_LOCK_SUCCESS
}

test "9p: Tlock on an unknown fid returns Rlerror EBADF" {
    const alloc = std.testing.allocator;
    var dev = try lockTestDevice(alloc, 5);
    defer freeLockTestDevice(alloc, &dev);

    var t = [_]u8{0} ** 40;
    t[4] = 52; // Tlock
    std.mem.writeInt(u32, t[7..11], 99, .little); // unknown fid

    var reply: [64]u8 = undefined;
    _ = dev.dispatch(t[0..], &reply);
    try std.testing.expectEqual(@as(u8, 7), reply[4]); // Rlerror
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, reply[7..11], .little)); // EBADF
}

test "9p: Tunlinkat deletes a file and Trename moves it (real host dir)" {
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(alloc, .{});
    defer tio.deinit();
    const io = tio.io();
    const cwd = std.Io.Dir.cwd();

    const base = "zig-9ptest-tmp";
    cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base);
    defer cwd.deleteTree(io, base) catch {};
    try cwd.writeFile(io, .{ .sub_path = base ++ "/victim.txt", .data = "x" });
    try cwd.writeFile(io, .{ .sub_path = base ++ "/a.txt", .data = "y" });

    var dev: Virtio9p = undefined;
    dev.io = io;
    dev.base = base;
    dev.alloc = alloc;
    dev.fids = std.AutoHashMap(u32, V9pFid).init(alloc);
    defer {
        var it = dev.fids.iterator();
        while (it.next()) |e| alloc.free(e.value_ptr.path);
        dev.fids.deinit();
    }
    try dev.fids.put(1, .{ .path = try alloc.dupe(u8, "") }); // root dir -> base
    try dev.fids.put(2, .{ .path = try alloc.dupe(u8, "a.txt") }); // the file to rename

    var reply: [128]u8 = undefined;

    // Tunlinkat: dfid[4]=1 name[s]="victim.txt" flags[4]=0
    var u = [_]u8{0} ** 64;
    u[4] = 76;
    std.mem.writeInt(u32, u[7..11], 1, .little);
    std.mem.writeInt(u16, u[11..13], 10, .little);
    @memcpy(u[13..23], "victim.txt");
    _ = dev.dispatch(u[0..27], &reply);
    try std.testing.expectEqual(@as(u8, 77), reply[4]); // Runlinkat
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, base ++ "/victim.txt", .{}));

    // Trename: fid[4]=2 dfid[4]=1 name[s]="b.txt"
    var r = [_]u8{0} ** 64;
    r[4] = 20;
    std.mem.writeInt(u32, r[7..11], 2, .little);
    std.mem.writeInt(u32, r[11..15], 1, .little);
    std.mem.writeInt(u16, r[15..17], 5, .little);
    @memcpy(r[17..22], "b.txt");
    _ = dev.dispatch(r[0..22], &reply);
    try std.testing.expectEqual(@as(u8, 21), reply[4]); // Rrename
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, base ++ "/a.txt", .{}));
    _ = try cwd.statFile(io, base ++ "/b.txt", .{}); // moved here
    try std.testing.expectEqualStrings("b.txt", dev.fids.get(2).?.path); // fid follows the file
}

test "9p: Tunlinkat on a missing file returns Rlerror ENOENT" {
    const alloc = std.testing.allocator;
    var tio = std.Io.Threaded.init(alloc, .{});
    defer tio.deinit();
    var dev: Virtio9p = undefined;
    dev.io = tio.io();
    dev.base = ".";
    dev.alloc = alloc;
    dev.fids = std.AutoHashMap(u32, V9pFid).init(alloc);
    defer freeLockTestDevice(alloc, &dev);
    try dev.fids.put(1, .{ .path = try alloc.dupe(u8, "") });

    var u = [_]u8{0} ** 64;
    u[4] = 76; // Tunlinkat
    std.mem.writeInt(u32, u[7..11], 1, .little);
    std.mem.writeInt(u16, u[11..13], 14, .little);
    @memcpy(u[13..27], "does-not-exist");
    var reply: [64]u8 = undefined;
    _ = dev.dispatch(u[0..31], &reply);
    try std.testing.expectEqual(@as(u8, 7), reply[4]); // Rlerror
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, reply[7..11], .little)); // ENOENT
}

test "9p: Tfsync on a valid fid returns Rfsync (no body)" {
    const alloc = std.testing.allocator;
    var dev = try lockTestDevice(alloc, 7);
    defer freeLockTestDevice(alloc, &dev);

    // size[4] type=50 tag[2] fid[4] datasync[4]
    var t = [_]u8{0} ** 20;
    t[4] = 50; // Tfsync
    std.mem.writeInt(u16, t[5..7], 1, .little); // tag
    std.mem.writeInt(u32, t[7..11], 7, .little); // fid

    var reply: [32]u8 = undefined;
    const n = dev.dispatch(t[0..], &reply);
    try std.testing.expectEqual(@as(u8, 51), reply[4]); // Rfsync
    try std.testing.expectEqual(@as(usize, 7), n); // header only, no body
}

test "9p: Tgetlock reports no conflict (F_UNLCK), echoing the range" {
    const alloc = std.testing.allocator;
    var dev = try lockTestDevice(alloc, 5);
    defer freeLockTestDevice(alloc, &dev);

    // type=54 fid[4] type[1] start[8] length[8] proc[4] id[s]
    var t = [_]u8{0} ** 40;
    t[4] = 54; // Tgetlock
    std.mem.writeInt(u32, t[7..11], 5, .little); // fid
    t[11] = 1; // F_WRLCK (querying)
    std.mem.writeInt(u64, t[12..20], 1024, .little); // start
    std.mem.writeInt(u64, t[20..28], 16, .little); // length
    std.mem.writeInt(u32, t[28..32], 4242, .little); // proc_id

    var reply: [64]u8 = undefined;
    _ = dev.dispatch(t[0..], &reply);
    try std.testing.expectEqual(@as(u8, 55), reply[4]); // Rgetlock
    try std.testing.expectEqual(@as(u8, 2), reply[7]); // F_UNLCK -> available
    try std.testing.expectEqual(@as(u64, 1024), std.mem.readInt(u64, reply[8..16], .little));
    try std.testing.expectEqual(@as(u64, 16), std.mem.readInt(u64, reply[16..24], .little));
    try std.testing.expectEqual(@as(u32, 4242), std.mem.readInt(u32, reply[24..28], .little));
}

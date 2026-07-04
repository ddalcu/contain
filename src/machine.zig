//! The `virt` machine: memory map + devices + CPU, matching the layout QEMU
//! exposes as `-M virt` so stock aarch64 kernels boot unmodified.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const IrqLine = @import("devices/gicv2.zig").IrqLine;
const Pl011 = @import("devices/uart_pl011.zig").Pl011;
const Uart16550 = @import("devices/uart_16550.zig").Uart16550;
const Pl031 = @import("devices/rtc_pl031.zig").Pl031;
const Gicv2 = @import("devices/gicv2.zig").Gicv2;
const pvh = @import("x86/pvh.zig");
const mptable = @import("x86/mptable.zig");
const VirtioBlk = @import("devices/virtio.zig").VirtioBlk;
const VirtioRng = @import("devices/virtio_rng.zig").VirtioRng;
const Virtio9p = @import("devices/virtio_9p.zig").Virtio9p;
const VirtioFs = @import("devices/virtio_fs.zig").VirtioFs;
const VirtioNet = @import("devices/virtio_net.zig").VirtioNet;
const Nat = @import("net/nat.zig").Nat;

pub const ram_base: u64 = 0x4000_0000;

/// Guest machine type. The accel backend is orthogonal: arm64-virt runs under
/// hvf/kvm, x86-microvm under kvm/whp.
pub const Platform = enum { arm64_virt, x86_microvm };

// virtio-mmio device window (matches the DTB) and interrupts.
const virtio_base: u64 = 0x0a00_0000;
const virtio_stride: u64 = 0x200;
const virtio_spi: u32 = 16; // first virtio SPI: blk -> INTID 48, rng -> 49, ...
const disk_size: usize = 16 * 1024 * 1024;

// x86-microvm layout: RAM from 0, virtio-mmio high (above RAM), 16550 COM1 at a
// port, IRQs are IOAPIC GSIs (COM1=4, virtio from 5). Firecracker-style.
pub const x86_ram_base: u64 = 0;
const x86_initrd_load: u64 = 0x0800_0000; // 128 MB: above the PVH kernel, below 512 MB RAM
const x86_virtio_base: u64 = 0xd000_0000;
const x86_virtio_stride: u64 = 0x1000;
const x86_virtio_size: u64 = 0x1000;
const com1_gsi: u32 = 4;
const x86_virtio_gsi0: u32 = 5; // first virtio device GSI

// Linux boot layout within RAM.
pub const dtb_load: u64 = 0x4000_0000;
pub const kernel_load: u64 = 0x4020_0000;
pub const initrd_load: u64 = 0x4800_0000;

// Interrupt IDs.
const uart_spi: u32 = 1; // PL011 -> INTID 33

/// The guest init path used with a rootfs-over-virtiofs boot (the kernel `init=`).
/// Process-global so `contain run` can pick a per-run unique name (concurrent
/// guests sharing one cached image rootfs must not clobber each other's init file).
pub var rootfs_init_path: []const u8 = "/.contain-init";

pub const Machine = struct {
    bus: Bus,
    platform: Platform = .arm64_virt,
    uart: *Pl011,
    // x86-microvm console (COM1) instead of the PL011; null on arm64.
    uart16550: ?*Uart16550 = null,
    // PVH boot result (x86 only): 32-bit entry point + start_info paddr.
    x86_entry: u32 = 0,
    x86_start_info: u64 = 0,
    x86_cmdline: ?[]u8 = null,
    rtc: *Pl031,
    gic: *Gicv2,
    blk: *VirtioBlk,
    disk: []u8,
    rng: *VirtioRng,
    p9: ?*Virtio9p = null,
    vfs: ?*VirtioFs = null, // the -v/host share device (tag "host"), if any
    rootfs_vfs: ?*VirtioFs = null, // the rootfs-over-virtiofs device (tag "rootfs"), if any
    net: ?*VirtioNet = null,
    natp: ?*Nat = null,
    net_io: ?*std.Io.Threaded = null,
    irq: IrqLine,
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Cooperative stop signal. The accel run loop checks this each iteration (and
    /// during idle/WFI slices) and returns when set, so a library embedder can
    /// power off a still-running guest. `requestStop` also kicks the vCPU out of a
    /// blocking hypervisor run via the backend-registered `accel_kick`.
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// The active vCPU handle + a backend "kick" that forces it to exit a blocked
    /// run (HVF: hv_vcpus_exit). Set by the accel backend while running, cleared on
    /// exit; null when no guest is running.
    accel_vcpu: u64 = 0,
    accel_kick: ?*const fn (vcpu: u64) void = null,
    /// Number of virtio devices exposed (for the DTB).
    num_virtio: u32 = 1,
    /// Optional scripted console input, fed to the UART RX one byte at a time as
    /// the guest consumes it (used to drive the shell non-interactively).
    input: []const u8 = "",
    input_pos: usize = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, ram_size: usize, share_path: ?[]const u8, rootfs_share: ?[]const u8, enable_net: bool, rng_seed: [32]u8) !*Machine {
        const self = try alloc.create(Machine);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.io = io;
        self.platform = .arm64_virt; // alloc.create() doesn't honor struct-field defaults
        self.uart16550 = null;
        self.x86_entry = 0;
        self.x86_start_info = 0;
        self.x86_cmdline = null;
        self.p9 = null;
        self.vfs = null;
        self.rootfs_vfs = null;
        self.net = null;
        self.natp = null;
        self.net_io = null;
        self.num_virtio = 1;
        self.irq = .{};
        self.stop_requested = .init(false); // alloc.create() ignores field defaults
        self.accel_vcpu = 0;
        self.accel_kick = null;
        self.bus = try Bus.init(alloc, ram_base, ram_size);

        const uart = try alloc.create(Pl011);
        uart.* = Pl011.init(io);
        self.uart = uart;
        try self.bus.addDevice(.{
            .base = Pl011.base,
            .size = Pl011.size,
            .ctx = uart,
            .readFn = uartRead,
            .writeFn = uartWrite,
            .name = "pl011",
        });

        const rtc = try alloc.create(Pl031);
        rtc.* = Pl031.init(io);
        self.rtc = rtc;
        try self.bus.addDevice(.{
            .base = Pl031.base,
            .size = Pl031.size,
            .ctx = rtc,
            .readFn = rtcRead,
            .writeFn = rtcWrite,
            .name = "pl031",
        });

        const gic = try alloc.create(Gicv2);
        gic.* = Gicv2.init(&self.irq);
        self.gic = gic;
        try self.bus.addDevice(.{
            .base = Gicv2.dist_base,
            .size = Gicv2.dist_size,
            .ctx = gic,
            .readFn = gicDistRead,
            .writeFn = gicDistWrite,
            .name = "gicd",
        });
        try self.bus.addDevice(.{
            .base = Gicv2.cpu_base,
            .size = Gicv2.cpu_size,
            .ctx = gic,
            .readFn = gicCpuRead,
            .writeFn = gicCpuWrite,
            .name = "gicc",
        });

        const disk = try alloc.alloc(u8, disk_size);
        @memset(disk, 0);
        self.disk = disk;
        const blk = try alloc.create(VirtioBlk);
        blk.* = VirtioBlk.init(virtio_base, 32 + virtio_spi, &self.bus, gic, disk);
        self.blk = blk;
        try self.bus.addDevice(.{
            .base = virtio_base,
            .size = VirtioBlk.size,
            .ctx = blk,
            .readFn = blkRead,
            .writeFn = blkWrite,
            .name = "virtio-blk",
        });

        // Additional virtio-mmio devices occupy consecutive slots after blk (0).
        var vidx: u32 = 1;

        // virtio-rng (always on): seeds the guest CRNG at boot so userspace
        // (node/V8) doesn't stall on getrandom() — important under a hardware
        // backend where real-time boot leaves little interrupt entropy.
        {
            const slot = virtio_base + virtio_stride * vidx;
            const rng = try alloc.create(VirtioRng);
            rng.* = VirtioRng.init(slot, 32 + virtio_spi + vidx, &self.bus, gic, rng_seed);
            self.rng = rng;
            try self.bus.addDevice(.{
                .base = slot,
                .size = VirtioRng.size,
                .ctx = rng,
                .readFn = rngRead,
                .writeFn = rngWrite,
                .name = "virtio-rng",
            });
            vidx += 1;
        }

        // Optional rootfs-over-virtiofs (see initX86): the container rootfs dir as
        // the guest's real root, demand-paged. The arm64 bootargs (built with the
        // DTB in cmdBoot) select root=rootfs rootfstype=virtiofs when this is set.
        if (rootfs_share) |rp| {
            const slot = virtio_base + virtio_stride * vidx;
            self.rootfs_vfs = try self.addShareDevice(alloc, io, gic, slot, 32 + virtio_spi + vidx, rp, "rootfs", true);
            vidx += 1;
        }

        // Optional host-directory share: virtio-fs by default (POSIX-complete,
        // memory-lean), or legacy 9p if CONTAIN_SHARE_FS=9p.
        if (share_path) |sp| {
            if (std.Io.Dir.cwd().openDir(io, sp, .{ .iterate = true })) |dir| {
                var d = dir;
                d.close(io); // just verifying it exists; the device uses cwd-relative paths
                const slot = virtio_base + virtio_stride * vidx;
                self.vfs = try self.addShareDevice(alloc, io, gic, slot, 32 + virtio_spi + vidx, sp, "host", false);
                vidx += 1;
            } else |err| {
                std.debug.print("[contain] share '{s}' unavailable: {s}\n", .{ sp, @errorName(err) });
            }
        }

        // Optional virtio-net + userspace NAT.
        if (enable_net) {
            const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
            // A dedicated concurrent Io for host sockets (timeouts need concurrency).
            const tio = try alloc.create(std.Io.Threaded);
            tio.* = std.Io.Threaded.init(alloc, .{});
            self.net_io = tio;
            const natp = try alloc.create(Nat);
            natp.* = Nat.init(alloc, mac);
            natp.io = tio.io();
            self.natp = natp;
            const slot = virtio_base + virtio_stride * vidx;
            const net = try alloc.create(VirtioNet);
            net.* = VirtioNet.init(slot, 32 + virtio_spi + vidx, &self.bus, gic, mac, natp);
            self.net = net;
            try self.bus.addDevice(.{
                .base = slot,
                .size = VirtioNet.size,
                .ctx = net,
                .readFn = netRead,
                .writeFn = netWrite,
                .name = "virtio-net",
            });
            vidx += 1;
        }
        self.num_virtio = vidx;
        return self;
    }

    /// Create the host-directory share device at `slot`/`irq` and register it on
    /// the bus. Uses virtio-fs (FUSE) by default; CONTAIN_SHARE_FS=9p selects the
    /// legacy 9p transport. Both are virtio-mmio, so the DTB/cmdline node is
    /// identical either way — only the guest-side `mount -t` differs (the init
    /// scripts try virtiofs then 9p).
    fn addShareDevice(self: *Machine, alloc: std.mem.Allocator, io: std.Io, gic: *Gicv2, slot: u64, irq: u32, path: []const u8, tag: []const u8, force_virtiofs: bool) !?*VirtioFs {
        const win: u64 = if (self.platform == .x86_microvm) x86_virtio_size else VirtioFs.size;
        if (force_virtiofs or useVirtiofs()) {
            const vfs = try alloc.create(VirtioFs);
            vfs.* = try VirtioFs.init(slot, irq, &self.bus, gic, io, path, tag, alloc);
            try self.bus.addDevice(.{ .base = slot, .size = win, .ctx = vfs, .readFn = vfsRead, .writeFn = vfsWrite, .name = "virtio-fs" });
            return vfs;
        }
        const p9 = try alloc.create(Virtio9p);
        p9.* = Virtio9p.init(slot, irq, &self.bus, gic, io, path, alloc);
        self.p9 = p9;
        try self.bus.addDevice(.{ .base = slot, .size = win, .ctx = p9, .readFn = p9Read, .writeFn = p9Write, .name = "virtio-9p" });
        return null;
    }

    /// Choose the host-share transport. Default virtio-fs (POSIX-complete,
    /// memory-lean) on both arches, now that the guest kernels ship
    /// CONFIG_VIRTIO_FS. `share_9p_override` (CONTAIN_SHARE_FS=9p) forces the
    /// legacy 9p transport (e.g. for an older fetched kernel without FUSE).
    pub var share_9p_override: bool = false;
    fn useVirtiofs() bool {
        return !share_9p_override;
    }

    fn appendVirtioCmd(cmd: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, base: u64, gsi: u32) !void {
        var buf: [80]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " virtio_mmio.device=0x{x}@0x{x}:{d}", .{ x86_virtio_size, base, gsi }) catch return;
        try cmd.appendSlice(alloc, s);
    }

    /// Build an x86-microvm machine: 16550 COM1 (port I/O) + virtio-mmio devices
    /// at high addresses (described to the kernel via the cmdline), no PL011/RTC/
    /// GIC-MMIO/DTB. The interrupt controller is the hypervisor's in-kernel
    /// IOAPIC; the GICv2 here serves only as the IRQ router (its `inject_fn` is
    /// set by the backend to hit the IOAPIC GSI). Runs under KVM/WHP only.
    pub fn initX86(alloc: std.mem.Allocator, io: std.Io, ram_size: usize, share_path: ?[]const u8, rootfs_share: ?[]const u8, enable_net: bool, rng_seed: [32]u8, for_whp: bool) !*Machine {
        const self = try alloc.create(Machine);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.io = io;
        self.platform = .x86_microvm;
        self.uart16550 = null;
        self.x86_entry = 0;
        self.x86_start_info = 0;
        self.x86_cmdline = null;
        self.p9 = null;
        self.vfs = null;
        self.rootfs_vfs = null;
        self.net = null;
        self.natp = null;
        self.net_io = null;
        self.num_virtio = 0;
        self.input = "";
        self.input_pos = 0;
        self.irq = .{};
        self.stop_requested = .init(false); // alloc.create() ignores field defaults
        self.accel_vcpu = 0;
        self.accel_kick = null;
        self.bus = try Bus.init(alloc, x86_ram_base, ram_size);

        const gic = try alloc.create(Gicv2);
        gic.* = Gicv2.init(&self.irq); // router only; emulated distributor unused on x86
        self.gic = gic;

        // PL011/PL031 are allocated so the shared `uart`/`rtc` fields stay valid
        // (deinit frees them) but are NOT wired into the x86 bus.
        const uart = try alloc.create(Pl011);
        uart.* = Pl011.init(io);
        self.uart = uart;
        const rtc = try alloc.create(Pl031);
        rtc.* = Pl031.init(io);
        self.rtc = rtc;

        const com1 = try alloc.create(Uart16550);
        com1.* = Uart16550.init(io, gic, com1_gsi);
        self.uart16550 = com1;

        var cmd: std.ArrayListUnmanaged(u8) = .empty;
        errdefer cmd.deinit(alloc);
        // pci=off: there is no PCI host bridge in this microvm, so stop the kernel
        // scanning 0xCF8/0xCFC (a full bus enumeration spins forever otherwise).
        // With a rootfs-over-virtiofs share the kernel mounts the host rootfs dir
        // directly as its real root (demand-paged — no whole-image-in-RAM initramfs),
        // and runs /.contain-init from it. `rootwait` lets the virtio-fs device probe
        // before mount_root. Otherwise boot the initramfs root via rdinit=/init.
        try cmd.appendSlice(alloc, "console=ttyS0 reboot=t panic=-1 pci=off acpi=off");
        if (rootfs_share != null) {
            // init= uses rootfs_init_path (default /.contain-init). `contain run`
            // sets a per-run UNIQUE name so concurrent guests sharing one cached
            // image rootfs (e.g. `contain compose up`) don't clobber each other's
            // init file on disk.
            var ibuf: [160]u8 = undefined;
            const s = std.fmt.bufPrint(&ibuf, " root=rootfs rootfstype=virtiofs rw rootwait init={s}", .{rootfs_init_path}) catch " root=rootfs rootfstype=virtiofs rw rootwait init=/.contain-init";
            try cmd.appendSlice(alloc, s);
        } else {
            try cmd.appendSlice(alloc, " rdinit=/init");
        }
        // WHP only emulates the LAPIC (no working LAPIC timer for us) and no PIC, so
        // the guest must use the i8254 PIT for the tick: disable the APIC timer,
        // force periodic mode, and skip the IRQ-routing check. KVM has an in-kernel
        // irqchip + LAPIC timer and needs none of this.
        if (for_whp) try cmd.appendSlice(alloc, " no_timer_check noapictimer nohz=off highres=off");

        var vidx: u32 = 0;

        // virtio-blk (always).
        const disk = try alloc.alloc(u8, disk_size);
        @memset(disk, 0);
        self.disk = disk;
        {
            const slot = x86_virtio_base + x86_virtio_stride * vidx;
            const gsi = x86_virtio_gsi0 + vidx;
            const blk = try alloc.create(VirtioBlk);
            blk.* = VirtioBlk.init(slot, gsi, &self.bus, gic, disk);
            self.blk = blk;
            try self.bus.addDevice(.{ .base = slot, .size = x86_virtio_size, .ctx = blk, .readFn = blkRead, .writeFn = blkWrite, .name = "virtio-blk" });
            try appendVirtioCmd(&cmd, alloc, slot, gsi);
            vidx += 1;
        }

        // virtio-rng (always; seeds the guest CRNG at boot).
        {
            const slot = x86_virtio_base + x86_virtio_stride * vidx;
            const gsi = x86_virtio_gsi0 + vidx;
            const rng = try alloc.create(VirtioRng);
            rng.* = VirtioRng.init(slot, gsi, &self.bus, gic, rng_seed);
            self.rng = rng;
            try self.bus.addDevice(.{ .base = slot, .size = x86_virtio_size, .ctx = rng, .readFn = rngRead, .writeFn = rngWrite, .name = "virtio-rng" });
            try appendVirtioCmd(&cmd, alloc, slot, gsi);
            vidx += 1;
        }

        // Optional rootfs-over-virtiofs: the container's unpacked rootfs dir mounted
        // as the guest's real root (tag "rootfs"), demand-paged instead of packed
        // into an in-RAM initramfs. Always virtio-fs (root=... rootfstype=virtiofs).
        if (rootfs_share) |rp| {
            const slot = x86_virtio_base + x86_virtio_stride * vidx;
            const gsi = x86_virtio_gsi0 + vidx;
            self.rootfs_vfs = try self.addShareDevice(alloc, io, gic, slot, gsi, rp, "rootfs", true);
            try appendVirtioCmd(&cmd, alloc, slot, gsi);
            vidx += 1;
        }

        // Optional host-directory share: virtio-fs by default, or legacy 9p if
        // CONTAIN_SHARE_FS=9p.
        if (share_path) |sp| {
            if (std.Io.Dir.cwd().openDir(io, sp, .{ .iterate = true })) |dir| {
                var d = dir;
                d.close(io);
                const slot = x86_virtio_base + x86_virtio_stride * vidx;
                const gsi = x86_virtio_gsi0 + vidx;
                self.vfs = try self.addShareDevice(alloc, io, gic, slot, gsi, sp, "host", false);
                try appendVirtioCmd(&cmd, alloc, slot, gsi);
                vidx += 1;
            } else |err| {
                std.debug.print("[contain] share '{s}' unavailable: {s}\n", .{ sp, @errorName(err) });
            }
        }

        // Optional virtio-net + NAT.
        if (enable_net) {
            const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
            const tio = try alloc.create(std.Io.Threaded);
            tio.* = std.Io.Threaded.init(alloc, .{});
            self.net_io = tio;
            const natp = try alloc.create(Nat);
            natp.* = Nat.init(alloc, mac);
            natp.io = tio.io();
            self.natp = natp;
            const slot = x86_virtio_base + x86_virtio_stride * vidx;
            const gsi = x86_virtio_gsi0 + vidx;
            const net = try alloc.create(VirtioNet);
            net.* = VirtioNet.init(slot, gsi, &self.bus, gic, mac, natp);
            self.net = net;
            try self.bus.addDevice(.{ .base = slot, .size = x86_virtio_size, .ctx = net, .readFn = netRead, .writeFn = netWrite, .name = "virtio-net" });
            try appendVirtioCmd(&cmd, alloc, slot, gsi);
            vidx += 1;
        }
        self.num_virtio = vidx;
        self.x86_cmdline = try cmd.toOwnedSlice(alloc);
        return self;
    }

    /// PVH boot (x86): load the `vmlinux` ELF segments + (optional) initramfs into
    /// guest RAM and build the hvm_start_info. Stores the 32-bit entry point and
    /// the start_info paddr for the backend to enter at.
    pub fn bootPvh(self: *Machine, vmlinux: []const u8, initrd: ?[]const u8) !void {
        const ram = self.bus.ram;
        const entry = try pvh.loadKernel(ram, self.bus.ram_base, vmlinux);
        // No ACPI under PVH, so the kernel needs an MP table to find the IOAPIC and
        // route the timer + virtio IRQs (otherwise it hangs in early init).
        mptable.build(ram, self.bus.ram_base, 1);
        var initrd_paddr: u64 = 0;
        var initrd_size: u64 = 0;
        if (initrd) |ir| {
            initrd_paddr = x86_initrd_load;
            const off = initrd_paddr - self.bus.ram_base;
            if (off + ir.len > ram.len) return error.InitrdTooLarge;
            @memcpy(ram[@intCast(off)..][0..ir.len], ir);
            initrd_size = ir.len;
        }
        self.x86_start_info = pvh.buildStartInfo(ram, .{
            .ram_base = self.bus.ram_base,
            .ram_size = ram.len,
            .cmdline = self.x86_cmdline orelse "console=ttyS0 rdinit=/init",
            .initrd_paddr = initrd_paddr,
            .initrd_size = initrd_size,
        });
        self.x86_entry = entry;
    }

    pub fn deinit(self: *Machine) void {
        self.bus.deinit();
        self.alloc.free(self.disk);
        self.alloc.destroy(self.blk);
        self.alloc.destroy(self.rng);
        if (self.p9) |p9| {
            p9.fids.deinit();
            self.alloc.destroy(p9);
        }
        if (self.vfs) |vfs| {
            vfs.deinit();
            self.alloc.destroy(vfs);
        }
        if (self.rootfs_vfs) |vfs| {
            vfs.deinit();
            self.alloc.destroy(vfs);
        }
        if (self.net) |net| self.alloc.destroy(net);
        if (self.natp) |natp| {
            natp.deinit();
            self.alloc.destroy(natp);
        }
        if (self.net_io) |t| {
            t.deinit();
            self.alloc.destroy(t);
        }
        if (self.uart16550) |u| self.alloc.destroy(u);
        if (self.x86_cmdline) |c| self.alloc.free(c);
        self.alloc.destroy(self.uart);
        self.alloc.destroy(self.rtc);
        self.alloc.destroy(self.gic);
        self.alloc.destroy(self);
    }

    fn blkRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*VirtioBlk, @ptrCast(@alignCast(ctx))).read(offset, sz);
    }
    fn blkWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*VirtioBlk, @ptrCast(@alignCast(ctx))).write(offset, value, sz);
    }
    fn rngRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*VirtioRng, @ptrCast(@alignCast(ctx))).read(offset, sz);
    }
    fn rngWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*VirtioRng, @ptrCast(@alignCast(ctx))).write(offset, value, sz);
    }
    fn p9Read(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*Virtio9p, @ptrCast(@alignCast(ctx))).read(offset, sz);
    }
    fn p9Write(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*Virtio9p, @ptrCast(@alignCast(ctx))).write(offset, value, sz);
    }
    fn vfsRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*VirtioFs, @ptrCast(@alignCast(ctx))).read(offset, sz);
    }
    fn vfsWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*VirtioFs, @ptrCast(@alignCast(ctx))).write(offset, value, sz);
    }
    fn netRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*VirtioNet, @ptrCast(@alignCast(ctx))).read(offset, sz);
    }
    fn netWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*VirtioNet, @ptrCast(@alignCast(ctx))).write(offset, value, sz);
    }

    /// Device servicing for a hardware-virt backend (HVF/KVM/WHP): the device
    /// work the hypervisor does NOT own. We feed scripted console input,
    /// recompute the UART line into the GIC, and pump the NAT + deliver RX. The
    /// `gic.setIrq` calls here either drive the emulated distributor
    /// (HVF) or inject into the in-kernel irqchip (KVM) via the GIC's injector
    /// hook. The generic timer is owned by the hypervisor, so the timer PPIs are
    /// deliberately not touched here. Called at every vCPU run-loop boundary
    /// (and, under HVF, during WFI idle slices).
    pub fn serviceDevicesHw(self: *Machine) void {
        switch (self.platform) {
            .arm64_virt => {
                if (self.input_pos < self.input.len and self.uart.readyForRx()) {
                    self.uart.pushRx(self.input[self.input_pos]);
                    self.input_pos += 1;
                }
                self.gic.setIrq(32 + uart_spi, self.uart.irqPending());
            },
            .x86_microvm => {
                const u = self.uart16550.?;
                if (self.input_pos < self.input.len and u.readyForRx()) {
                    u.pushRx(self.input[self.input_pos]);
                    self.input_pos += 1;
                }
                self.gic.setIrq(com1_gsi, u.irqPending());
            },
        }
        if (self.net) |net| net.service();
    }

    // ---- device MMIO trampolines ----
    fn uartRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*Pl011, @ptrCast(@alignCast(ctx))).read(offset, sz);
    }
    fn uartWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*Pl011, @ptrCast(@alignCast(ctx))).write(offset, value, sz);
    }
    fn rtcRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*Pl031, @ptrCast(@alignCast(ctx))).read(offset, sz);
    }
    fn rtcWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*Pl031, @ptrCast(@alignCast(ctx))).write(offset, value, sz);
    }
    fn gicDistRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*Gicv2, @ptrCast(@alignCast(ctx))).distRead(offset, sz);
    }
    fn gicDistWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*Gicv2, @ptrCast(@alignCast(ctx))).distWrite(offset, value, sz);
    }
    fn gicCpuRead(ctx: *anyopaque, offset: u64, sz: u8) u64 {
        return @as(*Gicv2, @ptrCast(@alignCast(ctx))).cpuRead(offset, sz);
    }
    fn gicCpuWrite(ctx: *anyopaque, offset: u64, value: u64, sz: u8) void {
        @as(*Gicv2, @ptrCast(@alignCast(ctx))).cpuWrite(offset, value, sz);
    }

    /// Load a flat blob at `addr` (DTB / kernel Image / initramfs).
    fn loadFlat(self: *Machine, addr: u64, data: []const u8) !void {
        const dst = self.bus.ramSlice(addr, data.len) orelse return error.ImageTooLarge;
        @memcpy(dst, data);
    }

    /// Set up an arm64 Linux boot: place the DTB, kernel Image and (optional)
    /// initramfs into guest RAM. The accel backend (HVF/KVM) primes the vCPU
    /// boot registers (PC=kernel, X0=DTB, EL1h+DAIF masked) itself.
    pub fn bootLinux(self: *Machine, image: []const u8, dtb: []const u8, initrd: ?[]const u8) !void {
        try self.loadFlat(dtb_load, dtb);
        try self.loadFlat(kernel_load, image);
        if (initrd) |ir| try self.loadFlat(initrd_load, ir);
    }

    /// Publish a host TCP port that bridges to a guest port (QEMU-style
    /// hostfwd). No-op if networking is disabled.
    pub fn addHostForward(self: *Machine, host_port: u16, guest_port: u16) !void {
        if (self.natp) |nat| try nat.addHostForward(host_port, guest_port);
    }

    /// Register a compose inter-service forward on the NAT (guest connections to
    /// `vip:cport` are relayed to 127.0.0.1:hport, where a peer service listens).
    pub fn addServiceForward(self: *Machine, vip: [4]u8, cport: u16, hport: u16) !void {
        if (self.natp) |nat| try nat.addServiceForward(vip, cport, hport);
    }

    /// Ask the running guest to stop. Safe to call from another thread: it sets the
    /// cooperative flag the accel loop polls, then kicks the vCPU out of any
    /// blocking hypervisor run so the loop notices the flag promptly.
    pub fn requestStop(self: *Machine) void {
        self.stop_requested.store(true, .release);
        if (self.accel_kick) |kick| kick(self.accel_vcpu);
    }
};

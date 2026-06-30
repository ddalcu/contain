//! Flattened Device Tree (DTB) generation.
//!
//! `contain` emits its own device tree describing the `virt` machine — the same
//! approach QEMU takes — so the guest kernel discovers memory, the UART, the
//! interrupt controller, the timer and virtio devices, and reads the kernel
//! command line + initramfs location from /chosen.
//!
//! All multi-byte values in a DTB are big-endian.

const std = @import("std");

const FDT_BEGIN_NODE: u32 = 0x1;
const FDT_END_NODE: u32 = 0x2;
const FDT_PROP: u32 = 0x3;
const FDT_NOP: u32 = 0x4;
const FDT_END: u32 = 0x9;
const FDT_MAGIC: u32 = 0xd00d_feed;

/// Imperative builder for the struct + strings blocks.
pub const Builder = struct {
    alloc: std.mem.Allocator,
    structs: std.ArrayList(u8),
    strings: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) Builder {
        return .{ .alloc = alloc, .structs = .empty, .strings = .empty };
    }

    pub fn deinit(self: *Builder) void {
        self.structs.deinit(self.alloc);
        self.strings.deinit(self.alloc);
    }

    fn tok(self: *Builder, t: u32) !void {
        try appendBe32(&self.structs, self.alloc, t);
    }

    fn pad(self: *Builder) !void {
        while (self.structs.items.len % 4 != 0) try self.structs.append(self.alloc, 0);
    }

    /// Intern a property name in the strings block, returning its offset.
    fn strOff(self: *Builder, name: []const u8) !u32 {
        // Linear search for an existing identical entry (small table).
        var i: usize = 0;
        while (i < self.strings.items.len) {
            const s = std.mem.sliceTo(self.strings.items[i..], 0);
            if (std.mem.eql(u8, s, name)) return @intCast(i);
            i += s.len + 1;
        }
        const off: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.alloc, name);
        try self.strings.append(self.alloc, 0);
        return off;
    }

    pub fn beginNode(self: *Builder, name: []const u8) !void {
        try self.tok(FDT_BEGIN_NODE);
        try self.structs.appendSlice(self.alloc, name);
        try self.structs.append(self.alloc, 0);
        try self.pad();
    }

    pub fn endNode(self: *Builder) !void {
        try self.tok(FDT_END_NODE);
    }

    fn propHeader(self: *Builder, name: []const u8, len: u32) !void {
        try self.tok(FDT_PROP);
        try appendBe32(&self.structs, self.alloc, len);
        try appendBe32(&self.structs, self.alloc, try self.strOff(name));
    }

    pub fn propEmpty(self: *Builder, name: []const u8) !void {
        try self.propHeader(name, 0);
    }

    pub fn propStr(self: *Builder, name: []const u8, value: []const u8) !void {
        try self.propHeader(name, @intCast(value.len + 1));
        try self.structs.appendSlice(self.alloc, value);
        try self.structs.append(self.alloc, 0);
        try self.pad();
    }

    /// Concatenated list of NUL-terminated strings (stringlist property).
    pub fn propStrList(self: *Builder, name: []const u8, values: []const []const u8) !void {
        var total: usize = 0;
        for (values) |v| total += v.len + 1;
        try self.propHeader(name, @intCast(total));
        for (values) |v| {
            try self.structs.appendSlice(self.alloc, v);
            try self.structs.append(self.alloc, 0);
        }
        try self.pad();
    }

    /// Raw byte-blob property (e.g. /chosen/rng-seed).
    pub fn propBytes(self: *Builder, name: []const u8, value: []const u8) !void {
        try self.propHeader(name, @intCast(value.len));
        try self.structs.appendSlice(self.alloc, value);
        try self.pad();
    }

    pub fn propU32(self: *Builder, name: []const u8, value: u32) !void {
        try self.propHeader(name, 4);
        try appendBe32(&self.structs, self.alloc, value);
    }

    pub fn propU64(self: *Builder, name: []const u8, value: u64) !void {
        try self.propHeader(name, 8);
        try appendBe32(&self.structs, self.alloc, @truncate(value >> 32));
        try appendBe32(&self.structs, self.alloc, @truncate(value));
    }

    pub fn propCells(self: *Builder, name: []const u8, cells: []const u32) !void {
        try self.propHeader(name, @intCast(cells.len * 4));
        for (cells) |c| try appendBe32(&self.structs, self.alloc, c);
    }

    /// Finalize into a complete DTB blob. Caller owns the returned slice.
    pub fn finish(self: *Builder, alloc: std.mem.Allocator) ![]u8 {
        try self.tok(FDT_END);

        const rsv_align = 8;
        const header_size = 40;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        // Header placeholder (filled at the end).
        try out.appendNTimes(alloc, 0, header_size);
        // Memory reservation block (single empty terminator entry).
        while (out.items.len % rsv_align != 0) try out.append(alloc, 0);
        const off_mem_rsv: u32 = @intCast(out.items.len);
        try appendBe32(&out, alloc, 0);
        try appendBe32(&out, alloc, 0);
        try appendBe32(&out, alloc, 0);
        try appendBe32(&out, alloc, 0);
        // Struct block.
        while (out.items.len % 4 != 0) try out.append(alloc, 0);
        const off_struct: u32 = @intCast(out.items.len);
        try out.appendSlice(alloc, self.structs.items);
        const size_struct: u32 = @intCast(out.items.len - off_struct);
        // Strings block.
        const off_strings: u32 = @intCast(out.items.len);
        try out.appendSlice(alloc, self.strings.items);
        const size_strings: u32 = @intCast(out.items.len - off_strings);

        const total: u32 = @intCast(out.items.len);
        writeBe32(out.items[0..], FDT_MAGIC);
        writeBe32(out.items[4..], total);
        writeBe32(out.items[8..], off_struct);
        writeBe32(out.items[12..], off_strings);
        writeBe32(out.items[16..], off_mem_rsv);
        writeBe32(out.items[20..], 17); // version
        writeBe32(out.items[24..], 16); // last_comp_version
        writeBe32(out.items[28..], 0); // boot_cpuid_phys
        writeBe32(out.items[32..], size_strings);
        writeBe32(out.items[36..], size_struct);

        return out.toOwnedSlice(alloc);
    }
};

fn appendBe32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(alloc, &buf);
}

fn writeBe32(buf: []u8, v: u32) void {
    std.mem.writeInt(u32, buf[0..4], v, .big);
}

// ---- the virt machine device tree ------------------------------------------

pub const VirtDtbOptions = struct {
    ram_base: u64 = 0x4000_0000,
    ram_size: u64 = 256 * 1024 * 1024,
    bootargs: []const u8 = "console=ttyAMA0 earlycon=pl011,0x9000000",
    initrd_start: ?u64 = null,
    initrd_end: ?u64 = null,
    num_virtio: u32 = 0,
    /// Optional entropy blob for /chosen/rng-seed. Lets the kernel initialise its
    /// CRNG at boot instead of waiting seconds for interrupt entropy — important
    /// under a hardware backend where real-time boot is so fast that little
    /// interrupt jitter has accrued (node/V8 otherwise blocks on getrandom()).
    rng_seed: ?[]const u8 = null,
};

// virt machine memory map constants (matching QEMU and our machine.zig).
pub const gicd_base: u64 = 0x0800_0000;
pub const gicc_base: u64 = 0x0801_0000;
pub const uart_base: u64 = 0x0900_0000;
pub const rtc_base: u64 = 0x0901_0000;
pub const virtio_base: u64 = 0x0a00_0000;
pub const virtio_stride: u64 = 0x200;
pub const uart_spi: u32 = 1; // PL011 SPI #1 (INTID 33)
pub const rtc_spi: u32 = 2; // PL031 RTC SPI #2 (INTID 34; alarm only, never raised)
pub const virtio_spi_base: u32 = 16; // first virtio SPI

// GIC interrupt cell encoding.
const GIC_SPI: u32 = 0;
const GIC_PPI: u32 = 1;
const IRQ_LEVEL_HIGH: u32 = 4;
const IRQ_EDGE_RISING: u32 = 1;

/// Build the full virt DTB. Caller owns the returned blob.
pub fn buildVirtDtb(alloc: std.mem.Allocator, opts: VirtDtbOptions) ![]u8 {
    var b = Builder.init(alloc);
    defer b.deinit();

    try b.beginNode(""); // root
    try b.propU32("#address-cells", 2);
    try b.propU32("#size-cells", 2);
    try b.propStr("compatible", "linux,dummy-virt");
    try b.propStr("model", "contain-virt");
    try b.propU32("interrupt-parent", 2); // GIC phandle (defined below)

    // /psci — power management (emulated via SMC; lets the guest power off).
    try b.beginNode("psci");
    try b.propStrList("compatible", &.{ "arm,psci-1.0", "arm,psci-0.2" });
    try b.propStr("method", "smc");
    try b.endNode();

    // /chosen
    try b.beginNode("chosen");
    try b.propStr("bootargs", opts.bootargs);
    try b.propStr("stdout-path", "/pl011@9000000");
    if (opts.initrd_start) |s| try b.propU64("linux,initrd-start", s);
    if (opts.initrd_end) |e| try b.propU64("linux,initrd-end", e);
    if (opts.rng_seed) |seed| try b.propBytes("rng-seed", seed);
    try b.endNode();

    // /memory@40000000
    {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "memory@{x}", .{opts.ram_base});
        try b.beginNode(name);
        try b.propStr("device_type", "memory");
        try b.propCells("reg", &.{
            @truncate(opts.ram_base >> 32),  @truncate(opts.ram_base),
            @truncate(opts.ram_size >> 32),  @truncate(opts.ram_size),
        });
        try b.endNode();
    }

    // /cpus
    try b.beginNode("cpus");
    try b.propU32("#address-cells", 1);
    try b.propU32("#size-cells", 0);
    try b.beginNode("cpu@0");
    try b.propStr("device_type", "cpu");
    try b.propStr("compatible", "arm,cortex-a57");
    try b.propU32("reg", 0);
    try b.endNode();
    try b.endNode();

    // /timer (ARMv8 generic timer). PPIs: secure-phys 13, nonsecure-phys 14,
    // virt 11, hyp 10 (PPI numbers = INTID - 16).
    try b.beginNode("timer");
    try b.propStr("compatible", "arm,armv8-timer");
    try b.propCells("interrupts", &.{
        GIC_PPI, 13, IRQ_LEVEL_HIGH,
        GIC_PPI, 14, IRQ_LEVEL_HIGH,
        GIC_PPI, 11, IRQ_LEVEL_HIGH,
        GIC_PPI, 10, IRQ_LEVEL_HIGH,
    });
    try b.propU32("interrupt-parent", 2);
    try b.propEmpty("always-on");
    try b.endNode();

    // /apb-pclk fixed clock for the PL011.
    try b.beginNode("apb-pclk");
    try b.propStr("compatible", "fixed-clock");
    try b.propU32("#clock-cells", 0);
    try b.propU32("clock-frequency", 24_000_000);
    try b.propStr("clock-output-names", "clk24mhz");
    try b.propU32("phandle", 1);
    try b.endNode();

    // /intc (GICv2)
    try b.beginNode("intc");
    try b.propStr("compatible", "arm,cortex-a15-gic");
    try b.propU32("#interrupt-cells", 3);
    try b.propEmpty("interrupt-controller");
    try b.propCells("reg", &.{
        @truncate(gicd_base >> 32),     @truncate(gicd_base),     0, 0x1000,
        @truncate(gicc_base >> 32),     @truncate(gicc_base),     0, 0x2000,
    });
    try b.propU32("phandle", 2);
    try b.endNode();

    // root needs interrupt-parent referencing the GIC.
    // (emitted as a root property below via NOP-free ordering is awkward, so we
    //  set it on each device's node instead.)

    // /pl011@9000000
    {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "pl011@{x}", .{uart_base});
        try b.beginNode(name);
        try b.propStrList("compatible", &.{ "arm,pl011", "arm,primecell" });
        try b.propCells("reg", &.{ @truncate(uart_base >> 32), @truncate(uart_base), 0, 0x1000 });
        try b.propCells("interrupts", &.{ GIC_SPI, uart_spi, IRQ_LEVEL_HIGH });
        try b.propU32("interrupt-parent", 2);
        try b.propCells("clocks", &.{ 1, 1 });
        try b.propStrList("clock-names", &.{ "uartclk", "apb_pclk" });
        try b.endNode();
    }

    // /pl031@9010000 (RTC — exposes host wall-clock so the guest has a real date)
    {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "pl031@{x}", .{rtc_base});
        try b.beginNode(name);
        try b.propStrList("compatible", &.{ "arm,pl031", "arm,primecell" });
        try b.propCells("reg", &.{ @truncate(rtc_base >> 32), @truncate(rtc_base), 0, 0x1000 });
        try b.propCells("interrupts", &.{ GIC_SPI, rtc_spi, IRQ_LEVEL_HIGH });
        try b.propU32("interrupt-parent", 2);
        try b.propCells("clocks", &.{1});
        try b.propStr("clock-names", "apb_pclk");
        try b.endNode();
    }

    // /virtio_mmio@... devices
    var i: u32 = 0;
    while (i < opts.num_virtio) : (i += 1) {
        const addr = virtio_base + i * virtio_stride;
        var namebuf: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "virtio_mmio@{x}", .{addr});
        try b.beginNode(name);
        try b.propStr("compatible", "virtio,mmio");
        try b.propCells("reg", &.{ @truncate(addr >> 32), @truncate(addr), 0, @truncate(virtio_stride) });
        try b.propCells("interrupts", &.{ GIC_SPI, virtio_spi_base + i, IRQ_EDGE_RISING });
        try b.propU32("interrupt-parent", 2);
        try b.endNode();
    }

    try b.endNode(); // root
    return b.finish(alloc);
}

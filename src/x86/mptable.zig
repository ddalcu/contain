//! Intel MultiProcessor (MP) table for the x86-microvm platform.
//!
//! Our PVH kernel boots without ACPI, so it has no other way to learn that an
//! IOAPIC exists or how ISA IRQs route to it. Without that, the kernel falls back
//! to "virtual wire mode", never enables the IOAPIC, and the timer IRQ0 (and the
//! virtio GSIs) are never delivered — boot hangs early (e.g. in
//! vga_arb_device_init, the first initcall that waits on a jiffies-based timer).
//!
//! We replicate firecracker's MP table: a floating pointer at 0x9FC00 (the last
//! KB of conventional memory, where the kernel scans for "_MP_") pointing at a
//! config table describing 1 CPU, the ISA bus, one IOAPIC at 0xFEC00000, an
//! identity ISA-IRQ→IOAPIC-pin routing (so virtio_mmio.device=...:N lands on
//! IOAPIC pin N, the same pin we inject via KVM_IRQ_LINE), and the LINT0/LINT1
//! ExtINT+NMI local sources. This is platform-independent data plumbing (testable
//! on any host), mirroring x86/pvh.zig.

const std = @import("std");

/// Where the MP floating pointer lives — the last KB of conventional (640 KB)
/// memory, one of the regions the kernel scans for the "_MP_" signature.
pub const mptable_start: u64 = 0x9_FC00;

const apic_version: u8 = 0x14;
const lapic_base: u32 = 0xFEE0_0000;
const ioapic_base: u32 = 0xFEC0_0000;

// MP config entry types.
const MP_PROCESSOR: u8 = 0;
const MP_BUS: u8 = 1;
const MP_IOAPIC: u8 = 2;
const MP_INTSRC: u8 = 3;
const MP_LINTSRC: u8 = 4;

// Interrupt source types (mp_irq_source_types).
const MP_INT: u8 = 0;
const MP_NMI: u8 = 1;
const MP_EXTINT: u8 = 3;

const CPU_ENABLED: u8 = 1;
const CPU_BOOTPROCESSOR: u8 = 2;
const CPU_STEPPING: u32 = 0x600;
const CPU_FEATURE_APIC: u32 = 0x200;
const CPU_FEATURE_FPU: u32 = 0x001;
const MPC_APIC_USABLE: u8 = 1;

// We describe the full 24-pin IOAPIC so every legacy ISA IRQ and every virtio GSI
// (COM1=4, virtio=5,6,7,…) has a route.
const num_io_intsrc: u8 = 24;

const MpfIntel = extern struct {
    signature: [4]u8,
    physptr: u32,
    length: u8,
    specification: u8,
    checksum: u8,
    feature1: u8,
    feature2: u8,
    feature3: u8,
    feature4: u8,
    feature5: u8,
};

const McHeader = extern struct {
    signature: [4]u8,
    length: u16,
    spec: u8,
    checksum: u8,
    oem: [8]u8,
    productid: [12]u8,
    oemptr: u32,
    oemsize: u16,
    oemcount: u16,
    lapic: u32,
    reserved: u32,
};

const McCpu = extern struct {
    type: u8,
    apicid: u8,
    apicver: u8,
    cpuflag: u8,
    cpufeature: u32,
    featureflag: u32,
    reserved: [2]u32,
};

const McBus = extern struct {
    type: u8,
    busid: u8,
    bustype: [6]u8,
};

const McIoapic = extern struct {
    type: u8,
    apicid: u8,
    apicver: u8,
    flags: u8,
    apicaddr: u32,
};

const McIntsrc = extern struct {
    type: u8,
    irqtype: u8,
    irqflag: u16,
    srcbus: u8,
    srcbusirq: u8,
    dstapic: u8,
    dstirq: u8,
};

const McLintsrc = extern struct {
    type: u8,
    irqtype: u8,
    irqflag: u16,
    srcbusid: u8,
    srcbusirq: u8,
    destapic: u8,
    destapiclint: u8,
};

comptime {
    std.debug.assert(@sizeOf(MpfIntel) == 16);
    std.debug.assert(@sizeOf(McHeader) == 44);
    std.debug.assert(@sizeOf(McCpu) == 20);
    std.debug.assert(@sizeOf(McBus) == 8);
    std.debug.assert(@sizeOf(McIoapic) == 8);
    std.debug.assert(@sizeOf(McIntsrc) == 8);
    std.debug.assert(@sizeOf(McLintsrc) == 8);
}

fn appendStruct(ram: []u8, off: *usize, comptime T: type, value: T) void {
    const bytes = std.mem.asBytes(&value);
    @memcpy(ram[off.* .. off.* + bytes.len], bytes);
    off.* += bytes.len;
}

/// 8-bit two's-complement checksum: the byte that makes the region sum to 0.
fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return (~sum) +% 1;
}

/// Build the MP floating pointer + config table into `ram` (indexed from
/// `ram_base`). `num_cpus` is the number of enabled CPUs (CPU 0 is the BSP).
pub fn build(ram: []u8, ram_base: u64, num_cpus: u8) void {
    const ioapic_id: u8 = num_cpus + 1;
    const mpf_off: usize = @intCast(mptable_start - ram_base);
    const mpc_off: usize = mpf_off + @sizeOf(MpfIntel);

    // --- config table entries (after the 44-byte header) ---
    var off: usize = mpc_off + @sizeOf(McHeader);
    var nentries: u16 = 0;

    var cpu: u8 = 0;
    while (cpu < num_cpus) : (cpu += 1) {
        appendStruct(ram, &off, McCpu, .{
            .type = MP_PROCESSOR,
            .apicid = cpu,
            .apicver = apic_version,
            .cpuflag = CPU_ENABLED | (if (cpu == 0) CPU_BOOTPROCESSOR else 0),
            .cpufeature = CPU_STEPPING,
            .featureflag = CPU_FEATURE_APIC | CPU_FEATURE_FPU,
            .reserved = .{ 0, 0 },
        });
        nentries += 1;
    }

    appendStruct(ram, &off, McBus, .{
        .type = MP_BUS,
        .busid = 0,
        .bustype = .{ 'I', 'S', 'A', ' ', ' ', ' ' },
    });
    nentries += 1;

    appendStruct(ram, &off, McIoapic, .{
        .type = MP_IOAPIC,
        .apicid = ioapic_id,
        .apicver = apic_version,
        .flags = MPC_APIC_USABLE,
        .apicaddr = ioapic_base,
    });
    nentries += 1;

    var irq: u8 = 0;
    while (irq < num_io_intsrc) : (irq += 1) {
        appendStruct(ram, &off, McIntsrc, .{
            .type = MP_INTSRC,
            .irqtype = MP_INT,
            .irqflag = 0, // MP_IRQPOL_DEFAULT (conforms to bus)
            .srcbus = 0,
            .srcbusirq = irq,
            .dstapic = ioapic_id,
            .dstirq = irq, // identity: ISA IRQ N -> IOAPIC pin N
        });
        nentries += 1;
    }

    // ExtINT on LINT0, NMI on LINT1 (virtual-wire fallback the kernel still wants).
    appendStruct(ram, &off, McLintsrc, .{
        .type = MP_LINTSRC,
        .irqtype = MP_EXTINT,
        .irqflag = 0,
        .srcbusid = 0,
        .srcbusirq = 0,
        .destapic = 0,
        .destapiclint = 0,
    });
    nentries += 1;
    appendStruct(ram, &off, McLintsrc, .{
        .type = MP_LINTSRC,
        .irqtype = MP_NMI,
        .irqflag = 0,
        .srcbusid = 0,
        .srcbusirq = 0,
        .destapic = 0xFF,
        .destapiclint = 1,
    });
    nentries += 1;

    const mpc_len: u16 = @intCast(off - mpc_off);

    // --- config table header (now that we know the length + entry count) ---
    var header = McHeader{
        .signature = .{ 'P', 'C', 'M', 'P' },
        .length = mpc_len,
        .spec = 4,
        .checksum = 0,
        .oem = .{ 'F', 'C', ' ', ' ', ' ', ' ', ' ', ' ' },
        .productid = .{ '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0' },
        .oemptr = 0,
        .oemsize = 0,
        .oemcount = nentries,
        .lapic = lapic_base,
        .reserved = 0,
    };
    {
        var hoff = mpc_off;
        appendStruct(ram, &hoff, McHeader, header);
    }
    // Checksum over the whole config table (header + entries) must be 0.
    header.checksum = checksum(ram[mpc_off..off]);
    ram[mpc_off + @offsetOf(McHeader, "checksum")] = header.checksum;

    // --- floating pointer ---
    var mpf = MpfIntel{
        .signature = .{ '_', 'M', 'P', '_' },
        .physptr = @intCast(mptable_start + @sizeOf(MpfIntel)),
        .length = 1,
        .specification = 4,
        .checksum = 0,
        .feature1 = 0, // 0 => config table present (not a default config)
        .feature2 = 0,
        .feature3 = 0,
        .feature4 = 0,
        .feature5 = 0,
    };
    {
        var foff = mpf_off;
        appendStruct(ram, &foff, MpfIntel, mpf);
    }
    mpf.checksum = checksum(ram[mpf_off .. mpf_off + @sizeOf(MpfIntel)]);
    ram[mpf_off + @offsetOf(MpfIntel, "checksum")] = mpf.checksum;
}

//! Minimal I/O APIC (82093AA) for the x86-microvm under WHP.
//!
//! KVM provides an in-kernel IOAPIC, but WHP only emulates the local APIC, so the
//! VMM must model the IOAPIC: the guest programs a 24-entry redirection table via
//! the MMIO index/data window at 0xFEC00000, and when a device raises a GSI we look
//! up the matching entry and deliver its vector to the target LAPIC (the WHP
//! backend does that via WHvRequestInterrupt). This is the x86 analogue of the
//! emulated GICv2 distributor's role for device IRQs.

const std = @import("std");

pub const base: u64 = 0xFEC0_0000;
pub const size: u64 = 0x1000;

const num_redir = 24;

pub const Delivery = struct {
    vector: u32,
    dest: u32,
    delivery_mode: u32, // 0=Fixed, 1=LowestPriority, 4=NMI, ...
    dest_mode: u32, // 0=physical, 1=logical
    level: bool, // trigger mode: false=edge, true=level
};

pub const Ioapic = struct {
    // Indirect register selector (written to IOREGSEL at offset 0x00).
    index: u8 = 0,
    id: u32 = 0,
    // 24 redirection entries, each 64 bits (low/high dwords interleaved at
    // indices 0x10+2*n / 0x11+2*n).
    redir: [num_redir]u64 = [_]u64{0x0001_0000} ** num_redir, // masked at reset

    pub fn init() Ioapic {
        return .{};
    }

    /// Look up the redirection entry for `gsi`; returns the delivery info unless
    /// the entry is masked (bit 16). The caller injects it into the LAPIC.
    pub fn deliver(self: *Ioapic, gsi: u32) ?Delivery {
        if (gsi >= num_redir) return null;
        const e = self.redir[gsi];
        if ((e & (1 << 16)) != 0) return null; // masked
        return .{
            .vector = @intCast(e & 0xff),
            .dest = @intCast((e >> 56) & 0xff),
            .delivery_mode = @intCast((e >> 8) & 0x7),
            .dest_mode = @intCast((e >> 11) & 0x1),
            .level = ((e >> 15) & 1) != 0,
        };
    }

    pub fn read(self: *Ioapic, off: u64, sz: u8) u64 {
        _ = sz;
        return switch (off) {
            0x00 => self.index,
            0x10 => self.regRead(),
            else => 0,
        };
    }

    pub fn write(self: *Ioapic, off: u64, value: u64, sz: u8) void {
        _ = sz;
        switch (off) {
            0x00 => self.index = @truncate(value),
            0x10 => self.regWrite(@truncate(value)),
            else => {},
        }
    }

    fn regRead(self: *Ioapic) u32 {
        return switch (self.index) {
            0x00 => self.id,
            0x01 => (@as(u32, num_redir - 1) << 16) | 0x11, // version 0x11, max redir entry
            0x02 => 0, // arbitration
            else => blk: {
                if (self.index >= 0x10 and self.index < 0x10 + num_redir * 2) {
                    const n = (self.index - 0x10) / 2;
                    const hi = ((self.index - 0x10) & 1) != 0;
                    const e = self.redir[n];
                    break :blk if (hi) @as(u32, @truncate(e >> 32)) else @as(u32, @truncate(e));
                }
                break :blk 0;
            },
        };
    }

    fn regWrite(self: *Ioapic, value: u32) void {
        switch (self.index) {
            0x00 => self.id = value,
            else => {
                if (self.index >= 0x10 and self.index < 0x10 + num_redir * 2) {
                    const n = (self.index - 0x10) / 2;
                    const hi = ((self.index - 0x10) & 1) != 0;
                    if (hi) {
                        self.redir[n] = (self.redir[n] & 0x0000_0000_ffff_ffff) | (@as(u64, value) << 32);
                    } else {
                        self.redir[n] = (self.redir[n] & 0xffff_ffff_0000_0000) | value;
                    }
                }
            },
        }
    }

    // Bus trampolines.
    pub fn busRead(ctx: *anyopaque, off: u64, sz: u8) u64 {
        return @as(*Ioapic, @ptrCast(@alignCast(ctx))).read(off, sz);
    }
    pub fn busWrite(ctx: *anyopaque, off: u64, value: u64, sz: u8) void {
        @as(*Ioapic, @ptrCast(@alignCast(ctx))).write(off, value, sz);
    }
};

test "ioapic: program a redirection entry and deliver" {
    var io = Ioapic.init();
    // All entries masked at reset.
    try std.testing.expectEqual(@as(?Delivery, null), io.deliver(5));
    // Program GSI 5 -> vector 0x33, dest 0, unmasked, edge.
    io.write(0x00, 0x12, 4); // index = redir[5] low dword (0x10 + 2*5 - wait below)
    // redir[5] low dword is index 0x10 + 5*2 = 0x1A.
    io.write(0x00, 0x1a, 4);
    io.write(0x10, 0x33, 4); // vector 0x33, not masked
    io.write(0x00, 0x1b, 4);
    io.write(0x10, 0, 4); // dest 0
    const d = io.deliver(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x33), d.vector);
}

//! Minimal MC146818 CMOS RTC for the x86-microvm under WHP.
//!
//! WHP emulates no RTC, so reads of the CMOS data port (0x71) return all-ones; the
//! kernel then sees the status-A "update in progress" (UIP) bit permanently set and
//! polls 0x70/0x71 forever. We model just enough — a fixed, consistent time with
//! UIP clear and a valid status — so the RTC read completes. KVM has no in-kernel
//! CMOS either, but our KVM boot survived because jiffies advanced past the read
//! timeout; modelling it here is cleaner and unblocks WHP.

const std = @import("std");

pub const Cmos = struct {
    index: u8 = 0,

    pub fn init() Cmos {
        return .{};
    }

    /// Port 0x70 (index select) or 0x71 (data) write.
    pub fn write(self: *Cmos, port: u16, value: u8) void {
        switch (port) {
            0x70 => self.index = value & 0x7f, // low 7 bits select the register; bit7=NMI
            else => {}, // 0x71 data writes ignored (we present a fixed clock)
        }
    }

    /// Port 0x71 (data) read. A fixed, self-consistent time in BCD (the kernel
    /// reads twice and compares, so values must not change between reads).
    pub fn read(self: *Cmos, port: u16) u8 {
        if (port != 0x71) return 0xff;
        return switch (self.index) {
            0x00 => 0x00, // seconds
            0x02 => 0x00, // minutes
            0x04 => 0x00, // hours (24h)
            0x06 => 0x02, // day of week
            0x07 => 0x01, // day of month
            0x08 => 0x01, // month
            0x09 => 0x25, // year (BCD => 2025)
            0x0a => 0x20, // status A: UIP=0, rate bits set
            0x0b => 0x02, // status B: 24-hour, BCD
            0x0c => 0x00, // status C: no pending interrupts
            0x0d => 0x80, // status D: RAM/time valid
            0x32 => 0x20, // century (BCD => 20xx)
            else => 0x00,
        };
    }
};

test "cmos: status A has UIP clear and time is consistent across reads" {
    var c = Cmos.init();
    c.write(0x70, 0x0a);
    try std.testing.expectEqual(@as(u8, 0), c.read(0x71) & 0x80); // UIP clear
    c.write(0x70, 0x00);
    try std.testing.expectEqual(c.read(0x71), c.read(0x71)); // stable seconds
}

//! ARM PL031 Real-Time Clock (as exposed by the QEMU `virt` machine at
//! 0x09010000).
//!
//! contain has no battery-backed RTC, so without this the guest boots at epoch 0
//! (1 Jan 1970). A 1970 wall clock breaks anything time-sensitive: TLS rejects
//! server certificates as "not yet valid" (so npm/https fetches fail), and npm's
//! own time-based logic misbehaves. This device exposes the *host* wall-clock so
//! the guest comes up with the correct date.
//!
//! Time is read-only and always tracks the host: DR (0x00) returns the current
//! host time in epoch seconds. LR/MR/CR/interrupt registers are accepted so the
//! kernel's rtc-pl031 driver and `hwclock` are happy, but writes don't move the
//! clock (the guest can't change host time). Only host capability used is reading
//! the wall clock — minimal added attack surface.

const std = @import("std");

pub const Pl031 = struct {
    pub const base: u64 = 0x0901_0000;
    pub const size: u64 = 0x1000;

    // Register offsets.
    const DR = 0x000; // Data register (current time, seconds)
    const MR = 0x004; // Match register
    const LR = 0x008; // Load register
    const CR = 0x00c; // Control register
    const IMSC = 0x010; // Interrupt mask set/clear
    const RIS = 0x014; // Raw interrupt status
    const MIS = 0x018; // Masked interrupt status
    const ICR = 0x01c; // Interrupt clear

    // PrimeCell identification: AMBA id 0x00041031 (PL031). The amba bus matches
    // the rtc-pl031 driver on these, read from 0xFE0..0xFEC / 0xFF0..0xFFC.
    const periph_id = [_]u8{ 0x31, 0x10, 0x04, 0x00 };
    const pcell_id = [_]u8{ 0x0d, 0xf0, 0x05, 0xb1 };

    io: std.Io, // host clock source
    cr: u32 = 1, // RTCEN: enabled
    mr: u32 = 0,
    imsc: u32 = 0,

    pub fn init(io: std.Io) Pl031 {
        return .{ .io = io };
    }

    /// Current host wall-clock time in whole seconds since the Unix epoch.
    fn hostSeconds(self: *Pl031) i64 {
        return std.Io.Clock.now(.real, self.io).toSeconds();
    }

    pub fn read(self: *Pl031, off: u64, sz: u8) u64 {
        _ = sz;
        if (off >= 0xfe0 and off < 0x1000) {
            const idx: usize = @intCast((off - 0xfe0) / 4);
            return if (idx < 4) periph_id[idx] else pcell_id[idx - 4];
        }
        return switch (off) {
            DR => @intCast(@max(@as(i64, 0), self.hostSeconds())),
            MR => self.mr,
            CR => self.cr,
            IMSC => self.imsc,
            RIS, MIS => 0, // no interrupts ever pending
            else => 0,
        };
    }

    pub fn write(self: *Pl031, off: u64, val: u64, sz: u8) void {
        _ = sz;
        switch (off) {
            // LR would set the time; we ignore it (the clock follows the host).
            CR => self.cr = @truncate(val),
            MR => self.mr = @truncate(val),
            IMSC => self.imsc = @truncate(val),
            else => {},
        }
    }
};

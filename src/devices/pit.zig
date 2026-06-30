//! Minimal i8254 PIT (programmable interval timer) for the x86-microvm under WHP.
//!
//! WHP provides no PIT, but a from-scratch x86 kernel needs one to (a) calibrate
//! the TSC ("calibrate against PIT") and (b) have a legacy timer interrupt (IRQ0)
//! until it switches to the LAPIC timer. KVM has an in-kernel PIT, so this is only
//! used by the WHP backend.
//!
//! We model two channels against a host monotonic clock (the guest TSC is the host
//! TSC under WHP, so a wall-clock PIT makes the kernel's TSC calibration measure
//! the real frequency):
//!   - channel 0: rate generator -> IRQ0 (`gic.pulse(0)` -> IOAPIC -> LAPIC).
//!   - channel 2: one-shot the kernel polls via port 0x61 bit 5 (OUT2) to time the
//!     TSC calibration interval.

const Gicv2 = @import("gicv2.zig").Gicv2;

const pit_hz: u64 = 1_193_182; // the canonical i8254 input frequency

// Windows monotonic clock (this device is only used by the WHP backend, so these
// externs are only analyzed on the Windows path — like the other WHP externs).
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) c_int;

pub const Pit = struct {
    gic: *Gicv2,
    qpc_origin: i64, // QueryPerformanceCounter at init
    qpc_freq: i64, // ticks per second

    // channel 0 (timer IRQ0)
    ch0_reload: u32 = 0x10000, // counts; 0 programmed => 65536
    ch0_access: u8 = 0, // 1=lo,2=hi,3=lohi
    ch0_wr_hi: bool = false,
    ch0_running: bool = false,
    ch0_next_ns: i128 = 0,

    // channel 2 (calibration one-shot)
    ch2_reload: u32 = 0,
    ch2_access: u8 = 0,
    ch2_wr_hi: bool = false,
    ch2_gate: bool = false,
    ch2_start_ns: i128 = 0,
    ch2_armed: bool = false,
    port61: u8 = 0,

    pub fn init(gic: *Gicv2) Pit {
        var origin: i64 = 0;
        var freq: i64 = 1;
        _ = QueryPerformanceCounter(&origin);
        _ = QueryPerformanceFrequency(&freq);
        return .{ .gic = gic, .qpc_origin = origin, .qpc_freq = if (freq == 0) 1 else freq };
    }

    // Monotonic nanoseconds since `origin`.
    fn nowNs(self: *Pit) i128 {
        var c: i64 = 0;
        _ = QueryPerformanceCounter(&c);
        const elapsed: i128 = @as(i128, c - self.qpc_origin);
        return @divTrunc(elapsed * 1_000_000_000, @as(i128, self.qpc_freq));
    }
    fn elapsedNs(self: *Pit) i128 {
        return self.nowNs();
    }

    /// Service channel 0: inject IRQ0 for each elapsed period. Call from the vCPU
    /// run loop (cheap; integer compares).
    pub fn tick(self: *Pit) void {
        if (!self.ch0_running) return;
        const now = self.nowNs();
        var guard: u32 = 0;
        while (now >= self.ch0_next_ns and guard < 16) : (guard += 1) {
            self.gic.pulse(0); // IRQ0 -> IOAPIC pin 0 -> LAPIC vector
            const period_ns: i128 = @intCast((@as(u64, self.ch0_reload) * 1_000_000_000) / pit_hz);
            self.ch0_next_ns += if (period_ns == 0) 1 else period_ns;
        }
    }

    // ---- port I/O (0x40-0x43 PIT, 0x61 gate/speaker) ----
    pub fn read(self: *Pit, port: u16) u8 {
        switch (port) {
            0x61 => {
                // bit 5 = OUT2: high once channel 2's one-shot count has elapsed.
                var v = self.port61 & ~@as(u8, 0x20);
                if (self.ch2_armed and self.ch2_gate) {
                    const el: i128 = self.elapsedNs() - self.ch2_start_ns;
                    const ticks: i128 = @divTrunc(el * @as(i128, pit_hz), 1_000_000_000);
                    if (ticks >= self.ch2_reload) v |= 0x20;
                }
                return v;
            },
            else => return 0,
        }
    }

    pub fn write(self: *Pit, port: u16, value: u8) void {
        switch (port) {
            0x43 => self.control(value),
            0x40 => self.writeCount(0, value),
            0x42 => self.writeCount(2, value),
            0x61 => {
                self.port61 = value;
                self.ch2_gate = (value & 0x01) != 0;
                if (self.ch2_gate) {
                    self.ch2_start_ns = self.elapsedNs();
                    self.ch2_armed = true;
                }
            },
            else => {},
        }
    }

    fn control(self: *Pit, v: u8) void {
        const channel = (v >> 6) & 0x3;
        const access = (v >> 4) & 0x3;
        if (access == 0) return; // latch command: ignored (we don't model readback latch)
        if (channel == 0) {
            self.ch0_access = access;
            self.ch0_wr_hi = false;
        } else if (channel == 2) {
            self.ch2_access = access;
            self.ch2_wr_hi = false;
        }
    }

    fn writeCount(self: *Pit, channel: u8, v: u8) void {
        if (channel == 0) {
            self.ch0_reload = applyByte(&self.ch0_wr_hi, self.ch0_access, self.ch0_reload, v);
            if (countComplete(self.ch0_access, self.ch0_wr_hi)) {
                if (self.ch0_reload == 0) self.ch0_reload = 0x10000;
                self.ch0_running = true;
                const period_ns: i128 = @intCast((@as(u64, self.ch0_reload) * 1_000_000_000) / pit_hz);
                self.ch0_next_ns = self.nowNs() + (if (period_ns == 0) 1 else period_ns);
            }
        } else if (channel == 2) {
            self.ch2_reload = applyByte(&self.ch2_wr_hi, self.ch2_access, self.ch2_reload, v);
            if (countComplete(self.ch2_access, self.ch2_wr_hi)) {
                if (self.ch2_reload == 0) self.ch2_reload = 0x10000;
                self.ch2_start_ns = self.elapsedNs();
                self.ch2_armed = true;
            }
        }
    }

    fn applyByte(wr_hi: *bool, access: u8, cur: u32, v: u8) u32 {
        return switch (access) {
            1 => v, // lobyte only
            2 => @as(u32, v) << 8, // hibyte only
            else => blk: { // lo then hi
                const r = if (wr_hi.*) (cur & 0x00ff) | (@as(u32, v) << 8) else @as(u32, v);
                wr_hi.* = !wr_hi.*;
                break :blk r;
            },
        };
    }
    fn countComplete(access: u8, wr_hi: bool) bool {
        return access != 3 or !wr_hi; // for lohi, complete after the hi byte (wr_hi back to false)
    }
};

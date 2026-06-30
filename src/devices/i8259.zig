//! Minimal i8259A PIC pair for the x86-microvm under WHP.
//!
//! We route interrupts through the IOAPIC (symmetric I/O mode), so the PIC never
//! actually delivers — but a from-scratch x86 kernel *probes* for a legacy PIC
//! (writes the master IMR at port 0x21 and reads it back); if the readback differs
//! it falls back to the "NULL legacy PIC", which makes it skip PIT-based TSC
//! calibration (-> "Unable to calibrate against PIT"). So we model just enough: the
//! ICW init sequence and a readable/writable IMR, so the probe passes and the
//! kernel performs TSC calibration via the PIT. KVM has an in-kernel PIC, so this
//! is WHP-only.

const std = @import("std");

const Chip = struct {
    imr: u8 = 0xff, // OCW1 mask (all masked at reset)
    init_step: u8 = 0, // 0=idle, 1=expect ICW2, 2=expect ICW3, 3=expect ICW4
    icw4_needed: bool = false,
    single: bool = false,
    vector_base: u8 = 0,

    fn cmd(self: *Chip, v: u8) void {
        if ((v & 0x10) != 0) { // ICW1: begin init
            self.init_step = 1;
            self.icw4_needed = (v & 0x01) != 0;
            self.single = (v & 0x02) != 0;
        }
        // OCW2 (EOI) / OCW3 (read ISR/IRR, poll): ignored — IOAPIC owns delivery.
    }

    fn data(self: *Chip, v: u8) void {
        switch (self.init_step) {
            1 => { // ICW2: vector base
                self.vector_base = v;
                self.init_step = if (self.single) (if (self.icw4_needed) 3 else 0) else 2;
            },
            2 => self.init_step = if (self.icw4_needed) 3 else 0, // ICW3
            3 => self.init_step = 0, // ICW4 -> init complete
            else => self.imr = v, // OCW1: interrupt mask
        }
    }
};

pub const Pic = struct {
    master: Chip = .{},
    slave: Chip = .{},

    pub fn init() Pic {
        return .{};
    }

    pub fn read(self: *Pic, port: u16) u8 {
        return switch (port) {
            0x21 => self.master.imr,
            0xa1 => self.slave.imr,
            else => 0,
        };
    }

    pub fn write(self: *Pic, port: u16, value: u8) void {
        switch (port) {
            0x20 => self.master.cmd(value),
            0x21 => self.master.data(value),
            0xa0 => self.slave.cmd(value),
            0xa1 => self.slave.data(value),
            else => {},
        }
    }
};

test "i8259: master IMR readback survives the probe + init sequence" {
    var pic = Pic.init();
    // The probe writes a value to the master IMR (port 0x21) and reads it back.
    pic.write(0x21, 0xab);
    try std.testing.expectEqual(@as(u8, 0xab), pic.read(0x21));
    // A standard init sequence then sets the mask without corrupting readback.
    pic.write(0x20, 0x11); // ICW1: cascade + ICW4
    pic.write(0x21, 0x20); // ICW2: vector base
    pic.write(0x21, 0x04); // ICW3
    pic.write(0x21, 0x01); // ICW4
    pic.write(0x21, 0xfe); // OCW1: mask
    try std.testing.expectEqual(@as(u8, 0xfe), pic.read(0x21));
}

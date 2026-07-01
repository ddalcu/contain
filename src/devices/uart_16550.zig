//! 16550A UART (NS16550), the standard PC COM1 serial port at I/O ports
//! 0x3F8..0x3FF. This is the x86-microvm console (ttyS0), the x86 analogue of the
//! arm64 PL011. Unlike MMIO devices it is reached through **port I/O** (the x86
//! `in`/`out` instructions), which a hardware backend surfaces as an IO exit
//! (KVM_EXIT_IO / WHP X64IoPortAccess) routed to `read`/`write` here.
//!
//! Interrupts use the same router as everything else: it calls `gic.setIrq` on
//! its line; under x86-KVM the GIC's injector forwards that to the in-kernel
//! IOAPIC GSI (COM1 = IRQ 4). TX completes instantly (THR is always empty), so
//! the kernel's 8250 driver works in both polled and interrupt-driven modes.

const std = @import("std");
const Gicv2 = @import("gicv2.zig").Gicv2;
const OutSink = @import("../console.zig").OutSink;

pub const Uart16550 = struct {
    pub const base_port: u16 = 0x3F8;
    pub const nports: u16 = 8;

    // Register offsets (DLAB in LCR bit 7 selects the divisor latch at 0/1).
    const RBR_THR_DLL = 0; // read RBR / write THR (DLAB=0); DLL (DLAB=1)
    const IER_DLM = 1; // IER (DLAB=0); DLM (DLAB=1)
    const IIR_FCR = 2; // read IIR / write FCR
    const LCR = 3; // line control (bit7 = DLAB)
    const MCR = 4; // modem control
    const LSR = 5; // line status (read-only)
    const MSR = 6; // modem status
    const SCR = 7; // scratch

    // IER bits.
    const IER_RX_AVAIL = 0x01; // received-data-available interrupt
    const IER_THR_EMPTY = 0x02; // transmitter-holding-register-empty interrupt

    // LSR bits.
    const LSR_DR = 0x01; // data ready
    const LSR_THRE = 0x20; // THR empty
    const LSR_TEMT = 0x40; // transmitter empty

    // IIR interrupt-ident values (bit0=0 means an interrupt is pending).
    const IIR_NONE = 0x01;
    const IIR_THR_EMPTY = 0x02;
    const IIR_RX_AVAIL = 0x04;

    io: std.Io,
    out: std.Io.File,
    sink: OutSink = .{}, // when set, guest output goes here instead of stdout
    gic: *Gicv2,
    irq_id: u32, // GSI / line number (COM1 = 4)

    // Register state.
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    scr: u8 = 0,
    fcr: u8 = 0,
    dll: u8 = 0,
    dlm: u8 = 0,
    // True once the THR-empty interrupt has been signalled and not yet re-armed
    // by an IIR read (so a single enable doesn't storm).
    thr_int_pending: bool = false,

    // RX ring (host input -> guest), filled by the console reader.
    rx_buf: [256]u8 = undefined,
    rx_head: usize = 0,
    rx_tail: usize = 0,
    rx_lock: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init(io: std.Io, gic: *Gicv2, irq_id: u32) Uart16550 {
        return .{ .io = io, .out = std.Io.File.stdout(), .gic = gic, .irq_id = irq_id };
    }

    fn rxLockAcquire(self: *Uart16550) void {
        while (self.rx_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn rxLockRelease(self: *Uart16550) void {
        self.rx_lock.store(false, .release);
    }
    fn rxEmpty(self: *Uart16550) bool {
        return self.rx_head == self.rx_tail;
    }

    fn dlab(self: *Uart16550) bool {
        return (self.lcr & 0x80) != 0;
    }

    /// Whether the UART should assert its interrupt line.
    pub fn irqPending(self: *Uart16550) bool {
        if ((self.ier & IER_RX_AVAIL) != 0 and !self.rxEmpty()) return true;
        if ((self.ier & IER_THR_EMPTY) != 0 and self.thr_int_pending) return true;
        return false;
    }

    /// Ready to accept a scripted/console RX byte (buffer empty + RX int enabled).
    pub fn readyForRx(self: *Uart16550) bool {
        return self.rxEmpty() and (self.ier & IER_RX_AVAIL) != 0;
    }

    /// Push a received byte (host input thread / scripted input).
    pub fn pushRx(self: *Uart16550, b: u8) void {
        self.rxLockAcquire();
        defer self.rxLockRelease();
        const next = (self.rx_tail + 1) % self.rx_buf.len;
        if (next == self.rx_head) return; // drop on overflow
        self.rx_buf[self.rx_tail] = b;
        self.rx_tail = next;
    }

    pub fn read(self: *Uart16550, off: u64, sz: u8) u64 {
        _ = sz;
        switch (off) {
            RBR_THR_DLL => {
                if (self.dlab()) return self.dll;
                self.rxLockAcquire();
                defer self.rxLockRelease();
                if (self.rxEmpty()) return 0;
                const b = self.rx_buf[self.rx_head];
                self.rx_head = (self.rx_head + 1) % self.rx_buf.len;
                self.syncIrq();
                return b;
            },
            IER_DLM => return if (self.dlab()) self.dlm else self.ier,
            IIR_FCR => {
                const v = self.iir();
                // Reading IIR acknowledges/clears a THR-empty interrupt.
                self.thr_int_pending = false;
                self.syncIrq();
                return v;
            },
            LCR => return self.lcr,
            MCR => return self.mcr,
            LSR => {
                var v: u8 = LSR_THRE | LSR_TEMT; // TX always ready
                if (!self.rxEmpty()) v |= LSR_DR;
                return v;
            },
            MSR => return 0xb0, // DCD|DSR|CTS asserted: looks like a connected line
            SCR => return self.scr,
            else => return 0,
        }
    }

    pub fn write(self: *Uart16550, off: u64, value: u64, sz: u8) void {
        _ = sz;
        const v: u8 = @truncate(value);
        switch (off) {
            RBR_THR_DLL => {
                if (self.dlab()) {
                    self.dll = v;
                } else {
                    if (!self.sink.emit(&[_]u8{v}))
                        self.out.writeStreamingAll(self.io, &[_]u8{v}) catch {};
                    // TX done immediately -> re-arm the THR-empty interrupt.
                    if ((self.ier & IER_THR_EMPTY) != 0) self.thr_int_pending = true;
                    self.syncIrq();
                }
            },
            IER_DLM => {
                if (self.dlab()) {
                    self.dlm = v;
                } else {
                    self.ier = v;
                    if ((v & IER_THR_EMPTY) != 0) self.thr_int_pending = true;
                    self.syncIrq();
                }
            },
            IIR_FCR => self.fcr = v, // FIFO control: accepted, not modelled
            LCR => self.lcr = v,
            MCR => self.mcr = v,
            SCR => self.scr = v,
            else => {}, // LSR/MSR read-only
        }
    }

    fn iir(self: *Uart16550) u8 {
        if ((self.ier & IER_RX_AVAIL) != 0 and !self.rxEmpty()) return IIR_RX_AVAIL;
        if ((self.ier & IER_THR_EMPTY) != 0 and self.thr_int_pending) return IIR_THR_EMPTY;
        return IIR_NONE;
    }

    fn syncIrq(self: *Uart16550) void {
        self.gic.setIrq(self.irq_id, self.irqPending());
    }
};

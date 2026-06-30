//! ARM GICv2 interrupt controller (distributor + CPU interface), matching the
//! `virt` machine layout: distributor at 0x08000000, CPU interface at
//! 0x08010000. Single-CPU only.
//!
//! Devices raise interrupts via `setIrq(intid, level)`. After any state change
//! the controller recomputes whether an IRQ should be signalled to the CPU and
//! updates the shared IrqLine. The CPU acknowledges via IAR (CPU interface) and
//! signals completion via EOIR.

/// IRQ line state: raised by the GIC, polled by the active accel backend each
/// vCPU run-loop boundary (`m.irq.pending`). One bool — it lives here because the
/// interrupt controller owns it.
pub const IrqLine = struct {
    pending: bool = false,
};

pub const num_irqs = 256; // 32 PPI/SGI + SPIs

pub const Gicv2 = struct {
    pub const dist_base: u64 = 0x0800_0000;
    pub const dist_size: u64 = 0x1_0000;
    pub const cpu_base: u64 = 0x0801_0000;
    pub const cpu_size: u64 = 0x2_0000;

    // Distributor state.
    ctlr: u32 = 0,
    enabled: [num_irqs]bool = [_]bool{false} ** num_irqs,
    pending: [num_irqs]bool = [_]bool{false} ** num_irqs,
    active: [num_irqs]bool = [_]bool{false} ** num_irqs,
    priority: [num_irqs]u8 = [_]u8{0} ** num_irqs,
    // Input line level for level-triggered interrupts.
    level: [num_irqs]bool = [_]bool{false} ** num_irqs,
    // Trigger configuration: true = edge-triggered, false = level (GICD_ICFGR).
    edge: [num_irqs]bool = [_]bool{false} ** num_irqs,

    // CPU interface state.
    cpu_ctlr: u32 = 0,
    pmr: u32 = 0xff, // priority mask (allow all by default once set)
    running_intid: u32 = 1023, // 1023 = idle

    irq_line: *IrqLine,

    // IRQ-raise abstraction: when a hardware backend with an *in-kernel* irqchip
    // (KVM vGIC, WHP APIC) is active, device interrupt lines must be injected
    // into the hypervisor instead of driving this emulated distributor. The
    // backend installs an injector; devices keep calling `setIrq`/`pulse`
    // unchanged. When null (HVF's emulated-GIC path) the emulated distributor
    // below is used.
    inject_ctx: ?*anyopaque = null,
    inject_fn: ?*const fn (ctx: *anyopaque, intid: u32, level: bool) void = null,

    pub fn init(irq_line: *IrqLine) Gicv2 {
        return .{ .irq_line = irq_line };
    }

    /// Drive an interrupt input line (level-sensitive). For a level-triggered
    /// interrupt the pending state tracks the line: it asserts while the line is
    /// high and clears when the line drops (unless latched by being active).
    pub fn setIrq(self: *Gicv2, intid: u32, lvl: bool) void {
        if (intid >= num_irqs) return;
        if (self.level[intid] == lvl) return; // no edge, nothing to do
        self.level[intid] = lvl;
        if (self.inject_fn) |f| {
            f(self.inject_ctx.?, intid, lvl); // in-kernel irqchip owns the distributor
            return;
        }
        self.pending[intid] = lvl;
        self.update();
    }

    pub fn pulse(self: *Gicv2, intid: u32) void {
        if (intid >= num_irqs) return;
        if (self.inject_fn) |f| {
            f(self.inject_ctx.?, intid, true);
            f(self.inject_ctx.?, intid, false);
            return;
        }
        self.pending[intid] = true;
        self.update();
    }

    /// Highest-priority pending+enabled interrupt that is not already active,
    /// or 1023 if none.
    fn highestPending(self: *Gicv2) u32 {
        var best: u32 = 1023;
        var best_prio: u16 = 0x100;
        var i: u32 = 0;
        while (i < num_irqs) : (i += 1) {
            if (self.pending[i] and self.enabled[i] and !self.active[i]) {
                if (self.priority[i] < best_prio) {
                    best_prio = self.priority[i];
                    best = i;
                }
            }
        }
        return best;
    }

    pub fn update(self: *Gicv2) void {
        const dist_on = (self.ctlr & 1) != 0;
        const cpu_on = (self.cpu_ctlr & 1) != 0;
        const cand = self.highestPending();
        const signal = dist_on and cpu_on and cand != 1023 and
            (@as(u16, self.priority[cand]) < (self.pmr & 0xff));
        self.irq_line.pending = signal;
    }

    // ---- distributor MMIO ----
    pub fn distRead(self: *Gicv2, off: u64, sz: u8) u64 {
        _ = sz;
        return switch (off) {
            0x000 => self.ctlr, // GICD_CTLR
            0x004 => blk: { // GICD_TYPER: ITLinesNumber
                const itlines: u32 = (num_irqs / 32) - 1;
                break :blk itlines; // CPUNumber=0 -> 1 cpu
            },
            0x008 => 0x0200_043b, // GICD_IIDR (arm)
            else => self.distReadBanked(off),
        };
    }

    fn distReadBanked(self: *Gicv2, off: u64) u64 {
        // ISENABLER 0x100, ICENABLER 0x180 (1 bit/irq)
        if (off >= 0x100 and off < 0x180) return self.readBits(&self.enabled, (off - 0x100) * 8);
        if (off >= 0x180 and off < 0x200) return self.readBits(&self.enabled, (off - 0x180) * 8);
        if (off >= 0x200 and off < 0x280) return self.readBits(&self.pending, (off - 0x200) * 8);
        if (off >= 0x280 and off < 0x300) return self.readBits(&self.pending, (off - 0x280) * 8);
        // IPRIORITYR 0x400 (1 byte/irq)
        if (off >= 0x400 and off < 0x800) {
            const base = off - 0x400;
            var v: u64 = 0;
            var k: u64 = 0;
            while (k < 4) : (k += 1) {
                if (base + k < num_irqs) v |= @as(u64, self.priority[base + k]) << @intCast(k * 8);
            }
            return v;
        }
        // ICFGR 0xC00 (2 bits/irq; bit1 of each field = edge)
        if (off >= 0xc00 and off < 0xd00) {
            const base = ((off - 0xc00) / 4) * 16;
            var v: u64 = 0;
            var k: u64 = 0;
            while (k < 16) : (k += 1) {
                if (base + k < num_irqs and self.edge[base + k]) v |= @as(u64, 2) << @intCast(k * 2);
            }
            return v;
        }
        return 0;
    }

    pub fn distWrite(self: *Gicv2, off: u64, val: u64, sz: u8) void {
        _ = sz;
        switch (off) {
            0x000 => {
                self.ctlr = @truncate(val);
                self.update();
                return;
            },
            else => {},
        }
        if (off >= 0x100 and off < 0x180) {
            self.writeBitsSet(&self.enabled, (off - 0x100) * 8, val);
        } else if (off >= 0x180 and off < 0x200) {
            self.writeBitsClear(&self.enabled, (off - 0x180) * 8, val);
        } else if (off >= 0x200 and off < 0x280) {
            self.writeBitsSet(&self.pending, (off - 0x200) * 8, val);
        } else if (off >= 0x280 and off < 0x300) {
            self.writeBitsClear(&self.pending, (off - 0x280) * 8, val);
        } else if (off >= 0x400 and off < 0x800) {
            const base = off - 0x400;
            var k: u64 = 0;
            while (k < 4) : (k += 1) {
                if (base + k < num_irqs) self.priority[base + k] = @truncate(val >> @intCast(k * 8));
            }
        } else if (off >= 0xc00 and off < 0xd00) {
            const base = ((off - 0xc00) / 4) * 16;
            var k: u64 = 0;
            while (k < 16) : (k += 1) {
                if (base + k < num_irqs) self.edge[base + k] = ((val >> @intCast(k * 2 + 1)) & 1) == 1;
            }
        }
        self.update();
    }

    fn readBits(self: *Gicv2, arr: *const [num_irqs]bool, start: u64) u64 {
        _ = self;
        var v: u64 = 0;
        var i: u64 = 0;
        while (i < 32) : (i += 1) {
            if (start + i < num_irqs and arr[start + i]) v |= @as(u64, 1) << @intCast(i);
        }
        return v;
    }

    fn writeBitsSet(self: *Gicv2, arr: *[num_irqs]bool, start: u64, val: u64) void {
        _ = self;
        var i: u64 = 0;
        while (i < 32) : (i += 1) {
            if (start + i < num_irqs and (val >> @intCast(i)) & 1 == 1) arr[start + i] = true;
        }
    }

    fn writeBitsClear(self: *Gicv2, arr: *[num_irqs]bool, start: u64, val: u64) void {
        _ = self;
        var i: u64 = 0;
        while (i < 32) : (i += 1) {
            if (start + i < num_irqs and (val >> @intCast(i)) & 1 == 1) arr[start + i] = false;
        }
    }

    // ---- CPU interface MMIO ----
    pub fn cpuRead(self: *Gicv2, off: u64, sz: u8) u64 {
        _ = sz;
        return switch (off) {
            0x000 => self.cpu_ctlr, // GICC_CTLR
            0x004 => self.pmr, // GICC_PMR
            0x00c => self.acknowledge(), // GICC_IAR
            0x014 => self.running_intid, // GICC_RPR (approx)
            0x0fc => 0x0000_043b, // GICC_IIDR
            else => 0,
        };
    }

    pub fn cpuWrite(self: *Gicv2, off: u64, val: u64, sz: u8) void {
        _ = sz;
        switch (off) {
            0x000 => self.cpu_ctlr = @truncate(val),
            0x004 => self.pmr = @truncate(val),
            0x010 => self.endOfInterrupt(@truncate(val)), // GICC_EOIR
            else => {},
        }
        self.update();
    }

    /// IAR read: acknowledge the highest pending interrupt, mark it active,
    /// clear its pending state (for edge) and return its INTID.
    fn acknowledge(self: *Gicv2) u32 {
        const id = self.highestPending();
        if (id == 1023) return 1023;
        self.active[id] = true;
        // For level-triggered lines that are still asserted, keep pending; else clear.
        if (!self.level[id]) self.pending[id] = false;
        self.running_intid = id;
        self.update();
        return id;
    }

    fn endOfInterrupt(self: *Gicv2, intid: u32) void {
        if (intid < num_irqs) self.active[intid] = false;
        self.running_intid = 1023;
        // Re-evaluate level lines: if still asserted, re-pend.
        if (intid < num_irqs and self.level[intid]) self.pending[intid] = true;
        self.update();
    }
};

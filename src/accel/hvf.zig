//! HVF accel backend: run the arm64 guest on Apple Silicon's Hypervisor.framework.
//! The guest CPU executes natively; this file only handles VM exits — MMIO (to the
//! reused `Bus`/devices), PSCI (power-off), WFI (idle), and the virtual-timer ->
//! emulated-GICv2 PPI bridge.
//!
//! The hypervisor maps `m.bus.ram` at guest-physical `ram_base`, so the guest and
//! the device virtqueue code touch the same host buffer. Device IRQs flow through
//! the emulated GICv2; we translate the GIC's computed `irq.pending` line into
//! HVF's `set_pending_interrupt` injection.
//!
//! Gating: the Hypervisor.framework `extern` decls + run loop live behind a
//! comptime-known `hvf_supported`, so this file still *compiles* on every target.
//! `run` returns `error.HvfUnsupported` off-target.

const std = @import("std");
const builtin = @import("builtin");
const machine_mod = @import("../machine.zig");
const Machine = machine_mod.Machine;

/// HVF is arm64-macOS only (the framework + the guest ISA are both arm64).
pub const hvf_supported = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

pub fn run(m: *Machine) !void {
    if (hvf_supported) {
        try runImpl(m);
    } else {
        return error.HvfUnsupported;
    }
}

// ---- Hypervisor.framework C ABI -------------------------------------------
// Only referenced from the `hvf_supported` branch, so never analyzed (and never
// required at link time) on other targets.

const hv_vcpu_t = u64;

const VcpuExitException = extern struct {
    syndrome: u64, // ESR_EL2
    virtual_address: u64,
    physical_address: u64, // faulting IPA (guest-physical)
};
// reason:u32 then 4 bytes padding (exception is 8-aligned) then 3x u64 = 32 bytes.
const VcpuExit = extern struct {
    reason: u32,
    exception: VcpuExitException,
};

extern "c" fn hv_vm_create(config: ?*anyopaque) c_int;
extern "c" fn hv_vm_destroy() c_int;
extern "c" fn hv_vm_map(addr: *anyopaque, ipa: u64, size: usize, flags: u64) c_int;
extern "c" fn hv_vcpu_create(vcpu: *hv_vcpu_t, exit: **VcpuExit, config: ?*anyopaque) c_int;
extern "c" fn hv_vcpu_destroy(vcpu: hv_vcpu_t) c_int;
extern "c" fn hv_vcpu_run(vcpu: hv_vcpu_t) c_int;
extern "c" fn hv_vcpu_get_reg(vcpu: hv_vcpu_t, reg: c_int, value: *u64) c_int;
extern "c" fn hv_vcpu_set_reg(vcpu: hv_vcpu_t, reg: c_int, value: u64) c_int;
extern "c" fn hv_vcpu_get_sys_reg(vcpu: hv_vcpu_t, reg: u16, value: *u64) c_int;
extern "c" fn hv_vcpu_set_sys_reg(vcpu: hv_vcpu_t, reg: u16, value: u64) c_int;
extern "c" fn hv_vcpu_set_pending_interrupt(vcpu: hv_vcpu_t, irq_type: u32, pending: bool) c_int;
extern "c" fn hv_vcpu_set_vtimer_mask(vcpu: hv_vcpu_t, masked: bool) c_int;
extern "c" fn hv_vcpus_exit(vcpus: [*]const hv_vcpu_t, count: u32) c_int;

extern "c" fn mach_absolute_time() u64;
const MachTimebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *MachTimebase) c_int;

// hv_reg_t: X0..X30 = 0..30, PC = 31, FPCR=32, FPSR=33, CPSR = 34.
const HV_REG_X0: c_int = 0;
const HV_REG_PC: c_int = 31;
const HV_REG_CPSR: c_int = 34;

// hv_sys_reg_t (uint16, encoded (op0<<14)|(op1<<11)|(CRn<<7)|(CRm<<3)|op2).
const HV_SYS_REG_CNTV_CTL_EL0: u16 = 0xDF19;
const HV_SYS_REG_CNTV_CVAL_EL0: u16 = 0xDF1A;

// hv_memory_flags_t.
const HV_MEMORY_READ: u64 = 1;
const HV_MEMORY_WRITE: u64 = 2;
const HV_MEMORY_EXEC: u64 = 4;

// hv_exit_reason_t.
const HV_EXIT_CANCELED: u32 = 0;
const HV_EXIT_EXCEPTION: u32 = 1;
const HV_EXIT_VTIMER_ACTIVATED: u32 = 2;

// hv_interrupt_type_t.
const HV_INTERRUPT_TYPE_IRQ: u32 = 0;

const HV_SUCCESS: c_int = 0;
const HV_DENIED: u32 = 0xfae94006;

// CPSR for the arm64 Linux entry: EL1h (M=0b0101) + DAIF all masked.
const cpsr_el1h_daif: u64 = 0x3c5;

// GICv2 PPI 27 = CNTV (virtual timer); matches machine.zig's `virt_timer_ppi`.
const virt_timer_ppi: u32 = 27;

// CNTV_CTL_EL0 bits.
const TMR_ENABLE: u64 = 1; // bit0
const TMR_IMASK: u64 = 2; // bit1
const TMR_ISTATUS: u64 = 4; // bit2

fn hvOk(ret: c_int, comptime what: []const u8) !void {
    if (ret == HV_SUCCESS) return;
    const u: u32 = @bitCast(ret);
    if (u == HV_DENIED) {
        std.debug.print(
            "[hvf] {s} failed: HV_DENIED (0x{x}). The binary needs the hypervisor entitlement.\n" ++
                "       Sign it:  codesign --entitlements hv.entitlements --force -s - zig-out/bin/contain\n",
            .{ what, u },
        );
    } else {
        std.debug.print("[hvf] {s} failed: 0x{x}\n", .{ what, u });
    }
    return error.HvfCallFailed;
}

fn getReg(vcpu: hv_vcpu_t, reg: c_int) u64 {
    var v: u64 = 0;
    _ = hv_vcpu_get_reg(vcpu, reg, &v);
    return v;
}

fn setReg(vcpu: hv_vcpu_t, reg: c_int, v: u64) void {
    _ = hv_vcpu_set_reg(vcpu, reg, v);
}

fn getSysReg(vcpu: hv_vcpu_t, reg: u16) u64 {
    var v: u64 = 0;
    _ = hv_vcpu_get_sys_reg(vcpu, reg, &v);
    return v;
}

/// Sign-extend the low `src_bits` of `val` to 64 bits.
/// Shadow store for the system registers HVF traps to us (EC 0x18) — mostly
/// debug / OS-lock / PMU registers that the guest reads back after writing. We
/// emulate them as a generic key->value store: a write stores the
/// value, a read returns the last write (default 0). This handles the common
/// read-after-write idiom (e.g. MDSCR_EL1) without modelling each register, and
/// is RAZ/WI for write-only / never-written ones. Registers the guest must see
/// real values for (the generic counters) are not trapped by HVF.
const SysregShadow = struct {
    keys: [128]u32 = undefined,
    vals: [128]u64 = undefined,
    n: usize = 0,

    fn find(self: *SysregShadow, key: u32) ?usize {
        var i: usize = 0;
        while (i < self.n) : (i += 1) if (self.keys[i] == key) return i;
        return null;
    }
    fn get(self: *SysregShadow, key: u32) u64 {
        return if (self.find(key)) |i| self.vals[i] else 0;
    }
    fn set(self: *SysregShadow, key: u32, val: u64) void {
        if (self.find(key)) |i| {
            self.vals[i] = val;
        } else if (self.n < self.keys.len) {
            self.keys[self.n] = key;
            self.vals[self.n] = val;
            self.n += 1;
        }
    }
};

/// Trapped MSR/MRS (EC 0x18). Decode the ISS register encoding and service it
/// from the shadow store, then advance past the instruction.
fn handleSysReg(vcpu: hv_vcpu_t, esr: u64, shadow: *SysregShadow) void {
    const op0: u32 = @intCast((esr >> 20) & 0x3);
    const op2: u32 = @intCast((esr >> 17) & 0x7);
    const op1: u32 = @intCast((esr >> 14) & 0x7);
    const crn: u32 = @intCast((esr >> 10) & 0xf);
    const rt: u5 = @intCast((esr >> 5) & 0x1f);
    const crm: u32 = @intCast((esr >> 1) & 0xf);
    const is_read = (esr & 1) != 0; // 1 = MRS (read), 0 = MSR (write)
    const key: u32 = (op0 << 16) | (op1 << 13) | (crn << 9) | (crm << 5) | op2;

    if (is_read) {
        const v = shadow.get(key);
        if (rt != 31) setReg(vcpu, @as(c_int, rt), v);
    } else {
        shadow.set(key, if (rt == 31) 0 else getReg(vcpu, @as(c_int, rt)));
    }
    setReg(vcpu, HV_REG_PC, getReg(vcpu, HV_REG_PC) +% 4);
}

fn signExtendFrom(val: u64, src_bits: u32) u64 {
    if (src_bits >= 64) return val;
    const shift: u6 = @intCast(64 - src_bits);
    const sv: i64 = @bitCast(val << shift);
    return @bitCast(sv >> shift);
}

fn ticksToNs(ticks: u64) u64 {
    var tb: MachTimebase = .{ .numer = 0, .denom = 0 };
    _ = mach_timebase_info(&tb);
    if (tb.denom == 0) return 5 * std.time.ns_per_ms;
    const prod = std.math.mul(u64, ticks, tb.numer) catch return std.math.maxInt(u64);
    return prod / tb.denom;
}

fn runImpl(m: *Machine) !void {
    const ram_ptr = m.bus.ram.ptr;
    const ram_len = m.bus.ram.len;
    const ipa = m.bus.ram_base;
    // HVF on Apple Silicon requires 16 KB-granule alignment for mappings.
    std.debug.assert(@intFromPtr(ram_ptr) % 0x4000 == 0);
    std.debug.assert(ipa % 0x4000 == 0 and ram_len % 0x4000 == 0);

    try hvOk(hv_vm_create(null), "hv_vm_create");
    defer _ = hv_vm_destroy();
    try hvOk(hv_vm_map(@ptrCast(ram_ptr), ipa, ram_len, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC), "hv_vm_map");

    var vcpu: hv_vcpu_t = 0;
    var exit: *VcpuExit = undefined;
    try hvOk(hv_vcpu_create(&vcpu, &exit, null), "hv_vcpu_create");
    defer _ = hv_vcpu_destroy(vcpu);

    // arm64 Linux boot protocol (mirrors machine.bootLinux): PC=kernel, X0=DTB,
    // X1..3 = 0, entering at EL1h with interrupts masked.
    setReg(vcpu, HV_REG_PC, machine_mod.kernel_load);
    setReg(vcpu, HV_REG_X0, machine_mod.dtb_load);
    setReg(vcpu, HV_REG_X0 + 1, 0);
    setReg(vcpu, HV_REG_X0 + 2, 0);
    setReg(vcpu, HV_REG_X0 + 3, 0);
    setReg(vcpu, HV_REG_CPSR, cpsr_el1h_daif);

    var running = true;
    // HVF auto-masks its virtual timer when it fires (VTIMER_ACTIVATED); we hold
    // the emulated PPI 27 asserted and unmask once the guest clears the timer.
    var vtimer_masked = false;
    var shadow: SysregShadow = .{};

    while (running) {
        syncVtimer(vcpu, m, &vtimer_masked);
        m.serviceDevicesHw();
        // Not sticky — re-assert the GIC's current line on every entry.
        _ = hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, m.irq.pending);

        try hvOk(hv_vcpu_run(vcpu), "hv_vcpu_run");

        switch (exit.reason) {
            HV_EXIT_VTIMER_ACTIVATED => {
                m.gic.setIrq(virt_timer_ppi, true);
                vtimer_masked = true;
            },
            HV_EXIT_EXCEPTION => {
                const esr = exit.exception.syndrome;
                const ec = (esr >> 26) & 0x3f;
                switch (ec) {
                    0x24 => handleDataAbort(vcpu, m, esr, exit.exception.physical_address) catch {
                        running = false;
                    },
                    0x16, 0x17 => handlePsci(vcpu, &running), // HVC / SMC -> PSCI
                    0x18 => handleSysReg(vcpu, esr, &shadow), // trapped MSR/MRS
                    0x01 => handleWfx(vcpu, m), // WFI / WFE
                    else => {
                        std.debug.print("[hvf] unhandled exception EC=0x{x} esr=0x{x} pc=0x{x}\n", .{ ec, esr, getReg(vcpu, HV_REG_PC) });
                        running = false;
                    },
                }
            },
            HV_EXIT_CANCELED => {}, // kicked by hv_vcpus_exit; re-service + re-run
            else => {
                std.debug.print("[hvf] unknown exit reason {d}\n", .{exit.reason});
                running = false;
            },
        }
    }
}

/// Bridge HVF's real virtual timer to the emulated GICv2 PPI 27. Only does work
/// while the timer is HVF-masked (i.e. after it fired); reads the guest's
/// CNTV_CTL and de-asserts + unmasks once the guest has cleared the condition.
fn syncVtimer(vcpu: hv_vcpu_t, m: *Machine, vtimer_masked: *bool) void {
    if (!vtimer_masked.*) return;
    const ctl = getSysReg(vcpu, HV_SYS_REG_CNTV_CTL_EL0);
    const asserted = (ctl & (TMR_ENABLE | TMR_IMASK | TMR_ISTATUS)) == (TMR_ENABLE | TMR_ISTATUS);
    m.gic.setIrq(virt_timer_ppi, asserted);
    if (!asserted) {
        _ = hv_vcpu_set_vtimer_mask(vcpu, false);
        vtimer_masked.* = false;
    }
}

/// Stage-2 data abort = guest MMIO. The ESR's ISS gives the access width and the
/// transfer register; the faulting IPA goes straight into the Bus (it resolves
/// the device base + RAM check). ISV==0 (no decoded syndrome — e.g. LDP/STP to
/// MMIO) is not yet handled (instruction-decode fallback deferred).
fn handleDataAbort(vcpu: hv_vcpu_t, m: *Machine, esr: u64, pa: u64) !void {
    const isv = (esr >> 24) & 1;
    if (isv == 0) {
        std.debug.print("[hvf] MMIO with ISV=0 (esr=0x{x} ipa=0x{x}) — insn-decode fallback not implemented\n", .{ esr, pa });
        return error.HvfUnhandledMmio;
    }
    const sas: u3 = @intCast((esr >> 22) & 3);
    const size: u8 = @as(u8, 1) << sas;
    const sse = ((esr >> 21) & 1) != 0; // sign-extend
    const srt: u5 = @intCast((esr >> 16) & 0x1f); // transfer register (31 = XZR)
    const sf = ((esr >> 15) & 1) != 0; // 64-bit register width
    const wnr = ((esr >> 6) & 1) != 0; // write, not read

    if (wnr) {
        const val: u64 = if (srt == 31) 0 else getReg(vcpu, @as(c_int, srt));
        m.bus.write(pa, val, size);
    } else {
        var val = m.bus.read(pa, size);
        if (sse) val = signExtendFrom(val, @as(u32, size) * 8);
        if (!sf) val &= 0xffff_ffff; // W register zero-extends to X
        if (srt != 31) setReg(vcpu, @as(c_int, srt), val);
    }
    m.bus.fault = false; // a clean MMIO access; clear any stale miss flag
    setReg(vcpu, HV_REG_PC, getReg(vcpu, HV_REG_PC) +% 4);
}

/// PSCI firmware call (HVC/SMC): SYSTEM_OFF/RESET halt the VM; PSCI_VERSION
/// returns 1.0; everything else returns NOT_SUPPORTED.
fn handlePsci(vcpu: hv_vcpu_t, running: *bool) void {
    switch (getReg(vcpu, HV_REG_X0)) {
        0x8400_0008, 0x8400_0009 => running.* = false, // SYSTEM_OFF / SYSTEM_RESET
        0x8400_0000 => setReg(vcpu, HV_REG_X0, 0x1_0000), // PSCI_VERSION = 1.0
        else => setReg(vcpu, HV_REG_X0, @bitCast(@as(i64, -1))), // NOT_SUPPORTED
    }
    setReg(vcpu, HV_REG_PC, getReg(vcpu, HV_REG_PC) +% 4);
}

/// WFI/WFE: the guest is idle. Retire the instruction, then park the host thread
/// in <=5 ms slices — servicing devices each slice so console/RX still flow —
/// until an interrupt is pending or the virtual-timer deadline passes (resuming
/// then lets HVF re-fire VTIMER_ACTIVATED), using HVF's real timer as the clock.
fn handleWfx(vcpu: hv_vcpu_t, m: *Machine) void {
    setReg(vcpu, HV_REG_PC, getReg(vcpu, HV_REG_PC) +% 4);
    const slice_ns: u64 = 5 * std.time.ns_per_ms;
    while (true) {
        m.serviceDevicesHw();
        if (m.irq.pending) return;

        var sleep_ns = slice_ns;
        const ctl = getSysReg(vcpu, HV_SYS_REG_CNTV_CTL_EL0);
        if ((ctl & (TMR_ENABLE | TMR_IMASK)) == TMR_ENABLE) { // enabled, not masked
            const cval = getSysReg(vcpu, HV_SYS_REG_CNTV_CVAL_EL0);
            const now = mach_absolute_time();
            if (cval <= now) return; // deadline reached; resume to fire the vtimer
            const ns = ticksToNs(cval - now);
            if (ns < sleep_ns) sleep_ns = ns;
        }
        m.io.sleep(std.Io.Duration.fromNanoseconds(@intCast(sleep_ns)), .awake) catch {};
    }
}

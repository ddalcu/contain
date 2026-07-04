//! WHP accel backend: run the x86-microvm guest on the Windows Hypervisor Platform
//! (WinHvPlatform.dll + WinHvEmulation.dll). Like the KVM backend it reuses the x86
//! machine, Bus and NAT verbatim — WHP maps `m.bus.ram` at guest-physical 0 and
//! IO/MMIO exits route to `m.uart16550` / `m.bus`.
//!
//! Differences from KVM (which has an in-kernel irqchip + decoded MMIO):
//!  1. WHP only emulates the **local APIC** (LocalApicEmulationMode=XApic). The
//!     IOAPIC/PIC/PIT are not provided, so we emulate a minimal IOAPIC
//!     (src/devices/ioapic.zig, MMIO at 0xFEC00000) and deliver device IRQs to the
//!     LAPIC via WHvRequestInterrupt through the GIC's `inject_fn` hook.
//!  2. WHP does **not** pre-decode MMIO/IO, so we drive the **WHP instruction
//!     emulator** (WHvEmulatorTryMmio/IoEmulation), whose callbacks route memory
//!     accesses to `m.bus` and port accesses to the 16550. The emulator advances
//!     RIP and reads/writes guest registers for us.
//!  3. The DLLs are loaded at runtime (LoadLibrary/GetProcAddress) so there is no
//!     build-time import-library dependency.
//!
//! Gating mirrors hvf.zig/kvm.zig: everything Windows-specific lives behind the
//! comptime-known `whp_supported`, referenced only inside `whp_supported` branches,
//! so the `.winapi` externs/callbacks are never analyzed on other targets.

const std = @import("std");
const builtin = @import("builtin");
const machine_mod = @import("../machine.zig");
const Machine = machine_mod.Machine;
const Uart16550 = @import("../devices/uart_16550.zig").Uart16550;
const ioapic_mod = @import("../devices/ioapic.zig");
const Ioapic = ioapic_mod.Ioapic;
const Pit = @import("../devices/pit.zig").Pit;
const Pic = @import("../devices/i8259.zig").Pic;
const Cmos = @import("../devices/cmos.zig").Cmos;

pub const whp_supported = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;

pub fn run(m: *Machine) !void {
    if (whp_supported) {
        try runImpl(m);
    } else {
        return error.WhpUnsupported;
    }
}

// ---- Win32 loader (kernel32; bundled, no SDK import lib needed) -------------
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

// Background timer thread: WHvRunVirtualProcessor blocks on guest HLT, and we
// cannot inject the PIT tick from the (blocked) vCPU thread — so a separate thread
// pulses the PIT, whose IRQ0 (WHvRequestInterrupt, thread-safe) wakes the vCPU.
const TimerThread = struct {
    pit: *Pit,
    whp: *const Whp,
    p: Handle,
    running: std.atomic.Value(bool),
    fn loop(self: *TimerThread) void {
        var n: u32 = 0;
        while (self.running.load(.acquire)) {
            Sleep(1);
            self.pit.tick();
            // Periodically break a blocked RunVirtualProcessor so the vCPU loop can
            // notice a permanently-halted (powered-off) guest and stop.
            n += 1;
            if (n % 200 == 0) _ = self.whp.CancelRunVirtualProcessor(self.p, 0, 0);
        }
    }
};

// ---- WHP types (WinHvPlatformDefs.h / WinHvEmulation.h) ---------------------
const HRESULT = i32;
const Handle = *anyopaque;

const SegmentRegister = extern struct {
    base: u64 = 0,
    limit: u32 = 0,
    selector: u16 = 0,
    attributes: u16 = 0,
};
const RegisterValue = extern union {
    reg64: u64,
    segment: SegmentRegister,
    reg128: [16]u8,
};

// Register names (WHV_REGISTER_NAME).
const REG_RAX: u32 = 0x00;
const REG_RIP: u32 = 0x10;
const REG_RFLAGS: u32 = 0x11;
const REG_ES: u32 = 0x12;
const REG_CS: u32 = 0x13;
const REG_SS: u32 = 0x14;
const REG_DS: u32 = 0x15;
const REG_FS: u32 = 0x16;
const REG_GS: u32 = 0x17;
const REG_RBX: u32 = 0x03;
const REG_CR0: u32 = 0x1C;
const REG_CR4: u32 = 0x1F;
const REG_EFER: u32 = 0x2001;

const PROP_LOCAL_APIC_EMULATION_MODE: u32 = 0x00001005;
const PROP_PROCESSOR_COUNT: u32 = 0x00001fff;
const LOCAL_APIC_MODE_XAPIC: u32 = 1;
const CAP_HYPERVISOR_PRESENT: u32 = 0x00000000;
const MAP_READ: u32 = 0x1;
const MAP_WRITE: u32 = 0x2;
const MAP_EXECUTE: u32 = 0x4;

// Exit reasons.
const EXIT_MEMORY_ACCESS: u32 = 0x1;
const EXIT_IO_PORT: u32 = 0x2;
const EXIT_UNRECOVERABLE: u32 = 0x4;
const EXIT_INTERRUPT_WINDOW: u32 = 0x7;
const EXIT_HALT: u32 = 0x8;
const EXIT_APIC_EOI: u32 = 0x9;
const EXIT_CANCELED: u32 = 0x2001;

const VpExitContext = extern struct {
    execution_state: u16,
    instr_len_cr8: u8,
    reserved: u8,
    reserved2: u32,
    cs: SegmentRegister,
    rip: u64,
    rflags: u64,
};
const IoPortAccessCtx = extern struct {
    instr_byte_count: u8,
    reserved: [3]u8,
    instr_bytes: [16]u8,
    access_info: u32,
    port: u16,
    reserved2: [3]u16,
    rax: u64,
    rcx: u64,
    rsi: u64,
    rdi: u64,
    ds: SegmentRegister,
    es: SegmentRegister,
};
const MemoryAccessCtx = extern struct {
    instr_byte_count: u8,
    reserved: [3]u8,
    instr_bytes: [16]u8,
    access_info: u32,
    gpa: u64,
    gva: u64,
};
const RunExitContext = extern struct {
    exit_reason: u32,
    reserved: u32,
    vp_context: VpExitContext,
    union_data: [160]u8,
};
const InterruptControl = extern struct {
    type_dest_trigger: u64, // Type:8, DestMode:4, TriggerMode:4, Reserved:48
    destination: u32,
    vector: u32,
};

// Emulator types (WinHvEmulation.h).
const EmulatorStatus = u32; // bit0 = EmulationSuccessful
const EmuMemoryAccessInfo = extern struct {
    gpa: u64,
    direction: u8, // 0 = read, 1 = write
    access_size: u8,
    data: [8]u8,
};
const EmuIoAccessInfo = extern struct {
    direction: u8, // 0 = in(read), 1 = out(write)
    port: u16,
    access_size: u16,
    data: u32,
};
const TranslateGvaResult = extern struct { result_code: u32, reserved: u32 };
const EmulatorCallbacks = extern struct {
    size: u32,
    reserved: u32,
    io_port: *const fn (ctx: *anyopaque, io: *EmuIoAccessInfo) callconv(.winapi) HRESULT,
    memory: *const fn (ctx: *anyopaque, mem: *EmuMemoryAccessInfo) callconv(.winapi) HRESULT,
    get_regs: *const fn (ctx: *anyopaque, names: [*]const u32, count: u32, values: [*]RegisterValue) callconv(.winapi) HRESULT,
    set_regs: *const fn (ctx: *anyopaque, names: [*]const u32, count: u32, values: [*]const RegisterValue) callconv(.winapi) HRESULT,
    translate_gva: *const fn (ctx: *anyopaque, gva: u64, flags: u32, result: *u32, gpa: *u64) callconv(.winapi) HRESULT,
};

// ---- function pointers -----------------------------------------------------
const Whp = struct {
    GetCapability: *const fn (code: u32, buf: *anyopaque, sz: u32, written: ?*u32) callconv(.winapi) HRESULT,
    CreatePartition: *const fn (out: *Handle) callconv(.winapi) HRESULT,
    SetupPartition: *const fn (p: Handle) callconv(.winapi) HRESULT,
    DeletePartition: *const fn (p: Handle) callconv(.winapi) HRESULT,
    SetPartitionProperty: *const fn (p: Handle, code: u32, buf: *const anyopaque, sz: u32) callconv(.winapi) HRESULT,
    MapGpaRange: *const fn (p: Handle, src: *anyopaque, gpa: u64, size: u64, flags: u32) callconv(.winapi) HRESULT,
    CreateVirtualProcessor: *const fn (p: Handle, vp: u32, flags: u32) callconv(.winapi) HRESULT,
    RunVirtualProcessor: *const fn (p: Handle, vp: u32, ctx: *anyopaque, ctx_sz: u32) callconv(.winapi) HRESULT,
    CancelRunVirtualProcessor: *const fn (p: Handle, vp: u32, flags: u32) callconv(.winapi) HRESULT,
    GetVirtualProcessorRegisters: *const fn (p: Handle, vp: u32, names: [*]const u32, count: u32, values: [*]RegisterValue) callconv(.winapi) HRESULT,
    SetVirtualProcessorRegisters: *const fn (p: Handle, vp: u32, names: [*]const u32, count: u32, values: [*]const RegisterValue) callconv(.winapi) HRESULT,
    RequestInterrupt: *const fn (p: Handle, ctrl: *const InterruptControl, sz: u32) callconv(.winapi) HRESULT,
    TranslateGva: *const fn (p: Handle, vp: u32, gva: u64, flags: u32, result: *TranslateGvaResult, gpa: *u64) callconv(.winapi) HRESULT,
    EmulatorCreate: *const fn (cb: *const EmulatorCallbacks, out: *Handle) callconv(.winapi) HRESULT,
    EmulatorTryIo: *const fn (emu: Handle, ctx: *anyopaque, vp: *const VpExitContext, io: *const IoPortAccessCtx, status: *EmulatorStatus) callconv(.winapi) HRESULT,
    EmulatorTryMmio: *const fn (emu: Handle, ctx: *anyopaque, vp: *const VpExitContext, mem: *const MemoryAccessCtx, status: *EmulatorStatus) callconv(.winapi) HRESULT,

    fn load() !Whp {
        const plat = LoadLibraryA("WinHvPlatform.dll") orelse {
            std.debug.print("[whp] WinHvPlatform.dll not found (enable the 'Windows Hypervisor Platform' feature).\n", .{});
            return error.WhpNoDll;
        };
        const emu = LoadLibraryA("WinHvEmulation.dll") orelse {
            std.debug.print("[whp] WinHvEmulation.dll not found.\n", .{});
            return error.WhpNoDll;
        };
        return .{
            .GetCapability = @ptrCast(try proc(plat, "WHvGetCapability")),
            .CreatePartition = @ptrCast(try proc(plat, "WHvCreatePartition")),
            .SetupPartition = @ptrCast(try proc(plat, "WHvSetupPartition")),
            .DeletePartition = @ptrCast(try proc(plat, "WHvDeletePartition")),
            .SetPartitionProperty = @ptrCast(try proc(plat, "WHvSetPartitionProperty")),
            .MapGpaRange = @ptrCast(try proc(plat, "WHvMapGpaRange")),
            .CreateVirtualProcessor = @ptrCast(try proc(plat, "WHvCreateVirtualProcessor")),
            .RunVirtualProcessor = @ptrCast(try proc(plat, "WHvRunVirtualProcessor")),
            .CancelRunVirtualProcessor = @ptrCast(try proc(plat, "WHvCancelRunVirtualProcessor")),
            .GetVirtualProcessorRegisters = @ptrCast(try proc(plat, "WHvGetVirtualProcessorRegisters")),
            .SetVirtualProcessorRegisters = @ptrCast(try proc(plat, "WHvSetVirtualProcessorRegisters")),
            .RequestInterrupt = @ptrCast(try proc(plat, "WHvRequestInterrupt")),
            .TranslateGva = @ptrCast(try proc(plat, "WHvTranslateGva")),
            .EmulatorCreate = @ptrCast(try proc(emu, "WHvEmulatorCreateEmulator")),
            .EmulatorTryIo = @ptrCast(try proc(emu, "WHvEmulatorTryIoEmulation")),
            .EmulatorTryMmio = @ptrCast(try proc(emu, "WHvEmulatorTryMmioEmulation")),
        };
    }
    fn proc(dll: *anyopaque, name: [*:0]const u8) !*anyopaque {
        return GetProcAddress(dll, name) orelse {
            std.debug.print("[whp] missing export: {s}\n", .{name});
            return error.WhpBadExport;
        };
    }
};

fn check(hr: HRESULT, what: []const u8) !void {
    if (hr < 0) {
        std.debug.print("[whp] {s} failed: hr=0x{x}\n", .{ what, @as(u32, @bitCast(hr)) });
        return error.WhpCall;
    }
}

// Per-run context handed to the emulator callbacks.
const Ctx = struct {
    whp: *const Whp,
    p: Handle,
    m: *Machine,
    pit: *Pit,
    pic: *Pic,
    cmos: *Cmos,

    fn ioCb(c: *anyopaque, io: *EmuIoAccessInfo) callconv(.winapi) HRESULT {
        const self: *Ctx = @ptrCast(@alignCast(c));
        const size: u8 = @intCast(io.access_size);
        if (io.port >= Uart16550.base_port and io.port < Uart16550.base_port + Uart16550.nports) {
            const u = self.m.uart16550.?;
            const off: u64 = io.port - Uart16550.base_port;
            if (io.direction == 1) {
                u.write(off, io.data, size);
            } else {
                io.data = @truncate(u.read(off, size));
            }
        } else if ((io.port >= 0x40 and io.port <= 0x43) or io.port == 0x61) {
            // i8254 PIT (TSC calibration + IRQ0).
            if (io.direction == 1) {
                self.pit.write(io.port, @truncate(io.data));
            } else {
                io.data = self.pit.read(io.port);
            }
        } else if (io.port == 0x20 or io.port == 0x21 or io.port == 0xa0 or io.port == 0xa1) {
            // i8259 PIC: probed by the kernel; modelled so it doesn't fall back to
            // the NULL PIC (which skips PIT TSC calibration).
            if (io.direction == 1) {
                self.pic.write(io.port, @truncate(io.data));
            } else {
                io.data = self.pic.read(io.port);
            }
        } else if (io.port == 0x70 or io.port == 0x71) {
            // CMOS RTC: without it the kernel spins on the UIP bit reading the clock.
            if (io.direction == 1) {
                self.cmos.write(io.port, @truncate(io.data));
            } else {
                io.data = self.cmos.read(io.port);
            }
        } else if (io.direction == 0) {
            io.data = 0xffff_ffff; // unclaimed port reads see all-ones
        }
        return 0;
    }
    fn memCb(c: *anyopaque, mem: *EmuMemoryAccessInfo) callconv(.winapi) HRESULT {
        const self: *Ctx = @ptrCast(@alignCast(c));
        const size: u8 = mem.access_size;
        if (mem.direction == 1) {
            var v: u64 = 0;
            var i: u8 = 0;
            while (i < size and i < 8) : (i += 1) v |= @as(u64, mem.data[i]) << @intCast(i * 8);
            self.m.bus.write(mem.gpa, v, size);
        } else {
            const v = self.m.bus.read(mem.gpa, size);
            var i: u8 = 0;
            while (i < size and i < 8) : (i += 1) mem.data[i] = @truncate(v >> @intCast(i * 8));
        }
        return 0;
    }
    fn getRegsCb(c: *anyopaque, names: [*]const u32, count: u32, values: [*]RegisterValue) callconv(.winapi) HRESULT {
        const self: *Ctx = @ptrCast(@alignCast(c));
        return self.whp.GetVirtualProcessorRegisters(self.p, 0, names, count, values);
    }
    fn setRegsCb(c: *anyopaque, names: [*]const u32, count: u32, values: [*]const RegisterValue) callconv(.winapi) HRESULT {
        const self: *Ctx = @ptrCast(@alignCast(c));
        return self.whp.SetVirtualProcessorRegisters(self.p, 0, names, count, values);
    }
    fn translateCb(c: *anyopaque, gva: u64, flags: u32, result: *u32, gpa: *u64) callconv(.winapi) HRESULT {
        const self: *Ctx = @ptrCast(@alignCast(c));
        var r = TranslateGvaResult{ .result_code = 0, .reserved = 0 };
        var pa: u64 = 0;
        const hr = self.whp.TranslateGva(self.p, 0, gva, flags, &r, &pa);
        result.* = r.result_code;
        gpa.* = pa;
        return hr;
    }
};

// IOAPIC injector: device line number IS the GSI; look up the redirection entry
// and deliver the resulting vector to the LAPIC via WHvRequestInterrupt.
const Injector = struct {
    whp: *const Whp,
    p: Handle,
    ioapic: *Ioapic,
    fn inject(ctx: *anyopaque, intid: u32, level: bool) void {
        const self: *Injector = @ptrCast(@alignCast(ctx));
        if (!level) return;
        const e = self.ioapic.deliver(intid) orelse return;
        // Pack Type(8) | DestMode(4)<<8 | TriggerMode(4)<<12 from the IOAPIC entry
        // (Linux uses logical destination mode for IOAPIC redirections).
        const tdt: u64 = @as(u64, e.delivery_mode) | (@as(u64, e.dest_mode) << 8) | (@as(u64, @intFromBool(e.level)) << 12);
        const ic = InterruptControl{ .type_dest_trigger = tdt, .destination = e.dest, .vector = e.vector };
        _ = self.whp.RequestInterrupt(self.p, &ic, @sizeOf(InterruptControl));
    }
};

fn runImpl(m: *Machine) !void {
    const whp = try Whp.load();

    var present: u32 = 0;
    _ = whp.GetCapability(CAP_HYPERVISOR_PRESENT, &present, @sizeOf(u32), null);
    if (present == 0) {
        std.debug.print("[whp] hypervisor not present (enable 'Windows Hypervisor Platform').\n", .{});
        return error.WhpNotPresent;
    }

    var partition: Handle = undefined;
    try check(whp.CreatePartition(&partition), "CreatePartition");
    defer _ = whp.DeletePartition(partition);

    var proc_count: u32 = 1;
    try check(whp.SetPartitionProperty(partition, PROP_PROCESSOR_COUNT, &proc_count, @sizeOf(u32)), "set ProcessorCount");
    var apic_mode: u32 = LOCAL_APIC_MODE_XAPIC;
    try check(whp.SetPartitionProperty(partition, PROP_LOCAL_APIC_EMULATION_MODE, &apic_mode, @sizeOf(u32)), "set LocalApicEmulationMode");
    try check(whp.SetupPartition(partition), "SetupPartition");

    try check(whp.MapGpaRange(partition, m.bus.ram.ptr, m.bus.ram_base, m.bus.ram.len, MAP_READ | MAP_WRITE | MAP_EXECUTE), "MapGpaRange");
    try check(whp.CreateVirtualProcessor(partition, 0, 0), "CreateVirtualProcessor");
    try setupPvhRegs(&whp, partition, m.x86_entry, m.x86_start_info);

    // Emulated IOAPIC on the bus + GIC injector (WHP gives us only the LAPIC).
    var ioapic = Ioapic.init();
    try m.bus.addDevice(.{ .base = ioapic_mod.base, .size = ioapic_mod.size, .ctx = &ioapic, .readFn = Ioapic.busRead, .writeFn = Ioapic.busWrite, .name = "ioapic" });
    var injector = Injector{ .whp = &whp, .p = partition, .ioapic = &ioapic };
    m.gic.inject_ctx = &injector;
    m.gic.inject_fn = Injector.inject;
    defer {
        m.gic.inject_fn = null;
        m.gic.inject_ctx = null;
    }

    // Emulated i8254 PIT (TSC calibration + IRQ0 tick) + i8259 PIC (probe only).
    var pit = Pit.init(m.gic);
    var pic = Pic.init();
    var cmos = Cmos.init();
    var ctx = Ctx{ .whp = &whp, .p = partition, .m = m, .pit = &pit, .pic = &pic, .cmos = &cmos };

    // Async timer thread (see TimerThread): pulses the PIT so its IRQ0 wakes the
    // vCPU even while WHvRunVirtualProcessor is blocked on HLT.
    var timer = TimerThread{ .pit = &pit, .whp = &whp, .p = partition, .running = std.atomic.Value(bool).init(true) };
    const timer_th = std.Thread.spawn(.{}, TimerThread.loop, .{&timer}) catch null;
    defer if (timer_th) |th| {
        timer.running.store(false, .release);
        th.join();
    };
    const callbacks = EmulatorCallbacks{
        .size = @sizeOf(EmulatorCallbacks),
        .reserved = 0,
        .io_port = Ctx.ioCb,
        .memory = Ctx.memCb,
        .get_regs = Ctx.getRegsCb,
        .set_regs = Ctx.setRegsCb,
        .translate_gva = Ctx.translateCb,
    };
    var emulator: Handle = undefined;
    try check(whp.EmulatorCreate(&callbacks, &emulator), "EmulatorCreateEmulator");

    var run_ctx: RunExitContext = undefined;
    var running = true;
    // Permanent-halt detection: the guest powers off with `cli; hlt` (IF=0). WHP
    // then loops returning HALT / interrupt-window exits (the timer keeps a masked
    // IRQ pending), never able to advance. Real progress (IO/MMIO) resets the
    // counter, so only a genuine wedged-with-IRQs-off guest trips it.
    var stuck: u32 = 0;
    // Also honor a cooperative stop from a library embedder (checked each loop
    // boundary, so it takes effect after the next exit).
    while (running and !m.stop_requested.load(.acquire)) {
        m.serviceDevicesHw();
        try check(whp.RunVirtualProcessor(partition, 0, &run_ctx, @sizeOf(RunExitContext)), "RunVirtualProcessor");
        switch (run_ctx.exit_reason) {
            EXIT_IO_PORT => {
                stuck = 0;
                const io: *const IoPortAccessCtx = @ptrCast(&run_ctx.union_data);
                var status: EmulatorStatus = 0;
                try check(whp.EmulatorTryIo(emulator, &ctx, &run_ctx.vp_context, io, &status), "EmulatorTryIo");
            },
            EXIT_MEMORY_ACCESS => {
                stuck = 0;
                const mem: *const MemoryAccessCtx = @ptrCast(&run_ctx.union_data);
                var status: EmulatorStatus = 0;
                try check(whp.EmulatorTryMmio(emulator, &ctx, &run_ctx.vp_context, mem, &status), "EmulatorTryMmio");
            },
            EXIT_HALT, EXIT_INTERRUPT_WINDOW, EXIT_CANCELED => {
                // A guest spinning here with interrupts disabled (RFLAGS.IF=0) can
                // never make progress -> it powered off (cli;hlt). The timer thread
                // periodically cancels RunVP so we re-observe this state; a few
                // consecutive IF=0 observations (no IO/MMIO between) means poweroff.
                if (run_ctx.vp_context.rflags & 0x200 == 0) {
                    stuck += 1;
                    if (stuck > 3) running = false;
                } else stuck = 0;
            },
            EXIT_APIC_EOI => {},
            EXIT_UNRECOVERABLE => {
                // The guest powers off via reboot=t (triple fault) -> unrecoverable.
                running = false;
            },
            else => {
                std.debug.print("[whp] unhandled exit 0x{x} rip=0x{x}\n", .{ run_ctx.exit_reason, run_ctx.vp_context.rip });
                running = false;
            },
        }
    }
}

/// PVH 32-bit protected-mode entry state (mirrors kvm.setupPvhRegs).
fn setupPvhRegs(whp: *const Whp, p: Handle, entry: u32, start_info: u64) !void {
    const code = SegmentRegister{ .base = 0, .limit = 0xffff_ffff, .selector = 0x10, .attributes = 0xc09b };
    const data = SegmentRegister{ .base = 0, .limit = 0xffff_ffff, .selector = 0x18, .attributes = 0xc093 };
    try setSeg(whp, p, REG_CS, code);
    try setSeg(whp, p, REG_DS, data);
    try setSeg(whp, p, REG_ES, data);
    try setSeg(whp, p, REG_FS, data);
    try setSeg(whp, p, REG_GS, data);
    try setSeg(whp, p, REG_SS, data);
    try setReg(whp, p, REG_CR0, 0x1); // PE, paging off
    try setReg(whp, p, REG_CR4, 0);
    try setReg(whp, p, REG_EFER, 0);
    try setReg(whp, p, REG_RIP, entry);
    try setReg(whp, p, REG_RBX, start_info);
    try setReg(whp, p, REG_RFLAGS, 0x2);
}

fn setReg(whp: *const Whp, p: Handle, name: u32, value: u64) !void {
    const rv = RegisterValue{ .reg64 = value };
    try check(whp.SetVirtualProcessorRegisters(p, 0, &[_]u32{name}, 1, &[_]RegisterValue{rv}), "set reg");
}
fn setSeg(whp: *const Whp, p: Handle, name: u32, seg: SegmentRegister) !void {
    const rv = RegisterValue{ .segment = seg };
    try check(whp.SetVirtualProcessorRegisters(p, 0, &[_]u32{name}, 1, &[_]RegisterValue{rv}), "set seg");
}

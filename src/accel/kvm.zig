//! KVM accel backend: run the arm64 guest on Linux/KVM (`/dev/kvm`). Like the
//! HVF backend, the guest CPU executes natively and the existing device models,
//! Bus and NAT are reused unchanged — KVM maps `m.bus.ram` at guest-physical
//! `ram_base` and MMIO exits route to `m.bus`.
//!
//! Two things differ from HVF and are the point of the Phase-2 de-risk:
//!  1. KVM_EXIT_MMIO delivers the *decoded* access (phys_addr/data/len/is_write),
//!     so there is no instruction-decode step (no ISV=0 problem).
//!  2. We use the **in-kernel vGIC v2** + in-kernel arch timer, so the emulated
//!     GICv2 distributor and the HVF vtimer bridge are NOT used. Device IRQs are
//!     injected via KVM_IRQ_LINE through the GIC's `inject_fn` hook (the
//!     IRQ-raise abstraction). PPIs/timer are owned by KVM.
//!
//! Gating mirrors hvf.zig/whp.zig: everything Linux-specific lives behind the
//! comptime-known `kvm_supported`, so this file compiles on every target.
//!
//! STATUS: written against the KVM uapi but NOT yet runtime-validated (needs an
//! arm64 Linux host with /dev/kvm). It cross-compiles for *-linux.

const std = @import("std");
const builtin = @import("builtin");
const machine_mod = @import("../machine.zig");
const Machine = machine_mod.Machine;
const Gicv2 = @import("../devices/gicv2.zig").Gicv2;
const Uart16550 = @import("../devices/uart_16550.zig").Uart16550;

pub const kvm_supported = builtin.os.tag == .linux;

pub fn run(m: *Machine) !void {
    if (kvm_supported) {
        try runImpl(m);
    } else {
        return error.KvmUnsupported;
    }
}

// ---- KVM uapi (linux/kvm.h) ------------------------------------------------
// Only referenced from the `kvm_supported` branch.

const KVMIO: u32 = 0xAE;
// _IOC(dir,type,nr,size): nr[0:8] type[8:16] size[16:30] dir[30:32].
fn IO(nr: u32) u32 {
    return (KVMIO << 8) | nr;
}
fn IOW(nr: u32, comptime T: type) u32 {
    return (1 << 30) | (@as(u32, @sizeOf(T)) << 16) | (KVMIO << 8) | nr;
}
fn IOR(nr: u32, comptime T: type) u32 {
    return (2 << 30) | (@as(u32, @sizeOf(T)) << 16) | (KVMIO << 8) | nr;
}
fn IOWR(nr: u32, comptime T: type) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | (KVMIO << 8) | nr;
}

const KvmUserspaceMemoryRegion = extern struct {
    slot: u32,
    flags: u32,
    guest_phys_addr: u64,
    memory_size: u64,
    userspace_addr: u64,
};
const KvmOneReg = extern struct { id: u64, addr: u64 };
const KvmVcpuInit = extern struct { target: u32, features: [7]u32 };
const KvmIrqLevel = extern struct { irq: u32, level: u32 };
const KvmCreateDevice = extern struct { type: u32, fd: u32, flags: u32 };
const KvmDeviceAttr = extern struct { flags: u32, group: u64, attr: u64, addr: u64 };

// struct kvm_run — only the fields we touch; the union begins at offset 32.
const KvmRun = extern struct {
    request_interrupt_window: u8,
    immediate_exit: u8,
    padding1: [6]u8,
    exit_reason: u32,
    ready_for_interrupt_injection: u8,
    if_flag: u8,
    flags: u16,
    cr8: u64,
    apic_base: u64,
    exit: extern union {
        mmio: extern struct {
            phys_addr: u64,
            data: [8]u8,
            len: u32,
            is_write: u8,
        },
        io: extern struct {
            direction: u8,
            size: u8,
            port: u16,
            count: u32,
            data_offset: u64,
        },
        system_event: extern struct {
            type: u32,
            ndata: u32,
            data: [16]u64,
        },
        padding: [256]u8,
    },
};

// ---- x86 register state (kvm_regs / kvm_sregs) ----
const KvmRegs = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rsp: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
};

const KvmSegment = extern struct {
    base: u64,
    limit: u32,
    selector: u16,
    type: u8,
    present: u8,
    dpl: u8,
    db: u8,
    s: u8,
    l: u8,
    g: u8,
    avl: u8,
    unusable: u8,
    padding: u8,
};

const KvmDtable = extern struct {
    base: u64,
    limit: u16,
    padding: [3]u16,
};

const KvmSregs = extern struct {
    cs: KvmSegment,
    ds: KvmSegment,
    es: KvmSegment,
    fs: KvmSegment,
    gs: KvmSegment,
    ss: KvmSegment,
    tr: KvmSegment,
    ldt: KvmSegment,
    gdt: KvmDtable,
    idt: KvmDtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,
};

const KvmPitConfig = extern struct {
    flags: u32,
    pad: [15]u32,
};

const KvmCpuidEntry2 = extern struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    padding: [3]u32,
};
// kvm_cpuid2 with an inline entry array. The ioctl number encodes only the 8-byte
// header size (the kernel keys on the magic/nr, not the buffer length).
const cpuid_max_entries = 256;
const KvmCpuid2 = extern struct {
    nent: u32,
    padding: u32,
    entries: [cpuid_max_entries]KvmCpuidEntry2,
};
const KvmCpuid2Hdr = extern struct { nent: u32, padding: u32 };

const KVM_CREATE_VM = IO(0x01);
const KVM_GET_VCPU_MMAP_SIZE = IO(0x04);
const KVM_CREATE_VCPU = IO(0x41);
const KVM_RUN = IO(0x80);
const KVM_SET_USER_MEMORY_REGION = IOW(0x46, KvmUserspaceMemoryRegion);
const KVM_IRQ_LINE = IOW(0x61, KvmIrqLevel);
const KVM_SET_ONE_REG = IOW(0xac, KvmOneReg);
const KVM_ARM_VCPU_INIT = IOW(0xae, KvmVcpuInit);
const KVM_ARM_PREFERRED_TARGET = IOR(0xaf, KvmVcpuInit);
const KVM_CREATE_DEVICE = IOWR(0xe0, KvmCreateDevice);
const KVM_SET_DEVICE_ATTR = IOW(0xe1, KvmDeviceAttr);
// x86-specific.
const KVM_CREATE_IRQCHIP = IO(0x60);
const KVM_CREATE_PIT2 = IOW(0x77, KvmPitConfig);
const KVM_GET_SUPPORTED_CPUID = IOWR(0x05, KvmCpuid2Hdr); // system ioctl (kvm_fd)
const KVM_SET_CPUID2 = IOW(0x90, KvmCpuid2Hdr); // vcpu ioctl
const KVM_SET_TSS_ADDR = IO(0x47); // arg = guest phys addr (3 pages)
const KVM_SET_IDENTITY_MAP_ADDR = IOW(0x48, u64); // arg = *u64 guest phys (1 page)
const KVM_GET_REGS = IOR(0x81, KvmRegs);
const KVM_SET_REGS = IOW(0x82, KvmRegs);
const KVM_GET_SREGS = IOR(0x83, KvmSregs);
const KVM_SET_SREGS = IOW(0x84, KvmSregs);

// kvm_run exit reasons.
const KVM_EXIT_IO: u32 = 2;
const KVM_EXIT_IO_IN: u8 = 0;
const KVM_EXIT_IO_OUT: u8 = 1;
const KVM_EXIT_HLT: u32 = 5;
const KVM_EXIT_MMIO: u32 = 6;
const KVM_EXIT_SHUTDOWN: u32 = 8;
const KVM_EXIT_FAIL_ENTRY: u32 = 9;
const KVM_EXIT_INTR: u32 = 10;
const KVM_EXIT_SYSTEM_EVENT: u32 = 24;

const KVM_SYSTEM_EVENT_SHUTDOWN: u32 = 1;
const KVM_SYSTEM_EVENT_RESET: u32 = 2;

// arm64 vcpu features.
const KVM_ARM_VCPU_PSCI_0_2: u5 = 2;

// in-kernel vGIC v2.
const KVM_DEV_TYPE_ARM_VGIC_V2: u32 = 5;
const KVM_DEV_ARM_VGIC_GRP_ADDR: u64 = 0;
const KVM_DEV_ARM_VGIC_GRP_NR_IRQS: u64 = 3;
const KVM_DEV_ARM_VGIC_GRP_CTRL: u64 = 4;
const KVM_DEV_ARM_VGIC_CTRL_INIT: u64 = 0;
const KVM_VGIC_V2_ADDR_TYPE_DIST: u64 = 0;
const KVM_VGIC_V2_ADDR_TYPE_CPU: u64 = 1;

// KVM_IRQ_LINE irq encoding: type<<24 | vcpu<<16 | num.
const KVM_ARM_IRQ_TYPE_SPI: u32 = 1;

// arm64 core-register ids (KVM_REG_ARM64 | SIZE_U64 | CORE | u32-offset).
const KVM_REG_ARM64: u64 = 0x6000000000000000;
const KVM_REG_SIZE_U64: u64 = 0x0030000000000000;
const KVM_REG_ARM_CORE: u64 = 0x0010000000000000;
fn coreReg(u32_off: u64) u64 {
    return KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | u32_off;
}
fn regX(n: u64) u64 {
    return coreReg(n * 2); // regs[n] at byte n*8 -> /4 = n*2
}
const REG_PC = coreReg(64); // pc at byte 256
const REG_PSTATE = coreReg(66); // pstate at byte 264

const PSTATE_EL1H_DAIF: u64 = 0x3c5;

fn ioctl(fd: i32, request: u32, arg: usize) !usize {
    const r = std.os.linux.ioctl(fd, request, arg);
    if (@as(isize, @bitCast(r)) < 0) return error.KvmIoctl;
    return r;
}

fn closeFd(fd: i32) void {
    _ = std.os.linux.close(fd);
}

/// The GIC injector: routes device `setIrq` to KVM_IRQ_LINE for the in-kernel
/// vGIC. Only SPIs (INTID >= 32) come here; PPIs/timer are in-kernel.
const Injector = struct {
    vm_fd: i32,
    fn inject(ctx: *anyopaque, intid: u32, level: bool) void {
        const self: *Injector = @ptrCast(@alignCast(ctx));
        if (intid < 32) return;
        var lvl = KvmIrqLevel{
            .irq = (KVM_ARM_IRQ_TYPE_SPI << 24) | (intid & 0xffff),
            .level = if (level) 1 else 0,
        };
        _ = ioctl(self.vm_fd, KVM_IRQ_LINE, @intFromPtr(&lvl)) catch {};
    }
};

fn setOneReg(vcpu_fd: i32, id: u64, value: u64) !void {
    var v = value;
    var reg = KvmOneReg{ .id = id, .addr = @intFromPtr(&v) };
    _ = try ioctl(vcpu_fd, KVM_SET_ONE_REG, @intFromPtr(&reg));
}

fn setDevAttr(dev_fd: i32, group: u64, attr: u64, addr: u64) !void {
    var a = KvmDeviceAttr{ .flags = 0, .group = group, .attr = attr, .addr = addr };
    _ = try ioctl(dev_fd, KVM_SET_DEVICE_ATTR, @intFromPtr(&a));
}

fn runImpl(m: *Machine) !void {
    switch (m.platform) {
        .arm64_virt => try runImplArm64(m),
        .x86_microvm => try runImplX86(m),
    }
}

fn openKvm() !i32 {
    return @intCast(std.posix.openatZ(std.posix.AT.FDCWD, "/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch {
        std.debug.print("[kvm] cannot open /dev/kvm (need the kvm group / a host with KVM).\n", .{});
        return error.KvmNoDevice;
    });
}

fn runImplArm64(m: *Machine) !void {
    const kvm_fd: i32 = try openKvm();
    defer closeFd(kvm_fd);

    const vm_fd: i32 = @intCast(try ioctl(kvm_fd, KVM_CREATE_VM, 0));
    defer closeFd(vm_fd);

    // Map guest RAM (4 KB-aligned; page_allocator + ram_base + size all satisfy).
    var region = KvmUserspaceMemoryRegion{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = m.bus.ram_base,
        .memory_size = m.bus.ram.len,
        .userspace_addr = @intFromPtr(m.bus.ram.ptr),
    };
    _ = try ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region));

    const vcpu_fd: i32 = @intCast(try ioctl(vm_fd, KVM_CREATE_VCPU, 0));
    defer closeFd(vcpu_fd);

    const run_size = try ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
    const run_mem = try std.posix.mmap(null, run_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, vcpu_fd, 0);
    defer std.posix.munmap(run_mem);
    const kvm_run: *volatile KvmRun = @ptrCast(@alignCast(run_mem.ptr));

    // Initialise the vcpu to the host-preferred target, with in-kernel PSCI 0.2.
    var vinit = std.mem.zeroes(KvmVcpuInit);
    _ = try ioctl(vm_fd, KVM_ARM_PREFERRED_TARGET, @intFromPtr(&vinit));
    vinit.features[0] |= @as(u32, 1) << KVM_ARM_VCPU_PSCI_0_2;
    _ = try ioctl(vcpu_fd, KVM_ARM_VCPU_INIT, @intFromPtr(&vinit));

    // In-kernel vGIC v2 at the same bases the DTB advertises.
    var cd = KvmCreateDevice{ .type = KVM_DEV_TYPE_ARM_VGIC_V2, .fd = 0, .flags = 0 };
    _ = try ioctl(vm_fd, KVM_CREATE_DEVICE, @intFromPtr(&cd));
    const gic_fd: i32 = @intCast(cd.fd);
    defer closeFd(gic_fd);
    var dist_base: u64 = Gicv2.dist_base;
    var cpu_base: u64 = Gicv2.cpu_base;
    try setDevAttr(gic_fd, KVM_DEV_ARM_VGIC_GRP_ADDR, KVM_VGIC_V2_ADDR_TYPE_DIST, @intFromPtr(&dist_base));
    try setDevAttr(gic_fd, KVM_DEV_ARM_VGIC_GRP_ADDR, KVM_VGIC_V2_ADDR_TYPE_CPU, @intFromPtr(&cpu_base));
    var nr_irqs: u32 = 256;
    try setDevAttr(gic_fd, KVM_DEV_ARM_VGIC_GRP_NR_IRQS, 0, @intFromPtr(&nr_irqs));
    try setDevAttr(gic_fd, KVM_DEV_ARM_VGIC_GRP_CTRL, KVM_DEV_ARM_VGIC_CTRL_INIT, 0);

    // Wire device IRQs to the in-kernel vGIC (the IRQ-raise abstraction).
    var injector = Injector{ .vm_fd = vm_fd };
    m.gic.inject_ctx = &injector;
    m.gic.inject_fn = Injector.inject;
    defer {
        m.gic.inject_fn = null;
        m.gic.inject_ctx = null;
    }

    // arm64 Linux boot protocol: PC=kernel, X0=DTB, PSTATE=EL1h+DAIF masked.
    try setOneReg(vcpu_fd, REG_PC, machine_mod.kernel_load);
    try setOneReg(vcpu_fd, regX(0), machine_mod.dtb_load);
    try setOneReg(vcpu_fd, REG_PSTATE, PSTATE_EL1H_DAIF);

    var running = true;
    while (running) {
        // Console input + UART line + NAT pump/RX. setIrq here injects via KVM.
        m.serviceDevicesHw();

        _ = ioctl(vcpu_fd, KVM_RUN, 0) catch |err| {
            std.debug.print("[kvm] KVM_RUN failed: {s}\n", .{@errorName(err)});
            return err;
        };

        switch (kvm_run.exit_reason) {
            KVM_EXIT_MMIO => handleMmio(kvm_run, m),
            KVM_EXIT_SYSTEM_EVENT => {
                const t = kvm_run.exit.system_event.type;
                if (t == KVM_SYSTEM_EVENT_SHUTDOWN or t == KVM_SYSTEM_EVENT_RESET) running = false;
            },
            KVM_EXIT_SHUTDOWN => running = false,
            KVM_EXIT_INTR => {}, // signal-interrupted; loop to re-service devices
            KVM_EXIT_HLT => {}, // shouldn't occur on arm64; treat as a yield
            KVM_EXIT_FAIL_ENTRY => {
                std.debug.print("[kvm] KVM_EXIT_FAIL_ENTRY\n", .{});
                running = false;
            },
            else => {
                std.debug.print("[kvm] unhandled exit reason {d}\n", .{kvm_run.exit_reason});
                running = false;
            },
        }
    }
}

/// Decoded MMIO: KVM already extracted the access, so route straight to the Bus.
/// KVM advances the guest PC for us — do not touch it here.
fn handleMmio(kvm_run: *volatile KvmRun, m: *Machine) void {
    const mmio = &kvm_run.exit.mmio;
    const pa = mmio.phys_addr;
    const len: u8 = @intCast(mmio.len);
    if (mmio.is_write != 0) {
        var val: u64 = 0;
        var i: u5 = 0;
        while (i < len) : (i += 1) val |= @as(u64, mmio.data[i]) << (@as(u6, i) * 8);
        m.bus.write(pa, val, len);
    } else {
        const val = m.bus.read(pa, len);
        var i: u5 = 0;
        while (i < len) : (i += 1) mmio.data[i] = @truncate(val >> (@as(u6, i) * 8));
    }
    m.bus.fault = false;
}

// ---- x86-microvm path ------------------------------------------------------

/// x86 IRQ injector: the device line number IS the IOAPIC GSI (no type field).
const X86Injector = struct {
    vm_fd: i32,
    fn inject(ctx: *anyopaque, intid: u32, level: bool) void {
        const self: *X86Injector = @ptrCast(@alignCast(ctx));
        var lvl = KvmIrqLevel{ .irq = intid, .level = if (level) 1 else 0 };
        _ = ioctl(self.vm_fd, KVM_IRQ_LINE, @intFromPtr(&lvl)) catch {};
    }
};

// Poweroff escape: KVM_RUN blocks on a permanent `cli; hlt` (in-kernel irqchip
// never returns KVM_EXIT_HLT for it). A helper thread periodically signals the
// vCPU thread so KVM_RUN returns EINTR and the loop can detect the halt.
var pw_vcpu_tid: i32 = 0;
fn pwSigHandler(_: c_int) callconv(.c) void {}
const PwPoll = struct {
    running: std.atomic.Value(bool),
    fn loop(self: *PwPoll) void {
        while (self.running.load(.acquire)) {
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 200 * 1000 * 1000 };
            _ = std.os.linux.syscall2(.nanosleep, @intFromPtr(&ts), 0);
            _ = std.os.linux.tgkill(std.os.linux.getpid(), pw_vcpu_tid, std.os.linux.SIG.USR1);
        }
    }
};

fn runImplX86(m: *Machine) !void {
    const kvm_fd = try openKvm();
    defer closeFd(kvm_fd);
    const vm_fd: i32 = @intCast(try ioctl(kvm_fd, KVM_CREATE_VM, 0));
    defer closeFd(vm_fd);

    var region = KvmUserspaceMemoryRegion{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = m.bus.ram_base,
        .memory_size = m.bus.ram.len,
        .userspace_addr = @intFromPtr(m.bus.ram.ptr),
    };
    _ = try ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region));

    // Standard x86 KVM setup (firecracker/cloud-hypervisor do this): give KVM its
    // internal identity map + TSS region in a high guest-phys hole above our RAM.
    var idmap: u64 = 0xfffb_c000;
    _ = ioctl(vm_fd, KVM_SET_IDENTITY_MAP_ADDR, @intFromPtr(&idmap)) catch {};
    _ = ioctl(vm_fd, KVM_SET_TSS_ADDR, 0xfffb_d000) catch {};

    // In-kernel PIC + IOAPIC + LAPIC + i8254 PIT (so the timer/irqchip aren't ours).
    _ = try ioctl(vm_fd, KVM_CREATE_IRQCHIP, 0);
    var pit = std.mem.zeroes(KvmPitConfig);
    _ = try ioctl(vm_fd, KVM_CREATE_PIT2, @intFromPtr(&pit));

    const vcpu_fd: i32 = @intCast(try ioctl(vm_fd, KVM_CREATE_VCPU, 0));
    defer closeFd(vcpu_fd);
    const run_size = try ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
    const run_mem = try std.posix.mmap(null, run_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, vcpu_fd, 0);
    defer std.posix.munmap(run_mem);
    const kvm_run: *volatile KvmRun = @ptrCast(@alignCast(run_mem.ptr));

    // The guest CPUID must advertise long mode (and PAE etc.) or the kernel's PVH
    // trampoline #GPs writing EFER.LME -> triple fault. Copy the host-supported set.
    try setupCpuid(kvm_fd, vcpu_fd);
    try setupPvhRegs(vcpu_fd, m.x86_entry, m.x86_start_info);

    var injector = X86Injector{ .vm_fd = vm_fd };
    m.gic.inject_ctx = &injector;
    m.gic.inject_fn = X86Injector.inject;
    defer {
        m.gic.inject_fn = null;
        m.gic.inject_ctx = null;
    }

    // Arm the poweroff-poll thread (see PwPoll): SIGUSR1 interrupts a blocked
    // KVM_RUN so we can spot a powered-off (cli;hlt, IF=0) guest and stop.
    {
        const HandlerPtr = @FieldType(@FieldType(std.posix.Sigaction, "handler"), "handler");
        var act = std.posix.Sigaction{
            .handler = .{ .handler = @as(HandlerPtr, @ptrCast(&pwSigHandler)) },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.USR1, &act, null);
    }
    pw_vcpu_tid = std.os.linux.gettid();
    var pw = PwPoll{ .running = std.atomic.Value(bool).init(true) };
    const pw_th = std.Thread.spawn(.{}, PwPoll.loop, .{&pw}) catch null;
    defer if (pw_th) |th| {
        pw.running.store(false, .release);
        th.join();
    };

    var running = true;
    var stuck: u32 = 0; // consecutive IF=0 observations with no IO/MMIO progress
    while (running) {
        m.serviceDevicesHw();
        const rc = std.os.linux.ioctl(vcpu_fd, KVM_RUN, 0);
        if (@as(isize, @bitCast(rc)) < 0) {
            if (@as(isize, @bitCast(rc)) == -4) { // EINTR (poll signal)
                var regs = std.mem.zeroes(KvmRegs);
                _ = ioctl(vcpu_fd, KVM_GET_REGS, @intFromPtr(&regs)) catch {};
                if (regs.rflags & 0x200 == 0) {
                    stuck += 1;
                    if (stuck > 3) running = false; // poweroff: cli;hlt forever
                } else stuck = 0;
                continue;
            }
            std.debug.print("[kvm] KVM_RUN failed\n", .{});
            return error.KvmIoctl;
        }
        switch (kvm_run.exit_reason) {
            KVM_EXIT_IO => {
                stuck = 0;
                handleIo(kvm_run, run_mem.ptr, m);
            },
            KVM_EXIT_MMIO => {
                stuck = 0;
                handleMmio(kvm_run, m);
            },
            KVM_EXIT_SHUTDOWN, KVM_EXIT_SYSTEM_EVENT => running = false,
            KVM_EXIT_HLT => {
                // A HLT with interrupts disabled can never wake -> the guest powered
                // off (machine_halt: cli;hlt). Stop cleanly instead of spinning.
                var regs = std.mem.zeroes(KvmRegs);
                _ = ioctl(vcpu_fd, KVM_GET_REGS, @intFromPtr(&regs)) catch {};
                if (regs.rflags & 0x200 == 0) running = false;
            },
            KVM_EXIT_INTR => {}, // signal-interrupted; loop to re-service devices
            KVM_EXIT_FAIL_ENTRY => {
                std.debug.print("[kvm] x86 KVM_EXIT_FAIL_ENTRY\n", .{});
                running = false;
            },
            else => {
                std.debug.print("[kvm] x86 unhandled exit reason {d}\n", .{kvm_run.exit_reason});
                running = false;
            },
        }
    }
}

/// Copy the host's KVM-supported CPUID to the guest vcpu so it advertises long
/// mode, PAE, SSE, etc. Without this KVM rejects the kernel's EFER.LME write.
fn setupCpuid(kvm_fd: i32, vcpu_fd: i32) !void {
    var cpuid = std.mem.zeroes(KvmCpuid2);
    cpuid.nent = cpuid_max_entries;
    _ = try ioctl(kvm_fd, KVM_GET_SUPPORTED_CPUID, @intFromPtr(&cpuid));
    _ = try ioctl(vcpu_fd, KVM_SET_CPUID2, @intFromPtr(&cpuid));
}

/// Set the PVH 32-bit protected-mode entry state: flat code/data segments, PE on
/// (paging off), EIP = entry, EBX -> hvm_start_info.
fn setupPvhRegs(vcpu_fd: i32, entry: u32, start_info: u64) !void {
    var sregs = std.mem.zeroes(KvmSregs);
    _ = try ioctl(vcpu_fd, KVM_GET_SREGS, @intFromPtr(&sregs));
    const code = KvmSegment{ .base = 0, .limit = 0xffff_ffff, .selector = 0x10, .type = 0xb, .present = 1, .dpl = 0, .db = 1, .s = 1, .l = 0, .g = 1, .avl = 0, .unusable = 0, .padding = 0 };
    const data = KvmSegment{ .base = 0, .limit = 0xffff_ffff, .selector = 0x18, .type = 0x3, .present = 1, .dpl = 0, .db = 1, .s = 1, .l = 0, .g = 1, .avl = 0, .unusable = 0, .padding = 0 };
    sregs.cs = code;
    sregs.ds = data;
    sregs.es = data;
    sregs.fs = data;
    sregs.gs = data;
    sregs.ss = data;
    sregs.cr0 = 0x1; // CR0.PE, paging disabled
    sregs.cr4 = 0;
    sregs.efer = 0;
    _ = try ioctl(vcpu_fd, KVM_SET_SREGS, @intFromPtr(&sregs));

    var regs = std.mem.zeroes(KvmRegs);
    regs.rip = entry;
    regs.rbx = start_info; // EBX -> hvm_start_info (PVH ABI)
    regs.rflags = 0x2; // reserved bit 1 set
    _ = try ioctl(vcpu_fd, KVM_SET_REGS, @intFromPtr(&regs));
}

/// Port-I/O exit. Only COM1 (0x3F8..0x3FF) is modelled -> the 16550; other ports
/// are ignored (PIT/PCI-config etc. are handled in-kernel or unused).
fn handleIo(kvm_run: *volatile KvmRun, run_base: [*]u8, m: *Machine) void {
    const io = &kvm_run.exit.io;
    const u = m.uart16550 orelse return;
    if (io.port < Uart16550.base_port or io.port >= Uart16550.base_port + Uart16550.nports) {
        // Unclaimed port: reads see all-ones (an empty bus), writes are dropped.
        if (io.direction == KVM_EXIT_IO_IN) {
            const data = run_base + io.data_offset;
            @memset(data[0 .. io.count * io.size], 0xff);
        }
        return;
    }
    const off: u64 = io.port - Uart16550.base_port;
    const data = run_base + io.data_offset;
    var i: u32 = 0;
    while (i < io.count) : (i += 1) {
        const slot = data + i * io.size;
        if (io.direction == KVM_EXIT_IO_OUT) {
            var val: u64 = 0;
            var b: u8 = 0;
            while (b < io.size) : (b += 1) val |= @as(u64, slot[b]) << (@as(u6, @intCast(b)) * 8);
            u.write(off, val, io.size);
        } else {
            const val = u.read(off, io.size);
            var b: u8 = 0;
            while (b < io.size) : (b += 1) slot[b] = @truncate(val >> (@as(u6, @intCast(b)) * 8));
        }
    }
}

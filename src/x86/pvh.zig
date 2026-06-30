//! PVH boot protocol for the x86-microvm platform (the x86 analogue of fdt.zig).
//!
//! PVH is the modern, bootloader-free way to start an x86 kernel: the `vmlinux`
//! ELF advertises a 32-bit protected-mode entry point via an ELF note
//! (XEN_ELFNOTE_PHYS32_ENTRY). The VMM loads the ELF PT_LOAD segments at their
//! physical addresses, builds an `hvm_start_info` (memory map + cmdline +
//! initramfs module) in guest RAM, and enters at the PVH entry with EBX pointing
//! at the start_info. No real-mode bzImage protocol, no ACPI, no DTB.
//!
//! This module is platform-independent data plumbing (testable on any host); the
//! x86 machine assembly and the KVM/WHP backends place the result in guest RAM
//! and set the 32-bit entry register state.

const std = @import("std");

pub const XEN_HVM_START_MAGIC: u32 = 0x336ec578;
const XEN_ELFNOTE_PHYS32_ENTRY: u32 = 18;

const PT_LOAD: u32 = 1;
const PT_NOTE: u32 = 4;

// e820 / memmap entry types.
pub const E820_RAM: u32 = 1;
pub const E820_RESERVED: u32 = 2;

pub const HvmStartInfo = extern struct {
    magic: u32,
    version: u32,
    flags: u32,
    nr_modules: u32,
    modlist_paddr: u64,
    cmdline_paddr: u64,
    rsdp_paddr: u64,
    memmap_paddr: u64,
    memmap_entries: u32,
    reserved: u32,
};

pub const HvmModlistEntry = extern struct {
    paddr: u64,
    size: u64,
    cmdline_paddr: u64,
    reserved: u64,
};

pub const HvmMemmapEntry = extern struct {
    addr: u64,
    size: u64,
    type: u32,
    reserved: u32,
};

/// Walk an ELF PT_NOTE blob for the PVH 32-bit entry (XEN_ELFNOTE_PHYS32_ENTRY,
/// name "Xen"). Factored out so it is unit-testable without a whole ELF.
pub fn findPvhEntryInNotes(notes: []const u8) ?u32 {
    var i: usize = 0;
    while (i + 12 <= notes.len) {
        const namesz = std.mem.readInt(u32, notes[i..][0..4], .little);
        const descsz = std.mem.readInt(u32, notes[i + 4 ..][0..4], .little);
        const ntype = std.mem.readInt(u32, notes[i + 8 ..][0..4], .little);
        i += 12;
        const name_pad = std.mem.alignForward(usize, namesz, 4);
        const desc_pad = std.mem.alignForward(usize, descsz, 4);
        if (i + name_pad + desc_pad > notes.len) return null;
        const name = notes[i .. i + namesz];
        const desc = notes[i + name_pad ..][0..descsz];
        if (ntype == XEN_ELFNOTE_PHYS32_ENTRY and std.mem.eql(u8, std.mem.sliceTo(name, 0), "Xen")) {
            if (descsz >= 4) return std.mem.readInt(u32, desc[0..4], .little);
        }
        i += name_pad + desc_pad;
    }
    return null;
}

/// Find the PVH entry point in a 64-bit ELF `vmlinux` by scanning its PT_NOTE
/// segments. Returns null if the kernel has no PVH note.
pub fn findPvhEntry(image: []const u8) ?u32 {
    if (image.len < 64 or !std.mem.eql(u8, image[0..4], "\x7fELF")) return null;
    if (image[4] != 2) return null; // ELFCLASS64
    const e_phoff = std.mem.readInt(u64, image[32..40], .little);
    const e_phentsize = std.mem.readInt(u16, image[54..56], .little);
    const e_phnum = std.mem.readInt(u16, image[56..58], .little);
    var idx: u16 = 0;
    while (idx < e_phnum) : (idx += 1) {
        const ph = e_phoff + @as(u64, idx) * e_phentsize;
        if (ph + 56 > image.len) break;
        const p_type = std.mem.readInt(u32, image[@intCast(ph)..][0..4], .little);
        if (p_type != PT_NOTE) continue;
        const p_offset = std.mem.readInt(u64, image[@intCast(ph + 8)..][0..8], .little);
        const p_filesz = std.mem.readInt(u64, image[@intCast(ph + 32)..][0..8], .little);
        if (p_offset + p_filesz > image.len) continue;
        if (findPvhEntryInNotes(image[@intCast(p_offset)..][0..@intCast(p_filesz)])) |e| return e;
    }
    return null;
}

/// Load a 64-bit `vmlinux` ELF's PT_LOAD segments into `ram` (indexed from
/// `ram_base`) and return the PVH entry point. BSS (memsz > filesz) is zeroed.
pub fn loadKernel(ram: []u8, ram_base: u64, image: []const u8) !u32 {
    if (image.len < 64 or !std.mem.eql(u8, image[0..4], "\x7fELF") or image[4] != 2) return error.NotElf64;
    const e_phoff = std.mem.readInt(u64, image[32..40], .little);
    const e_phentsize = std.mem.readInt(u16, image[54..56], .little);
    const e_phnum = std.mem.readInt(u16, image[56..58], .little);
    var idx: u16 = 0;
    while (idx < e_phnum) : (idx += 1) {
        const ph = e_phoff + @as(u64, idx) * e_phentsize;
        if (ph + 56 > image.len) return error.BadElf;
        const p_type = std.mem.readInt(u32, image[@intCast(ph)..][0..4], .little);
        if (p_type != PT_LOAD) continue;
        const p_offset = std.mem.readInt(u64, image[@intCast(ph + 8)..][0..8], .little);
        // p_paddr is at offset 24 (offset 16 is p_vaddr — a high kernel-virtual
        // address on a Linux vmlinux). PVH loads at the *physical* address.
        const p_paddr = std.mem.readInt(u64, image[@intCast(ph + 24)..][0..8], .little);
        const p_filesz = std.mem.readInt(u64, image[@intCast(ph + 32)..][0..8], .little);
        const p_memsz = std.mem.readInt(u64, image[@intCast(ph + 40)..][0..8], .little);
        if (p_paddr < ram_base or p_paddr + p_memsz > ram_base + ram.len) return error.SegmentOutOfRange;
        if (p_offset + p_filesz > image.len) return error.BadElf;
        const dst = (p_paddr - ram_base);
        @memcpy(ram[@intCast(dst)..][0..@intCast(p_filesz)], image[@intCast(p_offset)..][0..@intCast(p_filesz)]);
        if (p_memsz > p_filesz) @memset(ram[@intCast(dst + p_filesz)..][0..@intCast(p_memsz - p_filesz)], 0);
    }
    return findPvhEntry(image) orelse error.NoPvhEntry;
}

/// Where the boot structures live in low guest RAM (below the kernel load).
pub const Layout = struct {
    pub const start_info: u64 = 0x1000;
    pub const modlist: u64 = 0x1100;
    pub const memmap: u64 = 0x1200;
    pub const cmdline: u64 = 0x1400;
};

pub const BuildOpts = struct {
    ram_base: u64,
    ram_size: u64,
    cmdline: []const u8,
    initrd_paddr: u64 = 0,
    initrd_size: u64 = 0,
};

/// Write the hvm_start_info + memmap + (optional) module + cmdline into low guest
/// RAM and return the guest-physical address of the start_info. `ram` is indexed
/// from `opts.ram_base`.
pub fn buildStartInfo(ram: []u8, opts: BuildOpts) u64 {
    const L = Layout;
    // cmdline string (NUL-terminated).
    @memcpy(ram[L.cmdline .. L.cmdline + opts.cmdline.len], opts.cmdline);
    ram[L.cmdline + opts.cmdline.len] = 0;

    // Two memmap entries: low RAM below MMIO (640 KB classic), then main RAM.
    // We keep it simple: one RAM entry covering the whole window.
    const mm = HvmMemmapEntry{
        .addr = opts.ram_base,
        .size = opts.ram_size,
        .type = E820_RAM,
        .reserved = 0,
    };
    writeStruct(ram, L.memmap, HvmMemmapEntry, mm);

    var nr_modules: u32 = 0;
    if (opts.initrd_size != 0) {
        const mod = HvmModlistEntry{
            .paddr = opts.initrd_paddr,
            .size = opts.initrd_size,
            .cmdline_paddr = 0,
            .reserved = 0,
        };
        writeStruct(ram, L.modlist, HvmModlistEntry, mod);
        nr_modules = 1;
    }

    const si = HvmStartInfo{
        .magic = XEN_HVM_START_MAGIC,
        .version = 1,
        .flags = 0,
        .nr_modules = nr_modules,
        .modlist_paddr = if (nr_modules != 0) opts.ram_base + L.modlist else 0,
        .cmdline_paddr = opts.ram_base + L.cmdline,
        .rsdp_paddr = 0,
        .memmap_paddr = opts.ram_base + L.memmap,
        .memmap_entries = 1,
        .reserved = 0,
    };
    writeStruct(ram, L.start_info, HvmStartInfo, si);
    return opts.ram_base + L.start_info;
}

fn writeStruct(ram: []u8, off: u64, comptime T: type, value: T) void {
    const bytes = std.mem.asBytes(&value);
    @memcpy(ram[off .. off + bytes.len], bytes);
}

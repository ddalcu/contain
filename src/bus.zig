//! System memory bus: a flat RAM region plus a set of MMIO devices.
//!
//! The CPU performs *physical* accesses through this bus (the MMU, added in
//! M1, translates virtual->physical before calling here). Addresses inside the
//! RAM window hit the backing buffer; everything else is matched against the
//! registered MMIO devices. Misses raise a bus fault that the CPU turns into a
//! data abort.

const std = @import("std");

pub const MmioDevice = struct {
    base: u64,
    size: u64,
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, offset: u64, sz: u8) u64,
    writeFn: *const fn (ctx: *anyopaque, offset: u64, value: u64, sz: u8) void,
    name: []const u8,
};

pub const Bus = struct {
    ram: []u8,
    ram_base: u64,
    devices: std.ArrayList(MmioDevice),
    alloc: std.mem.Allocator,
    /// Set when an access misses all regions; CPU consults it after each access.
    fault: bool = false,
    fault_addr: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, ram_base: u64, ram_size: usize) !Bus {
        // Allocate guest RAM straight from the OS (mmap / VirtualAlloc) so pages
        // are demand-zeroed: host RSS only grows as the guest actually touches
        // memory, instead of committing the whole window up front. A fresh boot
        // touches far less than `ram_size`, so this is the bulk of the idle-RAM
        // win. (No @memset — OS-supplied pages are already zero.)
        const ram = try std.heap.page_allocator.alloc(u8, ram_size);
        return .{
            .ram = ram,
            .ram_base = ram_base,
            .devices = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Bus) void {
        std.heap.page_allocator.free(self.ram);
        self.devices.deinit(self.alloc);
    }

    pub fn addDevice(self: *Bus, dev: MmioDevice) !void {
        try self.devices.append(self.alloc, dev);
    }

    inline fn inRam(self: *const Bus, addr: u64, sz: u8) bool {
        // Overflow-safe: `addr + sz` could wrap for a near-2^64 address and
        // spuriously pass a naive upper-bound check, then index out of bounds.
        if (addr < self.ram_base) return false;
        const off = addr - self.ram_base;
        return sz <= self.ram.len and off <= self.ram.len - sz;
    }

    /// Direct RAM pointer for loaders/DMA. Returns null if the range is not
    /// entirely within RAM.
    pub fn ramSlice(self: *Bus, addr: u64, len: usize) ?[]u8 {
        if (addr < self.ram_base) return null;
        const off = addr - self.ram_base;
        // Overflow-safe upper bound (see inRam): `off + len` could wrap.
        if (len > self.ram.len or off > self.ram.len - len) return null;
        return self.ram[off .. off + len];
    }

    /// Host pointer to the start of the 4 KB RAM page containing physical `pa`,
    /// or null if that page is not entirely within the RAM window. Used by the
    /// CPU's instruction-fetch fast path to read straight from host memory while
    /// execution stays inside one guest page.
    pub inline fn ramHostPage(self: *Bus, pa: u64) ?[*]u8 {
        if (pa < self.ram_base) return null;
        const page_off = (pa - self.ram_base) & ~@as(u64, 0xfff);
        if (page_off + 0x1000 > self.ram.len) return null;
        return self.ram.ptr + page_off;
    }

    /// Host pointer to `sz` bytes at physical `pa`, or null if the range is not
    /// fully inside RAM (caller then falls back to the device path). Lets hot
    /// loads/stores hit the backing buffer directly without the device scan.
    pub inline fn ramHostPtr(self: *Bus, pa: u64, sz: u8) ?[*]u8 {
        if (pa < self.ram_base) return null;
        const off = pa - self.ram_base;
        if (sz > self.ram.len or off > self.ram.len - sz) return null; // overflow-safe
        return self.ram.ptr + off;
    }

    fn findDevice(self: *Bus, addr: u64) ?*MmioDevice {
        for (self.devices.items) |*d| {
            if (addr >= d.base and addr < d.base + d.size) return d;
        }
        return null;
    }

    pub fn read(self: *Bus, addr: u64, sz: u8) u64 {
        if (self.inRam(addr, sz)) {
            const off = addr - self.ram_base;
            return readBytes(self.ram[off..], sz);
        }
        if (self.findDevice(addr)) |d| {
            return d.readFn(d.ctx, addr - d.base, sz);
        }
        self.fault = true;
        self.fault_addr = addr;
        return 0;
    }

    pub fn write(self: *Bus, addr: u64, value: u64, sz: u8) void {
        if (self.inRam(addr, sz)) {
            const off = addr - self.ram_base;
            writeBytes(self.ram[off..], value, sz);
            return;
        }
        if (self.findDevice(addr)) |d| {
            d.writeFn(d.ctx, addr - d.base, value, sz);
            return;
        }
        self.fault = true;
        self.fault_addr = addr;
    }

    fn readBytes(buf: []const u8, sz: u8) u64 {
        return switch (sz) {
            1 => buf[0],
            2 => std.mem.readInt(u16, buf[0..2], .little),
            4 => std.mem.readInt(u32, buf[0..4], .little),
            8 => std.mem.readInt(u64, buf[0..8], .little),
            // Other widths (3,5,6,7) arise from page-crossing accesses split at a
            // page boundary; assemble little-endian byte by byte.
            else => blk: {
                var v: u64 = 0;
                var i: u8 = 0;
                while (i < sz) : (i += 1) v |= @as(u64, buf[i]) << @intCast(@as(u32, i) * 8);
                break :blk v;
            },
        };
    }

    fn writeBytes(buf: []u8, value: u64, sz: u8) void {
        switch (sz) {
            1 => buf[0] = @truncate(value),
            2 => std.mem.writeInt(u16, buf[0..2], @truncate(value), .little),
            4 => std.mem.writeInt(u32, buf[0..4], @truncate(value), .little),
            8 => std.mem.writeInt(u64, buf[0..8], value, .little),
            else => {
                var i: u8 = 0;
                while (i < sz) : (i += 1) buf[i] = @truncate(value >> @intCast(@as(u32, i) * 8));
            },
        }
    }
};

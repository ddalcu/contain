//! virtio-rng (entropy source) over the shared virtio-mmio transport. The guest
//! posts device-writable buffers on the single requestq; we fill each with
//! CSPRNG bytes and complete it. This lets the guest kernel initialise its CRNG
//! at boot (the hwrng framework pulls from us) instead of stalling seconds on
//! interrupt entropy — under a hardware backend, real-time boot is so fast that
//! little jitter has accrued, so node/V8 would otherwise block on getrandom().
//!
//! The entropy is a ChaCha CSPRNG seeded once from real host entropy (passed in
//! at init), so output is strong without needing libc in this cross-platform
//! device. Same virtqueue plumbing as virtio.zig (VirtioBlk).

const std = @import("std");
const Bus = @import("../bus.zig").Bus;
const Gicv2 = @import("gicv2.zig").Gicv2;

// virtio-mmio register offsets (subset; mirrors virtio.zig).
const MAGIC = 0x000;
const VERSION = 0x004;
const DEVICE_ID = 0x008;
const VENDOR_ID = 0x00c;
const DEVICE_FEATURES = 0x010;
const DEVICE_FEATURES_SEL = 0x014;
const DRIVER_FEATURES = 0x020;
const DRIVER_FEATURES_SEL = 0x024;
const QUEUE_SEL = 0x030;
const QUEUE_NUM_MAX = 0x034;
const QUEUE_NUM = 0x038;
const QUEUE_READY = 0x044;
const QUEUE_NOTIFY = 0x050;
const INTERRUPT_STATUS = 0x060;
const INTERRUPT_ACK = 0x064;
const STATUS = 0x070;
const QUEUE_DESC_LOW = 0x080;
const QUEUE_DESC_HIGH = 0x084;
const QUEUE_DRIVER_LOW = 0x090;
const QUEUE_DRIVER_HIGH = 0x094;
const QUEUE_DEVICE_LOW = 0x0a0;
const QUEUE_DEVICE_HIGH = 0x0a4;

const VIRTIO_RNG: u32 = 4;

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

pub const VirtioRng = struct {
    pub const size: u64 = 0x200;

    base: u64,
    irq_id: u32,
    bus: *Bus,
    gic: *Gicv2,
    rng: std.Random.ChaCha,

    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    queue_num: u32 = 0,
    queue_ready: u32 = 0,
    desc_addr: u64 = 0,
    avail_addr: u64 = 0,
    used_addr: u64 = 0,
    last_avail: u16 = 0,
    used_idx: u16 = 0,
    int_status: u32 = 0,

    pub fn init(base: u64, irq_id: u32, bus: *Bus, gic: *Gicv2, seed: [32]u8) VirtioRng {
        return .{ .base = base, .irq_id = irq_id, .bus = bus, .gic = gic, .rng = std.Random.ChaCha.init(seed) };
    }

    pub fn read(self: *VirtioRng, off: u64, sz: u8) u64 {
        _ = sz;
        return switch (off) {
            MAGIC => 0x7472_6976, // "virt"
            VERSION => 2,
            DEVICE_ID => VIRTIO_RNG,
            VENDOR_ID => 0x554d_4551, // "QEMU"
            DEVICE_FEATURES => if (self.device_features_sel == 1) 1 else 0, // VIRTIO_F_VERSION_1 (bit 32)
            QUEUE_NUM_MAX => 256,
            QUEUE_READY => self.queue_ready,
            INTERRUPT_STATUS => self.int_status,
            STATUS => self.status,
            else => 0,
        };
    }

    pub fn write(self: *VirtioRng, off: u64, value: u64, sz: u8) void {
        _ = sz;
        const v: u32 = @truncate(value);
        switch (off) {
            DEVICE_FEATURES_SEL => self.device_features_sel = v,
            DRIVER_FEATURES_SEL => self.driver_features_sel = v,
            DRIVER_FEATURES => {},
            QUEUE_SEL => {}, // single queue (0)
            QUEUE_NUM => self.queue_num = v,
            QUEUE_READY => self.queue_ready = v,
            QUEUE_DESC_LOW => self.desc_addr = (self.desc_addr & 0xffff_ffff_0000_0000) | v,
            QUEUE_DESC_HIGH => self.desc_addr = (self.desc_addr & 0xffff_ffff) | (@as(u64, v) << 32),
            QUEUE_DRIVER_LOW => self.avail_addr = (self.avail_addr & 0xffff_ffff_0000_0000) | v,
            QUEUE_DRIVER_HIGH => self.avail_addr = (self.avail_addr & 0xffff_ffff) | (@as(u64, v) << 32),
            QUEUE_DEVICE_LOW => self.used_addr = (self.used_addr & 0xffff_ffff_0000_0000) | v,
            QUEUE_DEVICE_HIGH => self.used_addr = (self.used_addr & 0xffff_ffff) | (@as(u64, v) << 32),
            QUEUE_NOTIFY => self.processQueue(),
            INTERRUPT_ACK => {
                self.int_status &= ~v;
                if (self.int_status == 0) self.gic.setIrq(self.irq_id, false);
            },
            STATUS => self.status = v,
            else => {},
        }
    }

    fn processQueue(self: *VirtioRng) void {
        if (self.queue_num == 0) return;
        const avail_idx: u16 = @truncate(self.bus.read(self.avail_addr + 2, 2));
        while (self.last_avail != avail_idx) {
            const ring_slot = self.last_avail % @as(u16, @truncate(self.queue_num));
            const head: u16 = @truncate(self.bus.read(self.avail_addr + 4 + @as(u64, ring_slot) * 2, 2));
            const written = self.fillChain(head);
            const ring_off = self.used_addr + 4 + @as(u64, self.used_idx % @as(u16, @truncate(self.queue_num))) * 8;
            self.bus.write(ring_off, head, 4); // used elem id
            self.bus.write(ring_off + 4, written, 4); // bytes written
            self.used_idx +%= 1;
            self.bus.write(self.used_addr + 2, self.used_idx, 2); // used.idx
            self.last_avail +%= 1;
        }
        self.int_status |= 1;
        self.gic.setIrq(self.irq_id, true);
    }

    /// Fill every device-writable descriptor in the chain with CSPRNG bytes.
    fn fillChain(self: *VirtioRng, head: u16) u32 {
        var idx = head;
        var total: u32 = 0;
        var buf: [256]u8 = undefined;
        while (true) {
            const d = self.descAt(idx);
            if ((d.flags & VRING_DESC_F_WRITE) != 0) {
                var done: u32 = 0;
                while (done < d.len) {
                    const n: u32 = @min(@as(u32, buf.len), d.len - done);
                    self.rng.fill(buf[0..n]);
                    var i: u32 = 0;
                    while (i < n) : (i += 1) self.bus.write(d.addr + done + i, buf[i], 1);
                    done += n;
                }
                total += d.len;
            }
            if ((d.flags & VRING_DESC_F_NEXT) == 0) break;
            idx = d.next;
        }
        return total;
    }

    const Desc = struct { addr: u64, len: u32, flags: u16, next: u16 };
    fn descAt(self: *VirtioRng, idx: u16) Desc {
        const a = self.desc_addr + @as(u64, idx) * 16;
        return .{
            .addr = self.bus.read(a, 8),
            .len = @truncate(self.bus.read(a + 8, 4)),
            .flags = @truncate(self.bus.read(a + 12, 2)),
            .next = @truncate(self.bus.read(a + 14, 2)),
        };
    }
};

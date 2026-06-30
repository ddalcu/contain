//! virtio-mmio transport (modern / version 2) + a virtio-blk device backed by a
//! host file. This is the shared foundation for M2 (virtio-net) and M3
//! (virtio-9p): the split-virtqueue handling here is device-agnostic.
//!
//! Split virtqueue layout in guest memory:
//!   desc[]  : descriptor table  (16 bytes each)
//!   avail   : driver -> device available ring
//!   used    : device -> driver used ring
//! The device reads physical guest memory through the Bus.

const Bus = @import("../bus.zig").Bus;
const Gicv2 = @import("gicv2.zig").Gicv2;

// virtio-mmio register offsets.
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
const CONFIG = 0x100;

const VIRTIO_BLK: u32 = 2;
const SECTOR: u64 = 512;

// virtio-blk request types.
const BLK_T_IN: u32 = 0; // read
const BLK_T_OUT: u32 = 1; // write

// Descriptor flags.
const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

pub const VirtioBlk = struct {
    pub const size: u64 = 0x200;

    base: u64,
    irq_id: u32, // GIC SPI INTID
    bus: *Bus,
    gic: *Gicv2,
    disk: []u8, // host-backed disk image (in memory; flushed by caller)

    // Register state.
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

    pub fn init(base: u64, irq_id: u32, bus: *Bus, gic: *Gicv2, disk: []u8) VirtioBlk {
        return .{ .base = base, .irq_id = irq_id, .bus = bus, .gic = gic, .disk = disk };
    }

    pub fn read(self: *VirtioBlk, off: u64, sz: u8) u64 {
        _ = sz;
        return switch (off) {
            MAGIC => 0x7472_6976, // "virt"
            VERSION => 2,
            DEVICE_ID => VIRTIO_BLK,
            VENDOR_ID => 0x554d_4551, // "QEMU"
            DEVICE_FEATURES => if (self.device_features_sel == 1) (1 << (32 - 32)) else 0, // VIRTIO_F_VERSION_1 (bit32)
            QUEUE_NUM_MAX => 256,
            QUEUE_READY => self.queue_ready,
            INTERRUPT_STATUS => self.int_status,
            STATUS => self.status,
            CONFIG => self.disk.len / SECTOR, // capacity (sectors), low 32 bits
            CONFIG + 4 => (self.disk.len / SECTOR) >> 32,
            else => 0,
        };
    }

    pub fn write(self: *VirtioBlk, off: u64, value: u64, sz: u8) void {
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

    fn processQueue(self: *VirtioBlk) void {
        const avail_idx = self.bus.read(self.avail_addr + 2, 2); // avail.idx
        while (self.last_avail != @as(u16, @truncate(avail_idx))) {
            const ring_slot = self.last_avail % @as(u16, @truncate(self.queue_num));
            const head: u16 = @truncate(self.bus.read(self.avail_addr + 4 + @as(u64, ring_slot) * 2, 2));
            self.handleChain(head);
            self.last_avail +%= 1;
        }
        // Raise used-buffer-notification interrupt.
        self.int_status |= 1;
        self.gic.setIrq(self.irq_id, true);
    }

    /// Walk a descriptor chain: [req header (RO)] [data (RO for write / WO for read)] [status byte (WO)].
    fn handleChain(self: *VirtioBlk, head: u16) void {
        var idx = head;
        var hdr_addr: u64 = 0;
        var data_addr: u64 = 0;
        var data_len: u64 = 0;
        var status_addr: u64 = 0;
        var part: u32 = 0;
        while (true) {
            const d = self.descAt(idx);
            if (part == 0) {
                hdr_addr = d.addr;
            } else if ((d.flags & VRING_DESC_F_NEXT) != 0 or (d.flags & VRING_DESC_F_WRITE) != 0 and status_addr == 0 and data_addr == 0) {
                // middle data descriptor (could be the data buffer)
                if (d.len == 1) status_addr = d.addr else {
                    data_addr = d.addr;
                    data_len = d.len;
                }
            }
            if (d.len == 1 and (d.flags & VRING_DESC_F_WRITE) != 0) status_addr = d.addr;
            if ((d.flags & VRING_DESC_F_NEXT) == 0) break;
            idx = d.next;
            part += 1;
        }

        const req_type: u32 = @truncate(self.bus.read(hdr_addr, 4));
        const sector = self.bus.read(hdr_addr + 8, 8);
        const offset = sector * SECTOR;
        var ok: u8 = 0;
        if (req_type == BLK_T_IN) { // device writes data to guest
            if (offset + data_len <= self.disk.len) {
                var i: u64 = 0;
                while (i < data_len) : (i += 1) self.bus.write(data_addr + i, self.disk[offset + i], 1);
            } else ok = 1;
        } else if (req_type == BLK_T_OUT) { // guest data -> disk
            if (offset + data_len <= self.disk.len) {
                var i: u64 = 0;
                while (i < data_len) : (i += 1) self.disk[offset + i] = @truncate(self.bus.read(data_addr + i, 1));
            } else ok = 1;
        }
        if (status_addr != 0) self.bus.write(status_addr, ok, 1); // 0 = VIRTIO_BLK_S_OK

        // Add to used ring.
        const total_written: u32 = if (req_type == BLK_T_IN) @truncate(data_len + 1) else 1;
        const ring_off = self.used_addr + 4 + @as(u64, self.used_idx % @as(u16, @truncate(self.queue_num))) * 8;
        self.bus.write(ring_off, head, 4); // used elem id
        self.bus.write(ring_off + 4, total_written, 4); // len
        self.used_idx +%= 1;
        self.bus.write(self.used_addr + 2, self.used_idx, 2); // used.idx
    }

    const Desc = struct { addr: u64, len: u32, flags: u16, next: u16 };
    fn descAt(self: *VirtioBlk, idx: u16) Desc {
        const a = self.desc_addr + @as(u64, idx) * 16;
        return .{
            .addr = self.bus.read(a, 8),
            .len = @truncate(self.bus.read(a + 8, 4)),
            .flags = @truncate(self.bus.read(a + 12, 2)),
            .next = @truncate(self.bus.read(a + 14, 2)),
        };
    }
};

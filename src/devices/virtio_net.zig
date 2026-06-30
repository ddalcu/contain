//! virtio-net device (modern virtio-mmio v2) wired to the userspace NAT stack.
//! Queue 0 = receive (device -> guest), queue 1 = transmit (guest -> device).
//! Each packet buffer is a 12-byte virtio_net_hdr followed by the Ethernet frame.

const Bus = @import("../bus.zig").Bus;
const Gicv2 = @import("gicv2.zig").Gicv2;
const Nat = @import("../net/nat.zig").Nat;

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

const VIRTIO_NET: u32 = 1;
const VIRTIO_NET_F_MAC: u6 = 5;
const NET_HDR_LEN = 12;

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

pub const VirtioNet = struct {
    pub const size: u64 = 0x200;

    base: u64,
    irq_id: u32,
    bus: *Bus,
    gic: *Gicv2,
    mac: [6]u8,
    nat: *Nat,

    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    queue_sel: u32 = 0,
    int_status: u32 = 0,

    // Per-queue state: [0]=RX, [1]=TX.
    qnum: [2]u32 = .{ 0, 0 },
    qready: [2]u32 = .{ 0, 0 },
    desc: [2]u64 = .{ 0, 0 },
    avail: [2]u64 = .{ 0, 0 },
    used: [2]u64 = .{ 0, 0 },
    last_avail: [2]u16 = .{ 0, 0 },
    used_idx: [2]u16 = .{ 0, 0 },

    pub fn init(base: u64, irq_id: u32, bus: *Bus, gic: *Gicv2, mac: [6]u8, nat: *Nat) VirtioNet {
        return .{ .base = base, .irq_id = irq_id, .bus = bus, .gic = gic, .mac = mac, .nat = nat };
    }

    pub fn read(self: *VirtioNet, off: u64, sz: u8) u64 {
        _ = sz;
        const s = self.queue_sel;
        return switch (off) {
            MAGIC => 0x7472_6976,
            VERSION => 2,
            DEVICE_ID => VIRTIO_NET,
            VENDOR_ID => 0x554d_4551,
            DEVICE_FEATURES => if (self.device_features_sel == 1)
                1 // VIRTIO_F_VERSION_1 (bit 32)
            else
                (@as(u64, 1) << VIRTIO_NET_F_MAC),
            QUEUE_NUM_MAX => 256,
            QUEUE_READY => if (s < 2) self.qready[s] else 0,
            INTERRUPT_STATUS => self.int_status,
            STATUS => self.status,
            // config: mac[6] then status[2] (link up).
            CONFIG => self.mac[0],
            CONFIG + 1 => self.mac[1],
            CONFIG + 2 => self.mac[2],
            CONFIG + 3 => self.mac[3],
            CONFIG + 4 => self.mac[4],
            CONFIG + 5 => self.mac[5],
            CONFIG + 6 => 1, // status: VIRTIO_NET_S_LINK_UP
            CONFIG + 7 => 0,
            else => 0,
        };
    }

    pub fn write(self: *VirtioNet, off: u64, value: u64, sz: u8) void {
        _ = sz;
        const v: u32 = @truncate(value);
        const s = self.queue_sel;
        switch (off) {
            DEVICE_FEATURES_SEL => self.device_features_sel = v,
            DRIVER_FEATURES_SEL => self.driver_features_sel = v,
            DRIVER_FEATURES => {},
            QUEUE_SEL => self.queue_sel = v,
            QUEUE_NUM => if (s < 2) {
                self.qnum[s] = v;
            },
            QUEUE_READY => if (s < 2) {
                self.qready[s] = v;
            },
            QUEUE_DESC_LOW => if (s < 2) {
                self.desc[s] = (self.desc[s] & 0xffff_ffff_0000_0000) | v;
            },
            QUEUE_DESC_HIGH => if (s < 2) {
                self.desc[s] = (self.desc[s] & 0xffff_ffff) | (@as(u64, v) << 32);
            },
            QUEUE_DRIVER_LOW => if (s < 2) {
                self.avail[s] = (self.avail[s] & 0xffff_ffff_0000_0000) | v;
            },
            QUEUE_DRIVER_HIGH => if (s < 2) {
                self.avail[s] = (self.avail[s] & 0xffff_ffff) | (@as(u64, v) << 32);
            },
            QUEUE_DEVICE_LOW => if (s < 2) {
                self.used[s] = (self.used[s] & 0xffff_ffff_0000_0000) | v;
            },
            QUEUE_DEVICE_HIGH => if (s < 2) {
                self.used[s] = (self.used[s] & 0xffff_ffff) | (@as(u64, v) << 32);
            },
            QUEUE_NOTIFY => {
                if (v == 1) self.processTx();
                self.deliverRx();
            },
            INTERRUPT_ACK => {
                self.int_status &= ~v;
                if (self.int_status == 0) self.gic.setIrq(self.irq_id, false);
            },
            STATUS => self.status = v,
            else => {},
        }
    }

    const Desc = struct { addr: u64, len: u32, flags: u16, next: u16 };
    fn descAt(self: *VirtioNet, q: usize, idx: u16) Desc {
        const a = self.desc[q] + @as(u64, idx) * 16;
        return .{
            .addr = self.bus.read(a, 8),
            .len = @truncate(self.bus.read(a + 8, 4)),
            .flags = @truncate(self.bus.read(a + 12, 2)),
            .next = @truncate(self.bus.read(a + 14, 2)),
        };
    }

    /// Periodic service: advance the NAT (host sockets) and deliver any frames.
    /// Called from `Machine.serviceDevicesHw` at each vCPU run-loop boundary so
    /// host->guest RX isn't starved — an earlier regression serviced RX too rarely
    /// and made large downloads time out (ETIMEDOUT). pump() and deliverRx() fully
    /// drain what's available and are cheap when idle (a spinlock + one
    /// guest-memory read), so no extra gate.
    pub fn service(self: *VirtioNet) void {
        self.nat.pump();
        self.deliverRx();
    }

    fn processTx(self: *VirtioNet) void {
        const q: usize = 1;
        if (self.qready[q] == 0 or self.qnum[q] == 0) return;
        const avail_idx: u16 = @truncate(self.bus.read(self.avail[q] + 2, 2));
        var buf: [2048]u8 = undefined;
        while (self.last_avail[q] != avail_idx) {
            const slot = self.last_avail[q] % @as(u16, @truncate(self.qnum[q]));
            const head: u16 = @truncate(self.bus.read(self.avail[q] + 4 + @as(u64, slot) * 2, 2));
            // Gather all readable bytes in the chain.
            var total: usize = 0;
            var idx = head;
            while (true) {
                const d = self.descAt(q, idx);
                if ((d.flags & VRING_DESC_F_WRITE) == 0) {
                    var i: u32 = 0;
                    while (i < d.len and total < buf.len) : (i += 1) {
                        buf[total] = @truncate(self.bus.read(d.addr + i, 1));
                        total += 1;
                    }
                }
                if ((d.flags & VRING_DESC_F_NEXT) == 0) break;
                idx = d.next;
            }
            if (total > NET_HDR_LEN) self.nat.input(buf[NET_HDR_LEN..total]);
            self.pushUsed(q, head, 0);
            self.last_avail[q] +%= 1;
        }
        self.raise();
    }

    fn deliverRx(self: *VirtioNet) void {
        const q: usize = 0;
        if (self.qready[q] == 0 or self.qnum[q] == 0) return;
        var frame: [2048]u8 = undefined;
        var delivered = false;
        while (true) {
            const avail_idx: u16 = @truncate(self.bus.read(self.avail[q] + 2, 2));
            if (self.last_avail[q] == avail_idx) break; // no RX buffers posted
            const n = self.nat.poll(frame[NET_HDR_LEN..]) orelse break;
            // zero the virtio_net_hdr
            @memset(frame[0..NET_HDR_LEN], 0);
            const total = NET_HDR_LEN + n;

            const slot = self.last_avail[q] % @as(u16, @truncate(self.qnum[q]));
            const head: u16 = @truncate(self.bus.read(self.avail[q] + 4 + @as(u64, slot) * 2, 2));
            // Scatter into writable descriptors.
            var written: usize = 0;
            var idx = head;
            while (written < total) {
                const d = self.descAt(q, idx);
                if ((d.flags & VRING_DESC_F_WRITE) != 0) {
                    var i: u32 = 0;
                    while (i < d.len and written < total) : (i += 1) {
                        self.bus.write(d.addr + i, frame[written], 1);
                        written += 1;
                    }
                }
                if ((d.flags & VRING_DESC_F_NEXT) == 0) break;
                idx = d.next;
            }
            self.pushUsed(q, head, @intCast(written));
            self.last_avail[q] +%= 1;
            delivered = true;
        }
        if (delivered) self.raise();
    }

    fn pushUsed(self: *VirtioNet, q: usize, head: u16, len: u32) void {
        const ring_off = self.used[q] + 4 + @as(u64, self.used_idx[q] % @as(u16, @truncate(self.qnum[q]))) * 8;
        self.bus.write(ring_off, head, 4);
        self.bus.write(ring_off + 4, len, 4);
        self.used_idx[q] +%= 1;
        self.bus.write(self.used[q] + 2, self.used_idx[q], 2);
    }

    fn raise(self: *VirtioNet) void {
        self.int_status |= 1;
        self.gic.setIrq(self.irq_id, true);
    }
};

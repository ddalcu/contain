//! virtio-fs device: shares a host directory into the guest over the **FUSE**
//! low-level protocol (mount with `-t virtiofs <tag>`). This is the POSIX-complete
//! successor to the 9p share (`virtio_9p.zig`): FUSE gives us proper inode
//! semantics, page-cache-backed mmap, real fsync/flush and byte-range locks —
//! everything images like SQLite, Postgres and the general "run a real rootfs"
//! path need. It is also how contain mounts a container's **root filesystem**
//! demand-paged from the host instead of packing the whole image into an in-RAM
//! initramfs (the big memory win).
//!
//! Transport: virtio-mmio (DeviceID 26). Unlike 9p (one queue) virtio-fs uses a
//! **hiprio** queue (index 0, FORGET / interrupts) plus one or more **request**
//! queues (index 1+). We advertise a single request queue, so two queues total;
//! both carry FUSE messages and route through the same dispatch.
//!
//! Protocol model (mirrors the 9p device's design): **stateless** host I/O. We do
//! NOT hold OS file handles across requests — every READ/WRITE re-opens the file
//! by its inode's path and does positional I/O, and READDIR re-opens the dir and
//! iterates to the requested offset. This sidesteps fd-lifetime bookkeeping and is
//! the exact approach proven out on 9p. Inodes (FUSE "nodeid"s) are tracked in a
//! table with lookup refcounts so FORGET frees them.

const std = @import("std");
const Bus = @import("../bus.zig").Bus;
const Gicv2 = @import("gicv2.zig").Gicv2;

// virtio-mmio register offsets (same layout as virtio.zig / virtio_9p.zig).
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

const VIRTIO_ID_FS: u32 = 26;

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

// virtio-fs has a hiprio queue (0) + N request queues. We expose one request
// queue, so two queues total.
const NUM_QUEUES = 2;

// ---- FUSE protocol constants (linux/fuse.h) --------------------------------

const FUSE_KERNEL_VERSION: u32 = 7;
// The minor we negotiate down to. 7.31 is old enough that every field layout we
// encode below is stable, and new enough for everything a container rootfs uses.
const FUSE_NEGOTIATED_MINOR: u32 = 31;

// opcodes
const FUSE_LOOKUP = 1;
const FUSE_FORGET = 2;
const FUSE_GETATTR = 3;
const FUSE_SETATTR = 4;
const FUSE_READLINK = 5;
const FUSE_SYMLINK = 6;
const FUSE_MKNOD = 8;
const FUSE_MKDIR = 9;
const FUSE_UNLINK = 10;
const FUSE_RMDIR = 11;
const FUSE_RENAME = 12;
const FUSE_LINK = 13;
const FUSE_OPEN = 14;
const FUSE_READ = 15;
const FUSE_WRITE = 16;
const FUSE_STATFS = 17;
const FUSE_RELEASE = 18;
const FUSE_FSYNC = 20;
const FUSE_SETXATTR = 21;
const FUSE_GETXATTR = 22;
const FUSE_LISTXATTR = 23;
const FUSE_REMOVEXATTR = 24;
const FUSE_FLUSH = 25;
const FUSE_INIT = 26;
const FUSE_OPENDIR = 27;
const FUSE_READDIR = 28;
const FUSE_RELEASEDIR = 29;
const FUSE_FSYNCDIR = 30;
const FUSE_GETLK = 31;
const FUSE_SETLK = 32;
const FUSE_SETLKW = 33;
const FUSE_ACCESS = 34;
const FUSE_CREATE = 35;
const FUSE_INTERRUPT = 36;
const FUSE_BMAP = 37;
const FUSE_DESTROY = 38;
const FUSE_BATCH_FORGET = 42;
const FUSE_READDIRPLUS = 44;
const FUSE_RENAME2 = 45;
const FUSE_LSEEK = 46;

// errno (negated in fuse_out_header.error)
const ENOENT = 2;
const EIO = 5;
const EBADF = 9;
const EACCES = 13;
const EEXIST = 17;
const ENOTDIR = 20;
const EISDIR = 21;
const EINVAL = 22;
const ENOSYS = 38;
const ENOTEMPTY = 39;
const ENODATA = 61;
const ENAMETOOLONG = 36;

// d_type
const DT_DIR: u32 = 4;
const DT_REG: u32 = 8;
const DT_LNK: u32 = 10;

// FUSE_SETATTR valid bits
const FATTR_SIZE: u32 = 1 << 3;

const ROOT_NODEID: u64 = 1;

pub const Node = struct {
    path: []u8, // relative to share root ("" = root)
    nlookup: u64, // outstanding kernel lookup refs (FORGET decrements)
    is_dir: bool,
};

const Queue = struct {
    num: u32 = 0,
    ready: u32 = 0,
    desc: u64 = 0,
    avail: u64 = 0,
    used: u64 = 0,
    last_avail: u16 = 0,
    used_idx: u16 = 0,
};

pub const VirtioFs = struct {
    pub const size: u64 = 0x200;

    irq_id: u32,
    bus: *Bus,
    gic: *Gicv2,
    io: std.Io,
    base: []const u8, // host share directory (cwd-relative)
    tag: []const u8, // virtiofs mount tag
    alloc: std.mem.Allocator,

    nodes: std.AutoHashMap(u64, Node),
    by_path: std.StringHashMap(u64),
    next_nodeid: u64 = 2, // 1 is root

    status: u32 = 0,
    device_features_sel: u32 = 0,
    queue_sel: u32 = 0,
    queues: [NUM_QUEUES]Queue = [_]Queue{.{}} ** NUM_QUEUES,
    int_status: u32 = 0,

    mmio_base: u64 = 0,
    pathbuf: [4096]u8 = undefined,
    // Scratch for one request/reply. FUSE writes can be up to max_write (128 KiB);
    // give headroom for the 40-byte in-header + struct + data.
    in_buf: []u8 = &.{},
    out_buf: []u8 = &.{},

    pub fn init(mmio_base: u64, irq_id: u32, bus: *Bus, gic: *Gicv2, io: std.Io, base_path: []const u8, tag: []const u8, alloc: std.mem.Allocator) !VirtioFs {
        var self = VirtioFs{
            .mmio_base = mmio_base,
            .irq_id = irq_id,
            .bus = bus,
            .gic = gic,
            .io = io,
            .base = base_path,
            .tag = tag,
            .alloc = alloc,
            .nodes = std.AutoHashMap(u64, Node).init(alloc),
            .by_path = std.StringHashMap(u64).init(alloc),
        };
        self.in_buf = try alloc.alloc(u8, 160 * 1024);
        self.out_buf = try alloc.alloc(u8, 160 * 1024);
        // Seed the root inode.
        const root_path = try alloc.dupe(u8, "");
        try self.nodes.put(ROOT_NODEID, .{ .path = root_path, .nlookup = 1, .is_dir = true });
        try self.by_path.put(root_path, ROOT_NODEID);
        return self;
    }

    pub fn deinit(self: *VirtioFs) void {
        var it = self.nodes.iterator();
        while (it.next()) |e| self.alloc.free(e.value_ptr.path);
        self.nodes.deinit();
        self.by_path.deinit();
        self.alloc.free(self.in_buf);
        self.alloc.free(self.out_buf);
    }

    fn hostPath(self: *VirtioFs, rel: []const u8) []const u8 {
        if (rel.len == 0) return self.base;
        return std.fmt.bufPrint(&self.pathbuf, "{s}/{s}", .{ self.base, rel }) catch self.base;
    }

    // ---- MMIO ---------------------------------------------------------------

    pub fn read(self: *VirtioFs, off: u64, sz: u8) u64 {
        _ = sz;
        return switch (off) {
            MAGIC => 0x7472_6976,
            VERSION => 2,
            DEVICE_ID => VIRTIO_ID_FS,
            VENDOR_ID => 0x554d_4551,
            DEVICE_FEATURES => if (self.device_features_sel == 1) 1 else 0, // bit32 = VERSION_1
            QUEUE_NUM_MAX => 128,
            QUEUE_READY => self.curQueue().ready,
            INTERRUPT_STATUS => self.int_status,
            STATUS => self.status,
            else => self.readConfig(off),
        };
    }

    // virtio_fs_config { char tag[36]; u32 num_request_queues; }
    fn readConfig(self: *VirtioFs, off: u64) u64 {
        if (off < CONFIG) return 0;
        const c = off - CONFIG;
        if (c < 36) return if (c < self.tag.len) self.tag[c] else 0;
        if (c >= 36 and c < 40) {
            const nq: u32 = 1; // one request queue
            return (nq >> @intCast((c - 36) * 8)) & 0xff;
        }
        return 0;
    }

    fn curQueue(self: *VirtioFs) *Queue {
        const i = if (self.queue_sel < NUM_QUEUES) self.queue_sel else 0;
        return &self.queues[i];
    }

    pub fn write(self: *VirtioFs, off: u64, value: u64, sz: u8) void {
        _ = sz;
        const v: u32 = @truncate(value);
        switch (off) {
            DEVICE_FEATURES_SEL => self.device_features_sel = v,
            DRIVER_FEATURES_SEL, DRIVER_FEATURES => {},
            QUEUE_SEL => self.queue_sel = v,
            QUEUE_NUM => self.curQueue().num = v,
            QUEUE_READY => self.curQueue().ready = v,
            QUEUE_DESC_LOW => setLo(&self.curQueue().desc, v),
            QUEUE_DESC_HIGH => setHi(&self.curQueue().desc, v),
            QUEUE_DRIVER_LOW => setLo(&self.curQueue().avail, v),
            QUEUE_DRIVER_HIGH => setHi(&self.curQueue().avail, v),
            QUEUE_DEVICE_LOW => setLo(&self.curQueue().used, v),
            QUEUE_DEVICE_HIGH => setHi(&self.curQueue().used, v),
            QUEUE_NOTIFY => self.processQueue(v),
            INTERRUPT_ACK => {
                self.int_status &= ~v;
                if (self.int_status == 0) self.gic.setIrq(self.irq_id, false);
            },
            STATUS => self.status = v,
            else => {},
        }
    }

    // ---- virtqueue ----------------------------------------------------------

    const Seg = struct { addr: u64, len: u32, writable: bool };

    fn processQueue(self: *VirtioFs, qidx: u32) void {
        if (qidx >= NUM_QUEUES) return;
        const q = &self.queues[qidx];
        if (q.num == 0) return;
        const avail_idx: u16 = @truncate(self.bus.read(q.avail + 2, 2));
        var did_work = false;
        while (q.last_avail != avail_idx) {
            const slot = q.last_avail % @as(u16, @truncate(q.num));
            const head: u16 = @truncate(self.bus.read(q.avail + 4 + @as(u64, slot) * 2, 2));
            self.handleChain(q, head);
            q.last_avail +%= 1;
            did_work = true;
        }
        if (did_work) {
            self.int_status |= 1;
            self.gic.setIrq(self.irq_id, true);
        }
    }

    fn handleChain(self: *VirtioFs, q: *Queue, head: u16) void {
        var segs: [64]Seg = undefined;
        var nseg: usize = 0;
        var idx = head;
        while (nseg < segs.len) {
            const a = q.desc + @as(u64, idx) * 16;
            const addr = self.bus.read(a, 8);
            const len: u32 = @truncate(self.bus.read(a + 8, 4));
            const flags: u16 = @truncate(self.bus.read(a + 12, 2));
            segs[nseg] = .{ .addr = addr, .len = len, .writable = (flags & VRING_DESC_F_WRITE) != 0 };
            nseg += 1;
            if ((flags & VRING_DESC_F_NEXT) == 0) break;
            idx = @truncate(self.bus.read(a + 14, 2));
        }

        // Gather readable segments (the FUSE request) into in_buf.
        var tlen: usize = 0;
        for (segs[0..nseg]) |s| {
            if (s.writable) continue;
            tlen += self.copyIn(s.addr, self.in_buf[tlen..], s.len);
        }

        // Total writable capacity available for the reply.
        var wcap: usize = 0;
        for (segs[0..nseg]) |s| {
            if (s.writable) wcap += s.len;
        }
        if (wcap > self.out_buf.len) wcap = self.out_buf.len;

        const rlen = self.dispatch(self.in_buf[0..tlen], self.out_buf[0..wcap]);

        // Scatter the reply across writable segments.
        var written: usize = 0;
        for (segs[0..nseg]) |s| {
            if (!s.writable) continue;
            if (written >= rlen) break;
            const n = @min(@as(usize, s.len), rlen - written);
            written += self.copyOut(s.addr, self.out_buf[written .. written + n]);
        }

        const ring_off = q.used + 4 + @as(u64, q.used_idx % @as(u16, @truncate(q.num))) * 8;
        self.bus.write(ring_off, head, 4);
        self.bus.write(ring_off + 4, @intCast(written), 4);
        q.used_idx +%= 1;
        self.bus.write(q.used + 2, q.used_idx, 2);
    }

    /// Bulk-copy `len` bytes of guest memory at `addr` into `dst` (fast path via a
    /// direct RAM slice; byte-wise fallback for the rare non-RAM segment).
    fn copyIn(self: *VirtioFs, addr: u64, dst: []u8, len: u32) usize {
        const n = @min(@as(usize, len), dst.len);
        if (self.bus.ramSlice(addr, n)) |src| {
            @memcpy(dst[0..n], src);
        } else {
            for (0..n) |i| dst[i] = @truncate(self.bus.read(addr + i, 1));
        }
        return n;
    }

    fn copyOut(self: *VirtioFs, addr: u64, src: []const u8) usize {
        if (self.bus.ramSlice(addr, src.len)) |dst| {
            @memcpy(dst, src);
        } else {
            for (src, 0..) |b, i| self.bus.write(addr + i, b, 1);
        }
        return src.len;
    }

    // ---- FUSE dispatch ------------------------------------------------------

    /// Handle one FUSE request in `in_buf`, write the reply (out_header + payload)
    /// into `out`, and return the reply length. `out` capacity is the writable
    /// descriptor space the driver provided.
    pub fn dispatch(self: *VirtioFs, in: []const u8, out: []u8) usize {
        if (in.len < 40 or out.len < 16) return 0;
        const opcode = rd32(in, 4);
        const unique = rd64(in, 8);
        const nodeid = rd64(in, 16);
        const body = in[40..];

        var r = Reply{ .buf = out, .unique = unique };

        switch (opcode) {
            FUSE_INIT => self.opInit(body, &r),
            FUSE_GETATTR => self.opGetattr(nodeid, &r),
            FUSE_LOOKUP => self.opLookup(nodeid, body, &r),
            FUSE_FORGET => {
                self.opForget(nodeid, rd64(body, 0));
                return 0; // FORGET has no reply
            },
            FUSE_BATCH_FORGET => {
                self.opBatchForget(body);
                return 0;
            },
            FUSE_SETATTR => self.opSetattr(nodeid, body, &r),
            FUSE_READLINK => self.opReadlink(nodeid, &r),
            FUSE_SYMLINK => self.opSymlink(nodeid, body, &r),
            FUSE_MKNOD => self.opMknod(nodeid, body, &r),
            FUSE_MKDIR => self.opMkdir(nodeid, body, &r),
            FUSE_UNLINK => self.opUnlink(nodeid, body, false, &r),
            FUSE_RMDIR => self.opUnlink(nodeid, body, true, &r),
            FUSE_RENAME => self.opRename(nodeid, body, false, &r),
            FUSE_RENAME2 => self.opRename(nodeid, body, true, &r),
            FUSE_LINK => self.opLink(nodeid, body, &r),
            FUSE_OPEN => self.opOpen(nodeid, &r, false),
            FUSE_OPENDIR => self.opOpen(nodeid, &r, true),
            FUSE_READ => self.opRead(nodeid, body, &r),
            FUSE_WRITE => self.opWrite(nodeid, body, &r),
            FUSE_READDIR => self.opReaddir(nodeid, body, &r),
            FUSE_READDIRPLUS => self.opReaddir(nodeid, body, &r), // fall back to plain form
            FUSE_STATFS => self.opStatfs(&r),
            FUSE_RELEASE, FUSE_RELEASEDIR => {}, // stateless: nothing to release -> ok
            FUSE_FSYNC, FUSE_FSYNCDIR, FUSE_FLUSH => {}, // writes are write-through -> ok
            FUSE_CREATE => self.opCreate(nodeid, body, &r),
            FUSE_ACCESS => {}, // permissive
            FUSE_GETLK => self.opGetlk(body, &r),
            FUSE_SETLK, FUSE_SETLKW => {}, // grant (client-side VFS enforces mutual excl.)
            FUSE_GETXATTR, FUSE_LISTXATTR => r.err = ENODATA,
            FUSE_SETXATTR, FUSE_REMOVEXATTR => r.err = ENOSYS,
            FUSE_LSEEK => self.opLseek(nodeid, body, &r),
            FUSE_INTERRUPT, FUSE_DESTROY, FUSE_BMAP => {},
            else => r.err = ENOSYS,
        }

        return r.finish();
    }

    fn opInit(self: *VirtioFs, body: []const u8, r: *Reply) void {
        _ = self;
        const kmajor = rd32(body, 0);
        const kminor = rd32(body, 4);
        const max_readahead = rd32(body, 8);
        if (kmajor < 7) {
            r.err = EINVAL;
            return;
        }
        const minor = @min(kminor, FUSE_NEGOTIATED_MINOR);
        var o = r.payload();
        o.put32(FUSE_KERNEL_VERSION); // major
        o.put32(minor); // minor
        o.put32(max_readahead); // max_readahead (echo)
        o.put32(0); // flags (no optional features negotiated)
        o.put16(16); // max_background
        o.put16(12); // congestion_threshold
        o.put32(128 * 1024); // max_write
        o.put32(1); // time_gran (1ns)
        o.put16(32); // max_pages (128K/4K)
        o.put16(0); // map_alignment
        o.put32(0); // flags2
        var i: usize = 0;
        while (i < 7) : (i += 1) o.put32(0); // unused[7]
        r.commit(o);
    }

    fn opGetattr(self: *VirtioFs, nodeid: u64, r: *Reply) void {
        const node = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        const st = self.statPath(node.path) catch return r.setErr(ENOENT);
        var o = r.payload();
        o.put64(3600); // attr_valid (sec)
        o.put32(0); // attr_valid_nsec
        o.put32(0); // dummy
        self.putAttr(&o, nodeid, st);
        r.commit(o);
    }

    fn opLookup(self: *VirtioFs, parent: u64, body: []const u8, r: *Reply) void {
        const name = cstr(body);
        const child = self.childPath(parent, name) catch return r.setErr(EIO);
        defer self.alloc.free(child);
        const st = self.statPath(child) catch return r.setErr(ENOENT);
        const id = self.intern(child, st.kind == .directory) catch return r.setErr(EIO);
        var o = r.payload();
        self.putEntry(&o, id, st);
        r.commit(o);
    }

    fn opForget(self: *VirtioFs, nodeid: u64, nlookup: u64) void {
        if (nodeid == ROOT_NODEID) return;
        const e = self.nodes.getPtr(nodeid) orelse return;
        if (e.nlookup <= nlookup) {
            _ = self.by_path.remove(e.path);
            const path = e.path;
            _ = self.nodes.remove(nodeid);
            self.alloc.free(path);
        } else {
            e.nlookup -= nlookup;
        }
    }

    fn opBatchForget(self: *VirtioFs, body: []const u8) void {
        // fuse_batch_forget_in { u32 count; u32 dummy; } then count × { u64 nodeid; u64 nlookup; }
        const count = rd32(body, 0);
        var off: usize = 8;
        var i: u32 = 0;
        while (i < count and off + 16 <= body.len) : (i += 1) {
            self.opForget(rd64(body, off), rd64(body, off + 8));
            off += 16;
        }
    }

    fn opSetattr(self: *VirtioFs, nodeid: u64, body: []const u8, r: *Reply) void {
        const node = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        const valid = rd32(body, 0);
        if (valid & FATTR_SIZE != 0) {
            const new_size = rd64(body, 16); // fh(8)@8 then size@16
            var file = std.Io.Dir.cwd().openFile(self.io, self.hostPath(node.path), .{ .mode = .read_write }) catch return r.setErr(EACCES);
            defer file.close(self.io);
            file.setLength(self.io, new_size) catch return r.setErr(EIO);
        }
        // mode/uid/gid/times accepted as no-ops (over-permissive sandbox), then
        // return the fresh attributes.
        const st = self.statPath(node.path) catch return r.setErr(ENOENT);
        var o = r.payload();
        o.put64(3600);
        o.put32(0);
        o.put32(0);
        self.putAttr(&o, nodeid, st);
        r.commit(o);
    }

    fn opReadlink(self: *VirtioFs, nodeid: u64, r: *Reply) void {
        const node = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        var lbuf: [4096]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(self.io, self.hostPath(node.path), &lbuf) catch return r.setErr(EINVAL);
        var o = r.payload();
        o.putBytes(lbuf[0..n]); // no trailing NUL for READLINK
        r.commit(o);
    }

    fn opSymlink(self: *VirtioFs, parent: u64, body: []const u8, r: *Reply) void {
        // name\0 target\0
        const name = cstr(body);
        const target = cstr(body[name.len + 1 ..]);
        const child = self.childPath(parent, name) catch return r.setErr(EIO);
        defer self.alloc.free(child);
        std.Io.Dir.cwd().symLink(self.io, target, self.hostPath(child), .{}) catch return r.setErr(EACCES);
        const st = self.statPath(child) catch return r.setErr(EIO);
        const id = self.intern(child, false) catch return r.setErr(EIO);
        var o = r.payload();
        self.putEntry(&o, id, st);
        r.commit(o);
    }

    fn opMknod(self: *VirtioFs, parent: u64, body: []const u8, r: *Reply) void {
        // fuse_mknod_in { u32 mode; u32 rdev; u32 umask; u32 padding; } then name\0
        const name = cstr(body[16..]);
        const child = self.childPath(parent, name) catch return r.setErr(EIO);
        defer self.alloc.free(child);
        // Only regular files are supported (no device nodes in the sandbox share).
        var f = std.Io.Dir.cwd().createFile(self.io, self.hostPath(child), .{ .truncate = false, .exclusive = true }) catch return r.setErr(EEXIST);
        f.close(self.io);
        const st = self.statPath(child) catch return r.setErr(EIO);
        const id = self.intern(child, false) catch return r.setErr(EIO);
        var o = r.payload();
        self.putEntry(&o, id, st);
        r.commit(o);
    }

    fn opMkdir(self: *VirtioFs, parent: u64, body: []const u8, r: *Reply) void {
        // fuse_mkdir_in { u32 mode; u32 umask; } then name\0
        const name = cstr(body[8..]);
        const child = self.childPath(parent, name) catch return r.setErr(EIO);
        defer self.alloc.free(child);
        std.Io.Dir.cwd().createDirPath(self.io, self.hostPath(child)) catch return r.setErr(EEXIST);
        const st = self.statPath(child) catch return r.setErr(EIO);
        const id = self.intern(child, true) catch return r.setErr(EIO);
        var o = r.payload();
        self.putEntry(&o, id, st);
        r.commit(o);
    }

    fn opUnlink(self: *VirtioFs, parent: u64, body: []const u8, is_dir: bool, r: *Reply) void {
        const name = cstr(body);
        const child = self.childPath(parent, name) catch return r.setErr(EIO);
        defer self.alloc.free(child);
        const host = self.hostPath(child);
        if (is_dir)
            std.Io.Dir.cwd().deleteDir(self.io, host) catch |e| return r.setErr(fsErrno(e))
        else
            std.Io.Dir.cwd().deleteFile(self.io, host) catch |e| return r.setErr(fsErrno(e));
        // Drop any cached inode for the removed path.
        if (self.by_path.get(child)) |id| self.dropNode(id);
    }

    fn opRename(self: *VirtioFs, olddir: u64, body: []const u8, is_v2: bool, r: *Reply) void {
        // RENAME:  fuse_rename_in  { u64 newdir; }                 then oldname\0 newname\0
        // RENAME2: fuse_rename2_in { u64 newdir; u32 flags; u32 pad; } then oldname\0 newname\0
        const hdr: usize = if (is_v2) 16 else 8;
        const newdir = rd64(body, 0);
        const names = body[hdr..];
        const oldname = cstr(names);
        const newname = cstr(names[oldname.len + 1 ..]);
        const src = self.childPath(olddir, oldname) catch return r.setErr(EIO);
        defer self.alloc.free(src);
        const dst = self.childPath(newdir, newname) catch return r.setErr(EIO);
        defer self.alloc.free(dst);
        const src_host = self.alloc.dupe(u8, self.hostPath(src)) catch return r.setErr(EIO);
        defer self.alloc.free(src_host);
        const dst_host = self.hostPath(dst);
        std.Io.Dir.cwd().rename(src_host, std.Io.Dir.cwd(), dst_host, self.io) catch |e| return r.setErr(fsErrno(e));
        if (self.by_path.get(src)) |id| self.dropNode(id);
    }

    fn opLink(self: *VirtioFs, oldnodeid_target: u64, body: []const u8, r: *Reply) void {
        _ = self;
        _ = oldnodeid_target;
        _ = body;
        // Hard links aren't portable across the host FS abstraction here; report
        // unsupported so callers fall back (very rare in container rootfses).
        r.setErr(ENOSYS);
    }

    fn opOpen(self: *VirtioFs, nodeid: u64, r: *Reply, is_dir: bool) void {
        _ = is_dir;
        _ = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        var o = r.payload();
        o.put64(0); // fh (stateless)
        o.put32(0); // open_flags (keep page cache)
        o.put32(0); // padding
        r.commit(o);
    }

    fn opRead(self: *VirtioFs, nodeid: u64, body: []const u8, r: *Reply) void {
        // fuse_read_in { u64 fh; u64 offset; u32 size; ... }
        const offset = rd64(body, 8);
        const nbytes = rd32(body, 16);
        const node = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        var file = std.Io.Dir.cwd().openFile(self.io, self.hostPath(node.path), .{}) catch return r.setErr(ENOENT);
        defer file.close(self.io);
        var o = r.payload();
        const want = @min(@as(usize, nbytes), o.remaining());
        // readPositionalAll returns a short count at EOF (no EndOfStream in its
        // error set), which is exactly the FUSE short-read semantics we want.
        const n = file.readPositionalAll(self.io, o.buf[o.pos .. o.pos + want], offset) catch return r.setErr(EIO);
        o.pos += n;
        r.commit(o);
    }

    fn opWrite(self: *VirtioFs, nodeid: u64, body: []const u8, r: *Reply) void {
        // fuse_write_in { u64 fh; u64 offset; u32 size; u32 write_flags; u64 lock_owner; u32 flags; u32 padding; } then data
        const offset = rd64(body, 8);
        const nbytes = rd32(body, 16);
        const data_off: usize = 40; // sizeof(fuse_write_in)
        if (data_off + nbytes > body.len) return r.setErr(EINVAL);
        const data = body[data_off .. data_off + nbytes];
        const node = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        var file = std.Io.Dir.cwd().openFile(self.io, self.hostPath(node.path), .{ .mode = .read_write }) catch return r.setErr(EACCES);
        defer file.close(self.io);
        file.writePositionalAll(self.io, data, offset) catch return r.setErr(EIO);
        var o = r.payload();
        o.put32(nbytes); // fuse_write_out.size
        o.put32(0); // padding
        r.commit(o);
    }

    fn opReaddir(self: *VirtioFs, nodeid: u64, body: []const u8, r: *Reply) void {
        // fuse_read_in { u64 fh; u64 offset; u32 size; ... }
        const offset = rd64(body, 8);
        const nbytes = rd32(body, 16);
        const node = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        var o = r.payload();
        const cap = @min(@as(usize, nbytes), o.remaining());

        var dir = self.openSubDir(node.path) catch return r.setErr(ENOENT);
        defer dir.close(self.io);
        var it = dir.iterate();
        var index: u64 = 0;
        // The FUSE readdir stream must include "." and ".." (the kernel does not
        // synthesize them). Emit them as the first two logical entries.
        const dots = [_][]const u8{ ".", ".." };
        for (dots) |dn| {
            if (index >= offset) {
                if (!putDirent(&o, cap, nodeid, index + 1, DT_DIR, dn)) {
                    r.commit(o);
                    return;
                }
            }
            index += 1;
        }
        while (it.next(self.io) catch null) |e| {
            if (index < offset) {
                index += 1;
                continue;
            }
            const dtype: u32 = switch (e.kind) {
                .directory => DT_DIR,
                .sym_link => DT_LNK,
                else => DT_REG,
            };
            if (!putDirent(&o, cap, index + 1, index + 1, dtype, e.name)) break;
            index += 1;
        }
        r.commit(o);
    }

    fn opStatfs(self: *VirtioFs, r: *Reply) void {
        _ = self;
        // fuse_statfs_out { fuse_kstatfs }
        var o = r.payload();
        o.put64(1 << 20); // blocks
        o.put64(1 << 19); // bfree
        o.put64(1 << 19); // bavail
        o.put64(1 << 16); // files
        o.put64(1 << 15); // ffree
        o.put32(4096); // bsize
        o.put32(255); // namelen
        o.put32(4096); // frsize
        o.put32(0); // padding
        var i: usize = 0;
        while (i < 6) : (i += 1) o.put32(0); // spare[6]
        r.commit(o);
    }

    fn opCreate(self: *VirtioFs, parent: u64, body: []const u8, r: *Reply) void {
        // fuse_create_in { u32 flags; u32 mode; u32 umask; u32 open_flags; } then name\0
        const name = cstr(body[16..]);
        const child = self.childPath(parent, name) catch return r.setErr(EIO);
        defer self.alloc.free(child);
        var f = std.Io.Dir.cwd().createFile(self.io, self.hostPath(child), .{ .truncate = true }) catch return r.setErr(EACCES);
        f.close(self.io);
        const st = self.statPath(child) catch return r.setErr(EIO);
        const id = self.intern(child, false) catch return r.setErr(EIO);
        var o = r.payload();
        self.putEntry(&o, id, st); // fuse_entry_out
        o.put64(0); // fuse_open_out.fh
        o.put32(0); // open_flags
        o.put32(0); // padding
        r.commit(o);
    }

    fn opGetlk(self: *VirtioFs, body: []const u8, r: *Reply) void {
        _ = self;
        _ = body;
        // Always report "no conflicting lock": fuse_lk_out { fuse_file_lock lk; }
        // with type = F_UNLCK (2).
        var o = r.payload();
        o.put64(0); // start
        o.put64(0); // end
        o.put32(2); // type = F_UNLCK
        o.put32(0); // pid
        r.commit(o);
    }

    fn opLseek(self: *VirtioFs, nodeid: u64, body: []const u8, r: *Reply) void {
        // fuse_lseek_in { u64 fh; u64 offset; u32 whence; u32 padding; }
        const offset = rd64(body, 8);
        const whence = rd32(body, 16);
        const node = self.nodes.get(nodeid) orelse return r.setErr(ENOENT);
        // Only SEEK_SET(0)/SEEK_CUR(1) are trivial; for SEEK_END(2) return size.
        var res = offset;
        if (whence == 2) {
            const st = self.statPath(node.path) catch return r.setErr(ENOENT);
            res = st.size;
        }
        var o = r.payload();
        o.put64(res); // fuse_lseek_out.offset
        r.commit(o);
    }

    // ---- inode table --------------------------------------------------------

    /// Return (creating if needed) the nodeid for a relative path, bumping its
    /// lookup refcount. FUSE requires a given inode map to one nodeid while it is
    /// referenced, so we dedup through `by_path`.
    fn intern(self: *VirtioFs, path: []const u8, is_dir: bool) !u64 {
        if (self.by_path.get(path)) |id| {
            if (self.nodes.getPtr(id)) |n| n.nlookup += 1;
            return id;
        }
        const id = self.next_nodeid;
        self.next_nodeid += 1;
        const owned = try self.alloc.dupe(u8, path);
        try self.nodes.put(id, .{ .path = owned, .nlookup = 1, .is_dir = is_dir });
        try self.by_path.put(owned, id);
        return id;
    }

    fn dropNode(self: *VirtioFs, id: u64) void {
        if (id == ROOT_NODEID) return;
        const e = self.nodes.getPtr(id) orelse return;
        _ = self.by_path.remove(e.path);
        const path = e.path;
        _ = self.nodes.remove(id);
        self.alloc.free(path);
    }

    fn childPath(self: *VirtioFs, parent: u64, name: []const u8) ![]u8 {
        const p = self.nodes.get(parent) orelse return error.NoNode;
        if (std.mem.eql(u8, name, ".")) return self.alloc.dupe(u8, p.path);
        if (std.mem.eql(u8, name, "..")) {
            const slash = std.mem.lastIndexOfScalar(u8, p.path, '/');
            return self.alloc.dupe(u8, if (slash) |s| p.path[0..s] else "");
        }
        if (p.path.len == 0) return self.alloc.dupe(u8, name);
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ p.path, name });
    }

    fn statPath(self: *VirtioFs, path: []const u8) !std.Io.Dir.Stat {
        return std.Io.Dir.cwd().statFile(self.io, self.hostPath(path), .{});
    }

    fn openSubDir(self: *VirtioFs, path: []const u8) !std.Io.Dir {
        return std.Io.Dir.cwd().openDir(self.io, self.hostPath(path), .{ .iterate = true });
    }

    // ---- FUSE struct writers ------------------------------------------------

    fn putAttr(self: *VirtioFs, o: *Payload, nodeid: u64, st: std.Io.Dir.Stat) void {
        _ = self;
        const is_dir = st.kind == .directory;
        const is_link = st.kind == .sym_link;
        const mode: u32 = blk: {
            if (is_dir) break :blk 0o040755;
            if (is_link) break :blk 0o120777;
            break :blk 0o100755;
        };
        o.put64(nodeid); // ino
        o.put64(st.size); // size
        o.put64((st.size + 511) / 512); // blocks
        o.put64(0); // atime
        o.put64(0); // mtime
        o.put64(0); // ctime
        o.put32(0); // atimensec
        o.put32(0); // mtimensec
        o.put32(0); // ctimensec
        o.put32(mode); // mode
        o.put32(if (is_dir) 2 else 1); // nlink
        o.put32(0); // uid
        o.put32(0); // gid
        o.put32(0); // rdev
        o.put32(4096); // blksize
        o.put32(0); // flags
    }

    fn putEntry(self: *VirtioFs, o: *Payload, nodeid: u64, st: std.Io.Dir.Stat) void {
        o.put64(nodeid); // nodeid
        o.put64(0); // generation
        o.put64(3600); // entry_valid
        o.put64(3600); // attr_valid
        o.put32(0); // entry_valid_nsec
        o.put32(0); // attr_valid_nsec
        self.putAttr(o, nodeid, st); // fuse_attr
    }
};

// ---- little-endian helpers --------------------------------------------------

fn rd32(b: []const u8, off: usize) u32 {
    if (off + 4 > b.len) return 0;
    return std.mem.readInt(u32, b[off .. off + 4][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    if (off + 8 > b.len) return 0;
    return std.mem.readInt(u64, b[off .. off + 8][0..8], .little);
}

/// Read a NUL-terminated string from the front of `b` (FUSE names are C strings).
fn cstr(b: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, b, 0) orelse b.len;
    return b[0..end];
}

fn setLo(p: *u64, v: u32) void {
    p.* = (p.* & 0xffff_ffff_0000_0000) | v;
}
fn setHi(p: *u64, v: u32) void {
    p.* = (p.* & 0xffff_ffff) | (@as(u64, v) << 32);
}

fn fsErrno(err: anyerror) i32 {
    return switch (err) {
        error.FileNotFound => ENOENT,
        error.AccessDenied, error.PermissionDenied => EACCES,
        error.PathAlreadyExists => EEXIST,
        error.IsDir => EISDIR,
        error.NotDir => ENOTDIR,
        error.DirNotEmpty => ENOTEMPTY,
        else => EIO,
    };
}

/// Append one fuse_dirent to a readdir stream, 8-byte aligned. Returns false when
/// it would overflow `cap` (the driver's requested size), signalling stop.
fn putDirent(o: *Payload, cap: usize, ino: u64, next_off: u64, dtype: u32, name: []const u8) bool {
    const rec = 24 + name.len; // sizeof(fuse_dirent) header (24) + name
    const padded = (rec + 7) & ~@as(usize, 7);
    if (o.pos + padded > cap) return false;
    if (o.pos + padded > o.buf.len) return false;
    o.put64(ino);
    o.put64(next_off);
    o.put32(@intCast(name.len));
    o.put32(dtype);
    o.putBytes(name);
    // pad to 8-byte boundary with zeros
    var i = rec;
    while (i < padded) : (i += 1) o.put8(0);
    return true;
}

/// A little-endian cursor over the reply payload region (i.e. everything after the
/// 16-byte fuse_out_header).
const Payload = struct {
    buf: []u8,
    pos: usize,

    fn remaining(self: *Payload) usize {
        return self.buf.len - self.pos;
    }
    fn put8(self: *Payload, v: u8) void {
        if (self.pos < self.buf.len) self.buf[self.pos] = v;
        self.pos += 1;
    }
    fn put16(self: *Payload, v: u16) void {
        if (self.pos + 2 <= self.buf.len) std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }
    fn put32(self: *Payload, v: u32) void {
        if (self.pos + 4 <= self.buf.len) std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    fn put64(self: *Payload, v: u64) void {
        if (self.pos + 8 <= self.buf.len) std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }
    fn putBytes(self: *Payload, b: []const u8) void {
        const n = @min(b.len, self.buf.len - @min(self.pos, self.buf.len));
        if (n > 0) @memcpy(self.buf[self.pos .. self.pos + n], b[0..n]);
        self.pos += b.len;
    }
};

/// Builds a FUSE reply: reserves the 16-byte fuse_out_header, lets the op fill a
/// payload, then back-patches len+error+unique.
const Reply = struct {
    buf: []u8,
    unique: u64,
    err: i32 = 0,
    len_override: ?usize = null,

    fn payload(self: *Reply) Payload {
        return .{ .buf = self.buf, .pos = 16 };
    }

    /// Adopt the payload cursor's end position as the reply length.
    fn commit(self: *Reply, o: Payload) void {
        self.len_override = o.pos;
    }

    fn setErr(self: *Reply, e: i32) void {
        self.err = e;
        self.len_override = 16; // header only
    }

    fn finish(self: *Reply) usize {
        const total: usize = if (self.err != 0) 16 else (self.len_override orelse 16);
        const clamped = @min(total, self.buf.len);
        std.mem.writeInt(u32, self.buf[0..4], @intCast(clamped), .little);
        std.mem.writeInt(i32, self.buf[4..8], if (self.err != 0) -self.err else 0, .little);
        std.mem.writeInt(u64, self.buf[8..16], self.unique, .little);
        return clamped;
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

/// Build a FUSE request into `buf`: fuse_in_header (40) + `payload`. Returns the
/// used slice.
fn mkReq(buf: []u8, opcode: u32, unique: u64, nodeid: u64, payload: []const u8) []const u8 {
    @memset(buf[0..40], 0);
    std.mem.writeInt(u32, buf[0..4], @intCast(40 + payload.len), .little); // len
    std.mem.writeInt(u32, buf[4..8], opcode, .little);
    std.mem.writeInt(u64, buf[8..16], unique, .little);
    std.mem.writeInt(u64, buf[16..24], nodeid, .little);
    @memcpy(buf[40 .. 40 + payload.len], payload);
    return buf[0 .. 40 + payload.len];
}

const TestFs = struct {
    tio: std.Io.Threaded,
    bus: Bus,
    irq: @import("gicv2.zig").IrqLine,
    gic: Gicv2,
    fs: VirtioFs,
    dir: []const u8,

    fn init(alloc: std.mem.Allocator, dir: []const u8) !*TestFs {
        const t = try alloc.create(TestFs);
        t.tio = std.Io.Threaded.init(alloc, .{});
        t.bus = try Bus.init(alloc, 0x4000_0000, 4096);
        t.irq = .{};
        t.gic = Gicv2.init(&t.irq);
        t.fs = try VirtioFs.init(0, 0, &t.bus, &t.gic, t.tio.io(), dir, "host", alloc);
        t.dir = dir;
        return t;
    }
    fn deinit(t: *TestFs, alloc: std.mem.Allocator) void {
        t.fs.deinit();
        t.bus.deinit();
        t.tio.deinit();
        alloc.destroy(t);
    }
};

test "virtio-fs: FUSE_INIT negotiates version and max_write" {
    const alloc = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    var tio0 = std.Io.Threaded.init(alloc, .{});
    defer tio0.deinit();
    const dir = "zig-vfs-init-tmp";
    cwd.deleteTree(tio0.io(), dir) catch {};
    try cwd.createDirPath(tio0.io(), dir);
    defer cwd.deleteTree(tio0.io(), dir) catch {};

    const t = try TestFs.init(alloc, dir);
    defer t.deinit(alloc);

    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    // fuse_init_in: major=7, minor=40, max_readahead=0x20000, flags=0
    var init_in: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, init_in[0..4], 7, .little);
    std.mem.writeInt(u32, init_in[4..8], 40, .little);
    std.mem.writeInt(u32, init_in[8..12], 0x20000, .little);
    const req = mkReq(&in, FUSE_INIT, 1, 0, &init_in);
    const n = t.fs.dispatch(req, &out);

    try testing.expect(n >= 16 + 24);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little)); // error==0
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, out[8..16], .little)); // unique
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[16..20], .little)); // major
    try testing.expectEqual(@as(u32, 31), std.mem.readInt(u32, out[20..24], .little)); // min(40,31)
    try testing.expectEqual(@as(u32, 128 * 1024), std.mem.readInt(u32, out[36..40], .little)); // max_write
}

test "virtio-fs: LOOKUP + READ round-trip a host file" {
    const alloc = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    var tio0 = std.Io.Threaded.init(alloc, .{});
    defer tio0.deinit();
    const dir = "zig-vfs-read-tmp";
    cwd.deleteTree(tio0.io(), dir) catch {};
    try cwd.createDirPath(tio0.io(), dir);
    defer cwd.deleteTree(tio0.io(), dir) catch {};
    const contents = "hello virtiofs";
    try cwd.writeFile(tio0.io(), .{ .sub_path = dir ++ "/hello.txt", .data = contents });

    const t = try TestFs.init(alloc, dir);
    defer t.deinit(alloc);

    var in: [256]u8 = undefined;
    var out: [4096]u8 = undefined;

    // LOOKUP "hello.txt" under root (nodeid 1).
    const name = "hello.txt\x00";
    const lreq = mkReq(&in, FUSE_LOOKUP, 2, ROOT_NODEID, name);
    _ = t.fs.dispatch(lreq, &out);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little));
    const nodeid = std.mem.readInt(u64, out[16..24], .little); // entry_out.nodeid
    try testing.expect(nodeid >= 2);
    // fuse_attr starts at payload+40 => out[56..]; size is the 2nd u64 (offset 8).
    const size = std.mem.readInt(u64, out[56 + 8 ..][0..8], .little);
    try testing.expectEqual(@as(u64, contents.len), size);

    // OPEN then READ.
    var open_in: [8]u8 = [_]u8{0} ** 8;
    const oreq = mkReq(&in, FUSE_OPEN, 3, nodeid, &open_in);
    _ = t.fs.dispatch(oreq, &out);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little));

    // fuse_read_in { u64 fh; u64 offset; u32 size; ... } = 40 bytes
    var read_in: [40]u8 = [_]u8{0} ** 40;
    std.mem.writeInt(u32, read_in[16..20], 100, .little); // size
    const rreq = mkReq(&in, FUSE_READ, 4, nodeid, &read_in);
    const rn = t.fs.dispatch(rreq, &out);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little));
    try testing.expectEqualStrings(contents, out[16..rn]);
}

test "virtio-fs: READDIR lists entries including . and .." {
    const alloc = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    var tio0 = std.Io.Threaded.init(alloc, .{});
    defer tio0.deinit();
    const dir = "zig-vfs-dir-tmp";
    cwd.deleteTree(tio0.io(), dir) catch {};
    try cwd.createDirPath(tio0.io(), dir);
    defer cwd.deleteTree(tio0.io(), dir) catch {};
    try cwd.writeFile(tio0.io(), .{ .sub_path = dir ++ "/a.txt", .data = "x" });

    const t = try TestFs.init(alloc, dir);
    defer t.deinit(alloc);

    var in: [256]u8 = undefined;
    var out: [4096]u8 = undefined;
    var read_in: [40]u8 = [_]u8{0} ** 40;
    std.mem.writeInt(u32, read_in[16..20], 4096, .little); // size
    const req = mkReq(&in, FUSE_READDIR, 5, ROOT_NODEID, &read_in);
    const n = t.fs.dispatch(req, &out);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little));
    // Walk the dirent stream collecting names.
    var found_dot = false;
    var found_dotdot = false;
    var found_a = false;
    var off: usize = 16;
    while (off + 24 <= n) {
        const namelen = std.mem.readInt(u32, out[off + 16 ..][0..4], .little);
        const nm = out[off + 24 .. off + 24 + namelen];
        if (std.mem.eql(u8, nm, ".")) found_dot = true;
        if (std.mem.eql(u8, nm, "..")) found_dotdot = true;
        if (std.mem.eql(u8, nm, "a.txt")) found_a = true;
        const rec = 24 + namelen;
        off += (rec + 7) & ~@as(usize, 7);
    }
    try testing.expect(found_dot and found_dotdot and found_a);
}

test "virtio-fs: CREATE + WRITE + READ back" {
    const alloc = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    var tio0 = std.Io.Threaded.init(alloc, .{});
    defer tio0.deinit();
    const dir = "zig-vfs-write-tmp";
    cwd.deleteTree(tio0.io(), dir) catch {};
    try cwd.createDirPath(tio0.io(), dir);
    defer cwd.deleteTree(tio0.io(), dir) catch {};

    const t = try TestFs.init(alloc, dir);
    defer t.deinit(alloc);

    var in: [256]u8 = undefined;
    var out: [4096]u8 = undefined;

    // CREATE "new.txt": fuse_create_in { u32 flags; u32 mode; u32 umask; u32 open_flags; } then name\0
    var cin: [16 + 8]u8 = [_]u8{0} ** 24;
    @memcpy(cin[16..], "new.txt\x00");
    const creq = mkReq(&in, FUSE_CREATE, 2, ROOT_NODEID, &cin);
    _ = t.fs.dispatch(creq, &out);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little));
    const nodeid = std.mem.readInt(u64, out[16..24], .little);

    // WRITE "data!" at offset 0.
    const payload = "data!";
    var win: [40 + 5]u8 = [_]u8{0} ** (40 + 5);
    std.mem.writeInt(u32, win[16..20], payload.len, .little); // size
    @memcpy(win[40..], payload);
    const wreq = mkReq(&in, FUSE_WRITE, 3, nodeid, &win);
    _ = t.fs.dispatch(wreq, &out);
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, out[4..8], .little));
    try testing.expectEqual(@as(u32, payload.len), std.mem.readInt(u32, out[16..20], .little));

    // READ back.
    var rin: [40]u8 = [_]u8{0} ** 40;
    std.mem.writeInt(u32, rin[16..20], 100, .little);
    const rreq = mkReq(&in, FUSE_READ, 4, nodeid, &rin);
    const rn = t.fs.dispatch(rreq, &out);
    try testing.expectEqualStrings(payload, out[16..rn]);
}

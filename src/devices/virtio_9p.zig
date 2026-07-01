//! virtio-9p device: shares a host directory into the guest over the 9P2000.L
//! protocol (mount with `-t 9p -o trans=virtio,version=9p2000.L <tag>`).
//! This is the M3 path: live host-directory access from inside the sandbox.
//!
//! The virtio-mmio transport mirrors virtio.zig (DeviceID 9). A request is a
//! descriptor chain: readable descriptors carry the T-message, writable
//! descriptors receive the R-message.

const std = @import("std");
const Bus = @import("../bus.zig").Bus;
const Gicv2 = @import("gicv2.zig").Gicv2;

// virtio-mmio register offsets (same layout as virtio.zig).
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

const VIRTIO_9P: u32 = 9;
const VIRTIO_9P_F_MOUNT_TAG: u64 = 1; // device offers a mount tag in config
const MOUNT_TAG = "host";

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

// 9P2000.L message types.
const Tlerror = 7;
const Tstatfs = 8;
const Tlopen = 12;
const Tlcreate = 14;
const Tsymlink = 16;
const Treadlink = 22;
const Tgetattr = 24;
const Tsetattr = 26;
const Trename = 20; // Rrename = 21
const Treaddir = 40;
const Tfsync = 50; // Rfsync = 51
const Tlock = 52; // Rlock = 53
const Tgetlock = 54; // Rgetlock = 55
const Tmkdir = 72;
const Trenameat = 74; // Rrenameat = 75
const Tunlinkat = 76; // Runlinkat = 77
const AT_REMOVEDIR: u32 = 0x200;

// 9P2000.L lock: F_* type values and Rlock status codes.
const P9_LOCK_TYPE_UNLCK: u8 = 2; // no (conflicting) lock
const P9_LOCK_SUCCESS: u8 = 0;
const Tversion = 100;
const Tattach = 104;
const Tflush = 108;
const Twalk = 110;
const Tread = 116;
const Twrite = 118;
const Tclunk = 120;

const QTFILE: u8 = 0x00;
const QTDIR: u8 = 0x80;

pub const Fid = struct {
    path: []u8, // relative to the share root ("" = root)
};

pub const Virtio9p = struct {
    pub const size: u64 = 0x200;

    irq_id: u32,
    bus: *Bus,
    gic: *Gicv2,
    io: std.Io,
    base: []const u8, // host share directory path (relative to cwd)
    alloc: std.mem.Allocator,
    fids: std.AutoHashMap(u32, Fid),
    pathbuf: [2048]u8 = undefined,

    status: u32 = 0,
    device_features_sel: u32 = 0,
    queue_num: u32 = 0,
    queue_ready: u32 = 0,
    desc_addr: u64 = 0,
    avail_addr: u64 = 0,
    used_addr: u64 = 0,
    last_avail: u16 = 0,
    used_idx: u16 = 0,
    int_status: u32 = 0,
    dbg: u32 = 0,
    msg: [16384]u8 = undefined, // scratch for one message

    mmio_base: u64 = 0,

    pub fn init(mmio_base: u64, irq_id: u32, bus: *Bus, gic: *Gicv2, io: std.Io, base_path: []const u8, alloc: std.mem.Allocator) Virtio9p {
        return .{
            .mmio_base = mmio_base,
            .irq_id = irq_id,
            .bus = bus,
            .gic = gic,
            .io = io,
            .base = base_path,
            .alloc = alloc,
            .fids = std.AutoHashMap(u32, Fid).init(alloc),
        };
    }

    /// Build the full host path (cwd-relative) for a fid's relative path.
    fn hostPath(self: *Virtio9p, rel: []const u8) []const u8 {
        if (rel.len == 0) return self.base;
        return std.fmt.bufPrint(&self.pathbuf, "{s}/{s}", .{ self.base, rel }) catch self.base;
    }

    pub fn read(self: *Virtio9p, off: u64, sz: u8) u64 {
        _ = sz;
        return switch (off) {
            MAGIC => 0x7472_6976,
            VERSION => 2,
            DEVICE_ID => VIRTIO_9P,
            VENDOR_ID => 0x554d_4551,
            DEVICE_FEATURES => if (self.device_features_sel == 1) 1 else VIRTIO_9P_F_MOUNT_TAG, // bit0 (low) = MOUNT_TAG; bit32 (high) = VERSION_1
            QUEUE_NUM_MAX => 128,
            QUEUE_READY => self.queue_ready,
            INTERRUPT_STATUS => self.int_status,
            STATUS => self.status,
            CONFIG => MOUNT_TAG.len, // tag length (u16)
            else => {
                // config tag string starts at CONFIG+2
                if (off >= CONFIG + 2 and off < CONFIG + 2 + MOUNT_TAG.len) {
                    return MOUNT_TAG[off - (CONFIG + 2)];
                }
                return 0;
            },
        };
    }

    pub fn write(self: *Virtio9p, off: u64, value: u64, sz: u8) void {
        _ = sz;
        const v: u32 = @truncate(value);
        switch (off) {
            DEVICE_FEATURES_SEL => self.device_features_sel = v,
            DRIVER_FEATURES_SEL, DRIVER_FEATURES, QUEUE_SEL => {},
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

    const Seg = struct { addr: u64, len: u32, writable: bool };

    fn processQueue(self: *Virtio9p) void {
        const avail_idx: u16 = @truncate(self.bus.read(self.avail_addr + 2, 2));
        while (self.last_avail != avail_idx) {
            const slot = self.last_avail % @as(u16, @truncate(self.queue_num));
            const head: u16 = @truncate(self.bus.read(self.avail_addr + 4 + @as(u64, slot) * 2, 2));
            self.handleChain(head);
            self.last_avail +%= 1;
        }
        self.int_status |= 1;
        self.gic.setIrq(self.irq_id, true);
    }

    fn handleChain(self: *Virtio9p, head: u16) void {
        // Collect the descriptor chain into readable (T-msg) and writable (R-msg) segments.
        var segs: [16]Seg = undefined;
        var nseg: usize = 0;
        var idx = head;
        while (nseg < segs.len) {
            const a = self.desc_addr + @as(u64, idx) * 16;
            const addr = self.bus.read(a, 8);
            const len: u32 = @truncate(self.bus.read(a + 8, 4));
            const flags: u16 = @truncate(self.bus.read(a + 12, 2));
            segs[nseg] = .{ .addr = addr, .len = len, .writable = (flags & VRING_DESC_F_WRITE) != 0 };
            nseg += 1;
            if ((flags & VRING_DESC_F_NEXT) == 0) break;
            idx = @truncate(self.bus.read(a + 14, 2));
        }

        // Gather the T-message from readable segments.
        var tlen: usize = 0;
        for (segs[0..nseg]) |s| {
            if (s.writable) continue;
            var i: u32 = 0;
            while (i < s.len and tlen < self.msg.len) : (i += 1) {
                self.msg[tlen] = @truncate(self.bus.read(s.addr + i, 1));
                tlen += 1;
            }
        }

        // Build the R-message into a separate buffer.
        var reply: [16384]u8 = undefined;
        const rlen = self.dispatch(self.msg[0..tlen], &reply);

        // Write the R-message across writable segments.
        var written: usize = 0;
        for (segs[0..nseg]) |s| {
            if (!s.writable) continue;
            var i: u32 = 0;
            while (i < s.len and written < rlen) : (i += 1) {
                self.bus.write(s.addr + i, reply[written], 1);
                written += 1;
            }
        }

        // Used ring.
        const ring_off = self.used_addr + 4 + @as(u64, self.used_idx % @as(u16, @truncate(self.queue_num))) * 8;
        self.bus.write(ring_off, head, 4);
        self.bus.write(ring_off + 4, @intCast(written), 4);
        self.used_idx +%= 1;
        self.bus.write(self.used_addr + 2, self.used_idx, 2);
    }

    // ---- 9P2000.L dispatch --------------------------------------------------

    pub fn dispatch(self: *Virtio9p, t: []const u8, reply: []u8) usize {
        if (t.len < 7) return 0;
        const ttype = t[4];
        const tag = rd16(t, 5);
        var w = Writer{ .buf = reply, .pos = 7 }; // leave room for size+type+tag

        const rtype: u8 = blk: {
            switch (ttype) {
                Tversion => {
                    // msize[4] version[s]
                    const msize = rd32(t, 7);
                    w.put32(@min(msize, 8192));
                    w.putStr("9P2000.L");
                    break :blk Tversion + 1;
                },
                Tattach => { // fid[4] afid[4] uname[s] aname[s] n_uname[4]
                    const fid = rd32(t, 7);
                    self.setFid(fid, "") catch break :blk self.lerror(&w, 12);
                    w.putQid(self.qidFor("") catch break :blk self.lerror(&w, 2));
                    break :blk Tattach + 1;
                },
                Tgetattr => { // fid[4] request_mask[8]
                    const fid = rd32(t, 7);
                    const f = self.fids.get(fid) orelse break :blk self.lerror(&w, 9);
                    const st = self.statPath(f.path) catch break :blk self.lerror(&w, 2);
                    self.putGetattr(&w, f.path, st);
                    break :blk Tgetattr + 1;
                },
                Twalk => break :blk self.doWalk(t, &w) catch self.lerror(&w, 2),
                Tlopen => { // fid[4] flags[4]
                    const fid = rd32(t, 7);
                    const f = self.fids.get(fid) orelse break :blk self.lerror(&w, 9);
                    const q = self.qidFor(f.path) catch break :blk self.lerror(&w, 2);
                    w.putQid(q);
                    w.put32(0); // iounit (0 = use msize)
                    break :blk Tlopen + 1;
                },
                Tlcreate => break :blk self.doLcreate(t, &w) catch self.lerror(&w, 13),
                Tsetattr => break :blk self.doSetattr(t, &w) catch self.lerror(&w, 5),
                Tmkdir => break :blk self.doMkdir(t, &w) catch self.lerror(&w, 13),
                Tsymlink => break :blk self.doSymlink(t, &w) catch self.lerror(&w, 13),
                Treadlink => break :blk self.doReadlink(t, &w) catch self.lerror(&w, 22),
                Treaddir => break :blk self.doReaddir(t, &w) catch self.lerror(&w, 2),
                Tread => break :blk self.doRead(t, &w) catch self.lerror(&w, 5),
                Twrite => break :blk self.doWrite(t, &w) catch self.lerror(&w, 5),
                Tclunk => {
                    const fid = rd32(t, 7);
                    if (self.fids.fetchRemove(fid)) |kv| self.alloc.free(kv.value.path);
                    break :blk Tclunk + 1;
                },
                Tstatfs => {
                    // type[4] bsize[4] blocks[8] bfree[8] bavail[8] files[8] ffree[8] fsid[8] namelen[4]
                    w.put32(0x01021994); // V9FS_MAGIC
                    w.put32(4096);
                    w.put64(1 << 20);
                    w.put64(1 << 19);
                    w.put64(1 << 19);
                    w.put64(1 << 16);
                    w.put64(1 << 15);
                    w.put64(0);
                    w.put32(255);
                    break :blk Tstatfs + 1;
                },
                Tfsync => break :blk self.doFsync(t, &w),
                Trename => break :blk self.doRename(t, &w) catch self.lerror(&w, 5),
                Trenameat => break :blk self.doRenameat(t, &w) catch self.lerror(&w, 5),
                Tunlinkat => break :blk self.doUnlinkat(t, &w) catch self.lerror(&w, 5),
                Tlock => break :blk self.doLock(t, &w),
                Tgetlock => break :blk self.doGetlock(t, &w),
                Tflush => break :blk Tflush + 1,
                else => break :blk self.lerror(&w, 95), // EOPNOTSUPP
            }
        };

        const total: u32 = @intCast(w.pos);
        // Fill header: size[4] type[1] tag[2]
        std.mem.writeInt(u32, reply[0..4], total, .little);
        reply[4] = rtype;
        std.mem.writeInt(u16, reply[5..7], tag, .little);
        return w.pos;
    }

    /// 9P2000.L fsync. Twrite already writes through to the host file, so there's no
    /// deferred guest buffer to flush — acknowledge success. Without this the fsync
    /// RPC fell through to EOPNOTSUPP and SQLite aborted with SQLITE_IOERR_FSYNC.
    ///   Tfsync: fid[4] datasync[4]  ->  Rfsync: (no body)
    fn doFsync(self: *Virtio9p, t: []const u8, w: *Writer) u8 {
        const fid = rd32(t, 7);
        _ = self.fids.get(fid) orelse return self.lerror(w, 9); // EBADF
        return Tfsync + 1; // Rfsync
    }

    /// 9P2000.L byte-range advisory lock (fcntl POSIX locks — used by e.g. SQLite).
    /// We grant every lock. contain maps one guest to one share, and the guest's
    /// v9fs client records each granted lock in its own VFS lock table
    /// (locks_lock_file_wait), so mutual exclusion *between guest processes* is
    /// enforced client-side. The server's only other role is cross-client
    /// coordination, which a single-guest share never needs. Without a handler the
    /// lock RPC fell through to EOPNOTSUPP and SQLite aborted with "disk I/O error".
    ///   Tlock: fid[4] type[1] flags[4] start[8] length[8] proc_id[4] client_id[s]
    ///   Rlock: status[1]
    fn doLock(self: *Virtio9p, t: []const u8, w: *Writer) u8 {
        const fid = rd32(t, 7);
        _ = self.fids.get(fid) orelse return self.lerror(w, 9); // EBADF
        w.put8(P9_LOCK_SUCCESS);
        return Tlock + 1; // Rlock
    }

    /// 9P2000.L test-lock (fcntl F_GETLK). We keep no server-side lock table, so we
    /// always report "no conflicting lock" (F_UNLCK), echoing back the queried
    /// range. SQLite relies on F_SETLK (granted above), not F_GETLK, for its locking.
    ///   Tgetlock: fid[4] type[1] start[8] length[8] proc_id[4] client_id[s]
    ///   Rgetlock: type[1] start[8] length[8] proc_id[4] client_id[s]
    fn doGetlock(self: *Virtio9p, t: []const u8, w: *Writer) u8 {
        const fid = rd32(t, 7);
        _ = self.fids.get(fid) orelse return self.lerror(w, 9); // EBADF
        const start = rd64(t, 12);
        const length = rd64(t, 20);
        const proc_id = rd32(t, 28);
        w.put8(P9_LOCK_TYPE_UNLCK); // available: no conflicting lock
        w.put64(start);
        w.put64(length);
        w.put32(proc_id);
        w.putStr(""); // client_id (no holder)
        return Tgetlock + 1; // Rgetlock
    }

    fn lerror(self: *Virtio9p, w: *Writer, errno: u32) u8 {
        _ = self;
        w.pos = 7;
        w.put32(errno);
        return Tlerror;
    }

    fn doWalk(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        const fid = rd32(t, 7);
        const newfid = rd32(t, 11);
        const nwname = rd16(t, 15);
        const base = self.fids.get(fid) orelse return self.lerror(w, 9);
        var path = try self.alloc.dupe(u8, base.path);
        defer self.alloc.free(path);
        var off: usize = 17;
        const nwqid_pos = w.pos;
        w.put16(0); // placeholder for nwqid
        var count: u16 = 0;
        var i: u16 = 0;
        while (i < nwname) : (i += 1) {
            const nlen = rd16(t, off);
            off += 2;
            const name = t[off .. off + nlen];
            off += nlen;
            const joined = try self.joinPath(path, name);
            self.alloc.free(path);
            path = joined;
            const q = self.qidFor(path) catch return self.lerror(w, 2);
            w.putQid(q);
            count += 1;
        }
        std.mem.writeInt(u16, w.buf[nwqid_pos .. nwqid_pos + 2][0..2], count, .little);
        try self.setFid(newfid, path);
        return Twalk + 1;
    }

    fn doLcreate(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        // fid[4] name[s] flags[4] mode[4] gid[4]; fid becomes the new file.
        const fid = rd32(t, 7);
        const nlen = rd16(t, 11);
        const name = t[13 .. 13 + nlen];
        const parent = self.fids.get(fid) orelse return self.lerror(w, 9);
        const child = try self.joinPath(parent.path, name);
        defer self.alloc.free(child);
        var f = std.Io.Dir.cwd().createFile(self.io, self.hostPath(child), .{ .truncate = true }) catch return self.lerror(w, 13);
        f.close(self.io);
        try self.setFid(fid, child); // fid now refers to the created file
        const q = self.qidFor(child) catch return self.lerror(w, 2);
        w.putQid(q);
        w.put32(0); // iounit
        return Tlcreate + 1;
    }

    fn doSetattr(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        // fid[4] valid[4] mode[4] uid[4] gid[4] size[8] atime…  We only honor SIZE
        // (truncate); mode/uid/gid/times are accepted as no-ops (over-permissive
        // for a sandbox). Without this, `echo > existing-file` (O_TRUNC) fails.
        const fid = rd32(t, 7);
        const valid = rd32(t, 11);
        const f = self.fids.get(fid) orelse return self.lerror(w, 9);
        const P9_SETATTR_SIZE: u32 = 0x08;
        if (valid & P9_SETATTR_SIZE != 0) {
            const new_size = rd64(t, 27);
            var file = std.Io.Dir.cwd().openFile(self.io, self.hostPath(f.path), .{ .mode = .read_write }) catch return self.lerror(w, 13);
            defer file.close(self.io);
            file.setLength(self.io, new_size) catch return self.lerror(w, 5);
        }
        return Tsetattr + 1;
    }

    fn doMkdir(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        // dfid[4] name[s] mode[4] gid[4] -> Rmkdir qid[13]
        const dfid = rd32(t, 7);
        const nlen = rd16(t, 11);
        const name = t[13 .. 13 + nlen];
        const parent = self.fids.get(dfid) orelse return self.lerror(w, 9);
        const child = try self.joinPath(parent.path, name);
        defer self.alloc.free(child);
        std.Io.Dir.cwd().createDirPath(self.io, self.hostPath(child)) catch return self.lerror(w, 17); // EEXIST
        const q = self.qidFor(child) catch return self.lerror(w, 2);
        w.putQid(q);
        return Tmkdir + 1;
    }

    /// 9P2000.L unlink a name under a directory fid (files or, with AT_REMOVEDIR,
    /// empty dirs). SQLite deletes its journal/temp files through this; without it
    /// the RPC returned EOPNOTSUPP and SQLite aborted with SQLITE_IOERR_DELETE.
    ///   Tunlinkat: dfid[4] name[s] flags[4]  ->  Runlinkat: (no body)
    fn doUnlinkat(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        const dfid = rd32(t, 7);
        const nlen = rd16(t, 11);
        const name = t[13 .. 13 + nlen];
        const flags = rd32(t, 13 + nlen);
        const parent = self.fids.get(dfid) orelse return self.lerror(w, 9);
        const child = try self.joinPath(parent.path, name);
        defer self.alloc.free(child);
        const host = self.hostPath(child);
        if (flags & AT_REMOVEDIR != 0)
            std.Io.Dir.cwd().deleteDir(self.io, host) catch |err| return self.lerror(w, fsErrno(err))
        else
            std.Io.Dir.cwd().deleteFile(self.io, host) catch |err| return self.lerror(w, fsErrno(err));
        return Tunlinkat + 1; // Runlinkat
    }

    /// 9P2000.L rename `fid` to `name` under directory `dfid`; the fid then refers to
    /// the moved file. (The Linux client prefers Trenameat, but supports both.)
    ///   Trename: fid[4] dfid[4] name[s]  ->  Rrename: (no body)
    fn doRename(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        const f = self.fids.getPtr(rd32(t, 7)) orelse return self.lerror(w, 9);
        const parent = self.fids.get(rd32(t, 11)) orelse return self.lerror(w, 9);
        const nlen = rd16(t, 15);
        const name = t[17 .. 17 + nlen];
        const dst_rel = try self.joinPath(parent.path, name);
        defer self.alloc.free(dst_rel);
        // hostPath reuses one scratch buffer, so snapshot the source before building
        // the destination.
        const src_host = try self.alloc.dupe(u8, self.hostPath(f.path));
        defer self.alloc.free(src_host);
        const dst_host = self.hostPath(dst_rel);
        std.Io.Dir.cwd().rename(src_host, std.Io.Dir.cwd(), dst_host, self.io) catch |err| return self.lerror(w, fsErrno(err));
        const newpath = try self.alloc.dupe(u8, dst_rel);
        self.alloc.free(f.path);
        f.path = newpath;
        return Trename + 1;
    }

    /// 9P2000.L rename oldname under olddirfid to newname under newdirfid.
    ///   Trenameat: olddirfid[4] oldname[s] newdirfid[4] newname[s]  ->  Rrenameat
    fn doRenameat(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        var off: usize = 7;
        const olddir = self.fids.get(rd32(t, off)) orelse return self.lerror(w, 9);
        off += 4;
        const onlen = rd16(t, off);
        off += 2;
        const oldname = t[off .. off + onlen];
        off += onlen;
        const newdir = self.fids.get(rd32(t, off)) orelse return self.lerror(w, 9);
        off += 4;
        const nnlen = rd16(t, off);
        off += 2;
        const newname = t[off .. off + nnlen];
        const src_rel = try self.joinPath(olddir.path, oldname);
        defer self.alloc.free(src_rel);
        const dst_rel = try self.joinPath(newdir.path, newname);
        defer self.alloc.free(dst_rel);
        const src_host = try self.alloc.dupe(u8, self.hostPath(src_rel));
        defer self.alloc.free(src_host);
        const dst_host = self.hostPath(dst_rel);
        std.Io.Dir.cwd().rename(src_host, std.Io.Dir.cwd(), dst_host, self.io) catch |err| return self.lerror(w, fsErrno(err));
        return Trenameat + 1;
    }

    fn doSymlink(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        // fid[4] name[s] symtgt[s] gid[4] -> Rsymlink qid[13]
        const fid = rd32(t, 7);
        const nlen = rd16(t, 11);
        const name = t[13 .. 13 + nlen];
        var off: usize = 13 + nlen;
        const tlen = rd16(t, off);
        off += 2;
        const target = t[off .. off + tlen];
        const parent = self.fids.get(fid) orelse return self.lerror(w, 9);
        const child = try self.joinPath(parent.path, name);
        defer self.alloc.free(child);
        std.Io.Dir.cwd().symLink(self.io, target, self.hostPath(child), .{}) catch return self.lerror(w, 13);
        w.putQid(.{ .qtype = 0x02, .version = 0, .path = std.hash.Wyhash.hash(0, child) }); // QTSYMLINK
        return Tsymlink + 1;
    }

    fn doReadlink(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        // fid[4] -> Rreadlink target[s]
        const fid = rd32(t, 7);
        const f = self.fids.get(fid) orelse return self.lerror(w, 9);
        var lbuf: [4096]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(self.io, self.hostPath(f.path), &lbuf) catch return self.lerror(w, 22); // EINVAL
        w.putStr(lbuf[0..n]);
        return Treadlink + 1;
    }

    fn doReaddir(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        const fid = rd32(t, 7);
        const offset = rd64(t, 11);
        const count = rd32(t, 19);
        const f = self.fids.get(fid) orelse return self.lerror(w, 9);
        const count_pos = w.pos;
        w.put32(0); // placeholder for data length
        var dir = self.openSubDir(f.path) catch return self.lerror(w, 2);
        defer dir.close(self.io);
        var it = dir.iterate();
        var entry_index: u64 = 0;
        var data_len: u32 = 0;
        // Synthesize "." and ".." then real entries; use index as the 9p offset.
        while (try it.next(self.io)) |e| {
            if (entry_index < offset) {
                entry_index += 1;
                continue;
            }
            const child = try self.joinPath(f.path, e.name);
            defer self.alloc.free(child);
            const q = self.qidFor(child) catch Qid{ .qtype = QTFILE, .version = 0, .path = 0 };
            // entry: qid[13] offset[8] type[1] name[s]
            const entry_size: u32 = 13 + 8 + 1 + 2 + @as(u32, @intCast(e.name.len));
            if (data_len + entry_size > count) break;
            w.putQid(q);
            w.put64(entry_index + 1); // next offset
            w.put8(if (q.qtype == QTDIR) 4 else 8); // d_type (DT_DIR/DT_REG)
            w.putStr(e.name);
            data_len += entry_size;
            entry_index += 1;
        }
        std.mem.writeInt(u32, w.buf[count_pos .. count_pos + 4][0..4], data_len, .little);
        return Treaddir + 1;
    }

    fn doRead(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        const fid = rd32(t, 7);
        const offset = rd64(t, 11);
        const count = rd32(t, 19);
        const f = self.fids.get(fid) orelse return self.lerror(w, 9);
        var file = std.Io.Dir.cwd().openFile(self.io, self.hostPath(f.path), .{}) catch return self.lerror(w, 2);
        defer file.close(self.io);
        const want = @min(count, 8000);
        const count_pos = w.pos;
        w.put32(0); // placeholder
        const n = file.readPositionalAll(self.io, w.buf[w.pos .. w.pos + want], offset) catch return self.lerror(w, 5);
        w.pos += n;
        std.mem.writeInt(u32, w.buf[count_pos .. count_pos + 4][0..4], @intCast(n), .little);
        return Tread + 1;
    }

    fn doWrite(self: *Virtio9p, t: []const u8, w: *Writer) !u8 {
        const fid = rd32(t, 7);
        const offset = rd64(t, 11);
        const count = rd32(t, 19);
        const data = t[23 .. 23 + count];
        const f = self.fids.get(fid) orelse return self.lerror(w, 9);
        var file = std.Io.Dir.cwd().openFile(self.io, self.hostPath(f.path), .{ .mode = .read_write }) catch return self.lerror(w, 13);
        defer file.close(self.io);
        file.writePositionalAll(self.io, data, offset) catch return self.lerror(w, 5);
        w.put32(count);
        return Twrite + 1;
    }

    // ---- host filesystem helpers -------------------------------------------

    /// Map a host filesystem error to the Linux errno the 9p client expects.
    fn fsErrno(err: anyerror) u32 {
        return switch (err) {
            error.FileNotFound => 2, // ENOENT
            error.AccessDenied, error.PermissionDenied => 13, // EACCES
            error.PathAlreadyExists => 17, // EEXIST
            error.IsDir => 21, // EISDIR
            error.NotDir => 20, // ENOTDIR
            error.DirNotEmpty => 39, // ENOTEMPTY
            else => 5, // EIO
        };
    }

    fn setFid(self: *Virtio9p, fid: u32, path: []const u8) !void {
        if (self.fids.fetchRemove(fid)) |kv| self.alloc.free(kv.value.path);
        try self.fids.put(fid, .{ .path = try self.alloc.dupe(u8, path) });
    }

    fn joinPath(self: *Virtio9p, base: []const u8, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, ".")) return self.alloc.dupe(u8, base);
        if (std.mem.eql(u8, name, "..")) {
            const slash = std.mem.lastIndexOfScalar(u8, base, '/');
            return self.alloc.dupe(u8, if (slash) |s| base[0..s] else "");
        }
        if (base.len == 0) return self.alloc.dupe(u8, name);
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ base, name });
    }

    const Qid = struct { qtype: u8, version: u32, path: u64 };

    fn statPath(self: *Virtio9p, path: []const u8) !std.Io.Dir.Stat {
        return std.Io.Dir.cwd().statFile(self.io, self.hostPath(path), .{});
    }

    fn qidFor(self: *Virtio9p, path: []const u8) !Qid {
        const st = try self.statPath(path);
        const is_dir = st.kind == .directory;
        return .{
            .qtype = if (is_dir) QTDIR else QTFILE,
            .version = 0,
            .path = std.hash.Wyhash.hash(0, path),
        };
    }

    fn openSubDir(self: *Virtio9p, path: []const u8) !std.Io.Dir {
        return std.Io.Dir.cwd().openDir(self.io, self.hostPath(path), .{ .iterate = true });
    }

    fn putGetattr(self: *Virtio9p, w: *Writer, path: []const u8, st: std.Io.Dir.Stat) void {
        const q = self.qidFor(path) catch Qid{ .qtype = QTFILE, .version = 0, .path = 0 };
        const is_dir = st.kind == .directory;
        const mode: u32 = (if (is_dir) @as(u32, 0o040000) else 0o100000) | 0o755;
        w.put64(0x000007ff); // valid mask (basic fields)
        w.putQid(q);
        w.put32(mode);
        w.put32(0); // uid
        w.put32(0); // gid
        w.put64(if (is_dir) 2 else 1); // nlink
        w.put64(0); // rdev
        w.put64(st.size);
        w.put64(4096); // blksize
        w.put64((st.size + 511) / 512); // blocks
        // atime/mtime/ctime (sec+nsec each), btime (sec+nsec), gen, data_version
        var k: u32 = 0;
        while (k < 10) : (k += 1) w.put64(0);
    }
};

// Little-endian readers over the T-message buffer.
fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off .. off + 2][0..2], .little);
}
fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off .. off + 4][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off .. off + 8][0..8], .little);
}

const Writer = struct {
    buf: []u8,
    pos: usize,

    fn put8(self: *Writer, v: u8) void {
        self.buf[self.pos] = v;
        self.pos += 1;
    }
    fn put16(self: *Writer, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos .. self.pos + 2][0..2], v, .little);
        self.pos += 2;
    }
    fn put32(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos .. self.pos + 4][0..4], v, .little);
        self.pos += 4;
    }
    fn put64(self: *Writer, v: u64) void {
        std.mem.writeInt(u64, self.buf[self.pos .. self.pos + 8][0..8], v, .little);
        self.pos += 8;
    }
    fn putStr(self: *Writer, s: []const u8) void {
        self.put16(@intCast(s.len));
        @memcpy(self.buf[self.pos .. self.pos + s.len], s);
        self.pos += s.len;
    }
    fn putQid(self: *Writer, q: Virtio9p.Qid) void {
        self.put8(q.qtype);
        self.put32(q.version);
        self.put64(q.path);
    }
};

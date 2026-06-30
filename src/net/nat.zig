//! A tiny slirp-style userspace NAT/TCP-IP stack. The guest talks Ethernet over
//! virtio-net to a virtual gateway; this module answers ARP/ICMP/DHCP itself and
//! relays the guest's TCP/UDP flows to the real host network via host sockets.
//! The only host attack surface is these outbound sockets.
//!
//! Host sockets are read on background threads doing plain blocking receives
//! (the single-threaded Io can't do timeouts); they push received bytes into a
//! mutex-protected queue that `pump()` drains on the emulator thread and turns
//! into frames for the guest. All TCP/IP state lives on the emulator thread.
//!
//! Addressing (matches QEMU user-mode networking):
//!   guest 10.0.2.15/24, gateway 10.0.2.2, dns 10.0.2.3 -> upstream resolver.

const std = @import("std");
const net = std.Io.net;

pub const upstream_dns = [4]u8{ 1, 1, 1, 1 };
pub const guest_ip = [4]u8{ 10, 0, 2, 15 };
pub const gateway_ip = [4]u8{ 10, 0, 2, 2 };
pub const dns_ip = [4]u8{ 10, 0, 2, 3 };
pub const netmask = [4]u8{ 255, 255, 255, 0 };
pub const gw_mac = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 };

const eth_hdr_len = 14;
// Max TCP payload per segment so the Ethernet frame stays under the guest's
// 1500-byte MTU (14 eth + 20 ip + 20 tcp = 54 bytes of headers).
const tcp_mss = 1400;

// Retransmission timeout bounds (a single timer per connection, keyed on the
// oldest unacked segment). Base ~200 ms, exponential backoff capped at ~2 s.
const base_rto_ns: i128 = 200 * std.time.ns_per_ms;
const max_rto_ns: i128 = 2 * std.time.ns_per_s;

/// Send-side TCP control block (host -> guest direction). Gives the NAT proper
/// flow control + retransmission so it never overruns the guest's receive window
/// and recovers lost segments. Shared by outbound flows (`TcpConn`) and
/// host->guest port forwards (`InConn`).
///
/// `sndbuf` holds host bytes not yet acknowledged by the guest. Bytes live in
/// `sndbuf.items[snd_head..]`; `sndbuf.items[snd_head]` is the byte at seq
/// `snd_una`. `snd_head` advances on ACK and the buffer is compacted lazily so
/// front-drops stay amortized O(1).
pub const Tcb = struct {
    snd_una: u32 = 0, // oldest unacknowledged seq
    snd_nxt: u32 = 0, // next seq to send
    snd_wnd: u32 = 0xffff, // guest's advertised receive window (already scaled)
    wscale: u6 = 0, // guest's window-scale shift (from its SYN)
    sndbuf: std.ArrayListUnmanaged(u8) = .empty,
    snd_head: usize = 0, // offset within sndbuf of the byte at snd_una
    rtx_deadline: i128 = 0,
    rtx_pending: bool = false,
    rto_ns: i128 = base_rto_ns,
    dup_acks: u8 = 0,
    fin_pending: bool = false, // host closed; send FIN after all data
    fin_sent: bool = false,
};

/// Walk TCP options (the bytes between the fixed 20-byte header and the data
/// offset) for the window-scale option (kind 3); return its shift (capped at 14
/// per RFC 7323), or 0 if absent.
pub fn parseWscale(opts: []const u8) u6 {
    var i: usize = 0;
    while (i < opts.len) {
        const kind = opts[i];
        if (kind == 0) break; // end of option list
        if (kind == 1) { // NOP
            i += 1;
            continue;
        }
        if (i + 1 >= opts.len) break;
        const len = opts[i + 1];
        if (len < 2 or i + len > opts.len) break;
        if (kind == 3 and len == 3) return @intCast(@min(opts[i + 2], 14));
        i += len;
    }
    return 0;
}

fn be16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}
fn wbe16(b: []u8, v: u16) void {
    std.mem.writeInt(u16, b[0..2], v, .big);
}

/// Internet checksum (RFC 1071).
pub fn checksum(data: []const u8, start: u32) u32 {
    var sum: u32 = start;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += (@as(u32, data[i]) << 8) | data[i + 1];
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    return sum;
}
pub fn csumFinish(sum_in: u32) u16 {
    var sum = sum_in;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

const Frame = struct {
    data: [1600]u8 = undefined,
    len: usize = 0,
};

const UdpSess = struct {
    id: u32,
    sport: u16,
    dst: [4]u8,
    gdst: [4]u8,
    dport: u16,
    sock: net.Socket,
    thread: ?std.Thread = null,
};

const TcpState = enum { established, closed };

const TcpConn = struct {
    id: u32,
    sport: u16,
    dst: [4]u8,
    dport: u16,
    stream: net.Stream,
    state: TcpState,
    recv_next: u32, // next seq we expect from the guest (guest->host direction)
    tcb: Tcb = .{}, // host->guest send state (flow control + retransmission)
    thread: ?std.Thread = null,
};

/// An event pushed by a reader thread for the emulator thread to process.
const Inbound = struct {
    id: u32,
    kind: enum { udp, tcp, tcp_eof },
    data: []u8,
};

// ---- host -> guest port forwarding (like QEMU `hostfwd`) ----
// A host TCP port is published; each accepted host connection is bridged into
// the guest as a fresh TCP flow to guest_ip:gport, with the NAT acting as the
// client (source gateway_ip:ephemeral). This lets an app the guest serves on a
// port be reached from the host.

const Listener = struct {
    gport: u16,
    server: net.Server,
    thread: ?std.Thread = null,
};

/// A freshly accepted host connection waiting for the emulator thread to start
/// the guest-side handshake.
const AcceptEv = struct {
    gport: u16,
    stream: net.Stream,
};

const InState = enum { syn_sent, established, closed };

/// A host->guest bridged TCP connection (guest is the server).
const InConn = struct {
    id: u32,
    gport: u16, // guest's listening port
    ephem: u16, // our source port toward the guest
    stream: net.Stream, // host-side accepted connection
    state: InState,
    recv_next: u32, // next seq we expect from the guest
    tcb: Tcb = .{}, // host->guest send state (flow control + retransmission)
    thread: ?std.Thread = null,
};

const ReaderCtx = struct {
    nat: *Nat,
    sock: net.Socket,
    id: u32,
    is_tcp: bool,
};

pub const Nat = struct {
    alloc: std.mem.Allocator,
    io: std.Io = undefined,
    guest_mac: [6]u8,
    have_guest_mac: bool = false,
    rx: std.ArrayListUnmanaged(Frame) = .empty,
    udp: std.ArrayListUnmanaged(UdpSess) = .empty,
    tcp: std.ArrayListUnmanaged(TcpConn) = .empty,
    inbound: std.ArrayListUnmanaged(Inbound) = .empty,
    lock_flag: std.atomic.Value(bool) = .{ .raw = false },
    isn: u32 = 0x4000_0000,
    next_id: u32 = 1,
    // Wall-clock (ns) cached once per pump(); RTO deadlines compare against it so
    // the hot ACK path never touches the clock and tests can set it directly.
    now_ns: i128 = 0,
    // host -> guest port forwarding
    inconns: std.ArrayListUnmanaged(InConn) = .empty,
    listeners: std.ArrayListUnmanaged(*Listener) = .empty,
    accepts: std.ArrayListUnmanaged(AcceptEv) = .empty,
    ephem_next: u16 = 40000,

    pub fn init(alloc: std.mem.Allocator, guest_mac: [6]u8) Nat {
        return .{ .alloc = alloc, .guest_mac = guest_mac, .have_guest_mac = true };
    }

    /// Publish host TCP `host_port` and bridge each connection to the guest's
    /// `guest_port`. Must be called after `io` is set and before the guest runs.
    /// Returns an error if the host port can't be bound.
    pub fn addHostForward(self: *Nat, host_port: u16, guest_port: u16) !void {
        const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = host_port } };
        const server = try addr.listen(self.io, .{ .mode = .stream });
        const lst = try self.alloc.create(Listener);
        lst.* = .{ .gport = guest_port, .server = server };
        try self.listeners.append(self.alloc, lst);
        lst.thread = std.Thread.spawn(.{}, acceptThread, .{ self, lst }) catch null;
    }

    /// Background thread: accept host connections and hand them to the emulator
    /// thread (via `accepts`) to start the guest-side handshake.
    fn acceptThread(self: *Nat, lst: *Listener) void {
        while (true) {
            const stream = lst.server.accept(self.io) catch break;
            self.lock();
            self.accepts.append(self.alloc, .{ .gport = lst.gport, .stream = stream }) catch {
                self.unlock();
                stream.close(self.io);
                continue;
            };
            self.unlock();
        }
    }

    /// Begin a host->guest bridged connection: pick an ephemeral source port and
    /// send a SYN to guest_ip:gport. Runs on the emulator thread (from pump()).
    fn startInbound(self: *Nat, gport: u16, stream: net.Stream) void {
        const ephem = self.ephem_next;
        self.ephem_next +%= 1;
        if (self.ephem_next < 40000) self.ephem_next = 40000;
        const id = self.next_id;
        self.next_id += 1;
        const iseq = self.isn;
        self.isn +%= 0x1000;
        self.inconns.append(self.alloc, .{
            .id = id,
            .gport = gport,
            .ephem = ephem,
            .stream = stream,
            .state = .syn_sent,
            .recv_next = 0,
            .tcb = .{ .snd_una = iseq, .snd_nxt = iseq },
        }) catch {
            stream.close(self.io);
            return;
        };
        // SYN: src=gateway:ephem -> dst=guest:gport.
        self.sendTcp(gateway_ip, ephem, gport, iseq, 0, 0x02, &.{});
    }

    fn findInConn(self: *Nat, gport: u16, ephem: u16) ?*InConn {
        for (self.inconns.items) |*c| if (c.gport == gport and c.ephem == ephem) return c;
        return null;
    }
    fn findInConnById(self: *Nat, id: u32) ?*InConn {
        for (self.inconns.items) |*c| if (c.id == id) return c;
        return null;
    }
    fn closeInbound(self: *Nat, id: u32) void {
        for (self.inconns.items, 0..) |*c, i| {
            if (c.id == id) {
                c.stream.close(self.io); // wakes its reader thread
                if (c.thread) |t| t.detach();
                c.tcb.sndbuf.deinit(self.alloc);
                _ = self.inconns.swapRemove(i);
                return;
            }
        }
    }

    /// Handle a guest TCP frame addressed to the gateway (i.e. belonging to a
    /// host->guest bridged connection where the guest is the server).
    fn handleInboundTcp(self: *Nat, gport: u16, ephem: u16, seq: u32, ack: u32, win: u16, flags: u8, opts: []const u8, payload: []const u8) void {
        const FIN = 0x01;
        const SYN = 0x02;
        const RST = 0x04;
        const ACK = 0x10;
        const c = self.findInConn(gport, ephem) orelse return;
        if (flags & RST != 0) {
            self.closeInbound(c.id);
            return;
        }
        if (c.state == .syn_sent) {
            if ((flags & SYN) != 0 and (flags & ACK) != 0) {
                c.recv_next = seq +% 1; // guest ISN + 1
                c.tcb.snd_una +%= 1; // our SYN consumed one seq
                c.tcb.snd_nxt = c.tcb.snd_una;
                c.tcb.wscale = parseWscale(opts);
                c.tcb.snd_wnd = win; // SYN window is unscaled
                c.state = .established;
                self.sendTcp(gateway_ip, c.ephem, c.gport, c.tcb.snd_nxt, c.recv_next, ACK, &.{});
                // Now start pulling host->guest bytes.
                c.thread = self.spawnReader(c.stream.socket, c.id, true);
            }
            return;
        }
        // Guest -> host data (forward in-order bytes to the host socket).
        if (payload.len > 0 and seq == c.recv_next) {
            _ = self.io.vtable.netWrite(self.io.userdata, c.stream.socket.handle, &.{}, &.{payload}, 1) catch {};
            c.recv_next +%= @intCast(payload.len);
        }
        // Process the guest's ACK + window; sends any newly-in-window data.
        self.tcpAck(&c.tcb, ack, win, payload.len, gateway_ip, c.ephem, c.gport, c.recv_next);
        if (payload.len > 0) self.sendTcp(gateway_ip, c.ephem, c.gport, c.tcb.snd_nxt, c.recv_next, ACK, &.{});
        if (flags & FIN != 0) {
            c.recv_next +%= 1;
            self.sendTcp(gateway_ip, c.ephem, c.gport, c.tcb.snd_nxt, c.recv_next, FIN | ACK, &.{});
            self.closeInbound(c.id);
        }
    }

    fn lock(self: *Nat) void {
        while (self.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Nat) void {
        self.lock_flag.store(false, .release);
    }

    pub fn deinit(self: *Nat) void {
        // Close sockets so blocked reader/accept threads return, then join them.
        for (self.listeners.items) |l| l.server.deinit(self.io);
        for (self.udp.items) |*u| u.sock.close(self.io);
        for (self.tcp.items) |*c| c.stream.close(self.io);
        for (self.inconns.items) |*c| c.stream.close(self.io);
        for (self.listeners.items) |l| if (l.thread) |t| t.join();
        for (self.udp.items) |*u| if (u.thread) |t| t.join();
        for (self.tcp.items) |*c| if (c.thread) |t| t.join();
        for (self.inconns.items) |*c| if (c.thread) |t| t.join();
        for (self.accepts.items) |*a| a.stream.close(self.io);
        for (self.inbound.items) |it| if (it.data.len > 0) self.alloc.free(it.data);
        for (self.tcp.items) |*c| c.tcb.sndbuf.deinit(self.alloc);
        for (self.inconns.items) |*c| c.tcb.sndbuf.deinit(self.alloc);
        for (self.listeners.items) |l| self.alloc.destroy(l);
        self.inbound.deinit(self.alloc);
        self.udp.deinit(self.alloc);
        self.tcp.deinit(self.alloc);
        self.inconns.deinit(self.alloc);
        self.listeners.deinit(self.alloc);
        self.accepts.deinit(self.alloc);
        self.rx.deinit(self.alloc);
    }

    fn enqueue(self: *Nat, frame: []const u8) void {
        var f = Frame{};
        if (frame.len > f.data.len) return;
        @memcpy(f.data[0..frame.len], frame);
        f.len = frame.len;
        self.rx.append(self.alloc, f) catch {};
    }

    pub fn poll(self: *Nat, out: []u8) ?usize {
        if (self.rx.items.len == 0) return null;
        const f = self.rx.orderedRemove(0);
        const n = @min(f.len, out.len);
        @memcpy(out[0..n], f.data[0..n]);
        return n;
    }

    // ---- reader threads ----
    fn readerThread(ctx: *ReaderCtx) void {
        const self = ctx.nat;
        var buf: [2048]u8 = undefined;
        while (true) {
            // Stream sockets need netRead (recv); datagram sockets use receive (recvfrom).
            const n = if (ctx.is_tcp) blk: {
                var iov = [1][]u8{&buf};
                break :blk self.io.vtable.netRead(self.io.userdata, ctx.sock.handle, &iov) catch break;
            } else blk: {
                const msg = ctx.sock.receive(self.io, &buf) catch break;
                break :blk msg.data.len;
            };
            if (n == 0) break; // EOF
            const copy = self.alloc.dupe(u8, buf[0..n]) catch break;
            self.lock();
            self.inbound.append(self.alloc, .{
                .id = ctx.id,
                .kind = if (ctx.is_tcp) .tcp else .udp,
                .data = copy,
            }) catch self.alloc.free(copy);
            self.unlock();
        }
        if (ctx.is_tcp) {
            self.lock();
            self.inbound.append(self.alloc, .{ .id = ctx.id, .kind = .tcp_eof, .data = &.{} }) catch {};
            self.unlock();
        }
        self.alloc.destroy(ctx);
    }

    fn spawnReader(self: *Nat, sock: net.Socket, id: u32, is_tcp: bool) ?std.Thread {
        const ctx = self.alloc.create(ReaderCtx) catch return null;
        ctx.* = .{ .nat = self, .sock = sock, .id = id, .is_tcp = is_tcp };
        return std.Thread.spawn(.{}, readerThread, .{ctx}) catch {
            self.alloc.destroy(ctx);
            return null;
        };
    }

    /// Drain reader-thread events and turn received bytes into guest frames.
    pub fn pump(self: *Nat) void {
        self.now_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;

        // Start the guest-side handshake for any newly accepted host connections.
        self.lock();
        const acc = self.accepts.toOwnedSlice(self.alloc) catch &[_]AcceptEv{};
        self.unlock();
        for (acc) |a| self.startInbound(a.gport, a.stream);
        if (acc.len > 0) self.alloc.free(acc);

        // Retransmit any segments the guest hasn't acked within the RTO.
        self.rtxCheck();

        self.lock();
        const items = self.inbound.toOwnedSlice(self.alloc) catch {
            self.unlock();
            return;
        };
        self.unlock();
        defer self.alloc.free(items);
        for (items) |item| {
            switch (item.kind) {
                .udp => if (self.findUdpById(item.id)) |u| self.sendUdp(u.gdst, u.dport, u.sport, item.data),
                .tcp => if (self.findTcpById(item.id)) |c| {
                    // Buffer the host bytes and send what fits the guest window;
                    // tcpOutput splits into <=MSS segments for the guest MTU.
                    c.tcb.sndbuf.appendSlice(self.alloc, item.data) catch {};
                    self.tcpOutput(&c.tcb, c.dst, c.dport, c.sport, c.recv_next);
                } else if (self.findInConnById(item.id)) |c| {
                    // host -> guest bytes on a bridged (inbound) connection.
                    c.tcb.sndbuf.appendSlice(self.alloc, item.data) catch {};
                    self.tcpOutput(&c.tcb, gateway_ip, c.ephem, c.gport, c.recv_next);
                },
                .tcp_eof => if (self.findTcpById(item.id)) |c| {
                    // Defer the FIN until all buffered data has been sent + acked.
                    c.tcb.fin_pending = true;
                    self.tcpOutput(&c.tcb, c.dst, c.dport, c.sport, c.recv_next);
                } else if (self.findInConnById(item.id)) |c| {
                    c.tcb.fin_pending = true;
                    self.tcpOutput(&c.tcb, gateway_ip, c.ephem, c.gport, c.recv_next);
                },
            }
            if (item.data.len > 0) self.alloc.free(item.data);
        }
    }

    /// Send as much of `t.sndbuf` as the guest's window allows, in <=MSS PSH|ACK
    /// segments from src:sport -> guest:dport (ack = our recv_next). Never sends
    /// past `snd_una + snd_wnd`. Arms the RTO when data goes in flight. Emits a
    /// deferred FIN once all buffered data has been sent.
    pub fn tcpOutput(self: *Nat, t: *Tcb, src: [4]u8, sport: u16, dport: u16, ack: u32) void {
        const live = t.sndbuf.items[t.snd_head..];
        while (true) {
            const inflight = t.snd_nxt -% t.snd_una; // bytes sent, not yet acked
            if (inflight >= t.snd_wnd) break; // window full
            const unsent_off: usize = inflight; // offset of snd_nxt within `live`
            if (unsent_off >= live.len) break; // nothing left to send
            const room: usize = t.snd_wnd - inflight;
            const avail = live.len - unsent_off;
            const n = @min(@min(room, avail), tcp_mss);
            if (n == 0) break;
            self.sendTcp(src, sport, dport, t.snd_nxt, ack, 0x18, live[unsent_off .. unsent_off + n]); // PSH|ACK
            t.snd_nxt +%= @intCast(n);
            self.armRtx(t);
        }
        // Send the FIN only after every data byte has been put on the wire.
        if (t.fin_pending and !t.fin_sent and (t.snd_nxt -% t.snd_una) >= live.len) {
            self.sendTcp(src, sport, dport, t.snd_nxt, ack, 0x11, &.{}); // FIN|ACK
            t.snd_nxt +%= 1;
            t.fin_sent = true;
            self.armRtx(t);
        }
    }

    fn armRtx(self: *Nat, t: *Tcb) void {
        if (!t.rtx_pending) {
            t.rtx_pending = true;
            t.rtx_deadline = self.now_ns + t.rto_ns;
        }
    }

    /// Apply a guest ACK + window update to the send state: free acknowledged
    /// bytes, update the window, handle duplicate-ACK fast retransmit, then send
    /// any newly-in-window data. `payload_len` distinguishes pure ACKs from data
    /// segments (only pure ACKs count toward dup-ack detection).
    pub fn tcpAck(self: *Nat, t: *Tcb, ack: u32, raw_win: u16, payload_len: usize, src: [4]u8, sport: u16, dport: u16, ack_to_guest: u32) void {
        t.snd_wnd = @as(u32, raw_win) << @as(u5, @intCast(t.wscale)); // wscale capped at 14
        const acked = ack -% t.snd_una; // new bytes acked (wrapping)
        const outstanding = t.snd_nxt -% t.snd_una;
        if (acked != 0 and acked <= outstanding) {
            t.snd_head += @as(usize, acked);
            t.snd_una = ack;
            t.dup_acks = 0;
            // Drop acked bytes from the front of sndbuf (compact lazily). The
            // FIN's phantom seq can push snd_head past the data length.
            if (t.snd_head >= t.sndbuf.items.len) {
                t.sndbuf.clearRetainingCapacity();
                t.snd_head = 0;
            } else if (t.snd_head > 65536 and t.snd_head * 2 >= t.sndbuf.items.len) {
                const rem = t.sndbuf.items.len - t.snd_head;
                std.mem.copyForwards(u8, t.sndbuf.items[0..rem], t.sndbuf.items[t.snd_head..]);
                t.sndbuf.items.len = rem;
                t.snd_head = 0;
            }
            t.rto_ns = base_rto_ns; // forward progress resets the backoff
            t.rtx_pending = false; // re-armed by tcpOutput if data remains
            self.tcpOutput(t, src, sport, dport, ack_to_guest);
        } else if (acked == 0 and payload_len == 0 and outstanding != 0) {
            // Pure duplicate ACK: fast-retransmit from snd_una on the 3rd.
            if (t.dup_acks < 255) t.dup_acks += 1;
            if (t.dup_acks == 3) {
                t.snd_nxt = t.snd_una;
                t.rtx_pending = false;
            }
            self.tcpOutput(t, src, sport, dport, ack_to_guest);
        } else {
            // Window-only update (or stale ACK): try to send newly-in-window data.
            self.tcpOutput(t, src, sport, dport, ack_to_guest);
        }
    }

    /// Retransmit the oldest unacked segment of any connection whose RTO expired.
    /// Rewinds snd_nxt to snd_una and backs the RTO off exponentially.
    pub fn rtxCheck(self: *Nat) void {
        for (self.tcp.items) |*c| self.rtxOne(&c.tcb, c.dst, c.dport, c.sport, c.recv_next);
        for (self.inconns.items) |*c| self.rtxOne(&c.tcb, gateway_ip, c.ephem, c.gport, c.recv_next);
    }

    fn rtxOne(self: *Nat, t: *Tcb, src: [4]u8, sport: u16, dport: u16, ack: u32) void {
        if (!t.rtx_pending or self.now_ns < t.rtx_deadline or t.snd_una == t.snd_nxt) return;
        t.snd_nxt = t.snd_una; // resend from the oldest unacked byte
        t.rto_ns = @min(t.rto_ns * 2, max_rto_ns);
        t.rtx_pending = false; // re-armed by tcpOutput
        t.fin_sent = false; // allow the FIN to be resent if it was outstanding
        self.tcpOutput(t, src, sport, dport, ack);
    }

    fn findUdpById(self: *Nat, id: u32) ?*UdpSess {
        for (self.udp.items) |*u| if (u.id == id) return u;
        return null;
    }
    fn findTcpById(self: *Nat, id: u32) ?*TcpConn {
        for (self.tcp.items) |*c| if (c.id == id) return c;
        return null;
    }

    fn writeEthHdr(buf: []u8, dst: [6]u8, src: [6]u8, ethertype: u16) void {
        @memcpy(buf[0..6], &dst);
        @memcpy(buf[6..12], &src);
        wbe16(buf[12..14], ethertype);
    }

    /// Process one Ethernet frame sent by the guest (virtio-net TX).
    pub fn input(self: *Nat, frame: []const u8) void {
        if (frame.len < eth_hdr_len) return;
        @memcpy(&self.guest_mac, frame[6..12]);
        self.have_guest_mac = true;
        switch (be16(frame[12..14])) {
            0x0806 => self.handleArp(frame),
            0x0800 => self.handleIpv4(frame),
            else => {},
        }
    }

    fn handleArp(self: *Nat, frame: []const u8) void {
        const p = frame[eth_hdr_len..];
        if (p.len < 28) return;
        if (be16(p[6..8]) != 1) return; // requests only
        const target_ip = p[24..28];
        if (!std.mem.eql(u8, target_ip, &gateway_ip) and !std.mem.eql(u8, target_ip, &dns_ip)) return;
        var buf: [42]u8 = undefined;
        writeEthHdr(&buf, self.guest_mac, gw_mac, 0x0806);
        const a = buf[eth_hdr_len..];
        wbe16(a[0..2], 1);
        wbe16(a[2..4], 0x0800);
        a[4] = 6;
        a[5] = 4;
        wbe16(a[6..8], 2);
        @memcpy(a[8..14], &gw_mac);
        @memcpy(a[14..18], target_ip);
        @memcpy(a[18..24], &self.guest_mac);
        @memcpy(a[24..28], p[14..18]);
        self.enqueue(&buf);
    }

    fn handleIpv4(self: *Nat, frame: []const u8) void {
        const ip = frame[eth_hdr_len..];
        if (ip.len < 20) return;
        const ihl = (ip[0] & 0x0f) * 4;
        if (ip.len < ihl) return;
        const payload = ip[ihl..];
        switch (ip[9]) {
            1 => self.handleIcmp(ip, payload),
            6 => self.handleTcp(ip, payload),
            17 => self.handleUdp(ip, payload),
            else => {},
        }
    }

    fn handleIcmp(self: *Nat, ip: []const u8, icmp: []const u8) void {
        if (icmp.len < 8 or icmp[0] != 8) return; // echo request only
        var buf: [1600]u8 = undefined;
        const total = eth_hdr_len + ip.len;
        if (total > buf.len) return;
        writeEthHdr(&buf, self.guest_mac, gw_mac, 0x0800);
        const oip = buf[eth_hdr_len..total];
        @memcpy(oip, ip);
        @memcpy(oip[12..16], ip[16..20]);
        @memcpy(oip[16..20], ip[12..16]);
        const ihl = (ip[0] & 0x0f) * 4;
        wbe16(oip[10..12], 0);
        wbe16(oip[10..12], csumFinish(checksum(oip[0..ihl], 0)));
        const oicmp = oip[ihl..];
        oicmp[0] = 0;
        wbe16(oicmp[2..4], 0);
        wbe16(oicmp[2..4], csumFinish(checksum(oicmp, 0)));
        self.enqueue(buf[0..total]);
    }

    // ---- UDP relay ----
    fn handleUdp(self: *Nat, ip: []const u8, udp: []const u8) void {
        if (udp.len < 8) return;
        const sport = be16(udp[0..2]);
        const dport = be16(udp[2..4]);
        if (dport == 67) {
            self.handleDhcp(udp[8..]);
            return;
        }
        const gdst: [4]u8 = ip[16..20].*;
        var dst = gdst;
        if (std.mem.eql(u8, &dst, &dns_ip)) dst = upstream_dns;
        self.udpForward(sport, dst, gdst, dport, udp[8..]);
    }

    fn findUdp(self: *Nat, sport: u16, gdst: [4]u8, dport: u16) ?*UdpSess {
        for (self.udp.items) |*u| {
            if (u.sport == sport and u.dport == dport and std.mem.eql(u8, &u.gdst, &gdst)) return u;
        }
        return null;
    }

    fn udpForward(self: *Nat, sport: u16, dst: [4]u8, gdst: [4]u8, dport: u16, payload: []const u8) void {
        const sess = self.findUdp(sport, gdst, dport) orelse blk: {
            const any = net.IpAddress{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } };
            const sock = any.bind(self.io, .{ .mode = .dgram }) catch return;
            const id = self.next_id;
            self.next_id += 1;
            self.udp.append(self.alloc, .{ .id = id, .sport = sport, .dst = dst, .gdst = gdst, .dport = dport, .sock = sock }) catch {
                var s = sock;
                s.close(self.io);
                return;
            };
            const u = &self.udp.items[self.udp.items.len - 1];
            u.thread = self.spawnReader(sock, id, false);
            break :blk u;
        };
        const to = net.IpAddress{ .ip4 = .{ .bytes = dst, .port = dport } };
        sess.sock.send(self.io, &to, payload) catch {};
    }

    fn sendUdp(self: *Nat, src: [4]u8, sport: u16, dport: u16, data: []const u8) void {
        var buf: [1600]u8 = undefined;
        const udp_len = 8 + data.len;
        const ip_total = 20 + udp_len;
        const total = eth_hdr_len + ip_total;
        if (total > buf.len) return;
        writeEthHdr(&buf, self.guest_mac, gw_mac, 0x0800);
        const ip = buf[eth_hdr_len..];
        self.writeIpHdr(ip, 17, src, @intCast(ip_total));
        const u = ip[20..];
        wbe16(u[0..2], sport);
        wbe16(u[2..4], dport);
        wbe16(u[4..6], @intCast(udp_len));
        wbe16(u[6..8], 0);
        if (data.len > 0) @memcpy(u[8 .. 8 + data.len], data);
        wbe16(u[6..8], self.l4Checksum(src, guest_ip, 17, u[0..udp_len]));
        self.enqueue(buf[0..total]);
    }

    // ---- TCP relay ----
    fn handleTcp(self: *Nat, ip: []const u8, tcp: []const u8) void {
        if (tcp.len < 20) return;
        const sport = be16(tcp[0..2]);
        const dport = be16(tcp[2..4]);
        const seq = std.mem.readInt(u32, tcp[4..8], .big);
        const data_off = (tcp[12] >> 4) * 4;
        if (tcp.len < data_off) return;
        const flags = tcp[13];
        const payload = tcp[data_off..];
        const dst: [4]u8 = ip[16..20].*;

        const win = be16(tcp[14..16]);
        const opts = if (data_off > 20) tcp[20..data_off] else &[_]u8{};

        // Frames addressed to the gateway belong to a host->guest bridged
        // connection (the guest is the server side); route them separately.
        if (std.mem.eql(u8, &dst, &gateway_ip)) {
            const ack = std.mem.readInt(u32, tcp[8..12], .big);
            self.handleInboundTcp(sport, dport, seq, ack, win, flags, opts, payload);
            return;
        }

        const FIN = 0x01;
        const SYN = 0x02;
        const RST = 0x04;
        const ACK = 0x10;

        const existing = self.findTcp(sport, dst, dport);
        if (existing == null) {
            if (flags & SYN == 0) return;
            const to = net.IpAddress{ .ip4 = .{ .bytes = dst, .port = dport } };
            const stream = to.connect(self.io, .{ .mode = .stream }) catch {
                self.sendTcp(dst, dport, sport, self.isn, seq +% 1, RST | ACK, &.{});
                return;
            };
            self.isn +%= 0x1000;
            const id = self.next_id;
            self.next_id += 1;
            self.tcp.append(self.alloc, .{
                .id = id,
                .sport = sport,
                .dst = dst,
                .dport = dport,
                .stream = stream,
                .state = .established,
                .recv_next = seq +% 1,
                // SYN window is unscaled; later segments apply the guest's wscale.
                .tcb = .{ .snd_una = self.isn +% 1, .snd_nxt = self.isn +% 1, .snd_wnd = win, .wscale = parseWscale(opts) },
            }) catch {
                var s = stream;
                s.close(self.io);
                return;
            };
            const c = &self.tcp.items[self.tcp.items.len - 1];
            c.thread = self.spawnReader(stream.socket, id, true);
            self.sendTcp(dst, dport, sport, self.isn, seq +% 1, SYN | ACK, &.{});
            return;
        }
        const c = existing.?;
        if (flags & RST != 0) {
            self.closeTcp(c.id);
            return;
        }
        const ack = std.mem.readInt(u32, tcp[8..12], .big);
        // Guest -> host data (forward in-order bytes to the host socket).
        if (payload.len > 0 and seq == c.recv_next) {
            _ = self.io.vtable.netWrite(self.io.userdata, c.stream.socket.handle, &.{}, &.{payload}, 1) catch {};
            c.recv_next +%= @intCast(payload.len);
        }
        // Process the guest's ACK + window; sends any newly-in-window data.
        self.tcpAck(&c.tcb, ack, win, payload.len, c.dst, c.dport, c.sport, c.recv_next);
        if (payload.len > 0) self.sendTcp(c.dst, c.dport, c.sport, c.tcb.snd_nxt, c.recv_next, ACK, &.{});
        if (flags & FIN != 0) {
            c.recv_next +%= 1;
            self.sendTcp(c.dst, c.dport, c.sport, c.tcb.snd_nxt, c.recv_next, FIN | ACK, &.{});
            self.closeTcp(c.id);
        }
    }

    fn findTcp(self: *Nat, sport: u16, dst: [4]u8, dport: u16) ?*TcpConn {
        for (self.tcp.items) |*c| {
            if (c.sport == sport and c.dport == dport and std.mem.eql(u8, &c.dst, &dst)) return c;
        }
        return null;
    }

    fn closeTcp(self: *Nat, id: u32) void {
        for (self.tcp.items, 0..) |*c, i| {
            if (c.id == id) {
                c.stream.close(self.io); // wakes the reader thread
                if (c.thread) |t| t.detach(); // it will exit on the closed socket
                c.tcb.sndbuf.deinit(self.alloc);
                _ = self.tcp.swapRemove(i);
                return;
            }
        }
    }

    fn sendTcp(self: *Nat, src: [4]u8, sport: u16, dport: u16, seq: u32, ack: u32, flags: u8, data: []const u8) void {
        var buf: [1600]u8 = undefined;
        const tcp_len = 20 + data.len;
        const ip_total = 20 + tcp_len;
        const total = eth_hdr_len + ip_total;
        if (total > buf.len) return;
        writeEthHdr(&buf, self.guest_mac, gw_mac, 0x0800);
        const ip = buf[eth_hdr_len..];
        self.writeIpHdr(ip, 6, src, @intCast(ip_total));
        const t = ip[20..];
        @memset(t[0..20], 0);
        wbe16(t[0..2], sport);
        wbe16(t[2..4], dport);
        std.mem.writeInt(u32, t[4..8], seq, .big);
        std.mem.writeInt(u32, t[8..12], ack, .big);
        t[12] = 5 << 4;
        t[13] = flags;
        wbe16(t[14..16], 64240);
        if (data.len > 0) @memcpy(t[20 .. 20 + data.len], data);
        wbe16(t[16..18], self.l4Checksum(src, guest_ip, 6, t[0..tcp_len]));
        self.enqueue(buf[0..total]);
    }

    fn writeIpHdr(self: *Nat, ip: []u8, proto: u8, src: [4]u8, ip_total: u16) void {
        _ = self;
        ip[0] = 0x45;
        ip[1] = 0;
        wbe16(ip[2..4], ip_total);
        wbe16(ip[4..6], 0);
        wbe16(ip[6..8], if (proto == 6) 0x4000 else 0);
        ip[8] = 64;
        ip[9] = proto;
        @memcpy(ip[12..16], &src);
        @memcpy(ip[16..20], &guest_ip);
        wbe16(ip[10..12], 0);
        wbe16(ip[10..12], csumFinish(checksum(ip[0..20], 0)));
    }

    fn l4Checksum(self: *Nat, src: [4]u8, dst: [4]u8, proto: u8, l4: []const u8) u16 {
        _ = self;
        var sum: u32 = 0;
        sum += (@as(u32, src[0]) << 8) | src[1];
        sum += (@as(u32, src[2]) << 8) | src[3];
        sum += (@as(u32, dst[0]) << 8) | dst[1];
        sum += (@as(u32, dst[2]) << 8) | dst[3];
        sum += proto;
        sum += @intCast(l4.len);
        return csumFinish(checksum(l4, sum));
    }

    // ---- DHCP server ----
    fn dhcpOption(opts: []const u8, want: u8) ?[]const u8 {
        var i: usize = 0;
        while (i < opts.len) {
            const code = opts[i];
            if (code == 255) return null;
            if (code == 0) {
                i += 1;
                continue;
            }
            if (i + 1 >= opts.len) return null;
            const len = opts[i + 1];
            if (i + 2 + len > opts.len) return null;
            if (code == want) return opts[i + 2 .. i + 2 + len];
            i += 2 + len;
        }
        return null;
    }

    fn handleDhcp(self: *Nat, bootp: []const u8) void {
        if (bootp.len < 240) return;
        if (!std.mem.eql(u8, bootp[236..240], &[4]u8{ 99, 130, 83, 99 })) return;
        const opts = bootp[240..];
        const msgtype = dhcpOption(opts, 53) orelse return;
        const reply_type: u8 = switch (msgtype[0]) {
            1 => 2, // DISCOVER -> OFFER
            3 => 5, // REQUEST -> ACK
            else => return,
        };
        var buf: [590]u8 = undefined;
        @memset(&buf, 0);
        writeEthHdr(&buf, self.guest_mac, gw_mac, 0x0800);
        const ip = buf[eth_hdr_len..];
        const bootp_len = 240 + 64;
        const udp_len = 8 + bootp_len;
        const ip_total = 20 + udp_len;
        ip[0] = 0x45;
        wbe16(ip[2..4], @intCast(ip_total));
        ip[8] = 64;
        ip[9] = 17;
        @memcpy(ip[12..16], &gateway_ip);
        @memcpy(ip[16..20], &[4]u8{ 255, 255, 255, 255 });
        wbe16(ip[10..12], csumFinish(checksum(ip[0..20], 0)));
        const udp = ip[20..];
        wbe16(udp[0..2], 67);
        wbe16(udp[2..4], 68);
        wbe16(udp[4..6], @intCast(udp_len));
        const bp = udp[8..];
        bp[0] = 2;
        bp[1] = 1;
        bp[2] = 6;
        @memcpy(bp[4..8], bootp[4..8]);
        @memcpy(bp[16..20], &guest_ip);
        @memcpy(bp[20..24], &gateway_ip);
        @memcpy(bp[28..34], &self.guest_mac);
        @memcpy(bp[236..240], &[4]u8{ 99, 130, 83, 99 });
        var o = bp[240..];
        var k: usize = 0;
        o[k] = 53;
        o[k + 1] = 1;
        o[k + 2] = reply_type;
        k += 3;
        o[k] = 54;
        o[k + 1] = 4;
        @memcpy(o[k + 2 .. k + 6], &gateway_ip);
        k += 6;
        o[k] = 51;
        o[k + 1] = 4;
        wbe16(o[k + 2 .. k + 4][0..2], 0);
        wbe16(o[k + 4 .. k + 6][0..2], 0xffff);
        k += 6;
        o[k] = 1;
        o[k + 1] = 4;
        @memcpy(o[k + 2 .. k + 6], &netmask);
        k += 6;
        o[k] = 3;
        o[k + 1] = 4;
        @memcpy(o[k + 2 .. k + 6], &gateway_ip);
        k += 6;
        o[k] = 6;
        o[k + 1] = 4;
        @memcpy(o[k + 2 .. k + 6], &dns_ip);
        k += 6;
        o[k] = 255;
        const total = eth_hdr_len + ip_total;
        self.enqueue(buf[0..total]);
    }
};

//! ARM PL011 UART (as exposed by the QEMU `virt` machine at 0x09000000).
//!
//! For M0 we only need enough to get characters out: writing to the data
//! register (DR, offset 0x00) emits a byte; reading the flag register (FR,
//! offset 0x18) reports the transmitter as never-full / always-ready.
//!
//! Receive, interrupts and the full register file are added in M1 so a real
//! kernel's console driver is happy.

const std = @import("std");

pub const Pl011 = struct {
    pub const base: u64 = 0x0900_0000;
    pub const size: u64 = 0x1000;

    // Register offsets.
    const DR = 0x000; // Data register
    const FR = 0x018; // Flag register
    const IBRD = 0x024; // Integer baud rate
    const FBRD = 0x028; // Fractional baud rate
    const LCR_H = 0x02c; // Line control
    const CR = 0x030; // Control
    const IFLS = 0x034; // Interrupt FIFO level select
    const IMSC = 0x038; // Interrupt mask set/clear
    const RIS = 0x03c; // Raw interrupt status
    const MIS = 0x040; // Masked interrupt status
    const ICR = 0x044; // Interrupt clear

    // Flag register bits.
    const FR_RXFE = 1 << 4; // receive FIFO empty
    const FR_TXFF = 1 << 5; // transmit FIFO full
    const FR_RXFF = 1 << 6; // receive FIFO full
    const FR_TXFE = 1 << 7; // transmit FIFO empty

    // PrimeCell identification registers (PL011), read back by drivers.
    const periph_id = [_]u8{ 0x11, 0x10, 0x14, 0x00 }; // 0xFE0..0xFEC
    const pcell_id = [_]u8{ 0x0d, 0xf0, 0x05, 0xb1 }; // 0xFF0..0xFFC

    // Host IO + stdout for emitted bytes.
    io: std.Io,
    out: std.Io.File,
    // Input ring buffer (filled by the host stdin reader thread in M1).
    rx_buf: [256]u8 = undefined,
    rx_head: usize = 0,
    rx_tail: usize = 0,
    rx_lock: std.atomic.Value(bool) = .{ .raw = false }, // guards the rx ring (stdin thread vs emulator)

    cr: u32 = 0x300, // TXE|RXE enabled by reset-ish default
    imsc: u32 = 0,
    ris: u32 = 0,
    // Output cursor-column tracking so we can auto-reply to the line editor's
    // ESC[6n cursor-position query with the *real* column. busybox queries the
    // position right after printing the prompt to learn where editing starts; a
    // fixed/wrong answer makes it think it's at the right margin and wrap every
    // keystroke onto a new line. `col` is the 0-based column; `out_state`/
    // `csi_buf` parse the outgoing byte stream.
    col: u16 = 0,
    out_state: u8 = 0, // 0 normal, 1 saw ESC, 2 inside CSI
    csi_buf: [16]u8 = undefined,
    csi_len: usize = 0,

    const max_cols: u16 = 80;

    pub fn init(io: std.Io) Pl011 {
        return .{ .io = io, .out = std.Io.File.stdout() };
    }

    fn rxLockAcquire(self: *Pl011) void {
        while (self.rx_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn rxLockRelease(self: *Pl011) void {
        self.rx_lock.store(false, .release);
    }

    fn rxEmpty(self: *Pl011) bool {
        return self.rx_head == self.rx_tail;
    }

    /// Raw interrupt status: RXRIS (bit4) + RTRIS (bit6) reflect pending RX data.
    fn rawIntStatus(self: *Pl011) u32 {
        var v = self.ris;
        if (!self.rxEmpty()) v |= (1 << 4) | (1 << 6);
        return v;
    }

    /// Whether the UART should be asserting its interrupt line: RX data present
    /// and either the RX (bit 4) or receive-timeout (bit 6) interrupt unmasked.
    pub fn irqPending(self: *Pl011) bool {
        return !self.rxEmpty() and (self.imsc & ((1 << 4) | (1 << 6))) != 0;
    }

    /// Ready to accept a scripted RX byte: buffer empty, receiver enabled
    /// (CR.RXE bit 9) and RX interrupt unmasked (driver is listening).
    pub fn readyForRx(self: *Pl011) bool {
        return self.rxEmpty() and (self.cr & (1 << 9)) != 0 and
            (self.imsc & ((1 << 4) | (1 << 6))) != 0;
    }

    /// Track the outgoing byte to keep `col` in sync with the on-screen cursor,
    /// and answer the line editor's ESC[6n query with the real position. This
    /// emulates just enough terminal behaviour that busybox's line editor reads
    /// back a correct column and doesn't blocking-wait or mis-wrap.
    fn trackOutput(self: *Pl011, b: u8) void {
        switch (self.out_state) {
            0 => if (b == 0x1b) {
                self.out_state = 1;
            } else self.advanceCol(b),
            1 => if (b == '[') {
                self.out_state = 2;
                self.csi_len = 0;
            } else {
                self.out_state = 0; // some other ESC x; ignore for column math
            },
            else => { // inside CSI: collect params until the final byte
                if (b >= 0x40 and b <= 0x7e) {
                    self.handleCsi(b);
                    self.out_state = 0;
                } else if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = b;
                    self.csi_len += 1;
                }
            },
        }
    }

    fn advanceCol(self: *Pl011, b: u8) void {
        switch (b) {
            '\r', '\n' => self.col = 0,
            0x08 => if (self.col > 0) {
                self.col -= 1;
            }, // backspace
            '\t' => self.col = @min((self.col / 8 + 1) * 8, max_cols - 1),
            else => if (b >= 0x20 and self.col + 1 < max_cols) {
                self.col += 1;
            },
        }
    }

    /// Parse the `idx`-th ';'-separated decimal parameter from `csi_buf`.
    fn csiParam(self: *Pl011, idx: usize, default: u16) u16 {
        var field: usize = 0;
        var val: u16 = 0;
        var has = false;
        for (self.csi_buf[0..self.csi_len]) |c| {
            if (c == ';') {
                if (field == idx) return if (has) val else default;
                field += 1;
                val = 0;
                has = false;
            } else if (c >= '0' and c <= '9') {
                val = val *% 10 +% (c - '0');
                has = true;
            }
        }
        if (field == idx) return if (has) val else default;
        return default;
    }

    fn handleCsi(self: *Pl011, final: u8) void {
        switch (final) {
            'n' => if (self.csiParam(0, 0) == 6) { // DSR: report cursor position
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[1;{d}R", .{self.col + 1}) catch return;
                for (s) |c| self.pushRx(c);
            },
            'H', 'f' => { // CUP row;col -> set column from the 2nd param
                const c = self.csiParam(1, 1);
                self.col = if (c == 0) 0 else @min(c - 1, max_cols - 1);
            },
            'G' => { // CHA: absolute column
                const c = self.csiParam(0, 1);
                self.col = if (c == 0) 0 else @min(c - 1, max_cols - 1);
            },
            'C' => { // cursor forward
                const n = self.csiParam(0, 1);
                self.col = @intCast(@min(@as(u32, self.col) + n, max_cols - 1));
            },
            'D' => { // cursor back
                const n = self.csiParam(0, 1);
                self.col = if (n >= self.col) 0 else self.col - n;
            },
            else => {}, // SGR colors (m), erase (K/J), etc.: no column change
        }
    }

    /// Push a received byte (called by the host input thread or TX cursor reply).
    pub fn pushRx(self: *Pl011, b: u8) void {
        self.rxLockAcquire();
        defer self.rxLockRelease();
        const next = (self.rx_tail + 1) % self.rx_buf.len;
        if (next == self.rx_head) return; // drop on overflow
        self.rx_buf[self.rx_tail] = b;
        self.rx_tail = next;
    }

    pub fn read(self: *Pl011, offset: u64, sz: u8) u64 {
        _ = sz;
        switch (offset) {
            DR => {
                self.rxLockAcquire();
                defer self.rxLockRelease();
                if (self.rxEmpty()) return 0;
                const b = self.rx_buf[self.rx_head];
                self.rx_head = (self.rx_head + 1) % self.rx_buf.len;
                return b;
            },
            FR => {
                var v: u32 = FR_TXFE; // TX always empty/ready
                if (self.rxEmpty()) v |= FR_RXFE;
                return v;
            },
            CR => return self.cr,
            IMSC => return self.imsc,
            RIS => return self.rawIntStatus(),
            MIS => return self.rawIntStatus() & self.imsc,
            IBRD, FBRD, LCR_H, IFLS => return 0,
            else => {
                if (offset >= 0xFE0 and offset < 0xFF0) {
                    return periph_id[(offset - 0xFE0) / 4];
                }
                if (offset >= 0xFF0 and offset <= 0xFFC) {
                    return pcell_id[(offset - 0xFF0) / 4];
                }
                return 0;
            },
        }
    }

    pub fn write(self: *Pl011, offset: u64, value: u64, sz: u8) void {
        _ = sz;
        switch (offset) {
            DR => {
                const byte: u8 = @truncate(value);
                self.out.writeStreamingAll(self.io, &[_]u8{byte}) catch {};
                self.trackOutput(byte);
            },
            CR => self.cr = @truncate(value),
            IMSC => self.imsc = @truncate(value),
            ICR => self.ris &= ~@as(u32, @truncate(value)),
            else => {},
        }
    }
};

//! Minimal newc-format cpio writer, enough to build a Linux initramfs.
//! Linux accepts an uncompressed cpio image directly, so no gzip is required.

const std = @import("std");

pub const MODE_DIR: u32 = 0o040755;
pub const MODE_FILE: u32 = 0o100755;
pub const MODE_SYMLINK: u32 = 0o120777;

pub const Writer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    ino: u32 = 1,

    pub fn init(alloc: std.mem.Allocator) Writer {
        return .{ .buf = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.alloc);
    }

    fn field(self: *Writer, value: u32) !void {
        var tmp: [8]u8 = undefined;
        // 8 uppercase hex digits, zero-padded.
        _ = std.fmt.bufPrint(&tmp, "{X:0>8}", .{value}) catch unreachable;
        try self.buf.appendSlice(self.alloc, &tmp);
    }

    fn pad4(self: *Writer) !void {
        while (self.buf.items.len % 4 != 0) try self.buf.append(self.alloc, 0);
    }

    fn entry(self: *Writer, name: []const u8, mode: u32, data: []const u8) !void {
        const namesize: u32 = @intCast(name.len + 1);
        try self.buf.appendSlice(self.alloc, "070701"); // c_magic
        try self.field(self.ino); // c_ino
        self.ino += 1;
        try self.field(mode); // c_mode
        try self.field(0); // c_uid
        try self.field(0); // c_gid
        try self.field(1); // c_nlink
        try self.field(0); // c_mtime
        try self.field(@intCast(data.len)); // c_filesize
        try self.field(0); // c_devmajor
        try self.field(0); // c_devminor
        try self.field(0); // c_rdevmajor
        try self.field(0); // c_rdevminor
        try self.field(namesize); // c_namesize
        try self.field(0); // c_check
        try self.buf.appendSlice(self.alloc, name);
        try self.buf.append(self.alloc, 0); // NUL
        try self.pad4(); // pad after name (header is 110 bytes)
        try self.buf.appendSlice(self.alloc, data);
        try self.pad4(); // pad after data
    }

    pub fn addDir(self: *Writer, name: []const u8) !void {
        try self.entry(name, MODE_DIR, "");
    }

    pub fn addFile(self: *Writer, name: []const u8, mode: u32, data: []const u8) !void {
        try self.entry(name, mode, data);
    }

    pub fn addSymlink(self: *Writer, name: []const u8, target: []const u8) !void {
        try self.entry(name, MODE_SYMLINK, target);
    }

    /// Append the archive trailer. Call once, last.
    pub fn finish(self: *Writer) !void {
        try self.entry("TRAILER!!!", 0, "");
    }

    pub fn bytes(self: *Writer) []const u8 {
        return self.buf.items;
    }
};

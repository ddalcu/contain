//! Dockerfile parsing for `contain build`. A from-scratch parser for the core
//! instruction set (FROM, RUN, COPY, ADD, ENV, WORKDIR, CMD, ENTRYPOINT, ARG,
//! LABEL, EXPOSE, USER) — enough to build the great majority of real Dockerfiles.
//! No BuildKit features (multi-stage graphs, cache/secret mounts, heredocs).
//!
//! The parser is deliberately pure + allocator-driven so it unit-tests without any
//! guest boot; `main.zig`'s cmdBuild drives the returned instructions: RUN executes
//! inside a contain guest with the build rootfs mounted rw over virtio-fs (so each
//! step's changes persist), COPY/ADD copy from the build context host-side, and the
//! metadata instructions accumulate into the output image config.

const std = @import("std");

pub const Op = enum {
    from,
    run,
    copy,
    add,
    env,
    workdir,
    cmd,
    entrypoint,
    arg,
    label,
    expose,
    user,
    unsupported,
};

pub const Instruction = struct {
    op: Op,
    /// The raw argument text (everything after the instruction keyword), trimmed.
    /// Interpretation is op-specific; helpers below parse the shapes that matter.
    args: []const u8,
    /// Original 1-based line number (for error messages).
    line: usize,
};

pub const Dockerfile = struct {
    instructions: []Instruction,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Dockerfile) void {
        self.arena.deinit();
    }
};

/// Parse Dockerfile `source` into an ordered instruction list. Handles comments
/// (# ...), blank lines, and backslash line-continuations. Instruction keywords
/// are case-insensitive (Docker convention: UPPERCASE, but we accept any case).
pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Dockerfile {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayListUnmanaged(Instruction) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const first_line = line_no;
        // Accumulate this logical line, following backslash continuations.
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        var seg = stripCr(raw);
        while (endsWithBackslash(seg)) {
            try acc.appendSlice(a, seg[0 .. seg.len - 1]);
            try acc.append(a, ' ');
            const nxt = lines.next() orelse break;
            line_no += 1;
            seg = stripCr(nxt);
        }
        try acc.appendSlice(a, seg);

        const trimmed = std.mem.trim(u8, acc.items, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue; // comment (we don't parse # directives)

        const sp = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const keyword = trimmed[0..sp];
        const rest = std.mem.trim(u8, trimmed[sp..], " \t");
        try list.append(a, .{ .op = opFromKeyword(keyword), .args = try a.dupe(u8, rest), .line = first_line });
    }

    return .{ .instructions = try list.toOwnedSlice(a), .arena = arena };
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn endsWithBackslash(line: []const u8) bool {
    // A line continues if it ends in a backslash (ignoring trailing whitespace).
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    return end > 0 and line[end - 1] == '\\';
}

fn opFromKeyword(kw: []const u8) Op {
    const map = .{
        .{ "FROM", Op.from },
        .{ "RUN", Op.run },
        .{ "COPY", Op.copy },
        .{ "ADD", Op.add },
        .{ "ENV", Op.env },
        .{ "WORKDIR", Op.workdir },
        .{ "CMD", Op.cmd },
        .{ "ENTRYPOINT", Op.entrypoint },
        .{ "ARG", Op.arg },
        .{ "LABEL", Op.label },
        .{ "EXPOSE", Op.expose },
        .{ "USER", Op.user },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(kw, entry[0])) return entry[1];
    }
    return .unsupported;
}

/// Parse an instruction argument that may be either JSON exec form (`["a","b"]`)
/// or shell form (`a b c`). For exec form, returns the parsed argv. For shell
/// form, returns a single-element slice with the whole string (the caller runs it
/// via `/bin/sh -c`). Allocated in `a`.
pub fn parseExecOrShell(a: std.mem.Allocator, args: []const u8) !struct { argv: []const []const u8, is_exec: bool } {
    const t = std.mem.trim(u8, args, " \t");
    if (t.len > 0 and t[0] == '[') {
        if (parseJsonArray(a, t)) |argv| return .{ .argv = argv, .is_exec = true } else |_| {}
    }
    const one = try a.alloc([]const u8, 1);
    one[0] = try a.dupe(u8, t);
    return .{ .argv = one, .is_exec = false };
}

/// Parse a JSON string array `["a","b"]` into a slice of strings.
pub fn parseJsonArray(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.NotArray;
    const items = parsed.value.array.items;
    const out = try a.alloc([]const u8, items.len);
    for (items, 0..) |v, i| {
        if (v != .string) return error.NotStringArray;
        out[i] = try a.dupe(u8, v.string);
    }
    return out;
}

/// Split a shell-form COPY/ADD/whitespace argument into space-separated tokens
/// (no quote handling beyond simple splitting — adequate for typical paths).
pub fn splitWords(a: std.mem.Allocator, args: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |w| try list.append(a, try a.dupe(u8, w));
    return list.toOwnedSlice(a);
}

/// Parse an `ENV` argument. Supports both `ENV KEY VALUE` (first space splits) and
/// `ENV KEY=VALUE [KEY2=VALUE2 ...]`. Returns a list of "KEY=VALUE" strings.
pub fn parseEnv(a: std.mem.Allocator, args: []const u8) ![]const []const u8 {
    const t = std.mem.trim(u8, args, " \t");
    // If there's no '=', it's the legacy `ENV KEY VALUE` form.
    if (std.mem.indexOfScalar(u8, t, '=') == null) {
        const sp = std.mem.indexOfAny(u8, t, " \t") orelse return &.{};
        const key = t[0..sp];
        const val = std.mem.trim(u8, t[sp..], " \t");
        const one = try a.alloc([]const u8, 1);
        one[0] = try std.fmt.allocPrint(a, "{s}={s}", .{ key, val });
        return one;
    }
    // KEY=VALUE form (possibly several, space-separated). Values with spaces would
    // need quoting; we keep it simple and split on whitespace between pairs.
    return splitWords(a, t);
}

/// Strip a trailing `AS <name>` (multi-stage alias) from a FROM argument and return
/// just the base image ref.
pub fn fromImage(args: []const u8) []const u8 {
    const t = std.mem.trim(u8, args, " \t");
    // The image is the first whitespace-delimited token; a following "AS <name>"
    // (multi-stage alias) or "--platform=..." flag is dropped. We ignore flags by
    // taking the first token that doesn't start with '-'.
    var it = std.mem.tokenizeAny(u8, t, " \t");
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '-') continue; // e.g. --platform=linux/amd64
        return tok;
    }
    return t;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "build: parse basic Dockerfile with continuation + comment" {
    const src =
        \\# a comment
        \\FROM alpine:3.19
        \\ENV FOO=bar
        \\RUN apk add --no-cache \
        \\    curl git
        \\COPY . /app
        \\WORKDIR /app
        \\CMD ["node", "index.js"]
    ;
    var df = try parse(testing.allocator, src);
    defer df.deinit();
    try testing.expectEqual(@as(usize, 6), df.instructions.len);
    try testing.expectEqual(Op.from, df.instructions[0].op);
    try testing.expectEqualStrings("alpine:3.19", df.instructions[0].args);
    try testing.expectEqual(Op.env, df.instructions[1].op);
    try testing.expectEqual(Op.run, df.instructions[2].op);
    // The continuation joined the two physical lines (exact interior whitespace is
    // irrelevant — the guest shell collapses it).
    try testing.expect(std.mem.indexOf(u8, df.instructions[2].args, "apk add --no-cache") != null);
    try testing.expect(std.mem.indexOf(u8, df.instructions[2].args, "curl git") != null);
    try testing.expectEqual(Op.copy, df.instructions[3].op);
    try testing.expectEqual(Op.cmd, df.instructions[5].op);
}

test "build: FROM strips AS alias" {
    try testing.expectEqualStrings("golang:1.22", fromImage("golang:1.22 AS builder"));
    try testing.expectEqualStrings("alpine", fromImage("alpine"));
}

test "build: exec vs shell form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exec = try parseExecOrShell(a, "[\"/bin/sh\", \"-c\", \"echo hi\"]");
    try testing.expect(exec.is_exec);
    try testing.expectEqual(@as(usize, 3), exec.argv.len);
    try testing.expectEqualStrings("echo hi", exec.argv[2]);
    const shell = try parseExecOrShell(a, "echo hello world");
    try testing.expect(!shell.is_exec);
    try testing.expectEqual(@as(usize, 1), shell.argv.len);
    try testing.expectEqualStrings("echo hello world", shell.argv[0]);
}

test "build: ENV both forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kv = try parseEnv(a, "KEY=value");
    try testing.expectEqualStrings("KEY=value", kv[0]);
    const legacy = try parseEnv(a, "KEY some value");
    try testing.expectEqualStrings("KEY=some value", legacy[0]);
}

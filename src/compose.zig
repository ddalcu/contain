//! compose.yaml parsing for `contain compose`. A focused YAML-subset parser for
//! the Compose service shape (image/build/command/environment/ports/volumes/
//! depends_on) — not a general YAML implementation, but enough for the common
//! docker-compose files people actually write. Indentation-based, 2-or-more-space
//! steps, `#` comments, list (`- x`) and map (`KEY: VAL`) children.
//!
//! `main.zig`'s cmdCompose drives the result: each service maps to a `contain run`
//! (or a `contain build` when it has a `build:` context), reusing the whole
//! run/build pipeline. Inter-service networking IS modeled (see `planNet`): each
//! service gets a virtual IP other services resolve its name to (via /etc/hosts),
//! and each guest's NAT relays a peer's vip:port to the host loopback port that
//! peer published — so `curl http://web:80` from one service reaches another.

const std = @import("std");

pub const Service = struct {
    name: []const u8,
    image: ?[]const u8 = null,
    build: ?[]const u8 = null, // build context dir
    command: ?[]const u8 = null, // shell-form command line
    env: std.ArrayListUnmanaged([]const u8) = .empty, // KEY=VALUE
    ports: std.ArrayListUnmanaged([]const u8) = .empty, // "host:container"
    expose: std.ArrayListUnmanaged([]const u8) = .empty, // "container" (inter-service only)
    volumes: std.ArrayListUnmanaged([]const u8) = .empty, // "host:container"
    depends_on: std.ArrayListUnmanaged([]const u8) = .empty,
};

pub const Compose = struct {
    services: []Service,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Compose) void {
        self.arena.deinit();
    }

    /// Find a service by name (nulls if absent).
    pub fn service(self: *const Compose, name: []const u8) ?*const Service {
        for (self.services) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
};

const Key = enum { none, environment, ports, expose, volumes, depends_on };

/// Parse a compose.yaml document into its services.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Compose {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var services: std.ArrayListUnmanaged(Service) = .empty;
    var in_services = false;
    var svc_indent: ?usize = null;
    var key_indent: ?usize = null;
    var cur: ?*Service = null;
    var cur_key: Key = .none;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw0| {
        const raw = stripComment(stripCr(raw0));
        if (isBlank(raw)) continue;
        const indent = leadingSpaces(raw);
        const content = std.mem.trim(u8, raw, " \t");

        if (indent == 0) {
            // A new top-level key. Only `services:` opens the section we parse.
            in_services = std.mem.startsWith(u8, content, "services:");
            svc_indent = null;
            cur = null;
            cur_key = .none;
            continue;
        }
        if (!in_services) continue;

        if (svc_indent == null) svc_indent = indent;

        if (indent == svc_indent.?) {
            // A service name: "name:".
            const name = trimKeyColon(content);
            try services.append(a, .{ .name = try a.dupe(u8, name) });
            cur = &services.items[services.items.len - 1];
            cur_key = .none;
            key_indent = null;
            continue;
        }

        // Deeper than the service indent: a key of the current service, or an item
        // of the current list/map key.
        if (cur == null) continue;

        if (std.mem.startsWith(u8, content, "- ") or std.mem.eql(u8, content, "-")) {
            // A list item for the current key.
            const item = std.mem.trim(u8, content[1..], " \t");
            try appendItem(a, cur.?, cur_key, unquote(item));
            continue;
        }

        // "key: value" — either a service key (if at the shallower key indent) or a
        // map entry under environment.
        const colon = std.mem.indexOfScalar(u8, content, ':') orelse continue;
        const key = std.mem.trim(u8, content[0..colon], " \t");
        const val = std.mem.trim(u8, content[colon + 1 ..], " \t");

        if (key_indent != null and indent > key_indent.? and cur_key == .environment) {
            // environment as a map: KEY: VALUE.
            try cur.?.env.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ key, unquote(val) }));
            continue;
        }

        // A service-level key.
        key_indent = indent;
        cur_key = .none;
        if (std.mem.eql(u8, key, "image")) {
            cur.?.image = try a.dupe(u8, unquote(val));
        } else if (std.mem.eql(u8, key, "build")) {
            cur.?.build = try a.dupe(u8, unquote(if (val.len != 0) val else "."));
        } else if (std.mem.eql(u8, key, "command")) {
            cur.?.command = try a.dupe(u8, parseCommand(a, val) catch val);
        } else if (std.mem.eql(u8, key, "environment")) {
            cur_key = .environment;
            if (val.len != 0) try cur.?.env.append(a, try a.dupe(u8, unquote(val)));
        } else if (std.mem.eql(u8, key, "ports")) {
            cur_key = .ports;
        } else if (std.mem.eql(u8, key, "expose")) {
            cur_key = .expose;
        } else if (std.mem.eql(u8, key, "volumes")) {
            cur_key = .volumes;
        } else if (std.mem.eql(u8, key, "depends_on")) {
            cur_key = .depends_on;
        }
        // Other keys (restart, networks, ...) are accepted and ignored.
    }

    return .{ .services = try services.toOwnedSlice(a), .arena = arena };
}

fn appendItem(a: std.mem.Allocator, s: *Service, key: Key, item: []const u8) !void {
    switch (key) {
        .environment => try s.env.append(a, try a.dupe(u8, item)),
        .ports => try s.ports.append(a, try a.dupe(u8, item)),
        .expose => try s.expose.append(a, try a.dupe(u8, item)),
        .volumes => try s.volumes.append(a, try a.dupe(u8, item)),
        .depends_on => try s.depends_on.append(a, try a.dupe(u8, item)),
        .none => {},
    }
}

/// A command may be a scalar string or a JSON/YAML flow array `["a","b"]`. For the
/// array form, join into a single shell string (best effort).
fn parseCommand(a: std.mem.Allocator, val: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, val, " \t");
    if (t.len > 0 and t[0] == '[') {
        const parsed = std.json.parseFromSlice(std.json.Value, a, t, .{}) catch return t;
        defer parsed.deinit();
        if (parsed.value == .array) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (parsed.value.array.items, 0..) |v, idx| {
                if (v != .string) continue;
                if (idx != 0) try buf.append(a, ' ');
                try buf.appendSlice(a, v.string);
            }
            return buf.items;
        }
    }
    return unquote(t);
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// Drop a trailing `# comment` (only when the '#' is preceded by whitespace or at
/// column 0, so a '#' inside a value like a URL fragment is left alone... best
/// effort — compose comments are almost always whole-line or space-prefixed).
fn stripComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) return line[0..i];
    }
    return line;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn trimKeyColon(content: []const u8) []const u8 {
    var s = content;
    if (s.len > 0 and s[s.len - 1] == ':') s = s[0 .. s.len - 1];
    return std.mem.trim(u8, s, " \t");
}

/// Strip surrounding single or double quotes from a scalar value.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

// ---- inter-service networking plan ------------------------------------------

pub const PortMap = struct {
    cport: u16, // the service's container port
    hport: u16, // the host loopback port it's published on (peers relay here)
};

/// The network identity of one service on the compose virtual network: a virtual
/// IP peers resolve its name to, and the host port each of its container ports is
/// published on. See `planNet`.
pub const NetInfo = struct {
    vip: [4]u8,
    ports: []PortMap,
};

fn stripProto(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '/')) |i| s[0..i] else s;
}

/// Parse a `ports:` entry ("8080:80", "80", "127.0.0.1:8080:80", "80/tcp") into
/// its container port and an optional explicit host port (the field just left of
/// the container port). Returns null if the container port isn't a number.
fn parsePortSpec(spec: []const u8) ?struct { cport: u16, hport: ?u16 } {
    var fields: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ':');
    while (it.next()) |f| : (n += 1) {
        if (n < fields.len) fields[n] = f;
    }
    if (n == 0 or n > fields.len) return null;
    const cport = std.fmt.parseInt(u16, stripProto(fields[n - 1]), 10) catch return null;
    const hport: ?u16 = if (n >= 2) (std.fmt.parseInt(u16, stripProto(fields[n - 2]), 10) catch null) else null;
    return .{ .cport = cport, .hport = hport };
}

/// Assign each service a place on the compose virtual network: a distinct virtual
/// IP (10.0.2.100+) and, for every container port it exposes (via `ports:` or
/// `expose:`), a host loopback port. An explicit `H:C` mapping keeps host port H;
/// everything else is auto-allocated from 20000 up, avoiding any explicit host
/// port. Deterministic given the service list. Caller frees via the arena it
/// passes. This is what makes services reachable from each other by name: each
/// guest gets /etc/hosts entries (name -> vip) and NAT relays vip:cport -> the
/// peer's 127.0.0.1:hport.
pub fn planNet(a: std.mem.Allocator, services: []Service) ![]NetInfo {
    const infos = try a.alloc(NetInfo, services.len);
    // Reserve every explicit host port first so auto-allocation never collides.
    var used = std.AutoHashMap(u16, void).init(a);
    defer used.deinit();
    for (services) |*s| for (s.ports.items) |p| {
        if (parsePortSpec(p)) |pp| if (pp.hport) |h| try used.put(h, {});
    };
    var auto: u16 = 20000;
    const nextAuto = struct {
        fn f(u: *std.AutoHashMap(u16, void), cur: *u16) !u16 {
            while (u.contains(cur.*)) cur.* += 1;
            const v = cur.*;
            try u.put(v, {});
            cur.* += 1;
            return v;
        }
    }.f;
    for (services, 0..) |*s, idx| {
        // Distinct last octet per service (wraps after 150; far beyond real use).
        infos[idx].vip = .{ 10, 0, 2, @intCast(100 + (idx % 150)) };
        var list: std.ArrayListUnmanaged(PortMap) = .empty;
        for (s.ports.items) |p| {
            const pp = parsePortSpec(p) orelse continue;
            const h = pp.hport orelse try nextAuto(&used, &auto);
            try list.append(a, .{ .cport = pp.cport, .hport = h });
        }
        for (s.expose.items) |e| {
            const cport = std.fmt.parseInt(u16, stripProto(std.mem.trim(u8, e, " \t")), 10) catch continue;
            try list.append(a, .{ .cport = cport, .hport = try nextAuto(&used, &auto) });
        }
        infos[idx].ports = try list.toOwnedSlice(a);
    }
    return infos;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "compose: parse services with image, ports, env list, volumes, depends_on" {
    const src =
        \\version: "3.8"
        \\services:
        \\  web:
        \\    image: nginx:alpine
        \\    ports:
        \\      - "8080:80"
        \\      - "8443:443"
        \\    environment:
        \\      - FOO=bar
        \\      - BAZ=qux
        \\    volumes:
        \\      - ./html:/usr/share/nginx/html
        \\    depends_on:
        \\      - db
        \\  db:
        \\    image: postgres:16
        \\    environment:
        \\      POSTGRES_PASSWORD: secret
    ;
    var c = try parse(testing.allocator, src);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.services.len);
    const web = c.service("web").?;
    try testing.expectEqualStrings("nginx:alpine", web.image.?);
    try testing.expectEqual(@as(usize, 2), web.ports.items.len);
    try testing.expectEqualStrings("8080:80", web.ports.items[0]);
    try testing.expectEqual(@as(usize, 2), web.env.items.len);
    try testing.expectEqualStrings("FOO=bar", web.env.items[0]);
    try testing.expectEqualStrings("./html:/usr/share/nginx/html", web.volumes.items[0]);
    try testing.expectEqualStrings("db", web.depends_on.items[0]);
    // Map-form environment.
    const db = c.service("db").?;
    try testing.expectEqualStrings("postgres:16", db.image.?);
    try testing.expectEqualStrings("POSTGRES_PASSWORD=secret", db.env.items[0]);
}

test "compose: planNet assigns per-service vips and host ports" {
    const src =
        \\services:
        \\  web:
        \\    image: nginx
        \\    ports:
        \\      - "8080:80"
        \\  db:
        \\    image: postgres
        \\    expose:
        \\      - "5432"
    ;
    var c = try parse(testing.allocator, src);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const plan = try planNet(arena.allocator(), c.services);
    try testing.expectEqual(@as(usize, 2), plan.len);
    // Each service gets a distinct virtual IP in the guest subnet, starting at .100.
    try testing.expectEqual([4]u8{ 10, 0, 2, 100 }, plan[0].vip);
    try testing.expectEqual([4]u8{ 10, 0, 2, 101 }, plan[1].vip);
    // web: the published mapping's host port is honored.
    try testing.expectEqual(@as(usize, 1), plan[0].ports.len);
    try testing.expectEqual(@as(u16, 80), plan[0].ports[0].cport);
    try testing.expectEqual(@as(u16, 8080), plan[0].ports[0].hport);
    // db: an `expose`d (container-only) port gets an auto-allocated host port that
    // avoids the explicit one (8080).
    try testing.expectEqual(@as(usize, 1), plan[1].ports.len);
    try testing.expectEqual(@as(u16, 5432), plan[1].ports[0].cport);
    try testing.expect(plan[1].ports[0].hport != 8080);
    try testing.expect(plan[1].ports[0].hport >= 20000);
}

test "compose: parse exposes container-only ports" {
    const src =
        \\services:
        \\  db:
        \\    image: postgres
        \\    expose:
        \\      - "5432"
        \\      - "9000"
    ;
    var c = try parse(testing.allocator, src);
    defer c.deinit();
    const db = c.service("db").?;
    try testing.expectEqual(@as(usize, 2), db.expose.items.len);
    try testing.expectEqualStrings("5432", db.expose.items[0]);
}

test "compose: build context and command flow array" {
    const src =
        \\services:
        \\  app:
        \\    build: ./app
        \\    command: ["node", "index.js"]
    ;
    var c = try parse(testing.allocator, src);
    defer c.deinit();
    const app = c.service("app").?;
    try testing.expectEqualStrings("./app", app.build.?);
    try testing.expectEqualStrings("node index.js", app.command.?);
}

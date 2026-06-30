//! Accel backend seam: selects how the guest vCPU runs on host hardware
//! virtualization — `hvf` (Apple Silicon), `kvm` (Linux), `whp` (Windows). The
//! device models, Bus, GIC and NAT are shared across all backends — only the
//! vCPU run/exit loop and interrupt injection differ.

const std = @import("std");
const builtin = @import("builtin");
const Machine = @import("../machine.zig").Machine;
const hvf = @import("hvf.zig");
const kvm = @import("kvm.zig");
const whp = @import("whp.zig");

pub const Kind = enum { hvf, kvm, whp };

pub fn parse(s: []const u8) ?Kind {
    if (std.mem.eql(u8, s, "hvf")) return .hvf;
    if (std.mem.eql(u8, s, "kvm")) return .kvm;
    if (std.mem.eql(u8, s, "whp")) return .whp;
    return null;
}

/// Whether `kind` can actually run on this host build.
pub fn supported(kind: Kind) bool {
    return switch (kind) {
        .hvf => hvf.hvf_supported,
        .kvm => kvm.kvm_supported,
        .whp => whp.whp_supported,
    };
}

/// The host's native hardware backend, chosen when CONTAIN_ACCEL is unset. A host
/// with no usable backend still resolves to one here; callers gate on
/// `supported()` and print a clear message before running.
pub fn autoDefault() Kind {
    if (builtin.os.tag == .windows) return .whp;
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) return .hvf;
    return .kvm; // Linux (x86-64 or arm64)
}

pub fn fromEnvOrDefault(override: ?[]const u8) Kind {
    if (override) |s| {
        if (s.len != 0) {
            if (parse(s)) |k| return k;
            std.debug.print("[contain] unknown CONTAIN_ACCEL='{s}'; using default.\n", .{s});
        }
    }
    return autoDefault();
}

pub fn run(kind: Kind, m: *Machine) !void {
    switch (kind) {
        .hvf => try hvf.run(m),
        .kvm => try kvm.run(m),
        .whp => try whp.run(m),
    }
}

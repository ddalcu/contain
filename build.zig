const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to the *host* CPU model when no explicit -Dtarget is given: letting
    // LLVM use the host's POPCNT/BMI/etc. for our device models + NAT is a free
    // speedup. Passing -Dtarget=... (e.g. for a portable, distributable binary)
    // overrides this back to baseline.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .native } });
    const optimize = b.standardOptimizeOption(.{});

    // The HVF accel backend (src/accel/hvf.zig) calls Hypervisor.framework, which
    // lives in libSystem and is only present/needed on Apple Silicon. Its externs
    // are comptime-dead elsewhere, so only this host links the framework + libc.
    const is_aarch64_macos = target.result.os.tag == .macos and target.result.cpu.arch == .aarch64;

    const exe = b.addExecutable(.{
        .name = "contain",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = is_aarch64_macos,
        }),
    });
    if (is_aarch64_macos) exe.root_module.linkFramework("Hypervisor", .{});

    const install = b.addInstallArtifact(exe, .{});

    if (is_aarch64_macos) {
        // Ad-hoc codesign with the hypervisor entitlement so `CONTAIN_ACCEL=hvf`
        // can create a VM (HVF returns HV_DENIED without it). Runs after install
        // so it signs the binary in zig-out/bin; the default build depends on it.
        const sign = b.addSystemCommand(&.{ "codesign", "--entitlements", "hv.entitlements", "--force", "-s", "-" });
        sign.addArg(b.getInstallPath(.bin, "contain"));
        sign.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&sign.step);
    } else {
        b.getInstallStep().dependOn(&install.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run contain");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

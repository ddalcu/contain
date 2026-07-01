const std = @import("std");
const builtin = @import("builtin");

// Pin the toolchain. contain tracks Zig 0.16.x exactly — the std `Io` API and
// several stdlib names differ on both earlier and later versions (see CLAUDE.md),
// so fail early with a clear message instead of deep inside a stdlib mismatch.
comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16)
        @compileError("contain requires Zig 0.16.x; found Zig " ++ builtin.zig_version_string);
}

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
        // Codesign with the hypervisor entitlement so `CONTAIN_ACCEL=hvf` can create
        // a VM (HVF returns HV_DENIED without it). Runs after install so it signs the
        // binary in zig-out/bin; the default build depends on it.
        //
        // Identity: ad-hoc ("-") by default. Ad-hoc has NO stable identity, so its
        // cdhash changes on every rebuild and a firewall like LuLu re-prompts each
        // build ("code signer changed"). Point this at a persistent self-signed
        // code-signing cert to stop that — the signature's identity is then stable,
        // so the firewall rule survives rebuilds. Set it via -Dsign-id=<name> or the
        // CONTAIN_CODESIGN_ID env var (see README: create the cert once in Keychain).
        const env_sign_id = b.graph.environ_map.get("CONTAIN_CODESIGN_ID");
        const sign_id = b.option([]const u8, "sign-id", "codesign identity for the HVF entitlement (default: ad-hoc '-')") orelse (env_sign_id orelse "-");
        const sign = b.addSystemCommand(&.{ "codesign", "--entitlements", "hv.entitlements", "--force", "-s", sign_id });
        sign.addArg(b.getInstallPath(.bin, "contain"));
        sign.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&sign.step);
    } else {
        b.getInstallStep().dependOn(&install.step);
    }

    // --- embeddable static library (src/capi.zig -> libcontain.a + contain.h) ---
    // Links into a host app (e.g. a sandboxed Swift app driving an AI agent). The
    // archive itself isn't codesigned; the embedding app bundle is signed with the
    // combined entitlements (see contain-app.entitlements). On Apple Silicon the
    // app must also link `-framework Hypervisor`.
    const lib = b.addLibrary(.{
        .name = "contain",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = is_aarch64_macos,
        }),
    });
    if (is_aarch64_macos) lib.root_module.linkFramework("Hypervisor", .{});
    const lib_install = b.addInstallArtifact(lib, .{});
    const header_install = b.addInstallFile(b.path("include/contain.h"), "include/contain.h");
    const lib_step = b.step("lib", "Build the embeddable static library + C header");
    lib_step.dependOn(&lib_install.step);
    lib_step.dependOn(&header_install.step);
    b.getInstallStep().dependOn(&lib_install.step);
    b.getInstallStep().dependOn(&header_install.step);

    // On macOS, re-pack the archive so Apple's ld (Xcode/Swift) accepts it: Zig's
    // archiver emits members the classic linker rejects as "not 8-byte aligned".
    if (target.result.os.tag == .macos) {
        const repack = b.addSystemCommand(&.{ "sh", "tools/repack_lib.sh" });
        repack.addArg(b.getInstallPath(.lib, "libcontain.a"));
        repack.step.dependOn(&lib_install.step);
        lib_step.dependOn(&repack.step);
        b.getInstallStep().dependOn(&repack.step);
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

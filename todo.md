# contain — pivot to hardware virtualization: status & TODO

**Goal:** turn `contain` into a fast, host-safe Linux/OCI sandbox for AI agents by
running the guest on the host's **hardware virtualization** (near-native speed)
instead of the software interpreter. Each host runs a native-arch Linux guest, so
host-ISA == guest-ISA and acceleration always applies:

| Host | Backend | Guest |
|---|---|---|
| Apple Silicon (arm64 macOS) | **HVF** (Hypervisor.framework) | arm64 |
| x86 Linux | **KVM** (`/dev/kvm`) | x86-64 |
| x86 Windows | **WHP** (Windows Hypervisor Platform) | x86-64 |

The existing device models (virtio, GICv2, UART, NAT, FDT) are **reused verbatim**:
the hypervisor maps `m.bus.ram.ptr` at guest-physical `ram_base`, so the guest and
the device virtqueue code touch the same host buffer. Selected by `CONTAIN_ACCEL`
(`interp`|`hvf`|`kvm`|`whp`) in `src/accel/accel.zig`.

**End state (decided with the user):** hardware-virt only. **DONE** — the software
interpreter (`cpu.zig`) + JIT (`jit.zig`) + `accel=interp` have been **removed**
(item 5 below). Non-x86/non-arm host support is dropped.

---

## TL;DR — where we are

- **Phase 1 (HVF, arm64 macOS): DONE & PROVEN on this M4 Max.** Boots Linux
  natively, reuses every device, runs node v24.18.0 (V8 JIT + OpenSSL) at native
  speed. **boot + 2 node benchmarks + poweroff in ~0.46 s wall** vs **~352 s**
  interpreted (~750×); identical bench results confirm correctness.
- **Phase 2 (KVM, arm64 guest): IMPLEMENTED + compile-validated; NOT runtime-tested**
  (no `/dev/kvm` on macOS — verified Docker Desktop's VM doesn't expose it either).
- **Phase 3 (x86-microvm platform + x86-KVM): DONE & PROVEN on WSL2 `/dev/kvm`.**
  Boots the custom x86 kernel to userspace with virtio blk/9p(mount+read)/net+NAT
  (DNS+HTTP)/rng, clean poweroff/exit (~5.6s wall). Fixed a chain of real bugs in
  the blind code: PVH loader read `p_vaddr` not `p_paddr`; missing CPUID→EFER.LME
  triple-fault; no MP table→no IOAPIC/timer; PCI-scan storm (`pci=off`); + TSS/
  identity map. The **firecracker CI kernels dead-end** (no-acpi: early-mm
  direct-map bootstrap fault; with-acpi: hangs in acpi_init) — so we **build our
  own**: `tools/build_x86_kernel.sh` → `artifacts/vmlinux-contain` (linux 6.6.58,
  PVH + virtio-mmio-cmdline + 9p + 8250, deferred-struct-page-init/NUMA/KASLR off,
  needs gcc-13). See memory `contain-x86-kvm-boot`.
- **Phase 4 (WHP, Windows): DONE & PROVEN on this Windows host.** `src/accel/whp.zig`
  boots the same kernel natively on Windows (no WSL) to userspace — virtio
  blk/9p/net+NAT, clean exit (~18.7s). WHP only emulates the LAPIC, so we added
  emulated IOAPIC/PIT/i8259/CMOS (`src/devices/`), drive the WHP instruction
  emulator (WinHvEmulation) for MMIO/IO, and use an async timer thread (PIT IRQ0 +
  RunVP-cancel for clean poweroff). Cmdline `noapictimer nohz=off highres=off` is
  WHP-only (`initX86(for_whp)`). See memory `contain-whp-backend`.
- **Phase 5 (OCI/Docker pull + unpack + run): WORKING on HVF + KVM + WHP, from
  scratch.** `contain pull <img> <dir>` and `contain oci <img> [-- cmd]` pull public
  Docker Hub images (no external tools) and run them; `cmdRunOci` now picks the
  host-arch kernel (x86 vmlinux-contain → KVM/WHP, arm64 Image-arm64 → HVF). **Proven
  end-to-end: `contain oci node:22-alpine -- node …` pulls the real amd64 node image
  and runs node v22.23.1** — a V8-JIT + OpenSSL stress test is byte-correct on KVM
  (Linux), and node runs on WHP (Windows). Two real bugs fixed: OCI argv was written
  unquoted into the init script (shell re-parsed `for(...)`); and Windows can't make
  on-disk symlinks, so the unpack now records them in a `.contain-symlinks` sidecar
  that `packRootfs` replays into the cpio (+ path-separator normalization).

**Cross-OS hardware-virt matrix is COMPLETE: HVF (arm64 mac) / KVM (x86 Linux) /
WHP (x86 Windows) all boot Linux to userspace and run pulled OCI images + node.**

`zig build test` is green on Linux + Windows; native + `aarch64-linux` +
`x86_64-linux` all cross-compile. Nothing committed (repo rule: no commits without
explicit ask).

---

## What's DONE

### New files
- `src/accel/accel.zig` — `Kind` enum + `fromEnvOrDefault`/`resolve`/`run` dispatcher.
- `src/accel/hvf.zig` — HVF backend (arm64 macOS). **Proven.**
- `src/accel/kvm.zig` — KVM backend, **both** arm64 (in-kernel vGIC v2 + timer) and
  x86 (in-kernel irqchip + PIT + PVH entry) paths. **Compile-validated only.**
- `src/devices/virtio_rng.zig` — always-on entropy (ChaCha CSPRNG, host-seeded).
  **Essential**, not optional: under a hardware backend real-time boot leaves no
  interrupt entropy, so without it crng takes ~5 s and node blocks on getrandom();
  with it, crng inits in ~0.04 s. Helps the interpreter too.
- `src/devices/uart_16550.zig` — x86 COM1 console (port I/O). **Unit-tested.**
- `src/x86/pvh.zig` — PVH boot: start_info/memmap structs, ELF PHYS32_ENTRY note
  parser, vmlinux PT_LOAD loader, start_info builder. **Unit-tested.**
- `hv.entitlements` — `com.apple.security.hypervisor` for HVF.

### Changed
- `build.zig` — links the `Hypervisor` framework + libc and ad-hoc-codesigns on
  aarch64-macOS (re-signing each build → a harmless "code signer changed" prompt).
- `src/machine.zig` — `Platform` enum + `initX86` (16550 + virtio-mmio at high
  addrs + cmdline `virtio_mmio.device=…`, no PL011/RTC/DTB) + `bootPvh`;
  `serviceDevicesHw` (shared HVF/KVM device service) branches per platform.
- `src/devices/gicv2.zig` — **the IRQ-raise abstraction**: optional
  `inject_fn`/`inject_ctx`. When an in-kernel irqchip backend sets it, `setIrq`/
  `pulse` forward to the hypervisor (KVM_IRQ_LINE: arm64 SPI = INTID, x86 GSI =
  line) instead of the emulated distributor. interp/HVF leave it null. The one
  genuinely cross-cutting seam; devices call `gic.setIrq` unchanged.
- `src/fdt.zig` — `/chosen/rng-seed` (helps kernels with TRUST_BOOTLOADER).
- `src/main.zig` — `CONTAIN_ACCEL` selection; **auto-detects an ELF kernel as an
  x86 `vmlinux`** → `bootX86` (x86-microvm, hardware backend required). rng-seed.
- `src/tests.zig` — tests for the 16550, the GIC inject hook, and PVH.

### How it runs
- arm64 (this mac): `CONTAIN_ACCEL=hvf ./zig-out/bin/contain boot artifacts/Image-arm64 <cpio> [tty]`
- x86 (on a KVM host): `./zig-out/bin/contain boot <vmlinux> <initramfs>` — the ELF
  magic selects the x86-microvm platform; defaults to `accel=kvm`.
- Default `accel` is the host's native backend (`accel.autoDefault`): HVF on Apple
  Silicon, WHP on Windows, KVM elsewhere. (`interp` is gone — see item 5.)

---

## NEXT — validate the blind x86/KVM work on the WSL/Windows host

The user is switching this session to a **Windows / WSL** host next. That unblocks
two things at once: **WSL2 exposes `/dev/kvm`** (so the x86-KVM backend becomes
testable) and Windows is the **WHP** target (Phase 4).

1. **Build on WSL** (x86_64 Linux): `zig build` (no HVF/codesign there). Confirm
   `zig build test` green.
2. **Validate Phase 2 (arm64 KVM) — optional/secondary:** needs an *arm64* KVM
   host; WSL is x86, so this stays unvalidated unless an arm64 box appears. The x86
   path is the priority.
3. **Validate Phase 3 (x86-microvm on KVM) — the main event.** Need a minimal
   **x86-64 `vmlinux`** built with: PVH entry (`CONFIG_PVH=y`), virtio-mmio
   (`CONFIG_VIRTIO_MMIO=y` + cmdline-device support), virtio-blk/net/9p, 16550
   console (`CONFIG_SERIAL_8250=y`, ttyS0), no module deps. Plus an x86-64 rootfs
   cpio (initramfs to start; reuse the Alpine approach for x86). Then:
   `./contain boot vmlinux initramfs.cpio <input-with-/app/start.sh-style>` and
   expect the kernel log over ttyS0, virtio probes, a shell, node, clean poweroff.
   **The /app/start.sh concatenated-cpio trick works great for a deterministic
   benchmark** (see how the HVF node bench was driven).

### Risks/gaps to expect when it first runs (highest-likelihood first)
- **PVH 32-bit entry register state** (`setupPvhRegs` in kvm.zig) is the most
  likely thing to be subtly wrong — one boot tells you (no output / FAIL_ENTRY →
  wrong CS/CR0/EIP/EBX). Cross-check against firecracker/cloud-hypervisor's PVH
  setup.
- **Shutdown/poweroff without ACPI.** Currently rely on `reboot=t` → triple fault →
  `KVM_EXIT_SHUTDOWN`. `poweroff` may just halt; may need an i8042 0xfe reset-port
  trap or a tiny ACPI-PM device.
- **WFI/idle servicing.** `KVM_RUN` blocks on guest idle; nothing services host→
  guest RX/console during true idle. Fine for non-interactive boot+bench; for
  interactive/heavy-net add a signal (`immediate_exit` + SIGUSR1 kick from a thread
  / the NAT readers).
- **16550 TX-empty interrupt** could storm under a level-triggered IOAPIC pin; if
  so, gate it / treat COM1 as edge.
- **virtio-mmio cmdline vs in-kernel IOAPIC GSIs** (5,6,7,…) — verify the kernel
  maps `virtio_mmio.device=…:<gsi>` to the same GSI we inject on.
- (arm64 KVM) **GICv3-only hosts** may reject `KVM_DEV_TYPE_ARM_VGIC_V2`.

### Then
4. **Phase 4 (WHP):** port only the backend (`src/accel/whp.zig`, gated to
   x86_64-windows like jit.zig). Reuses the entire Phase-3 x86 platform. Needs
   Hyper-V / Windows Hypervisor Platform enabled.
5. **Remove the interpreter/JIT — DONE.** Deleted `src/cpu.zig`, `src/jit.zig`,
   `accel=interp`, the bare-metal `run` + `jitbench` subcommands, the `test/*.S`
   kernels + `src/testdata` + `tools/build_test_kernels.sh` + `tools/neonfuzz/`.
   `accel.autoDefault()` now returns the host backend (HVF/WHP/KVM); `Machine` no
   longer owns a `Cpu`/dcache/code_bits (and dropped the `updateIrqs`/`serviceNet`
   interpreter callbacks); the shared `IrqLine` moved to `src/devices/gicv2.zig`.
   `zig build test` green (18/18); x86_64/aarch64-linux + x86_64-windows
   cross-compile; HVF boot of `artifacts/Image-arm64` validated end-to-end
   (virtio-blk/9p/NAT + clean poweroff). Removed ~6.4k lines of `src/` + the
   neonfuzz tooling. See memory `contain-pivot-hardware-virt`.
6. **Phase 5 (OCI pipeline): DONE for the pull/unpack/run core (from scratch, no
   skopeo/umoci).** `src/oci/registry.zig`: token dance + multi-arch index +
   config + gzip-tar layers + whiteout unpack (std.http.Client TLS / json / flate
   / tar). `contain pull <img> <dir> [arch]` and `contain oci [-p host:guest]
   <img> [-- cmd]` (main.zig: pull → pack rootfs into the initramfs as root →
   boot the host-arch kernel). **Runs on KVM + WHP + HVF**; `oci -p` wires the NAT
   hostfwd; x86 uses `vmlinux-contain` (`tools/build_x86_kernel.sh`). 9p
   `Tsetattr`/`Tmkdir`/`Tsymlink`/`Treadlink` are now implemented (writes work),
   and the Windows unpack records symlinks in a sidecar (no on-disk symlinks).
   Remaining polish: (a) the rootfs is packed into RAM (initramfs) — fine to
   ~hundreds of MB; for big images move to virtio-blk; (b) private registries /
   auth (out of scope for now).

---

## Key facts / gotchas for the next session

- **HVF (proven):** emulated GICv2 + `hv_vcpu_set_pending_interrupt`; vtimer→PPI27
  bridge; handles EC 0x24 (MMIO), 0x16/0x17 (PSCI), **0x18 (trapped MSR/MRS, shadow
  store — HVF traps debug/OS-lock/PMU regs)**, 0x01 (WFI). HV_REG: X0..30=0..30,
  PC=31, CPSR=34. CPSR entry 0x3c5. HV_DENIED=0xfae94006 → codesign hint.
- **KVM uapi:** ioctl numbers via the `_IOC` helper (`IO/IOW/IOR/IOWR`, magic
  0xAE). arm64 core-reg ids `KVM_REG_ARM64|SIZE_U64|CORE|<u32-offset>` (PC=64,
  PSTATE=66, Xn=n*2). x86 PVH: in-kernel irqchip+PIT, flat 32-bit segments, CR0.PE,
  EIP=entry, EBX=start_info. KVM advances PC on MMIO itself (don't +4). MMIO/IO are
  pre-decoded (no instruction decode).
- **Zig 0.16:** no `std.crypto.random` / `std.posix.getrandom` / `std.posix.close`.
  Use `std.c.arc4random_buf` (macOS, comptime-gated), `std.os.linux.close`,
  `std.posix.{openatZ,mmap,munmap}`. `u16550` is a valid integer type name (don't
  use it as an identifier). Backend files compile on every target via comptime-dead
  gating (`hvf_supported`/`kvm_supported`, the `jit.zig:63` pattern).
- **Build:** `zig build` (native), `zig build -Dtarget=x86_64-linux` /
  `aarch64-linux` to validate the Linux/KVM code compiles. A cross-build OVERWRITES
  `zig-out/bin/contain` — rebuild native before running locally (`exec format
  error` = a stale cross binary).
- **WSL build (x86 Linux):** install Zig 0.16 in WSL; optionally redirect caches
  (`--cache-dir ~/.cache/contain-cc --global-cache-dir ~/.cache/contain-gc
  --prefix ~/cb`). Invoke WSL via the PowerShell tool; put multi-line/quoted work in
  a script. `pkill -f 'bin/contain'` (a bare `pkill -f contain` kills your shell).
- **Driving node non-interactively:** concatenate a tiny cpio with `/app/start.sh`
  onto the rootfs cpio (`cat rootfs.cpio app.cpio > combined.cpio`); the kernel
  processes concatenated initramfs archives and the Alpine init execs
  `/app/start.sh`. Used for the HVF node benchmark.
- **Memory:** see `~/.claude/.../memory/contain-pivot-hardware-virt.md` and
  `contain-hvf-backend-notes.md` for the durable details.

---

## Reference — the prior milestone (software emulator, removed)

Before the pivot, `contain` was a from-scratch aarch64 **software** emulator
(interpreter + opt-in x86 JIT) that booted Linux and ran heavy Node byte-identical
to native across ~44 B guest instructions, validated with a NEON differential
fuzzer. That code (`src/cpu.zig`, `src/jit.zig`, the `test/*.S` kernels, and
`tools/neonfuzz/`) was the correctness reference during the pivot but ran ~135–180×
slower than native — it has now been **removed** (item 5). The git history retains
it if it's ever needed.

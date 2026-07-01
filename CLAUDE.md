# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this is

`contain` is a from-scratch, host-safe Linux sandbox / lightweight Docker
alternative written in Zig — a "Docker without the Docker daemon" for running
untrusted code and AI-agent workloads. It runs the guest on the host's **native
hardware virtualization** (the cross-OS matrix is complete: **HVF** on Apple
Silicon, **KVM** on x86/arm64 Linux, **WHP** on x86 Windows), reusing the same
from-scratch device models, `Bus`, GIC/IOAPIC and userspace NAT on every backend.
It also pulls and runs public **OCI/Docker images** (from-scratch registry client,
no external tools): `contain run` is a drop-in for `docker run` —
`contain run node:22-alpine node ...` runs node natively. `contain build` builds
images from a Dockerfile and `contain compose up` runs a multi-service
`compose.yaml` — same syntax as Docker (x86 only for now; see the virtiofs note).

Each host runs a native-arch Linux guest (host-ISA == guest-ISA), so acceleration
always applies. Complete: shell, virtio-blk with host persistence, virtio-9p
mounts, virtio-net + NAT, and the OCI pull/run pipeline. (Earlier milestones shipped
a from-scratch aarch64 software interpreter + JIT as a transitional fallback; those
have been removed now that the hardware backends are validated — see memory
`contain-pivot-hardware-virt`.)

## Toolchain

- **Zig 0.16.0** (pinned — the std `Io` API and several stdlib names differ from
  earlier/later versions; see Gotchas).
- No other build dependencies. No external cross-toolchain, qemu, dtc, or cpio
  needed.

## Commands

```sh
zig build                          # debug build -> zig-out/bin/contain (+ libcontain.a)
zig build -Doptimize=ReleaseFast   # faster host device-model/NAT code
zig build test                     # unit tests (16550/GIC/PVH/mptable/NAT/console/session)
zig build lib                      # embeddable static lib -> zig-out/lib/libcontain.a + include/contain.h
./tools/fetch_artifacts.sh         # fetch busybox + build demo initramfs (kernel auto-fetches)
```

Boot / run (see README for the full matrix):

```sh
./zig-out/bin/contain boot artifacts/Image-arm64 artifacts/initramfs.cpio tty - artifacts/share
./zig-out/bin/contain run node:22-alpine node -e 'console.log(2+2)'
```

The backend is auto-selected per host (HVF on Apple Silicon, KVM on Linux, WHP on
Windows); `CONTAIN_ACCEL=hvf|kvm|whp` overrides it.

## Architecture

```
src/
  main.zig              CLI (docker-style `run`/`build`/`compose`); the embedded
                        default init script; interactive-tty + raw-terminal
                        handling; run/build/compose/pull/boot/mkinitramfs/stripbtf.
                        `run` on x86 mounts the image rootfs over virtio-fs
                        (demand-paged root=rootfs) instead of an in-RAM initramfs
                        — the big memory win (see contain-virtiofs-build-compose).
  build.zig             Dockerfile parser (core instruction set) for `contain build`
  compose.zig           compose.yaml parser (service subset) for `contain compose`
  capi.zig              C ABI for embedding (export fn contain_*; see contain.h)
  session.zig           library boot orchestration: start/writeInput/stop/deinit,
                        no host TTY, no process.exit (the non-CLI cmdBoot)
  console.zig           OutSink: pluggable guest-console output sink (callback or
                        stdout fallback); used by both UARTs
  rootfs.zig            rootfs-dir -> in-memory initramfs packing + the persistent
                        agentic-shell /init builder (shared by CLI + session)
  machine.zig           the `virt` machine: memory map + device wiring; boot setup
  bus.zig               physical address space + MMIO device dispatch
  fdt.zig               builds the device tree (DTB) handed to the kernel
  cpio.zig              builds the newc initramfs
  accel/                vCPU backends (selected by CONTAIN_ACCEL via accel.zig):
    hvf.zig             Apple Silicon Hypervisor.framework (arm64 macOS)
    kvm.zig             Linux /dev/kvm (arm64 + x86)
    whp.zig             Windows Hypervisor Platform (x86 Windows)
  x86/pvh.zig           PVH boot (ELF PHYS32_ENTRY + hvm_start_info)
  x86/mptable.zig       Intel MP table (IOAPIC + IRQ routing, no ACPI)
  oci/registry.zig      from-scratch OCI/Docker pull + unpack (TLS/json/gzip/tar)
  kernel_fetch.zig      in-process auto-fetch of the guest kernel (arm64/x86) when
                        missing — a plain HTTPS GET + gunzip of contain's prebuilt
                        kernel from the GitHub release (built by build_kernel.sh)
  devices/
    uart_pl011.zig      PL011 UART (arm64 console)
    uart_16550.zig      16550 COM1 (x86 console, port I/O)
    gicv2.zig           GICv2 interrupt controller (+ IRQ-raise abstraction; IrqLine)
    ioapic.zig          I/O APIC   } emulated for WHP (WHP only emulates the
    pit.zig             i8254 PIT  } local APIC); KVM has these in-kernel and
    i8259.zig           PIC (probe)} arm64 uses the GIC instead.
    cmos.zig            MC146818 RTC (x86; stops the kernel's UIP poll)
    virtio.zig          virtio-mmio transport + virtio-blk (host-file backed)
    virtio_9p.zig       virtio-9p / 9P2000.L (host-directory backed; arm64 default)
    virtio_fs.zig       virtio-fs / FUSE (host-dir backed; DEFAULT share + rootfs
                        transport on x86 — POSIX-complete, symlink-sidecar aware)
    virtio_net.zig      virtio-net device (RX/TX virtqueues)
    virtio_rng.zig      virtio-rng (always-on entropy; essential under hw-virt)
  net/nat.zig           userspace slirp-style NAT (ARP/ICMP/DHCP/DNS + TCP/UDP relay
                        + host->guest TCP port forwarding / hostfwd)
  tests.zig             unit tests (devices / PVH / mptable / NAT)
tools/                  build_kernel.sh (Docker: builds both guest kernels ->
                        release assets), fetch_artifacts.sh (busybox + demo
                        initramfs), build_alpine_node.sh (Alpine aarch64 + Node 24
                        image), build_x86_kernel.sh (local x86 PVH kernel + initramfs)
```

Execution model: `accel.run(kind, m)` enters the host hypervisor's vCPU run loop.
The guest CPU executes natively; the backend only handles VM exits — MMIO routes to
`m.bus` (the device models), interrupts flow through the emulated/in-kernel irqchip,
and `Machine.serviceDevicesHw` feeds console input + the UART line + the NAT
pump/RX at each run-loop boundary. Devices reach guest memory through the `Bus`.

## Embedding as a library (C ABI)

Besides the CLI, contain builds an embeddable static library so it can run inside a
host app (the motivating case: a **sandboxed macOS Swift app** driving an AI coding
agent). `zig build lib` emits `zig-out/lib/libcontain.a` + `zig-out/include/contain.h`.

- **`contain.h` API** — `contain_start(cfg)` boots a guest on a background thread and
  returns an opaque handle; `contain_write(vm,bytes)` feeds the console (host->guest);
  the `out_fn` callback delivers guest console output; `contain_stop(vm)` powers it off
  mid-run; `contain_free(vm)` tears down. Plus `contain_fetch_kernel(dest)` and
  `contain_pull_image(ref,dest,arch)` — both take an explicit **sandbox-writable path**.
  `cfg.rootfs_dir` packs an unpacked OCI rootfs into an in-memory initramfs (no temp
  cpio); the generated `/init` mounts the 9p share + brings up NAT + execs a persistent
  shell (see `rootfs.buildShellInit`). The boot defaults to `contain.interactive` so the
  guest waits for `contain_write` instead of auto-powering-off.
- **Clean teardown (no `process.exit`)** — the library path must return to its caller,
  so `Session.deinit` actually runs `Machine.deinit`. The old "joining NAT threads can
  hang" problem is fixed in `nat.zig`: deinit `shutdown()`s each socket (a plain
  `close()` does NOT wake a `recv()` blocked on another thread on macOS) and
  self-connects to each published port to wake `accept()`, then joins. Stop is
  cooperative: `Machine.requestStop` sets `stop_requested` (polled by the run loop +
  WFI idle) and calls `accel_kick` (HVF `hv_vcpus_exit`) to break a blocked
  `hv_vcpu_run`. **Kick is HVF-only so far**; KVM/WHP stop only at a loop boundary.
- **Entitlements** — `contain-app.entitlements` is the reference plist for the embedding
  app: `com.apple.security.hypervisor` is App Sandbox compatible on macOS (UTM ships
  this on the Mac App Store). The userspace NAT needs only `network.client`/`.server`
  (NOT the privileged `com.apple.vm.networking`). The `.a` itself isn't signed; the app
  bundle is. The app must also link `-framework Hypervisor`.
- **Apple-ld gotcha** — Zig's archiver writes members the classic Apple linker rejects
  as "not 8-byte aligned". `tools/repack_lib.sh` (run automatically by `zig build lib`
  on macOS) re-packs the archive with `libtool -static` so Xcode/Swift can link it.
- **Validation** — `examples/smoke.c` is the C client + smoke test (start → write a
  command → see the reply via `out_fn` → stop → free, no hang). Build/sign/run it per
  the header comment; it doubles as the Swift call-sequence reference.

## Accel backends (hardware virtualization)

The guest CPU runs natively (~hundreds of × faster than a software emulator). The
device models, `Bus`, GICv2 and NAT are reused **verbatim**: the hypervisor maps
`m.bus.ram.ptr` at guest-physical `ram_base`, so the guest and the virtqueue code
touch the same host buffer; MMIO exits route to `m.bus`. Selected by `CONTAIN_ACCEL`
(`hvf`, `kvm`, `whp`) via `src/accel/accel.zig`; unset picks the host's native
backend (`accel.autoDefault`).

- **`src/accel/hvf.zig`** — Apple Silicon (arm64-macOS). **Done and proven**: boots
  Linux + runs node's V8 JIT/OpenSSL at native speed (boot+bench+poweroff well under
  a second). Uses the **emulated GICv2** (its MMIO traps to `m.bus`) and injects the
  GIC's computed line via `hv_vcpu_set_pending_interrupt`; bridges HVF's real vtimer
  to GICv2 PPI 27. Handles exits: data-abort→MMIO, HVC/SMC→PSCI, **EC 0x18 trapped
  MSR/MRS** (shadow store — HVF traps debug/OS-lock/PMU regs), WFI→idle. Needs the
  `com.apple.security.hypervisor` entitlement — `build.zig` codesigns with
  `hv.entitlements` on aarch64-macOS every build. It signs **ad-hoc** by default,
  whose cdhash changes each rebuild, so a firewall (LuLu/Little Snitch) re-prompts
  ("code signer changed") every build. Fix: sign with a **stable self-signed
  code-signing cert** — create one once in Keychain (Certificate Assistant →
  self-signed, type "Code Signing", e.g. `contain-dev`), then
  `export CONTAIN_CODESIGN_ID=contain-dev` (or `zig build -Dsign-id=contain-dev`).
  The signature's identity is then stable and the firewall rule persists.
- **`src/accel/kvm.zig`** — Linux `/dev/kvm`. **x86 path done & proven on WSL2**
  (boots the x86-microvm kernel to userspace, virtio blk/9p/net, ~5.6 s, clean
  exit). arm64 path implemented + compile-validated, not yet runtime-tested (no
  arm64 Linux host). arm64 uses the **in-kernel vGIC v2 + arch timer**; x86 uses the
  **in-kernel IOAPIC/PIC/PIT/LAPIC** (KVM_CREATE_IRQCHIP + KVM_CREATE_PIT2) + CPUID
  (KVM_SET_CPUID2). KVM_EXIT_MMIO/IO are pre-decoded (no instruction decode); arm64
  poweroff via KVM_EXIT_SYSTEM_EVENT, x86 via an IF=0-halt detector (SIGUSR1 poll
  thread breaks the blocked KVM_RUN). See memory `contain-x86-kvm-boot`.
- **`src/accel/whp.zig`** — Windows Hypervisor Platform (x86 Windows). **Done &
  proven**: boots the same x86 kernel natively on Windows (no WSL) to userspace,
  virtio blk/9p/net, clean exit. WinHvPlatform.dll + WinHvEmulation.dll are
  runtime-loaded (no SDK import lib). WHP emulates **only the LAPIC**, so we emulate
  the IOAPIC/PIT/i8259/CMOS (`src/devices/`) and drive the WHP **instruction
  emulator** (WHvEmulatorTryMmio/Io) for decode. An async timer thread pulses the
  PIT (WHvRequestInterrupt is thread-safe) to wake a HLT-blocked RunVP. The IOAPIC
  injector must honor the redir entry's **logical** dest mode (not physical). See
  memory `contain-whp-backend`.

The **x86-microvm platform** (`machine.zig:initX86` + `bootPvh`): 16550 COM1 +
virtio-mmio at high addrs (declared via the `virtio_mmio.device=` cmdline) + the MP
table; no PL011/RTC/GIC-MMIO/DTB. Auto-selected when `boot`'s kernel is an ELF
(`vmlinux`). Default accel: WHP on Windows, KVM elsewhere. The custom guest kernel
is built by `tools/build_x86_kernel.sh` (the firecracker CI kernels dead-end in
early mm); WHP needs cmdline `noapictimer nohz=off highres=off` (WHP-only, via
`initX86(for_whp)` — it breaks KVM's in-kernel LAPIC timer).
- **IRQ-raise abstraction** — the one cross-cutting seam. Devices always call
  `gic.setIrq`. `Gicv2` has an optional `inject_fn`/`inject_ctx`: when an in-kernel
  irqchip backend (KVM) sets it, `setIrq`/`pulse` forward to `KVM_IRQ_LINE` (SPI =
  INTID) instead of the emulated distributor; HVF leaves it null and uses the
  emulated distributor. `Machine.serviceDevicesHw` is the shared HVF/KVM/WHP
  device-service (input + UART line + NAT pump/RX; the timer is the hypervisor's).
  The shared `IrqLine` (the GIC→vCPU pending line, polled via `m.irq.pending`) lives
  in `src/devices/gicv2.zig`.
- **`src/devices/virtio_rng.zig`** — always-on entropy source (ChaCha CSPRNG seeded
  from host entropy via `Machine.init(..., rng_seed)`). Essential under a hardware
  backend: real-time boot leaves no interrupt entropy, so without it crng takes ~5 s
  and node blocks on `getrandom()`. With it, crng inits in ~0.04 s.

Backend files compile on every target via comptime-dead gating (`hvf_supported` /
`kvm_supported` / `whp_supported` — the framework `extern`s + run loop live behind a
comptime-known bool, so each file still *compiles* off-target); frameworks/libs are
linked only on their host in `build.zig`.

## The guest kernel

contain builds its **own lightweight guest kernels** (Linux 6.6.58) — one per arch,
with virtio blk/net/9p/rng + the console **built-in** (no modules, no fscache).
`tools/build_kernel.sh` builds both inside a Docker container (arm64 natively on
Apple Silicon, x86 cross-compiled with `x86_64-linux-gnu-gcc`) and emits gzip'd
release assets `Image-arm64.gz` / `vmlinux-contain-x86_64.gz` (~11–12 MB each).
Build gotchas (hard-won — see git history for the iterations):
- Source is fetched **on the host** and mounted in, because the container can sit
  behind a TLS-intercepting proxy whose root CA it lacks (the host trusts it) —
  see memory `contain-tls-proxy-container-ca`.
- **Do NOT `strip` the x86 `vmlinux`** — `strip --strip-debug` drops the
  `.note.Xen` `PT_NOTE` (PVH `PHYS32_ENTRY`) and the kernel won't boot. Disable
  `DEBUG_INFO` in the config to keep it small instead, and ship vmlinux as-is.
- The out-of-tree (`O=`) build breaks on `net/netfilter/xt_TCPMSS.o` ("No rule to
  make target"); both arches disable `NETFILTER` (not needed — NAT is host-side),
  which sidesteps it and trims size.
- arm64 boots from a **DTB** so `ACPI` is disabled; x86 keeps `ACPI` (it falls
  back to the MP table). Validate boot per arch (arm64 on HVF here; x86 needs an
  x86 KVM/WHP host — can't boot on an arm64 Mac).

`src/kernel_fetch.zig` **auto-fetches** the host-arch kernel the first time
`run`/`boot` finds it missing — a plain HTTPS GET of the release asset from
`github.com/ddalcu/contain/releases` + gunzip (`std.http.Client` +
`std.compress.flate`), written to `artifacts/Image-arm64` (arm64) or
`artifacts/vmlinux-contain` (x86) via a `.part` temp + rename. Bump `release_tag`
in `kernel_fetch.zig` when republishing rebuilt kernels. The fetch is scoped to the
canonical path (`kernel_fetch.defaultKernelPath()`) so a custom `boot <kernel>` is
never overwritten.

Earlier this used the prebuilt **Kata Containers 3.12.0 arm64 kernel** (Linux
6.1.62) streamed from its ~158 MB `.tar.xz`; that was replaced by our own builds to
drop the large download and the Kata dependency. Distro kernels that ship virtio/9p
as `.ko` modules are a dead end here (module BTF validation + netfs/fscache dep
chains); the `stripbtf` subcommand exists from that era but isn't needed with a
built-in kernel.

## Conventions

- Match the surrounding Zig style; keep comment density similar to the file.
- New emulated devices: implement `read(off,sz)` / `write(off,val,sz)`, wire them
  in `machine.zig` (MMIO window + trampolines + DTB node count via `num_virtio`).
- Keep host attack surface minimal: only file I/O (disk/9p) and the NAT's
  outbound sockets. Don't add host capabilities the guest can reach without a
  clear reason.

## Gotchas (hard-won — read before debugging)

**Windows / workflow**
- A backgrounded `contain` boot holds `contain.exe`, so rebuilds fail with
  `AccessDenied`. Kill first: `Get-Process contain | Stop-Process -Force`, then
  `rm -f zig-out/bin/contain.exe` and rebuild; verify the exe exists.
- PowerShell **drops empty-string `''` arguments** to native programs. Use `-`
  to skip a positional `boot` slot (`isNone` treats `""` and `-` as "none").
- `std.Io.Dir.statFile`/`openFile` with a path **relative to an iterated dir
  handle** fails with `Unexpected` on Windows. The 9p backend stores the share
  base path and builds **full cwd-relative paths** instead.
- A cross-build (`zig build -Dtarget=...`) OVERWRITES `zig-out/bin/contain` —
  rebuild native before running locally (`exec format error` = a stale cross
  binary). On aarch64-macOS the native build re-signs with the HVF entitlement.

**virtio-fs (rootfs-over-virtiofs) invariants**
- The x86 guest has **no working RTC** (emulated CMOS is a fixed time; `rtc_cmos`
  probe fails), so the clock starts near the epoch and **TLS cert validation fails**
  ("certificate not trusted") for apk/pip/npm over HTTPS. The generated init bakes
  `date -s @<host-epoch>` (via `hostEpochSecs`) to set a sane clock — don't remove it.
- **Windows can't create real symlinks** at runtime either: `VirtioFs.opSymlink`
  records a placeholder + `.contain-symlinks` sidecar/map entry (like the OCI unpack)
  instead of a host `symlink()`. Without it, `apk add`/`dpkg` fail EACCES creating
  `.so`-version links. `attrOf`/READLINK/READDIR are symlink-sidecar aware.
- rootfs-over-virtiofs boots via `root=rootfs rootfstype=virtiofs rw rootwait
  init=<per-run-unique>`; the init must `mount devtmpfs /dev` then
  `exec </dev/console >/dev/console 2>&1` (the image `/dev` has no console at exec).

**Device / boot invariants**
- virtio probe (arm64, emulated GICv2) needs **GICv2 ICFGR** (edge/level config),
  and clean power-off + disk writeback needs **PSCI** `SYSTEM_OFF` (HVF's
  `handlePsci`). The accel backend, not `machine.zig`, primes the vCPU boot
  registers (HVF/KVM set PC=kernel, X0=DTB, EL1h+DAIF masked themselves);
  `bootLinux` only loads DTB/kernel/initrd into RAM.

**Zig 0.16 stdlib**
- `Machine`/devices are heap-allocated with `alloc.create`, which **does NOT
  honor struct field defaults** — initialize every field explicitly in `init`
  (a missing `p9 = null` caused a deinit segfault).
- `ArrayListUnmanaged` initializer is `.empty` (not `.{}`).
- `std.Thread.Mutex` is gone here — use a `std.atomic.Value(bool)` spinlock.
- Host sockets (`net/nat.zig`): `Socket.receiveTimeout` returns
  `ConcurrencyUnavailable` (the Init `Io` can't time out), so the NAT reads host
  sockets on **background `std.Thread`s doing plain blocking `receive`**, feeding
  a spinlock-guarded queue drained by `pump()`. For **TCP** use
  `io.vtable.netRead` / `io.vtable.netWrite` (plain `Socket.receive` returns
  `Unexpected` on stream sockets). Networking uses a dedicated
  `std.Io.Threaded` instance.
- 9p `Rgetattr` must emit all 10 trailing u64 time/gen/data_version fields, or
  the mount fails after `Tclunk`.

**Performance invariants (don't regress)**
- **Guest RAM** is allocated from `std.heap.page_allocator` with **no
  `@memset`** (OS demand-zeroes) so host RSS tracks touched pages (~60 MB for a
  boot, not the full window). Don't add an init-time memset.
- Non-interactive `boot` ends with `std.process.exit(0)` after disk writeback —
  joining the NAT reader threads on the way out hangs.

**Networking (NAT) — fixed, don't regress**
- The host->guest TCP path has real flow control + retransmission (`Tcb` in
  `nat.zig`): per-conn `snd_una`/`snd_nxt`/`snd_wnd` + a `sndbuf`, `tcpOutput`
  never sends past `snd_una+snd_wnd`, `tcpAck` frees acked bytes / does dup-ack
  fast-retransmit, and `rtxCheck` (called from `pump`, timed off `now_ns`) resends
  on RTO. The guest's **window scale** is parsed from its SYN (`parseWscale`) so
  windows > 64 KB work. This fixed npm `ETIMEDOUT` on large packages. Validated:
  3 MB HTTP download completes exactly; `npm install systeminformation` succeeds.
  Tests: `nat tcp send respects the guest receive window`, `nat tcp retransmits …`.

**Status**
- **Node.js runs at native speed.** The Alpine+Node image
  (`tools/build_alpine_node.sh`, Node 24.18.0) and the pulled `node:22-alpine` OCI
  image boot and run heavy, diverse JS (V8 JIT + OpenSSL + Wasm) — the guest CPU
  executes natively under the hardware backend. (`npm`'s `/usr/bin/npm` symlink is
  missing from the Alpine image build because it uses apk `--no-scripts`; node
  itself works.)

## Testing changes

Always run `zig build test` (fast, no artifacts needed). For boot-level changes, do
a build and boot `artifacts/Image-arm64` with the default init (default accel on this
host) — it self-tests virtio-blk, 9p, and networking and powers off:
`./zig-out/bin/contain boot artifacts/Image-arm64 artifacts/initramfs.cpio - - artifacts/share`.
A cross-build (`zig build -Dtarget=x86_64-linux` / `aarch64-linux` /
`x86_64-windows`) confirms the KVM/WHP gating still compiles.

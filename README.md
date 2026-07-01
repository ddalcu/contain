# contain

contain is a from-scratch, host-safe Linux sandbox in Zig — a lightweight Docker
alternative for running untrusted code and AI-agent workloads. It runs the guest
on the host's **native hardware virtualization** and reuses its own from-scratch
device models (virtio-blk/9p/net, GIC/IOAPIC, a userspace NAT) on every backend,
so the same code gives a real Linux sandbox across operating systems:

| Host | Backend | Guest |
|---|---|---|
| Apple Silicon (arm64 macOS) | **HVF** (Hypervisor.framework) | arm64 |
| x86 Linux | **KVM** (`/dev/kvm`) | x86-64 |
| x86 Windows | **WHP** (Windows Hypervisor Platform) | x86-64 |

It also pulls and runs public **OCI / Docker Hub images** with a from-scratch
registry client (no docker, skopeo, or external tools). `contain run` is a
**drop-in for `docker run`** — same flags, same syntax:
`contain run node:22-alpine node --version` pulls the real image and runs node
natively. The only host attack surface is file I/O on the disk image / mounted
directories and the NAT's outbound sockets.

Each host runs a native-arch Linux guest (host-ISA == guest-ISA), so the guest CPU
executes natively on the host's hypervisor. The device models, `Bus`, GIC/IOAPIC
and the userspace NAT are entirely from scratch and shared across all three
backends.

## Install

**Linux / macOS — one command:**

```sh
curl -fsSL https://raw.githubusercontent.com/ddalcu/contain/main/install.sh | sh
```

Downloads the latest release binary for your OS/arch and installs it to
`/usr/local/bin` (override with `PREFIX=$HOME/.local/bin`). **Windows:** grab
`contain-windows-x86_64.exe` from the
[Releases](https://github.com/ddalcu/contain/releases) page — it runs as-is. Or
build from source (below); the only dependency is Zig 0.16.

> **Unsigned binaries:** contain isn't code-signed / notarized yet, so a binary
> downloaded through a **browser** may be blocked by Gatekeeper (macOS) or
> SmartScreen (Windows). The `curl | sh` install above avoids this — files fetched
> in a terminal aren't quarantined. If you already downloaded via a browser:
> on macOS run `xattr -d com.apple.quarantine ./contain` (or right-click → Open
> once); on Windows click "More info → Run anyway" on the SmartScreen prompt.

## Quick start

```sh
# 1. Build contain (needs Zig 0.16, the only build dependency).
zig build -Doptimize=ReleaseFast        # -> zig-out/bin/contain

# 2. Run a Docker image — same as `docker run`, but on the host's hypervisor.
#    The lightweight guest kernel auto-fetches on first run (arm64 and x86).
./zig-out/bin/contain run alpine cat /etc/os-release
./zig-out/bin/contain run node:22-alpine node --version
```

`run <image>` pulls a public Docker Hub image (no docker/skopeo needed), then
boots it on the host's hardware backend (KVM on x86 Linux, WHP on Windows, HVF on
Apple Silicon — auto-selected). The first run downloads the image; re-runs reuse it.

### Common usage

```sh
# Interactive shell inside an image
contain run -it alpine

# Run a one-off command (override the image's default)
contain run python:3-alpine python3 -c 'print(2**100)'

# Mount a host directory at a container path (read-write), like docker -v
contain run -v ./myproject:/app node:22-alpine sh -c 'cd /app && npm ci && node app.js'

# Forward a port — a server in the guest becomes reachable on the host
contain run -p 8080:3000 node:22-alpine \
    node -e 'require("http").createServer((_,r)=>r.end("hi")).listen(3000,"0.0.0.0")'
#   then on the host:   curl http://127.0.0.1:8080   ->  hi

# Everything together (an interactive dev sandbox, Docker-style)
contain run -it -p 8080:8080 -v ./code:/app python:3-alpine

# Build an image from a Dockerfile — a drop-in for `docker build`
contain build -t myapp .
contain run myapp

# Run a multi-service compose.yaml — `contain compose up` / `build` / `config`
contain compose up
```

The flags mirror `docker run`:

| flag | meaning |
|---|---|
| `-i`, `-t`, `-it` | interactive shell (attach your terminal); exit the shell to power off |
| `-v <host>:<container>` | mount a host directory at the container path (read-write, via virtio-fs; 9p on arm64) |
| `-p <host>:<guest>` | publish a guest TCP port on the host's `127.0.0.1` (repeatable) |
| `-e <KEY=VALUE>` | set an environment variable (repeatable) |
| `-w <dir>` | working directory for the command |
| `--entrypoint <cmd>` | override the image's entrypoint |
| `IMAGE [CMD...]` | everything after the image is the command (no `--` needed) |

`--rm`, `--name`, and `-u/--user` are accepted for `docker run` compatibility and
ignored (a contain guest is always ephemeral and runs as root); `-d/--detach` is
unsupported (it runs in the foreground).

Only the directory you `-v` and the ports you `-p` cross the sandbox boundary —
everything else the guest does is isolated from the host. To just download an
image's rootfs without running it, use `contain pull <image>`. For full control
(your own kernel + rootfs, a persistent `/dev/vda` disk, scripted input), see
[`contain boot`](#run) below.

## What works

- **Boots a real Linux kernel to a working userspace shell** — arm64 (a custom
  `Image`) under HVF, x86-64 (a custom PVH kernel) under KVM/WHP. Inside the guest:
  fork/exec, pipes, `/proc`, file I/O and busybox/distro applets all work.
- **virtio-mmio + virtio-blk (with host persistence)** — `src/devices/virtio.zig`
  implements the virtio-mmio transport (modern/v2, split virtqueues) and a
  virtio-blk device backed by a **host file**. The guest creates `/dev/vda` and
  disk I/O **persists to the host file across boots**.
- **Live host-directory mounts (virtio-fs / FUSE)** — `src/devices/virtio_fs.zig`
  is a from-scratch virtio-fs device speaking the FUSE low-level protocol; the guest
  `mount -t virtiofs host /host` exposes a **host directory live** with full POSIX
  semantics (proper inodes, symlinks, `fsync`, byte-range locks — SQLite and friends
  work). It's the default share transport on x86; `src/devices/virtio_9p.zig` (a
  9P2000.L device) remains the arm64 default and the `CONTAIN_SHARE_FS=9p` fallback.
- **Memory-efficient rootfs (rootfs over virtio-fs)** — on x86, `contain run` mounts
  the image's rootfs as the guest's real root over virtio-fs and **demand-pages** it
  from the host, instead of packing the whole image into an in-RAM initramfs. Only
  the pages the workload actually touches become resident, so a heavy image runs in a
  fraction of the memory (default guest RAM is 1 GB, `-m` to change).
- **`contain build` and `contain compose`** — `contain build -t name .` builds an
  image from a Dockerfile (`src/build.zig`: FROM/RUN/COPY/ADD/ENV/WORKDIR/CMD/
  ENTRYPOINT/ARG; each RUN executes in a guest over virtio-fs so steps compose).
  `contain compose up` runs a multi-service `compose.yaml` (`src/compose.zig`), each
  service a guest reachable via its published ports **and by service name from other
  services** (inter-service DNS): each service gets a virtual IP that peers resolve
  its name to (via `/etc/hosts`), and the NAT relays a peer's `vip:port` to the host
  port that peer published — so `curl http://web:80` from one service reaches another.
  Each container also gets its **own writable layer** (a per-container overlayfs upper
  over the shared read-only image root), so concurrent containers of the same image
  don't clobber each other's writes.
- **Networking (virtio-net + userspace NAT)** — `src/devices/virtio_net.zig` +
  `src/net/nat.zig` implement a virtio-net device and a slirp-style NAT (ARP, ICMP,
  DHCP, DNS forwarding, and a TCP/UDP relay to the real host network). The guest
  gets an IP, pings the gateway, resolves DNS and **fetches real pages off the
  internet over TCP** (HTTP verified end-to-end, including multi-MB transfers). TLS
  is carried transparently as opaque TCP, so package managers work given a
  TLS-capable userspace.
- **The agent-sandbox workflow** — drive the guest non-interactively (init runs a
  command script), feed a scripted stdin file, or **attach your real terminal** for
  a live shell (`tty` mode). An agent can mount host code, install dependencies over
  the network, and compile/run it in isolation.
- **OCI / Docker Hub images** — `src/oci/registry.zig` does the Docker Hub token
  dance, multi-arch index, gzip-tar layers and whiteouts over `std.http.Client` TLS,
  with no docker, skopeo or external tools; the unpacked rootfs is mounted over
  virtio-fs (x86) or packed into the initramfs (arm64) and booted on the host backend.

## Hardware virtualization (HVF / KVM / WHP)

The same device models, `Bus`, GIC/IOAPIC and NAT run the guest on the host's
native hypervisor — the guest CPU executes natively. The backend is auto-selected
per host (`CONTAIN_ACCEL=hvf|kvm|whp` overrides it). Both guest kernels are
contain's own lightweight builds (`tools/build_kernel.sh`): arm64 hosts boot the
`Image`, x86 hosts boot the PVH `vmlinux` (the `boot` verb detects the ELF and
switches to the x86-microvm platform automatically). Either auto-fetches on first
run; to build + boot a guest kernel by hand:

```sh
# x86 Linux (KVM) or Windows (WHP): build the guest kernel, then boot it.
./tools/build_x86_kernel.sh                 # -> artifacts/kernel-contain-x86_64
./zig-out/bin/contain boot artifacts/kernel-contain-x86_64 artifacts/initramfs-x86.cpio - \
    artifacts/disk.img artifacts/share
```

## Requirements

- **[Zig 0.16.0](https://ziglang.org/download/)** — that's the only build
  dependency. No external cross-toolchain, QEMU, `dtc` or `cpio` is needed.
- Nothing else: the guest kernel (arm64 or x86) auto-fetches in-process on first
  `run`/`boot` — a plain HTTPS GET + gunzip of contain's prebuilt kernel from the
  GitHub release, no external tools. The optional `tools/fetch_artifacts.sh`
  (busybox + demo initramfs for the low-level `boot` demo) uses `curl`, `gzip` and
  `tar`; `tools/build_kernel.sh` (re)builds the kernels and needs Docker.
- The hardware backend's host virtualization must be enabled: KVM (`/dev/kvm`, the
  `kvm` group), WHP (the "Windows Hypervisor Platform" feature), or HVF (the
  hypervisor entitlement; `build.zig` ad-hoc-codesigns on Apple Silicon).

## Build & test

```sh
zig build                          # builds zig-out/bin/contain
zig build test                     # runs the unit tests (16550/GIC/PVH/mptable/NAT)
zig build -Doptimize=ReleaseFast   # faster host device-model/NAT code
./tools/fetch_artifacts.sh         # fetch busybox + build the demo initramfs (kernel auto-fetches)
```

## Run

Boot real Linux with the full sandbox (shell + host-dir mount + networking +
persistent disk):
```sh
./tools/fetch_artifacts.sh
mkdir -p artifacts/share && echo "hello from the host" > artifacts/share/readme.txt
head -c 16777216 /dev/zero > artifacts/disk.img
./zig-out/bin/contain boot artifacts/kernel-contain-arm64 artifacts/initramfs.cpio '' artifacts/disk.img artifacts/share
# the guest boots a 6.1 kernel, mounts the host dir over 9p, gets an IP via the
# NAT, resolves DNS and fetches a page off the internet, and persists /dev/vda.

# drive it like an agent would, by feeding a command script as console input:
printf 'uname -a\nls /host\nwget -O - http://example.com/\n' > cmds.txt
./zig-out/bin/contain boot artifacts/kernel-contain-arm64 artifacts/initramfs.cpio cmds.txt '' artifacts/share
```

**Interactive shell** — put `tty` in the input slot to attach your real
terminal and get a live `/ #` prompt (with `/host` mounted and networking up):
```sh
./zig-out/bin/contain boot artifacts/kernel-contain-arm64 artifacts/initramfs.cpio tty '' artifacts/share
# type commands; `poweroff -f` (or `exit`) leaves and writes the disk back.
```

> **Windows / PowerShell:** PowerShell drops empty `''` arguments to native
> programs, so use `-` to skip a positional slot, e.g.
> `./zig-out/bin/contain boot artifacts/kernel-contain-arm64 artifacts/initramfs.cpio tty - artifacts/share`

**A full Alpine rootfs with Node.js 24** — boot a proper Alpine aarch64
userspace (instead of the busybox-only initramfs) with Node 24 LTS, npm, bash,
curl and ca-certificates preinstalled, and expose a guest server to the host:
```sh
# build the image (run inside a Linux env, as root or via fakeroot — it uses
# apk.static to bootstrap the rootfs and packs it as a gzip initramfs)
./tools/build_alpine_node.sh                 # -> artifacts/alpine-node.cpio.gz

# interactive shell with host port 8080 forwarded to the guest's port 8080
./zig-out/bin/contain boot artifacts/kernel-contain-arm64 artifacts/alpine-node.cpio.gz tty - - 8080
#   inside the guest:  node -e 'require("http").createServer((q,s)=>s.end("hi")).listen(8080,"0.0.0.0")'
#   then on the host:  curl http://127.0.0.1:8080
```

## CLI

```
contain run [OPTIONS] IMAGE [COMMAND] [ARG...]
        pull an image and run it on the host's hardware backend (KVM/WHP/HVF) —
        a drop-in for `docker run`.
          -i, -t, -it, --interactive, --tty   attach an interactive shell
          -p, --publish host:guest            forward a TCP port (repeatable)
          -v, --volume  host:/path            mount a host dir at the container path
          -e, --env     KEY=VALUE             set an env var (repeatable)
          -w, --workdir DIR                   working dir for the command
          --entrypoint  CMD                   override the image entrypoint
          --rm, --name, -u/--user             accepted (ignored) for docker-compat
          -d, --detach                        unsupported (runs in the foreground)

contain pull <image> [dest-dir] [arch]
        pull a public Docker Hub image and unpack its rootfs (from-scratch
        registry client; no docker/skopeo). dest-dir defaults to ./<image>-rootfs;
        arch defaults to the host.

contain boot <kernel> [initramfs] [input] [disk] [share] [ports]
        boot a Linux kernel (arm64 Image, or an x86 vmlinux ELF -> x86-microvm).
          input  - file fed to the guest console (scripted commands), or the
                   literal "tty" to attach your real terminal interactively
          disk   - host file backing /dev/vda (virtio-blk); persisted on exit
          share  - host directory exported via virtio-9p (tag "host")
          ports  - host->guest TCP forwards: "8080", "8080:3000", or a comma
                   list "8080,5173:5173". Each host port is published on
                   127.0.0.1 and bridged to the guest port (QEMU-style hostfwd),
                   so a server the guest runs is reachable from the host.
        (use "" — or "-" on Windows PowerShell — to skip a positional argument)

contain mkinitramfs <busybox> <out.cpio> [extra-file ...]
        build an initramfs from a static busybox; extra files (e.g. kernel
        .ko modules) are added at their basename in /.

CONTAIN_ACCEL=hvf|kvm|whp   override the auto-selected backend.
```

## Layout

```
src/
  main.zig          CLI entry; OCI run + initramfs packing
  machine.zig       the machine: memory map + device wiring (arm64 virt / x86-microvm)
  bus.zig           physical memory bus + MMIO dispatch
  accel/            vCPU backends: hvf, kvm, whp (+ accel.zig dispatcher)
  x86/              PVH boot + MP table for the x86-microvm platform
  devices/          UARTs, GICv2/IOAPIC/PIT/PIC/CMOS, virtio-blk/9p/net/rng
  oci/registry.zig  from-scratch OCI/Docker pull + unpack
  net/nat.zig       userspace slirp-style NAT/TCP-IP stack
tools/              helper scripts (artifacts, x86 kernel build, ...)
```

## Security model

`contain` is a sandbox: the guest is a virtual machine with no access to host
syscalls, devices, or memory. The host surface is deliberately tiny and explicit:

- **Files** — only the disk image you pass (`disk`) and the directory you share
  (`share`) are reachable, and only the paths you name.
- **Network** — the guest's traffic is terminated by the userspace NAT, which
  opens ordinary outbound host sockets (like any client program). The only
  inbound listeners are the host->guest port forwards you explicitly request
  (`ports`), bound to `127.0.0.1`; there is no raw host network access.

This makes it suitable for running untrusted code or AI-agent workloads. It is
*not* a security boundary against host-level exploits of the hypervisor or the
device models themselves — treat it as defense-in-depth, not a vault.

## Performance & footprint

- **Native-speed guest.** The guest CPU runs on the host's hypervisor, so compute
  inside the guest (V8 JIT, OpenSSL, compilers) runs at near-native speed.
- **Idle is cheap.** When the guest is idle it executes `WFI`/`HLT`; the backend
  parks the host thread until the next interrupt or timer deadline, so an idle
  guest costs ~no host CPU.
- **Low memory.** Guest RAM is allocated straight from the OS and demand-zeroed
  (no upfront `memset`), so host RSS tracks what the guest actually touches — a
  full boot + networking demo sits around ~60 MB rather than the full RAM window.
- Non-interactive boots exit promptly once the guest powers off.

## Limitations

- Single core.
- The x86 hardware backends need their guest artifacts built once with
  `tools/build_x86_kernel.sh` (the kernel + a busybox initramfs); it needs `gcc-13`.
  WHP is ~3× slower than KVM (the WHP instruction emulator does several API
  round-trips per MMIO/IO exit) — correct, just not yet optimized.
- The arm64-KVM path is implemented and compile-validated but not yet
  runtime-tested (no arm64 Linux host available).

## Contributing

Issues and PRs welcome. Please:

- Keep `zig build test` green and add a focused test for new behaviour.
- Read [`CLAUDE.md`](CLAUDE.md) — it documents the architecture, the build/run
  commands, and the non-obvious invariants (the IRQ-raise abstraction, the
  Zig 0.16 stdlib quirks, Windows specifics).
- Match the surrounding code style.

## License

[MIT](LICENSE).

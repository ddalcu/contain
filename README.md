# contain

**Run Docker images without Docker.** A single static binary that boots real
Linux VMs on your OS's built-in hypervisor — no daemon, no root, no Docker
Desktop, no dependencies. Written from scratch in Zig.

```sh
contain run node:22-alpine node -e 'console.log("hello from a VM")'
```

That one command pulls the image straight from Docker Hub (its own registry
client — no `docker`, no `skopeo`), boots a real Linux kernel on your machine's
native hypervisor, and runs node **at full native speed** — the guest CPU
executes on the hardware, not in an emulator.

| Your machine | Hypervisor used | It's already on your system |
|---|---|---|
| macOS (Apple Silicon) | Hypervisor.framework (HVF) | ✅ built into macOS |
| Linux (x86-64) | KVM (`/dev/kvm`) | ✅ built into the kernel |
| Windows (x86-64) | Windows Hypervisor Platform | ✅ a features checkbox |

## Why

- **No daemon, no root.** `contain` is one process you run like any other CLI.
  Nothing installs services, nothing runs in the background, nothing needs
  `sudo` (just the `kvm` group on Linux).
- **Stronger isolation than containers.** Every workload gets its own kernel in
  a hardware VM — not a namespaced process sharing your host kernel. The host
  surface is tiny and explicit: the directories you `-v`, the ports you `-p`,
  and outbound sockets from its userspace NAT. Built for running **untrusted
  code and AI agents**.
- **Fast where it counts.** Guest CPU is native (V8, OpenSSL, compilers run at
  hardware speed). Boot-to-workload is well under a second on Apple Silicon. An
  idle guest parks on `WFI`/`HLT` and costs ~no host CPU. A full boot with
  networking sits around **~60 MB of host RAM**.
- **Genuinely from scratch.** The virtio devices (blk/net/9p/fs/rng), the
  GICv2/IOAPIC interrupt controllers, the slirp-style NAT/TCP stack, the OCI
  registry client, the Dockerfile parser, the compose runner — all implemented
  in this repo, in Zig, with zero runtime dependencies. It's a fun codebase to
  read.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ddalcu/contain/main/install.sh | sh
```

Installs the latest release to `/usr/local/bin` (override with
`PREFIX=$HOME/.local/bin`). **Windows:** grab `contain-windows-x86_64.exe` from
[Releases](https://github.com/ddalcu/contain/releases) — it runs as-is.

Or build from source — the only dependency is [Zig 0.16](https://ziglang.org/download/):

```sh
zig build -Doptimize=ReleaseFast    # -> zig-out/bin/contain
```

> Binaries aren't code-signed yet. The `curl | sh` install avoids
> Gatekeeper/SmartScreen prompts; if you downloaded via a browser instead, run
> `xattr -d com.apple.quarantine ./contain` (macOS) or click "More info → Run
> anyway" (Windows).

## Use it like Docker

The flags mirror `docker run`, `docker build`, and `docker compose`:

```sh
# One-off commands in any public Docker Hub image
contain run alpine cat /etc/os-release
contain run python:3-alpine python3 -c 'print(2**100)'

# Interactive shell
contain run -it alpine

# Mount your code (read-write) and use the network — npm, pip, apk all work
contain run -v ./myproject:/app node:22-alpine sh -c 'cd /app && npm ci && node app.js'

# Publish a port
contain run -p 8080:3000 node:22-alpine \
    node -e 'require("http").createServer((_,r)=>r.end("hi")).listen(3000,"0.0.0.0")'
# host:  curl http://127.0.0.1:8080   ->  hi

# Build from a Dockerfile, then run it
contain build -t myapp .
contain run myapp

# Multi-service compose.yaml — services reach each other by name
contain compose up
```

| flag | meaning |
|---|---|
| `-i`, `-t`, `-it` | interactive shell; exit to power off |
| `-v <host>:<container>` | mount a host dir (read-write, virtio-fs / 9p) |
| `-p <host>:<guest>` | publish a guest TCP port on `127.0.0.1` (repeatable) |
| `-e KEY=VALUE` | set an env var (repeatable) |
| `-w <dir>` | working directory |
| `-m <size>` | guest RAM (default 1G) |
| `--entrypoint <cmd>` | override the image entrypoint |

`--rm`, `--name`, `-u` are accepted for compatibility (a contain guest is
always ephemeral and runs as root); `-d/--detach` is unsupported (foreground
only). `contain pull <image>` downloads a rootfs without running it.

## How it works

There is no container runtime underneath — `contain` **is** the runtime:

1. **Pull.** A from-scratch OCI registry client does the Docker Hub token
   dance, picks your architecture from the manifest index, and unpacks the
   gzip-tar layers (whiteouts included) over `std.http.Client` TLS.
2. **Boot.** It boots its own lightweight Linux kernel (auto-fetched once,
   ~11 MB) on the host hypervisor — HVF, KVM, or WHP, auto-selected. The
   device models (virtio-blk/net/fs/9p/rng, UART, GICv2/IOAPIC) are shared
   across all three backends.
3. **Run.** On x86 the image rootfs is mounted over virtio-fs and
   **demand-paged** from the host — only the files the workload actually
   touches use memory. Networking is a userspace slirp-style NAT: DHCP, DNS,
   and a real TCP stack with flow control and retransmission, so large
   `npm install`s just work. Compose services get virtual IPs, name resolution,
   and a private writable overlay each.

Each host runs a native-arch guest (host-ISA == guest-ISA), so hardware
acceleration always applies. `CONTAIN_ACCEL=hvf|kvm|whp` overrides the backend.

## Security model

The guest is a hardware VM with its own kernel — no shared host kernel, no
host syscalls, no host devices. What crosses the boundary is exactly what you
ask for:

- **Files:** only the directories you `-v` (and the disk file you pass to
  `boot`), nothing else.
- **Network:** guest traffic terminates in the userspace NAT, which opens
  ordinary outbound host sockets like any client program. Inbound is only the
  `-p` ports you publish, bound to `127.0.0.1`. No raw host network access.

That makes it a good fit for untrusted code and AI-agent workloads. It is
*not* a formally audited boundary — treat it as strong defense-in-depth, not a
vault.

## Advanced: `contain boot`

For full control — your own kernel and initramfs, a persistent `/dev/vda`
disk image, scripted console input, host-dir shares, port forwards:

```sh
contain boot <kernel> [initramfs] [input] [disk] [share] [ports]
#   input:  a file of commands fed to the console, or "tty" for a live shell
#   disk:   host file backing /dev/vda (persists across boots)
#   share:  host directory mounted in the guest
#   ports:  "8080" or "8080:3000,5173:5173" host->guest TCP forwards
# ("-" skips a slot)
```

```sh
./tools/fetch_artifacts.sh     # busybox demo initramfs (kernel auto-fetches)
./zig-out/bin/contain boot artifacts/kernel-contain-arm64 artifacts/initramfs.cpio tty - artifacts/share
```

`tools/build_kernel.sh` rebuilds the guest kernels (needs Docker);
`contain mkinitramfs <busybox> <out.cpio>` builds a minimal initramfs.

## Build & test

```sh
zig build                          # debug build
zig build test                     # unit tests
zig build -Doptimize=ReleaseFast   # release build
zig build lib                      # embeddable C library (libcontain.a + contain.h)
```

The C library (`zig build lib`) embeds the whole sandbox in another app —
start a VM on a background thread, feed it console input, get output via a
callback. See `include/contain.h` and `examples/smoke.c`.

## Limitations

- Single vCPU per guest (for now).
- Public registries only (no auth yet).
- `-d/--detach` is unsupported; guests run in the foreground.
- The arm64-Linux KVM path is implemented but not yet runtime-validated.
- WHP (Windows) is correct but ~3× slower than KVM on MMIO-heavy work.

## Contributing

Issues and PRs welcome. Keep `zig build test` green, add a focused test for
new behavior, and read [`CLAUDE.md`](CLAUDE.md) for the architecture notes and
the non-obvious invariants before touching the device models.

## License

[MIT](LICENSE)

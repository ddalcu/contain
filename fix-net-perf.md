# Plan: fix NAT networking (npm ETIMEDOUT) + remaining JIT/Tier-3 work

> ## STATUS (2026-06-29)
> **1. Network — DONE & shipped (commit efcad80).** Real host→guest TCP flow
> control + retransmission + window-scale parsing in `src/net/nat.zig`, plus a
> dedicated `net_service_period` cadence so RX isn't starved. Validated: a 3 MB
> HTTP download completes exactly, and `npm install systeminformation` (the
> repro) succeeds. See CLAUDE.md "Networking (NAT) — fixed".
>
> **2. JIT — substantially expanded & validated; kept opt-in (commits 9177dcc,
> later).** Added LDR/STR (uimm int, helper-call), B.cond, logical (incl
> BIC/ORN + shifts + XZR/MOV-reg), MADD/MSUB/MUL/MNEG, MOVN/MOVK, BL/BR/BLR/RET,
> TBZ/TBNZ, and all 32-bit (W) forms. Boots Linux + runs Node **byte-identical to
> the interpreter** (`CONTAIN_JIT=1`), ~9x on `contain jitbench`. Fixed a 32-bit
> zero-extend store bug + SMC marking in `peekInsn`. Added `CONTAIN_JIT_STATS`
> (block-breaking histogram).
> **Finding (measured, decisive):** the memory-form JIT is ~4.5x *slower* than the
> tuned interpreter on real code (boot+node: ~24 vs ~109 MIPS), byte-identical,
> and this is **architectural, not a coverage gap**. Proof: I added a lot of
> integer coverage this session — STP/LDP + SP-relative loads/stores/ADD — which
> cut JIT fallbacks 622M -> 255M and grew avg block length 2.04 -> 2.62, yet
> JIT-on perf stayed at **24 MIPS, unchanged**. So coverage alone buys nothing.
> The cost is per-instruction: every memory op (42% of instructions) is a C-ABI
> helper CALL, and every op is load-op-store to the Cpu struct (no register
> allocation). Contrast `jitbench` (pure-ALU, no memory, one long block) where the
> same JIT hits 1140 MIPS — i.e. the JIT is only fast on long, memory-free,
> fallback-free blocks, which real code never sustains (branches + ~1/3 unhandled
> ops keep blocks ~2-3 insns).
> **BREAKTHROUGH (later in the session): the dominant cost was compile thrash, not
> the per-instruction model.** `CONTAIN_JIT_STATS` showed **35.9M block compiles**
> on a boot+node run — the JIT was recompiling cold, run-once code constantly
> (each compile reads up to 64 insns + emits x86), a tax the interpreter never
> pays. Adding a **hotness gate** (interpret a block until its entry VA has run
> `hot_threshold`=32 times, then compile once) cut compiles 35.9M -> 1.5M and took
> **JIT-on from ~22 -> ~87 MIPS (4x)**, byte-identical. Plus a direct-mapped block
> cache (O(1) flush) and an inline TLB load fast path.
> **Current state:** JIT-on ~87 vs interpreter ~108 MIPS — near parity (was ~4.5x
> slower). The remaining ~8 cyc/insn gap is per-block call+frame+dispatch overhead
> at ~2.5-insn blocks. To make the JIT *beat* the interpreter (and be enabled by
> default) still needs **block chaining** (eliminate the per-block round-trip) and
> **register allocation** (eliminate load-op-store; pays off once chaining keeps
> values in regs across loop iterations) — these two reinforce each other. That is
> the remaining work for a real default-on JIT win; the hotness gate made the JIT
> viable (cold code now stays interpreted, so JIT-on no longer regresses cold/
> run-once code catastrophically).
> **Decision:** JIT still opt-in until it beats the interpreter (chaining+regalloc);
> interpreter optimized in the meantime (the shipped win).
>
> **3. Interpreter — optimized, ~20% faster on real boot+node (committed).** The
> production path. Cumulative **~89 -> 107 MIPS**, all byte-identical (validated
> incl. fork/COW + blk/9p/net + clean poweroff):
>   - batched `run` loop (service devices per-batch, not per-instruction),
>   - **inline TLB-hit fast path in `memRead`/`memWrite`** (the big one, ~11%;
>     memory is ~42% of instructions) — preserves the exact permission/COW + SMC
>     checks,
>   - decoded-cache arms for the hottest leaf forms: integer LDR/STR uimm
>     (`.ldst_uimm`) and STP/LDP (`.ldst_pair`),
>   - `CONTAIN_PROFILE=1` execution profiler used to target the above.
>   Remaining cost is the memory access itself + a long tail of leaf forms; further
>   interpreter gains are incremental. The only large remaining lever is the
>   register-allocating JIT rewrite.

Handoff doc for a fresh-context agent. Two independent workstreams:
1. **Network** — the userspace NAT never did large transfers reliably; npm
   `ETIMEDOUT` on bigger packages (e.g. `npx systeminformation`). This is the
   priority.
2. **JIT / Tier 3** — what's done and what's left to reach "huge" gains on real
   boot/Node workloads (not just the microbenchmark).

Build/test as usual: `zig build test` (fast, no artifacts), and for boot-level
changes `zig build -Doptimize=ReleaseFast` then boot `artifacts/Image-arm64` with
`artifacts/node-min.cpio`. See CLAUDE.md.

---

## 1. NETWORK — root cause (confirmed by reading `src/net/nat.zig`)

The NAT (`src/net/nat.zig`) is a slirp-style userspace relay. Host sockets are
read on background threads (`readerThread`) into an `inbound` queue; `pump()`
drains it and turns received bytes into guest TCP segments via `sendStream`,
which are queued as ethernet frames in `self.rx` and delivered to the guest's
virtio-net RX ring by `deliverRx()` (`src/devices/virtio_net.zig`).

**The bug: the host→guest TCP path has no flow control and no retransmission.**

- `TcpConn` / `InConn` (nat.zig ~line 67, ~108) track only `our_seq` (next seq we
  send) and `recv_next` (next seq we expect from the guest). There is **no
  `snd_una`** (highest seq the guest has ACKed) and **no send buffer** of
  unacked data.
- Both guest-TCP handlers **discard the guest's ACK number**: `handleInboundTcp`
  starts with `_ = ack;` (nat.zig:223) and the outbound `handleTcp` (nat.zig:535)
  never uses the ack field or the guest's advertised window either.
- `sendStream` (nat.zig:382) just loops, emitting `<=tcp_mss` (1400-byte)
  PSH|ACK segments and advancing `*seq`, **as fast as `pump()` runs**, with no
  regard for the guest's receive window and no record of what was sent.

Consequence: on a large/fast download the NAT emits segments far beyond the
guest's TCP receive-window edge. The guest's TCP stack **discards** out-of-window
segments (correct per RFC) and keeps ACKing the same in-window edge. The NAT,
not tracking ACKs, never notices and **never retransmits** the discarded data →
a permanent sequence gap → the guest's socket read stalls → npm reports
`read ETIMEDOUT` / "Invalid response body". Small responses fit inside the
initial window in one burst, so they work — which is why small installs and DNS
are fine but `systeminformation` (larger packument + tarball) fails.

Secondary factor (made it worse recently): `housekeep_period` in `src/cpu.zig`
was raised 64→1024 for interpreter perf. `net.service()` (NAT `pump()` +
`deliverRx()`) runs from `updateIrqs` once per housekeeping pass, so RX is now
serviced ~16x less often (~12 µs vs ~0.8 µs). That reduces host→guest throughput
and widens the stall window. Not the root cause, but relevant.

Other minor issues noted while reading:
- `poll()` (nat.zig:295) returns one frame per call via `orderedRemove(0)` —
  O(n) shifting of the `rx` ArrayList; fine for now, but a ring/eat-from-head
  index would be cheaper under load.
- `enqueue()` (nat.zig:287) silently drops frames larger than `Frame.data`
  (1600 B). `sendStream` already splits to <=MSS so this shouldn't trigger, but
  keep the invariant if MSS/MTU changes.
- The NAT advertises a fixed 64240-byte window to the guest (`sendTcp`,
  nat.zig ~line 644: `wbe16(t[14..16], 64240)`) and ignores TCP options, so it
  also ignores the guest's **window scale** — see step 2 below.

---

## 1a. NETWORK — the fix (a minimal real TCP sender, host→guest)

Implement proper send-side flow control + retransmission per connection. Do it
for the **outbound** path first (`TcpConn`, the npm/guest-is-client case — that's
the repro), then mirror to `InConn` (host→guest port forwarding).

### State to add to `TcpConn` (and later `InConn`)
- `snd_una: u32` — oldest unacknowledged seq (start = ISN+1 after handshake).
- `snd_nxt: u32` — next seq to send (replaces ad-hoc `our_seq` advancement).
- `snd_wnd: u32` — guest's advertised receive window (bytes), updated from every
  guest segment's window field × the guest's window-scale (see options below).
- `sndbuf: std.ArrayListUnmanaged(u8)` — unacked + not-yet-sent host bytes,
  indexed so `sndbuf[0]` corresponds to seq `snd_una`.
- `rtx_deadline` / `rtx_pending: bool` — retransmission timer (see timing below).
- `dup_acks: u8` — for fast retransmit (optional, nice-to-have).

### Data flow changes
1. **Receive from host** (`pump`, the `.tcp` case): instead of calling
   `sendStream` immediately, **append `item.data` to `conn.sndbuf`** and then call
   a new `tcpOutput(conn)`.
2. **`tcpOutput(conn)`**: send the window of unsent data, i.e. bytes in
   `sndbuf` whose seq is in `[snd_nxt, snd_una + snd_wnd)`, as `<=tcp_mss`
   PSH|ACK segments, advancing `snd_nxt`. If nothing is in flight and there is
   unsent data, arm the RTO. Never advance past `snd_una + snd_wnd`.
3. **Guest ACK handling** (in `handleTcp` / `handleInboundTcp` — stop discarding
   `ack`): when a guest segment arrives,
   - update `snd_wnd` from its window field (apply window scale),
   - if `ack` is in `(snd_una, snd_nxt]`: drop `ack - snd_una` bytes from the
     front of `sndbuf`, set `snd_una = ack`, reset `dup_acks`, re-arm/disarm RTO,
     then `tcpOutput(conn)` to send newly-in-window data.
   - if `ack == snd_una` and it's a pure dup-ack: `dup_acks += 1`; on the 3rd,
     fast-retransmit (set `snd_nxt = snd_una`, `tcpOutput`).
4. **Retransmission timeout**: in `pump()` (runs periodically), if `rtx_pending`
   and the deadline passed and `snd_una != snd_nxt`, set `snd_nxt = snd_una`,
   re-`tcpOutput`, and back off the RTO (double it, capped). On any ACK that
   advances `snd_una`, reset RTO to the base.
   - Timing source: `pump()` has no insn_count, but `Nat` has `io`. Use
     `std.Io.Clock.now(.awake, io).nanoseconds` for deadlines (already used by
     the RTC and the boot timer). Base RTO ~200 ms, cap ~2 s. Avoid per-segment
     timers; one timer per connection keyed on the oldest unacked segment is
     enough.

### TCP options / window scale (needed for throughput > 64 KB)
- The guest's SYN carries a **window scale** option; Linux uses it and grows the
  window into the hundreds of KB / MB. To pace host→guest correctly you must read
  the guest's wscale from its SYN and apply it to every advertised window:
  `snd_wnd = raw_window << guest_wscale`.
- Parse TCP options in the SYN handler (walk the options between byte 20 and
  `data_off*4`): kind 3 = window scale (len 3, value = shift). Store
  `guest_wscale` on the connection (default 0 if absent).
- You should also **advertise window scaling in the NAT's own SYN/SYN-ACK** if
  you want the guest→host direction to use large windows, but that direction
  already works (small ACKs/requests), so it's optional.

### Don't-break checklist
- DNS (UDP) path is unaffected — leave `sendUdp`/UDP sessions alone.
- The handshake (SYN/SYN-ACK/ACK) and FIN/RST handling must keep working; only
  the *data* send path changes. Initialize `snd_una = snd_nxt = ISN+1` at
  establish.
- Guest→host data path (guest sends, NAT writes to host socket) already works;
  optionally add out-of-order buffering there too, but TCP rarely reorders on a
  loopback-ish path, so defer.

### Also do (cheap, complementary)
- **Decouple network servicing from `housekeep_period`.** Service the NAT
  (`pump` + `deliverRx`) on a *shorter* cadence than the timer/GIC housekeeping,
  so the 1024 CPU-perf setting doesn't starve RX. Options: (a) add a separate
  `net_service_period` (~128) counter in `Cpu.step`/`runJit` that calls a
  lightweight net-only hook, or (b) split `updateIrqs` (machine.zig) into a
  frequent net part and an infrequent timer/GIC part. Measure: this alone may
  noticeably help even before full flow control.
- Consider making `poll`/`rx` a head-indexed ring to avoid O(n) `orderedRemove`.

### How to validate
- Repro: in the guest, `npx systeminformation` (or `npm i systeminformation`).
  Currently `ETIMEDOUT`; must complete after the fix.
- Throughput: `wget`/`node` a few-MB file over the NAT; should sustain, not stall.
- Regression: small `npm i <tiny-pkg>`, DNS (`node -e "require('dns').lookup
  ('example.com',...)"` → resolves), host→guest port forward (the `InConn` path).
- Use the differential method from CLAUDE.md if a specific transfer corrupts.

### Risk
TCP seq/window arithmetic (u32 wraparound — use wrapping compares `a -% b`),
window-edge off-by-ones, and RTO churn. Build incrementally: get ACK tracking +
windowed send working first (fixes the overrun), then add RTO retransmission
(fixes any genuine loss). Keep verifying small downloads + DNS each step.

---

## 2. JIT / TIER 3 — current state and what's left

The JIT (`src/jit.zig`) translates guest aarch64 basic blocks to native x86-64.
It is gated by `Cpu.jit: ?*Jit` (default `null` → interpreter only → boot
untouched). `contain jitbench` measures it: **~9–10x** on a hot integer loop
(interpreter ~148 MIPS, JIT ~1300–1480 MIPS), results bit-identical.

### Done (committed, validated against the interpreter)
- Executable memory on Windows (`VirtualAlloc`, `callconv(.winapi)`; x86-64 is
  I-cache-coherent for same-thread write-then-run, so no flush).
- x86-64 `Emitter` + `compileBlock`: MOVZ, ADD/SUB imm, ADD/SUB shifted-reg
  (shift 0), ADDS/SUBS/CMP (NZCV via x86 `setcc`; SUB carry = `SETNC`), and the
  block terminators B / CBZ / CBNZ (return the next guest VA; `b .` sets
  `halted`). X0..X30 only (X31/SP/XZR → interpreter).
- Reg/flag/halted offsets via `@offsetOf(Cpu, ...)` — **Zig reorders struct
  fields, so `x` is NOT at offset 0**; never assume.
- `Jit` block cache keyed by `dec_gen` (so TLBI/SMC flush via `decFlush` also
  flushes blocks), `Cpu.runJit` dispatcher (native block → fall back to `step()`
  for anything unhandled; housekeeping/IRQ serviced at block boundaries),
  `Cpu.peekInsn` (side-effect-free read for compiling).
- Tests in `jit.zig`: exec-memory PoC, ALU block == interpreter, CBNZ loop ==
  interpreter.

### Left to do, in priority order (each must stay byte-identical to the interpreter)
1. **Loads/stores (LDR/STR)** — the unlock for real code (boot/Node hit memory
   every few instructions). Emit a CALL into a C-ABI helper wrapping
   `memRead`/`memWrite`, then check `Cpu.aborted` after the call and bail out of
   the block (return current `pc`) if an abort/exception was taken.
   - Win64 ABI: this needs a stack frame and to preserve the Cpu base across the
     call. Simplest: switch the block base register from RCX to a callee-saved
     reg (RBX): prologue `push rbx; mov rbx,rcx; sub rsp,0x28` (shadow space +
     16-align), epilogue `add rsp,0x28; pop rbx; ret`, and change all
     `[rcx+disp]` ModRMs (0x81/0x91/0x83…) to RBX-based (rm=011). Then args go in
     RCX/RDX/R8 for the helper call.
   - Start with the unsigned-offset integer forms (`ldstUimm`, opc 00/01); defer
     SIMD/FP loads, pair, pre/post-index to the interpreter.
2. **`B.cond`** — translate the ARM condition (from the stored N/Z/C/V bytes) to
   an x86 test + `cmov` selecting taken vs fallthrough VA (like CBZ/CBNZ). This
   keeps flag-driven loops (the common V8/tsc shape) inside the JIT.
3. **More ALU + 32-bit**: MOVN/MOVK, logical shifted-reg (AND/ORR/EOR/ANDS),
   shifts (LSLV/LSRV/ASRV and immediate), MADD/MUL, and the `sf==0` (32-bit)
   variants (use 32-bit x86 ops; result zero-extends into the 64-bit store).
4. **Block chaining**: when a block's branch target is an already-compiled block,
   emit a direct `jmp` to it instead of returning to the dispatcher — removes the
   per-iteration hashmap lookup + call overhead (the current ~10x is *with* that
   overhead; chaining pushes it higher).
5. **Guest→host register allocation**: today blocks are memory-form
   (load/op/store per instruction). Keeping hot guest regs in host registers
   across a block is the big remaining multiplier. Do a simple linear-scan over
   the block's referenced registers.
6. **Enable by default**: once boot + node run **bit-identical** with the JIT on
   (compare final state / output vs interpreter), set `Cpu.jit` in
   `machine.init` (and/or a CLI/env flag). Until then keep it opt-in.

### JIT correctness invariants (don't regress)
- SMC: a store to a page we've executed from must invalidate blocks. Already
  handled — `smcCheck` bumps `dec_gen`; the block cache keys on `dec_gen`.
- IRQ delivery must stay prompt enough for shutdown (`poweroff`). The dispatcher
  services IRQ at block boundaries; keep blocks bounded (currently <=64 insns).
- The interpreter remains the source of truth; every JIT addition is validated
  against it before being trusted.

### How to validate the JIT
- `contain jitbench` for the speedup number.
- Per-feature: extend the `jit.zig` tests (compile a program exercising the new
  op, run via the dispatcher, compare registers/flags/memory to `Cpu.step`).
- Before enabling by default: boot `node-min.cpio` with JIT on and confirm the
  self-test output + `node` results are identical to JIT off.

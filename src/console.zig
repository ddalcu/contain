//! Pluggable guest-console output sink.
//!
//! The CLI writes guest console bytes straight to the host's stdout. When
//! `contain` is embedded as a library (e.g. inside a sandboxed Swift app driving
//! an AI coding agent), there is no shared stdout to scribble on — each VM's
//! output must be delivered to the embedder. `OutSink` is the seam: the UART
//! devices emit through it, and a null `write_fn` falls back to stdout so the CLI
//! behaviour is unchanged.
//!
//! The callback uses the C calling convention so it can be a Swift/Obj-C/C
//! function pointer handed across the `src/capi.zig` boundary verbatim.

/// A C-ABI byte sink. `write_fn(ctx, data, len)` receives one chunk of guest
/// console output; `ctx` is the embedder's opaque context. A default-constructed
/// sink (`.{}`) has a null `write_fn`, which `emit` reports as "not handled" so
/// the caller can fall back to stdout.
pub const OutSink = struct {
    ctx: ?*anyopaque = null,
    write_fn: ?*const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void = null,

    /// Deliver `bytes` to the sink. Returns true if a callback handled them, or
    /// false (no callback installed) so the device can fall back to stdout.
    pub fn emit(self: OutSink, bytes: []const u8) bool {
        if (self.write_fn) |f| {
            if (bytes.len != 0) f(self.ctx, bytes.ptr, bytes.len);
            return true;
        }
        return false;
    }
};

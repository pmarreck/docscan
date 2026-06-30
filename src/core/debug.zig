//! Debug tracing port for failure analysis ("why did extraction return nothing?").
//!
//! Pure and wasm-safe: native builds emit `[docscan] …` trace lines to stderr when
//! enabled; the `wasm32-freestanding` slice comptime-elides the whole thing (it has no
//! stderr and must stay zero-import). Toggle from the CLI via the `docscan_set_debug`
//! FFI when `DOCSCAN_DEBUG=1`. The core never reads env or owns I/O — it only emits
//! through this port, keeping the hexagonal boundary intact.
const std = @import("std");
const builtin = @import("builtin");

/// stderr tracing is only meaningful off wasm-freestanding. Comptime-known, so the
/// `trace` body below is removed entirely from the wasm build (std.debug.print is never
/// instantiated → no stderr dependency, no added imports).
const trace_supported = builtin.target.os.tag != .freestanding;

var enabled: bool = false;

/// Enable/disable debug tracing. Called from the FFI (`docscan_set_debug`). Harmless on
/// wasm — `trace` is comptime-elided there regardless of this flag.
pub fn setEnabled(on: bool) void {
	enabled = on;
}

pub fn isEnabled() bool {
	return enabled;
}

/// Emit one trace line to stderr when enabled. On wasm-freestanding this compiles to a
/// no-op (the `if (trace_supported)` block is comptime-eliminated).
pub fn trace(comptime fmt: []const u8, args: anytype) void {
	if (trace_supported) {
		if (enabled) std.debug.print("[docscan] " ++ fmt ++ "\n", args);
	}
}

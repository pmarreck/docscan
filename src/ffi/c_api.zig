//! C FFI boundary for docscan.
//! All exported functions use C calling convention and flat C types.
//! This is the public API that the C CLI and any external consumers call.

/// Return the docscan version string as a null-terminated C string.
export fn docscan_version() [*:0]const u8 {
	return "0.1.0";
}

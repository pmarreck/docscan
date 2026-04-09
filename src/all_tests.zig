//! Aggregated test entry point for docscan.
//! Import every module that contains tests here so `zig build test`
//! discovers them all in a single pass.

test {
	_ = @import("core/document.zig");
	_ = @import("core/parser_md.zig");
}

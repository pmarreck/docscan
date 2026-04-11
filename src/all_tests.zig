//! Aggregated test entry point for docscan.
//! Import every module that contains tests here so `zig build test`
//! discovers them all in a single pass.
//!
//! NOTE: FFI tests live in a separate test target (ffi_tests) because
//! c_api.zig uses @import("core") (a named module), while this file
//! imports core files directly. Zig does not allow a file to exist in
//! two modules simultaneously.

test {
	_ = @import("core/document.zig");
	_ = @import("core/parser_md.zig");
	_ = @import("core/xml.zig");
	_ = @import("core/zip.zig");
	_ = @import("core/parser_docx.zig");
	_ = @import("core/pdf_objects.zig");
	_ = @import("core/parser_pdf.zig");
	_ = @import("core/ole2.zig");
	_ = @import("core/parser_doc.zig");
	_ = @import("core/parser_rtf.zig");
	_ = @import("core/parser_epub.zig");
	_ = @import("core/chunker.zig");
	_ = @import("core/storage.zig");
	_ = @import("core/search.zig");
	_ = @import("core/ignore.zig");
	_ = @import("core/encoding.zig");
}

//! Aggregated test entry point for docscan.
//! Import every module that contains tests here so `zig build test`
//! discovers them all in a single pass.

test {
	_ = @import("core/document.zig");
	_ = @import("core/parser_md.zig");
	_ = @import("core/xml.zig");
	_ = @import("core/zip.zig");
	_ = @import("core/parser_docx.zig");
	_ = @import("core/pdf_objects.zig");
	_ = @import("core/parser_pdf.zig");
}

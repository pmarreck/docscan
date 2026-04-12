//! Core module root — re-exports all docscan core sub-modules.
//! This file exists so the "core" module can provide access to
//! document types, parsers, chunker, storage, and search from a
//! single import in the FFI layer.

pub const document = @import("document.zig");
pub const storage = @import("storage.zig");
pub const search = @import("search.zig");
pub const chunker = @import("chunker.zig");
pub const parser_md = @import("parser_md.zig");
pub const parser_docx = @import("parser_docx.zig");
pub const parser_pdf = @import("parser_pdf.zig");
pub const parser_doc = @import("parser_doc.zig");
pub const parser_rtf = @import("parser_rtf.zig");
pub const parser_epub = @import("parser_epub.zig");

// Internal sub-modules re-exported for test discovery
pub const xml = @import("xml.zig");
pub const zip = @import("zip.zig");
pub const pdf_objects = @import("pdf_objects.zig");
pub const ole2 = @import("ole2.zig");
pub const ignore = @import("ignore.zig");
pub const encoding = @import("encoding.zig");
pub const wordfix = @import("wordfix.zig");

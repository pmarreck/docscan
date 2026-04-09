//! Document model types for docscan.
//! All types are pure data — no I/O, no allocations in the structs themselves.
//! The Zig core operates on these types; the C FFI boundary translates them
//! to/from flat C representations.

const std = @import("std");

/// Supported document formats for parsing and indexing.
pub const Format = enum {
	md,
	docx,
	pdf,
	doc,
	rtf,

	/// Return the file extension string (without dot) for this format.
	pub fn extension(self: Format) []const u8 {
		return switch (self) {
			.md => "md",
			.docx => "docx",
			.pdf => "pdf",
			.doc => "doc",
			.rtf => "rtf",
		};
	}

	/// Attempt to detect format from a file extension string (without dot).
	pub fn fromExtension(ext: []const u8) ?Format {
		const lower = ext;
		if (std.mem.eql(u8, lower, "md") or std.mem.eql(u8, lower, "markdown")) return .md;
		if (std.mem.eql(u8, lower, "docx")) return .docx;
		if (std.mem.eql(u8, lower, "pdf")) return .pdf;
		if (std.mem.eql(u8, lower, "doc")) return .doc;
		if (std.mem.eql(u8, lower, "rtf")) return .rtf;
		return null;
	}
};

/// A key-value metadata entry extracted from a document (author, date, subject, etc.).
pub const MetadataEntry = struct {
	key: []const u8,
	value: []const u8,
};

/// A hierarchical section within a document, supporting recursive nesting.
/// Level 0 = document root, 1 = top-level heading, 2 = sub-heading, etc.
pub const Section = struct {
	heading: ?[]const u8,
	level: u8,
	content: []const u8,
	children: []const Section,
	page: ?u32 = null, // starting page number (1-based, PDF)
	source_line: ?u32 = null, // starting line number (1-based, markdown)
};

/// A parsed document with structural metadata — the output of any format parser.
/// All slices are borrowed from the parser's arena; do not use after the arena is freed.
pub const Document = struct {
	path: []const u8,
	format: Format,
	title: ?[]const u8,
	metadata: []const MetadataEntry,
	sections: []const Section,
};

/// A text chunk derived from document sections, ready for embedding.
/// Carries structural context (section breadcrumb path) so search results
/// can report where in the document the match occurred.
pub const Chunk = struct {
	document_path: []const u8,
	section_path: []const u8,
	heading: ?[]const u8,
	text: []const u8,
	start_byte: u64,
	end_byte: u64,
	chunk_index: u32,
	page: ?u32 = null, // page number (1-based, PDF)
	source_line: ?u32 = null, // line number (1-based, markdown)
};

/// A search result combining vector similarity and lexical BM25 scores
/// via Reciprocal Rank Fusion (RRF).
pub const SearchResult = struct {
	document_path: []const u8,
	document_title: ?[]const u8,
	section_path: []const u8,
	heading: ?[]const u8,
	text: []const u8,
	score: f32,
	vector_score: f32,
	lexical_score: f32,
	page: ?u32 = null, // page number (1-based, PDF)
	source_line: ?u32 = null, // line number (1-based, markdown)
};

// ── Tests ──────────────────────────────────────────────────────────────

test "Format.extension round-trips" {
	const cases = [_]struct { fmt: Format, ext: []const u8 }{
		.{ .fmt = .md, .ext = "md" },
		.{ .fmt = .docx, .ext = "docx" },
		.{ .fmt = .pdf, .ext = "pdf" },
		.{ .fmt = .doc, .ext = "doc" },
		.{ .fmt = .rtf, .ext = "rtf" },
	};
	for (cases) |c| {
		try std.testing.expectEqualStrings(c.ext, c.fmt.extension());
		try std.testing.expectEqual(c.fmt, Format.fromExtension(c.ext).?);
	}
}

test "Format.fromExtension returns null for unknown" {
	try std.testing.expectEqual(null, Format.fromExtension("txt"));
	try std.testing.expectEqual(null, Format.fromExtension("xlsx"));
	try std.testing.expectEqual(null, Format.fromExtension(""));
}

test "Format.fromExtension accepts markdown alias" {
	try std.testing.expectEqual(Format.md, Format.fromExtension("markdown").?);
}

test "Section can be constructed with children" {
	const child = Section{
		.heading = "Subsection",
		.level = 2,
		.content = "child content",
		.children = &.{},
	};
	const parent = Section{
		.heading = "Top",
		.level = 1,
		.content = "parent content",
		.children = &.{child},
	};
	try std.testing.expectEqual(@as(usize, 1), parent.children.len);
	try std.testing.expectEqualStrings("Subsection", parent.children[0].heading.?);
}

test "Document can hold metadata entries" {
	const meta = [_]MetadataEntry{
		.{ .key = "author", .value = "Peter" },
		.{ .key = "date", .value = "2026-04-08" },
	};
	const doc = Document{
		.path = "/test/doc.md",
		.format = .md,
		.title = "Test Doc",
		.metadata = &meta,
		.sections = &.{},
	};
	try std.testing.expectEqual(@as(usize, 2), doc.metadata.len);
	try std.testing.expectEqualStrings("author", doc.metadata[0].key);
	try std.testing.expectEqualStrings("Peter", doc.metadata[0].value);
}

test "Chunk fields are accessible" {
	const chunk = Chunk{
		.document_path = "/test/doc.pdf",
		.section_path = "Section 1 > 1.1",
		.heading = "Introduction",
		.text = "Lorem ipsum dolor sit amet.",
		.start_byte = 0,
		.end_byte = 27,
		.chunk_index = 0,
	};
	try std.testing.expectEqual(@as(u64, 27), chunk.end_byte);
	try std.testing.expectEqualStrings("Introduction", chunk.heading.?);
}

test "SearchResult fields are accessible" {
	const result = SearchResult{
		.document_path = "/test/contract.docx",
		.document_title = "Service Agreement",
		.section_path = "Section 4 > 4.2",
		.heading = "Indemnification",
		.text = "The party shall indemnify...",
		.score = 0.95,
		.vector_score = 0.92,
		.lexical_score = 0.88,
	};
	try std.testing.expect(result.score > result.vector_score);
	try std.testing.expectEqualStrings("Indemnification", result.heading.?);
}

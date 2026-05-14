//! DOCX parser for docscan.
//! Extracts text with heading-aware section structure from .docx files.
//! A .docx file is a ZIP archive containing XML files; this module
//! extracts `word/document.xml`, parses it with the XML parser, and
//! builds a hierarchical Document with heading-based sections.
//! Optionally extracts metadata from `docProps/core.xml`.
//! Pure computation — no I/O. Receives byte slices, returns a Document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wordfix = @import("wordfix.zig");
const document = @import("document.zig");
const Document = document.Document;
const Section = document.Section;
const MetadataEntry = document.MetadataEntry;
const Format = document.Format;
const xml = @import("xml.zig");
const zip = @import("zip.zig");

/// A flat section before nesting is applied.
const FlatSection = struct {
	heading: ?[]const u8, // owned, must be freed
	level: u8,
	content_buf: std.ArrayList(u8),
	page: u32 = 1, // 1-based page number at start of this section

	fn deinit(self: *FlatSection, gpa: Allocator) void {
		if (self.heading) |h| gpa.free(h);
		self.content_buf.deinit(gpa);
	}
};

/// Map a DOCX paragraph style name to a heading level.
/// Returns null if the style is not a heading.
fn headingLevel(style: []const u8) ?u8 {
	if (std.mem.eql(u8, style, "Title")) return 0;
	if (std.mem.eql(u8, style, "Heading1") or std.mem.eql(u8, style, "heading 1")) return 1;
	if (std.mem.eql(u8, style, "Heading2") or std.mem.eql(u8, style, "heading 2")) return 2;
	if (std.mem.eql(u8, style, "Heading3") or std.mem.eql(u8, style, "heading 3")) return 3;
	if (std.mem.eql(u8, style, "Heading4") or std.mem.eql(u8, style, "heading 4")) return 4;
	if (std.mem.eql(u8, style, "Heading5") or std.mem.eql(u8, style, "heading 5")) return 5;
	if (std.mem.eql(u8, style, "Heading6") or std.mem.eql(u8, style, "heading 6")) return 6;
	return null;
}

/// Find the `<w:body>` element in the parsed XML tree.
fn findBody(node: xml.XmlNode) ?xml.XmlNode {
	if (std.mem.eql(u8, node.tag, "w:body")) return node;
	for (node.children) |child| {
		if (findBody(child)) |body| return body;
	}
	return null;
}

/// Find a child element by tag name (first match).
fn findChild(node: xml.XmlNode, tag: []const u8) ?xml.XmlNode {
	for (node.children) |child| {
		if (std.mem.eql(u8, child.tag, tag)) return child;
	}
	return null;
}

/// Extract the paragraph style from a `<w:p>` element.
/// Looks for `<w:pPr>/<w:pStyle w:val="...">`.
fn getParagraphStyle(p_node: xml.XmlNode) ?[]const u8 {
	const pPr = findChild(p_node, "w:pPr") orelse return null;
	const pStyle = findChild(pPr, "w:pStyle") orelse return null;
	return pStyle.getAttr("w:val");
}

/// Count page break elements inside a `<w:p>` paragraph.
/// Counts both `<w:lastRenderedPageBreak/>` and `<w:br w:type="page"/>` inside runs.
fn countPageBreaks(p_node: xml.XmlNode) u32 {
	var count: u32 = 0;
	for (p_node.children) |child| {
		if (std.mem.eql(u8, child.tag, "w:r")) {
			for (child.children) |run_child| {
				if (std.mem.eql(u8, run_child.tag, "w:lastRenderedPageBreak")) {
					count += 1;
				} else if (std.mem.eql(u8, run_child.tag, "w:br")) {
					if (run_child.getAttr("w:type")) |btype| {
						if (std.mem.eql(u8, btype, "page")) {
							count += 1;
						}
					}
				}
			}
		}
		// Also check inside w:hyperlink which wraps w:r elements
		if (std.mem.eql(u8, child.tag, "w:hyperlink")) {
			for (child.children) |hyp_child| {
				if (std.mem.eql(u8, hyp_child.tag, "w:r")) {
					for (hyp_child.children) |run_child| {
						if (std.mem.eql(u8, run_child.tag, "w:lastRenderedPageBreak")) {
							count += 1;
						} else if (std.mem.eql(u8, run_child.tag, "w:br")) {
							if (run_child.getAttr("w:type")) |btype| {
								if (std.mem.eql(u8, btype, "page")) {
									count += 1;
								}
							}
						}
					}
				}
			}
		}
	}
	return count;
}

/// Extract concatenated text from all `<w:r>/<w:t>` runs in a `<w:p>` paragraph.
fn extractParagraphText(gpa: Allocator, p_node: xml.XmlNode) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(gpa);

	for (p_node.children) |child| {
		if (std.mem.eql(u8, child.tag, "w:r")) {
			for (child.children) |run_child| {
				if (std.mem.eql(u8, run_child.tag, "w:t")) {
					if (run_child.text) |text| {
						try buf.appendSlice(gpa, text);
					}
				}
			}
		}
		// Also handle w:hyperlink which wraps w:r elements
		if (std.mem.eql(u8, child.tag, "w:hyperlink")) {
			for (child.children) |hyp_child| {
				if (std.mem.eql(u8, hyp_child.tag, "w:r")) {
					for (hyp_child.children) |run_child| {
						if (std.mem.eql(u8, run_child.tag, "w:t")) {
							if (run_child.text) |text| {
								try buf.appendSlice(gpa, text);
							}
						}
					}
				}
			}
		}
	}

	return try buf.toOwnedSlice(gpa);
}

/// Recursively build nested Section tree from flat sections.
fn buildTree(
	gpa: Allocator,
	flat: []const FlatSection,
	start: usize,
	end: usize,
) ![]const Section {
	var sections: std.ArrayList(Section) = .empty;
	errdefer {
		for (sections.items) |s| freeSectionContents(gpa, s);
		sections.deinit(gpa);
	}

	var i = start;
	while (i < end) {
		const fs = &flat[i];
		const content = try gpa.dupe(u8, fs.content_buf.items);
		errdefer gpa.free(content);

		const heading_dupe: ?[]const u8 = if (fs.heading) |h| try gpa.dupe(u8, h) else null;
		errdefer if (heading_dupe) |h| gpa.free(h);

		// Find range of children: consecutive sections with level > fs.level.
		// Root sections (heading=null, level=0) never absorb children.
		const child_start = i + 1;
		var child_end = child_start;
		if (fs.heading != null) {
			while (child_end < end) {
				if (flat[child_end].level <= fs.level) break;
				child_end += 1;
			}
		}

		const children = try buildTree(gpa, flat, child_start, child_end);
		errdefer {
			for (children) |c| freeSectionContents(gpa, c);
			gpa.free(children);
		}

		try sections.append(gpa, Section{
			.heading = heading_dupe,
			.level = fs.level,
			.content = content,
			.children = children,
			.page_physical = fs.page,
		});

		i = child_end;
	}

	return try sections.toOwnedSlice(gpa);
}

/// Free the contents of a single Section recursively.
fn freeSectionContents(gpa: Allocator, section: Section) void {
	for (section.children) |child| {
		freeSectionContents(gpa, child);
	}
	if (section.children.len > 0) {
		gpa.free(section.children);
	}
	if (section.heading) |h| {
		gpa.free(h);
	}
	if (section.content.len > 0) {
		gpa.free(section.content);
	}
}

/// Extract metadata from `docProps/core.xml` if present.
fn extractMetadata(gpa: Allocator, archive: []const u8) !struct {
	metadata: []const MetadataEntry,
	title: ?[]const u8,
} {
	const core_xml = zip.extractEntry(gpa, archive, "docProps/core.xml") catch |err| switch (err) {
		error.InvalidZip => return .{ .metadata = try gpa.alloc(MetadataEntry, 0), .title = null },
		else => return err,
	};

	if (core_xml == null) {
		return .{ .metadata = try gpa.alloc(MetadataEntry, 0), .title = null };
	}
	defer gpa.free(core_xml.?);

	const doc = xml.parse(gpa, core_xml.?) catch {
		return .{ .metadata = try gpa.alloc(MetadataEntry, 0), .title = null };
	};
	defer xml.freeXmlDoc(gpa, doc);

	var entries = std.ArrayList(MetadataEntry).empty;
	errdefer {
		for (entries.items) |e| {
			gpa.free(e.key);
			gpa.free(e.value);
		}
		entries.deinit(gpa);
	}

	var title: ?[]const u8 = null;

	if (doc.root) |root| {
		for (root.children) |child| {
			const key_name = mapCoreProperty(child.tag) orelse continue;
			const value = child.text orelse continue;
			if (value.len == 0) continue;

			const key_copy = try gpa.dupe(u8, key_name);
			errdefer gpa.free(key_copy);
			const val_copy = try gpa.dupe(u8, value);
			errdefer gpa.free(val_copy);

			try entries.append(gpa, MetadataEntry{
				.key = key_copy,
				.value = val_copy,
			});

			if (std.mem.eql(u8, key_name, "title") and title == null) {
				title = try gpa.dupe(u8, value);
			}
		}
	}

	return .{
		.metadata = try entries.toOwnedSlice(gpa),
		.title = title,
	};
}

/// Map Dublin Core / DOCX core property tag names to simple keys.
fn mapCoreProperty(tag: []const u8) ?[]const u8 {
	if (std.mem.eql(u8, tag, "dc:title")) return "title";
	if (std.mem.eql(u8, tag, "dc:creator")) return "author";
	if (std.mem.eql(u8, tag, "dc:subject")) return "subject";
	if (std.mem.eql(u8, tag, "dc:description")) return "description";
	if (std.mem.eql(u8, tag, "dcterms:created")) return "created";
	if (std.mem.eql(u8, tag, "dcterms:modified")) return "modified";
	if (std.mem.eql(u8, tag, "cp:lastModifiedBy")) return "last_modified_by";
	return null;
}

/// Parse a DOCX file (as a byte slice of the ZIP archive) into a Document.
/// Caller owns the returned Document; free with `freeDocument`.
pub fn parse(gpa: Allocator, content: []const u8, path: []const u8) !Document {
	// Extract word/document.xml from the ZIP
	const doc_xml = (try zip.extractEntry(gpa, content, "word/document.xml")) orelse
		return error.InvalidZip;
	defer gpa.free(doc_xml);

	// Parse the XML
	const xml_doc = try xml.parse(gpa, doc_xml);
	defer xml.freeXmlDoc(gpa, xml_doc);

	// Find <w:body>
	const body = if (xml_doc.root) |root| findBody(root) else null;

	// Build flat sections from paragraphs
	var flat_sections = std.ArrayList(FlatSection).empty;
	defer {
		for (flat_sections.items) |*fs| fs.deinit(gpa);
		flat_sections.deinit(gpa);
	}

	if (body) |body_node| {
		var current: ?usize = null;
		var current_page: u32 = 1;
		for (body_node.children) |child| {
			if (!std.mem.eql(u8, child.tag, "w:p")) continue;

			// Count page breaks in this paragraph (before processing text).
			// Page breaks appear inside runs and indicate the content that
			// follows them is on the next page.
			const page_breaks = countPageBreaks(child);
			current_page += page_breaks;

			const text = try extractParagraphText(gpa, child);

			const style = getParagraphStyle(child);
			const level: ?u8 = if (style) |s| headingLevel(s) else null;

			if (level != null) {
				// This paragraph is a heading — start a new section.
				// The FlatSection takes ownership of `text`.
				try flat_sections.append(gpa, FlatSection{
					.heading = text,
					.level = level.?,
					.content_buf = .empty,
					.page = current_page,
				});
				current = flat_sections.items.len - 1;
			} else {
				defer gpa.free(text);
				// Body text — append to current section
				if (text.len == 0 and current == null and flat_sections.items.len == 0) {
					continue; // skip leading empty paragraphs
				}
				if (current == null) {
					try flat_sections.append(gpa, FlatSection{
						.heading = null,
						.level = 0,
						.content_buf = .empty,
						.page = current_page,
					});
					current = flat_sections.items.len - 1;
				}
				const fs = &flat_sections.items[current.?];
				if (fs.content_buf.items.len > 0) {
					try fs.content_buf.append(gpa, '\n');
				}
				try fs.content_buf.appendSlice(gpa, text);
			}
		}
	}

	// Build hierarchical tree
	const sections = if (flat_sections.items.len > 0)
		try buildTree(gpa, flat_sections.items, 0, flat_sections.items.len)
	else
		try gpa.alloc(Section, 0);
	errdefer {
		for (sections) |s| freeSectionContents(gpa, s);
		if (sections.len > 0) gpa.free(sections);
	}

	// Extract metadata
	const meta = try extractMetadata(gpa, content);
	errdefer {
		for (meta.metadata) |m| {
			gpa.free(m.key);
			gpa.free(m.value);
		}
		gpa.free(meta.metadata);
		if (meta.title) |t| gpa.free(t);
	}

	// Determine title: prefer metadata title, else first heading
	var title: ?[]const u8 = meta.title;
	if (title == null) {
		for (flat_sections.items) |fs| {
			if (fs.level == 1 and fs.heading != null) {
				title = try gpa.dupe(u8, fs.heading.?);
				break;
			}
		}
	}
	errdefer if (meta.title == null) {
		if (title) |t| gpa.free(t);
	};

	const path_dupe = try gpa.dupe(u8, path);
	errdefer gpa.free(path_dupe);

	// Normalize extracted text
	wordfix.applySections(gpa, sections);

	return Document{		.path = path_dupe,
		.format = .docx,
		.title = title,
		.metadata = meta.metadata,
		.sections = sections,
	};
}

/// Recursively free all memory owned by a Document returned from `parse`.
pub fn freeDocument(gpa: Allocator, doc: Document) void {
	for (doc.sections) |section| {
		freeSectionContents(gpa, section);
	}
	if (doc.sections.len > 0) {
		gpa.free(doc.sections);
	}
	if (doc.title) |t| {
		gpa.free(t);
	}
	for (doc.metadata) |m| {
		gpa.free(m.key);
		gpa.free(m.value);
	}
	gpa.free(doc.metadata);
	gpa.free(doc.path);
}

// ── Test helpers ─────────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal DOCX-format ZIP archive with the given document.xml body content.
/// Wraps the body in the required DOCX XML structure.
fn buildTestDocx(gpa: Allocator, body_xml: []const u8, core_xml: ?[]const u8) ![]const u8 {
	const doc_xml_prefix =
		\\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		\\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
		\\<w:body>
	;
	const doc_xml_suffix =
		\\</w:body>
		\\</w:document>
	;

	// Build full document.xml
	var doc_buf = std.ArrayList(u8).empty;
	defer doc_buf.deinit(gpa);
	try doc_buf.appendSlice(gpa, doc_xml_prefix);
	try doc_buf.appendSlice(gpa, body_xml);
	try doc_buf.appendSlice(gpa, doc_xml_suffix);

	const content_types =
		\\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		\\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
		\\<Default Extension="xml" ContentType="application/xml"/>
		\\<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
		\\</Types>
	;

	const rels =
		\\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		\\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
		\\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
		\\</Relationships>
	;

	if (core_xml) |core| {
		return zip.buildTestZip(gpa, &.{
			.{ .name = "[Content_Types].xml", .data = content_types },
			.{ .name = "_rels/.rels", .data = rels },
			.{ .name = "word/document.xml", .data = doc_buf.items },
			.{ .name = "docProps/core.xml", .data = core },
		});
	} else {
		return zip.buildTestZip(gpa, &.{
			.{ .name = "[Content_Types].xml", .data = content_types },
			.{ .name = "_rels/.rels", .data = rels },
			.{ .name = "word/document.xml", .data = doc_buf.items },
		});
	}
}

// ── Tests ────────────────────────────────────────────────────────────

test "extract text from simple document" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Introduction</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>This is the body text.</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/simple.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.docx, doc.format);
	try testing.expectEqualStrings("/test/simple.docx", doc.path);
	try testing.expectEqual(@as(usize, 1), doc.sections.len);

	const s0 = doc.sections[0];
	try testing.expectEqualStrings("Introduction", s0.heading.?);
	try testing.expectEqual(@as(u8, 1), s0.level);
	try testing.expect(std.mem.indexOf(u8, s0.content, "This is the body text.") != null);
}

test "multiple headings with nesting" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter One</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Chapter one text.</w:t></w:r></w:p>
		\\<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Section 1.1</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Section 1.1 text.</w:t></w:r></w:p>
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter Two</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Chapter two text.</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/nested.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 2), doc.sections.len);

	// Chapter One with Section 1.1 as child
	try testing.expectEqualStrings("Chapter One", doc.sections[0].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[0].level);
	try testing.expectEqual(@as(usize, 1), doc.sections[0].children.len);

	const sub = doc.sections[0].children[0];
	try testing.expectEqualStrings("Section 1.1", sub.heading.?);
	try testing.expectEqual(@as(u8, 2), sub.level);

	// Chapter Two
	try testing.expectEqualStrings("Chapter Two", doc.sections[1].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[1].level);
}

test "document with no headings" {
	const body =
		\\<w:p><w:r><w:t>Just some plain text</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>with multiple paragraphs.</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/noheadings.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.sections[0].heading);
	try testing.expectEqual(@as(u8, 0), doc.sections[0].level);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Just some plain text") != null);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "with multiple paragraphs.") != null);
}

test "empty document" {
	const body = "";

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/empty.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
}

test "unicode content preserved" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>日本語の見出し</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Héllo wörld — «quotes» ™</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/unicode.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expectEqualStrings("日本語の見出し", doc.sections[0].heading.?);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Héllo wörld") != null);
}

test "metadata extraction from core.xml" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Test Doc</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Content here.</w:t></w:r></w:p>
	;

	const core =
		\\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		\\<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/">
		\\<dc:title>My Document Title</dc:title>
		\\<dc:creator>Peter Marreck</dc:creator>
		\\<dcterms:created>2026-04-08T12:00:00Z</dcterms:created>
		\\</cp:coreProperties>
	;

	const docx = try buildTestDocx(testing.allocator, body, core);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/meta.docx");
	defer freeDocument(testing.allocator, doc);

	// Title should come from metadata
	try testing.expectEqualStrings("My Document Title", doc.title.?);

	// Check metadata entries
	try testing.expect(doc.metadata.len >= 2);
	var found_author = false;
	var found_title = false;
	for (doc.metadata) |m| {
		if (std.mem.eql(u8, m.key, "author")) {
			try testing.expectEqualStrings("Peter Marreck", m.value);
			found_author = true;
		}
		if (std.mem.eql(u8, m.key, "title")) {
			try testing.expectEqualStrings("My Document Title", m.value);
			found_title = true;
		}
	}
	try testing.expect(found_author);
	try testing.expect(found_title);
}

test "multiple text runs concatenated" {
	const body =
		\\<w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>World</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/runs.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Hello World") != null);
}

test "title level maps correctly" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Document Title</w:t></w:r></w:p>
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>First Chapter</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Body text.</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/title.docx");
	defer freeDocument(testing.allocator, doc);

	// Title style maps to level 0 — it becomes the sole top-level section
	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expectEqualStrings("Document Title", doc.sections[0].heading.?);
	try testing.expectEqual(@as(u8, 0), doc.sections[0].level);

	// Heading1 at level 1 is a child of the level-0 Title
	try testing.expectEqual(@as(usize, 1), doc.sections[0].children.len);
	const ch = doc.sections[0].children[0];
	try testing.expectEqualStrings("First Chapter", ch.heading.?);
	try testing.expectEqual(@as(u8, 1), ch.level);
	try testing.expect(std.mem.indexOf(u8, ch.content, "Body text.") != null);
}

test "page tracking with lastRenderedPageBreak" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Page 1 Heading</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Content on page 1.</w:t></w:r></w:p>
		\\<w:p><w:r><w:lastRenderedPageBreak/><w:t>Content on page 2.</w:t></w:r></w:p>
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Page 2 Heading</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>More page 2 content.</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/pagebreak.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 2), doc.sections.len);

	// First section starts on page 1
	try testing.expectEqualStrings("Page 1 Heading", doc.sections[0].heading.?);
	try testing.expectEqual(@as(?u32, 1), doc.sections[0].page_physical);

	// Second section starts on page 2 (after the lastRenderedPageBreak)
	try testing.expectEqualStrings("Page 2 Heading", doc.sections[1].heading.?);
	try testing.expectEqual(@as(?u32, 2), doc.sections[1].page_physical);
}

test "page tracking with hard page break (w:br type=page)" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>First Page</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>Some text.</w:t></w:r></w:p>
		\\<w:p><w:r><w:br w:type="page"/></w:r></w:p>
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Second Page</w:t></w:r></w:p>
		\\<w:p><w:r><w:t>More text.</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/hardbreak.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 2), doc.sections.len);

	try testing.expectEqualStrings("First Page", doc.sections[0].heading.?);
	try testing.expectEqual(@as(?u32, 1), doc.sections[0].page_physical);

	try testing.expectEqualStrings("Second Page", doc.sections[1].heading.?);
	try testing.expectEqual(@as(?u32, 2), doc.sections[1].page_physical);
}

test "page tracking with multiple page breaks" {
	const body =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Page 1</w:t></w:r></w:p>
		\\<w:p><w:r><w:lastRenderedPageBreak/><w:t>Text.</w:t></w:r></w:p>
		\\<w:p><w:r><w:lastRenderedPageBreak/><w:t>Text.</w:t></w:r></w:p>
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Page 3</w:t></w:r></w:p>
	;

	const docx = try buildTestDocx(testing.allocator, body, null);
	defer testing.allocator.free(docx);

	const doc = try parse(testing.allocator, docx, "/test/multipagebreak.docx");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 2), doc.sections.len);

	try testing.expectEqualStrings("Page 1", doc.sections[0].heading.?);
	try testing.expectEqual(@as(?u32, 1), doc.sections[0].page_physical);

	// Two page breaks passed → page 3
	try testing.expectEqualStrings("Page 3", doc.sections[1].heading.?);
	try testing.expectEqual(@as(?u32, 3), doc.sections[1].page_physical);
}

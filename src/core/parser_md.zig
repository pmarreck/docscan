//! Markdown parser for docscan.
//! Extracts text with heading-based section structure from Markdown content.
//! Pure computation — no I/O. Receives byte slices, returns a Document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document = @import("document.zig");
const Document = document.Document;
const Section = document.Section;
const Format = document.Format;
const wordfix = @import("wordfix.zig");
/// A flat section before nesting is applied.
const FlatSection = struct {
	heading: ?[]const u8,
	level: u8,
	content_lines: std.ArrayList([]const u8),
	source_line: ?u32 = null, // 1-based line number where this section starts

	fn deinit(self: *FlatSection, gpa: Allocator) void {
		self.content_lines.deinit(gpa);
	}
};

/// Detect an ATX heading line. Returns the level (1-6) and heading text,
/// or null if the line is not a valid heading (requires space after #).
fn parseHeadingLine(line: []const u8) ?struct { level: u8, text: []const u8 } {
	if (line.len == 0 or line[0] != '#') return null;

	var level: u8 = 0;
	for (line) |c| {
		if (c == '#') {
			level += 1;
			if (level > 6) return null;
		} else break;
	}

	// Must have a space after the #'s
	if (level >= line.len or line[level] != ' ') return null;

	const text = std.mem.trim(u8, line[level + 1 ..], " \t");
	return .{ .level = level, .text = text };
}

/// Join content lines into a single trimmed string, allocated via allocator.
/// Leading/trailing blank lines are stripped; inner lines joined with newline.
fn joinContentLines(gpa: Allocator, lines: []const []const u8) ![]const u8 {
	// Find first and last non-empty lines
	var first: usize = 0;
	var last: usize = 0;
	var found_any = false;

	for (lines, 0..) |line, i| {
		const trimmed = std.mem.trim(u8, line, " \t");
		if (trimmed.len > 0) {
			if (!found_any) {
				first = i;
				found_any = true;
			}
			last = i;
		}
	}

	if (!found_any) {
		return try gpa.dupe(u8, "");
	}

	const relevant = lines[first .. last + 1];

	// Calculate total length
	var total_len: usize = 0;
	for (relevant, 0..) |line, i| {
		total_len += line.len;
		if (i < relevant.len - 1) total_len += 1; // newline
	}

	const buf = try gpa.alloc(u8, total_len);
	var offset: usize = 0;
	for (relevant, 0..) |line, i| {
		@memcpy(buf[offset .. offset + line.len], line);
		offset += line.len;
		if (i < relevant.len - 1) {
			buf[offset] = '\n';
			offset += 1;
		}
	}

	return buf;
}

/// Recursively build nested Section tree from a slice of flat sections.
/// Processes `flat[start..end]` and groups children under their parent headings.
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
		const content = try joinContentLines(gpa, fs.content_lines.items);
		errdefer gpa.free(content);

		const heading_dupe: ?[]const u8 = if (fs.heading) |h| try gpa.dupe(u8, h) else null;
		errdefer if (heading_dupe) |h| gpa.free(h);

		// Find range of children: consecutive sections with level > fs.level.
		// Root/preamble sections (heading=null, level=0) never absorb children —
		// only real headings do. This prevents h1 from becoming a child of preamble.
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
			.source_line = fs.source_line,
		});

		i = child_end;
	}

	return try sections.toOwnedSlice(gpa);
}

/// Free the contents of a single Section (heading, content, children recursively).
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

/// Parse markdown content into a Document with hierarchical sections.
/// Headings (ATX-style: `# `, `## `, etc.) define section boundaries and nesting.
/// Memory: all returned slices are allocated via `gpa`; free with `freeDocument`.
pub fn parse(gpa: Allocator, content: []const u8, path: []const u8) !Document {
	var flat_sections: std.ArrayList(FlatSection) = .empty;
	defer {
		for (flat_sections.items) |*fs| fs.deinit(gpa);
		flat_sections.deinit(gpa);
	}

	var line_iter = std.mem.splitScalar(u8, content, '\n');
	var current: ?usize = null; // index into flat_sections
	var line_num: u32 = 0; // 0-based counter, stored as 1-based

	while (line_iter.next()) |line| {
		line_num += 1;
		if (parseHeadingLine(line)) |heading| {
			try flat_sections.append(gpa, FlatSection{
				.heading = heading.text,
				.level = heading.level,
				.content_lines = .empty,
				.source_line = line_num,
			});
			current = flat_sections.items.len - 1;
		} else {
			if (current == null) {
				const trimmed = std.mem.trim(u8, line, " \t");
				if (trimmed.len == 0 and flat_sections.items.len == 0) {
					continue; // skip leading blank lines
				}
				try flat_sections.append(gpa, FlatSection{
					.heading = null,
					.level = 0,
					.content_lines = .empty,
					.source_line = line_num,
				});
				current = flat_sections.items.len - 1;
			}
			try flat_sections.items[current.?].content_lines.append(gpa, line);
		}
	}

	// Empty document
	if (flat_sections.items.len == 0) {
		const path_dupe = try gpa.dupe(u8, path);
		return Document{
			.path = path_dupe,
			.format = .md,
			.title = null,
			.metadata = try gpa.alloc(document.MetadataEntry, 0),
			.sections = try gpa.alloc(Section, 0),
		};
	}

	// Build hierarchical tree
	const sections = try buildTree(gpa, flat_sections.items, 0, flat_sections.items.len);
	errdefer {
		for (sections) |s| freeSectionContents(gpa, s);
		gpa.free(sections);
	}

	// Extract title from first level-1 heading
	var title: ?[]const u8 = null;
	for (flat_sections.items) |fs| {
		if (fs.level == 1 and fs.heading != null) {
			title = try gpa.dupe(u8, fs.heading.?);
			break;
		}
	}
	errdefer if (title) |t| gpa.free(t);

	const path_dupe = try gpa.dupe(u8, path);
	errdefer gpa.free(path_dupe);

	wordfix.applySections(gpa, sections);

	return Document{		.path = path_dupe,
		.format = .md,
		.title = title,
		.metadata = try gpa.alloc(document.MetadataEntry, 0),
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
	gpa.free(doc.metadata);
	gpa.free(doc.path);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "basic heading structure — two top-level headings with content" {
	const input =
		\\# First Heading
		\\
		\\First content here.
		\\
		\\# Second Heading
		\\
		\\Second content here.
	;
	const doc = try parse(testing.allocator, input, "/test/basic.md");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 2), doc.sections.len);

	try testing.expectEqualStrings("First Heading", doc.sections[0].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[0].level);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "First content here.") != null);

	try testing.expectEqualStrings("Second Heading", doc.sections[1].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[1].level);
	try testing.expect(std.mem.indexOf(u8, doc.sections[1].content, "Second content here.") != null);

	// Title should be the first level-1 heading
	try testing.expectEqualStrings("First Heading", doc.title.?);
	try testing.expectEqual(Format.md, doc.format);
}

test "nested headings — h1 > h2 > h3 produces children hierarchy" {
	const input =
		\\# Top
		\\
		\\Top content.
		\\
		\\## Sub
		\\
		\\Sub content.
		\\
		\\### SubSub
		\\
		\\SubSub content.
	;
	const doc = try parse(testing.allocator, input, "/test/nested.md");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expectEqualStrings("Top", doc.sections[0].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[0].level);

	// h2 is a child of h1
	try testing.expectEqual(@as(usize, 1), doc.sections[0].children.len);
	const sub = doc.sections[0].children[0];
	try testing.expectEqualStrings("Sub", sub.heading.?);
	try testing.expectEqual(@as(u8, 2), sub.level);

	// h3 is a child of h2
	try testing.expectEqual(@as(usize, 1), sub.children.len);
	const subsub = sub.children[0];
	try testing.expectEqualStrings("SubSub", subsub.heading.?);
	try testing.expectEqual(@as(u8, 3), subsub.level);
}

test "no headings — plain text produces single root section" {
	const input =
		\\Just some plain text
		\\with multiple lines
		\\but no headings at all.
	;
	const doc = try parse(testing.allocator, input, "/test/plain.md");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.sections[0].heading);
	try testing.expectEqual(@as(u8, 0), doc.sections[0].level);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Just some plain text") != null);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
}

test "empty document — produces 0 sections" {
	const doc = try parse(testing.allocator, "", "/test/empty.md");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
}

test "heading with no content — content is empty string" {
	const input =
		\\# Lonely Heading
	;
	const doc = try parse(testing.allocator, input, "/test/lonely.md");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expectEqualStrings("Lonely Heading", doc.sections[0].heading.?);
	try testing.expectEqualStrings("", doc.sections[0].content);
}

test "content before first heading — goes into level-0 root section" {
	const input =
		\\Some preamble text.
		\\
		\\# Actual Heading
		\\
		\\Heading content.
	;
	const doc = try parse(testing.allocator, input, "/test/preamble.md");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 2), doc.sections.len);

	// First section is the preamble
	try testing.expectEqual(@as(?[]const u8, null), doc.sections[0].heading);
	try testing.expectEqual(@as(u8, 0), doc.sections[0].level);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Some preamble text.") != null);

	// Second section is the heading
	try testing.expectEqualStrings("Actual Heading", doc.sections[1].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[1].level);
}

test "multiple blank lines — don't produce extra sections" {
	const input =
		\\# Heading
		\\
		\\
		\\
		\\
		\\Content after many blanks.
	;
	const doc = try parse(testing.allocator, input, "/test/blanks.md");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 1), doc.sections.len);
	try testing.expectEqualStrings("Heading", doc.sections[0].heading.?);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Content after many blanks.") != null);
}

test "ATX heading edge cases — #NoSpace is NOT a heading, ###### Level 6 works" {
	const input =
		\\#NoSpace should be content
		\\###### Level 6
		\\
		\\Level 6 content.
	;
	const doc = try parse(testing.allocator, input, "/test/edge.md");
	defer freeDocument(testing.allocator, doc);

	// #NoSpace is not a heading — becomes preamble content
	// ###### Level 6 is a valid heading
	try testing.expectEqual(@as(usize, 2), doc.sections.len);

	// Preamble with #NoSpace
	try testing.expectEqual(@as(?[]const u8, null), doc.sections[0].heading);
	try testing.expectEqual(@as(u8, 0), doc.sections[0].level);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "#NoSpace should be content") != null);

	// Level 6 heading
	try testing.expectEqualStrings("Level 6", doc.sections[1].heading.?);
	try testing.expectEqual(@as(u8, 6), doc.sections[1].level);
}

test "legal reporter abbreviation — intra-token spaces preserved (no 'U. S.' -> 'US.')" {
	// Regression (incitez_web 2026-06-13): the md path collapsed the space inside
	// "U. S." reporter abbreviations -> "US.", breaking incitez citation recall.
	const input =
		\\# Memo
		\\
		\\Compare 530 U. S. 238, 241-242 (2000).
	;
	const doc = try parse(testing.allocator, input, "/test/reporter.md");
	defer freeDocument(testing.allocator, doc);

	var found = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "530 U. S. 238") != null) found = true;
	}
	try testing.expect(found);
}

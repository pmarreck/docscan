//! Pure-Zig Document -> plain UTF-8 text flattener.
//!
//! Intent: the WASM parse-to-text slice (and any consumer that wants the
//! readable text of a parsed document, not its structure) needs a way to turn
//! a `Document` section tree into a flat UTF-8 byte string. The CLI's `extract`
//! command does this C-side while walking the flat FFI representation; this is
//! the in-core, no-I/O, no-C-dependency equivalent so it can run under
//! wasm32-freestanding.
//!
//! Technique: depth-first pre-order walk of the `Section` tree. Each section
//! emits its heading (if non-empty) on its own line, then its body content,
//! then recurses into children — preserving document reading order.

const std = @import("std");
const document = @import("document.zig");
const Document = document.Document;
const Section = document.Section;

/// Flatten a parsed `Document` into plain UTF-8 text. Caller owns the returned
/// slice (allocated with `allocator`). Headings precede their section body;
/// sections are emitted in depth-first document order.
pub fn documentToPlainText(allocator: std.mem.Allocator, doc: Document) ![]u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	for (doc.sections) |sec| {
		try appendSection(allocator, &buf, sec);
	}
	return buf.toOwnedSlice(allocator);
}

/// Append one section (heading + content) and recurse into its children.
fn appendSection(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), sec: Section) !void {
	if (sec.heading) |h| {
		if (h.len > 0) {
			try buf.appendSlice(allocator, h);
			try buf.append(allocator, '\n');
		}
	}
	if (sec.content.len > 0) {
		try buf.appendSlice(allocator, sec.content);
		if (!std.mem.endsWith(u8, sec.content, "\n")) try buf.append(allocator, '\n');
	}
	for (sec.children) |child| {
		try appendSection(allocator, buf, child);
	}
}

test "documentToPlainText flattens nested sections in depth-first order" {
	const a = std.testing.allocator;
	const grandchild = Section{ .heading = "Sub", .level = 2, .content = "child body", .children = &.{} };
	const children = [_]Section{grandchild};
	const top = Section{ .heading = "Title", .level = 1, .content = "top body", .children = &children };
	const secs = [_]Section{top};
	const doc = Document{ .path = "x.md", .format = .md, .title = "Title", .metadata = &.{}, .sections = &secs };
	const text = try documentToPlainText(a, doc);
	defer a.free(text);
	try std.testing.expectEqualStrings("Title\ntop body\nSub\nchild body\n", text);
}

test "documentToPlainText returns empty string for a document with no sections" {
	const a = std.testing.allocator;
	const doc = Document{ .path = "x.txt", .format = .txt, .title = null, .metadata = &.{}, .sections = &.{} };
	const text = try documentToPlainText(a, doc);
	defer a.free(text);
	try std.testing.expectEqualStrings("", text);
}

test "documentToPlainText skips empty headings and preserves an existing trailing newline" {
	const a = std.testing.allocator;
	// Heading is empty -> omitted; content already ends in newline -> not doubled.
	const sec = Section{ .heading = "", .level = 0, .content = "body line\n", .children = &.{} };
	const secs = [_]Section{sec};
	const doc = Document{ .path = "x.txt", .format = .txt, .title = null, .metadata = &.{}, .sections = &secs };
	const text = try documentToPlainText(a, doc);
	defer a.free(text);
	try std.testing.expectEqualStrings("body line\n", text);
}

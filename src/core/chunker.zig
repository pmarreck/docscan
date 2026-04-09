//! Structure-aware chunker: converts parsed Documents (with hierarchical Sections)
//! into flat Chunks suitable for embedding. Pure computation — no I/O.
//!
//! Algorithm: walk the section tree recursively to produce proto-chunks, then
//! merge adjacent small siblings. Final pass assigns sequential indices and
//! cumulative byte offsets.

const std = @import("std");
const document = @import("document.zig");

pub const ChunkOptions = struct {
	max_chunk_tokens: usize = 1500,
	min_chunk_tokens: usize = 100,
	tokens_per_byte: f32 = 0.25, // rough approximation: 1 token ≈ 4 bytes
};

/// Internal proto-chunk: pre-merge, pre-index representation.
const ProtoChunk = struct {
	section_path: []const u8, // always allocated
	heading: ?[]const u8, // borrowed from section
	text: []const u8, // borrowed from section content or allocated during merge
	parent_path: []const u8, // always allocated
	text_allocated: bool, // true if text was allocated (merged text)
	page: ?u32 = null, // page number from section (PDF)
	source_line: ?u32 = null, // line number from section (markdown)
};

/// Estimate token count for a text span.
fn estimateTokens(text: []const u8, tokens_per_byte: f32) usize {
	const f: f32 = @floatFromInt(text.len);
	const tokens = f * tokens_per_byte;
	const rounded: usize = @intFromFloat(@ceil(tokens));
	return if (rounded == 0 and text.len > 0) 1 else rounded;
}

/// Returns true if text is empty or whitespace-only.
fn isBlankContent(text: []const u8) bool {
	for (text) |c| {
		if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return false;
	}
	return true;
}

/// Build a breadcrumb path by joining parent_path and current heading with " > ".
/// Allocates the result. Null headings are skipped (parent_path returned as-is dup).
fn buildBreadcrumb(allocator: std.mem.Allocator, parent_path: []const u8, heading: ?[]const u8) ![]const u8 {
	if (heading) |h| {
		if (parent_path.len == 0) {
			return try allocator.dupe(u8, h);
		}
		const total = parent_path.len + 3 + h.len; // " > "
		const buf = try allocator.alloc(u8, total);
		@memcpy(buf[0..parent_path.len], parent_path);
		@memcpy(buf[parent_path.len..][0..3], " > ");
		@memcpy(buf[parent_path.len + 3 ..][0..h.len], h);
		return buf;
	}
	// Null heading — just duplicate parent path
	return try allocator.dupe(u8, parent_path);
}

/// Split content at paragraph boundaries (double newline).
/// Returns slices into the original content (no allocation for the text itself).
/// Split content on single newlines (fallback when no \n\n boundaries exist).
fn splitOnSingleNewline(allocator: std.mem.Allocator, content: []const u8) ![]const []const u8 {
	var lines: std.ArrayListUnmanaged([]const u8) = .{};
	defer lines.deinit(allocator);

	var start: usize = 0;
	for (content, 0..) |ch, i| {
		if (ch == '\n') {
			const line = content[start..i];
			if (!isBlankContent(line)) {
				try lines.append(allocator, line);
			}
			start = i + 1;
		}
	}
	if (start < content.len) {
		const line = content[start..];
		if (!isBlankContent(line)) {
			try lines.append(allocator, line);
		}
	}

	return try lines.toOwnedSlice(allocator);
}

fn splitParagraphs(allocator: std.mem.Allocator, content: []const u8) ![]const []const u8 {
	var paragraphs: std.ArrayListUnmanaged([]const u8) = .{};
	defer paragraphs.deinit(allocator);

	var start: usize = 0;
	var i: usize = 0;
	while (i < content.len) {
		if (i + 1 < content.len and content[i] == '\n' and content[i + 1] == '\n') {
			const para = content[start..i];
			if (!isBlankContent(para)) {
				try paragraphs.append(allocator, para);
			}
			// Skip all consecutive newlines
			while (i < content.len and content[i] == '\n') : (i += 1) {}
			start = i;
		} else {
			i += 1;
		}
	}
	// Last paragraph
	if (start < content.len) {
		const para = content[start..];
		if (!isBlankContent(para)) {
			try paragraphs.append(allocator, para);
		}
	}

	return try paragraphs.toOwnedSlice(allocator);
}

/// Recursively emit proto-chunks from a section tree.
fn chunkSection(
	allocator: std.mem.Allocator,
	section: document.Section,
	parent_path: []const u8,
	options: ChunkOptions,
	out: *std.ArrayListUnmanaged(ProtoChunk),
) !void {
	const my_path = try buildBreadcrumb(allocator, parent_path, section.heading);

	const has_children = section.children.len > 0;
	const has_content = !isBlankContent(section.content);

	if (has_children) {
		// Parent with preamble: emit preamble as its own chunk
		if (has_content) {
			try emitContentChunks(allocator, section.content, my_path, parent_path, section.heading, options, out, section.page, section.source_line);
		}
		// Recurse into children
		for (section.children) |child| {
			try chunkSection(allocator, child, my_path, options, out);
		}
		// my_path was used as parent for children's buildBreadcrumb calls,
		// which dupe from it. If we also emitted preamble, my_path is owned
		// by the preamble proto-chunk. If not, it's orphaned — free it.
		if (!has_content) {
			allocator.free(my_path);
		}
	} else if (has_content) {
		// Leaf section with content
		try emitContentChunks(allocator, section.content, my_path, parent_path, section.heading, options, out, section.page, section.source_line);
	} else {
		// Empty leaf — skip, free path
		allocator.free(my_path);
	}
}

/// Emit one or more proto-chunks for a content string, splitting at paragraphs if too large.
fn emitContentChunks(
	allocator: std.mem.Allocator,
	content: []const u8,
	section_path: []const u8,
	parent_path: []const u8,
	heading: ?[]const u8,
	options: ChunkOptions,
	out: *std.ArrayListUnmanaged(ProtoChunk),
	page: ?u32,
	source_line: ?u32,
) !void {
	const token_count = estimateTokens(content, options.tokens_per_byte);

	if (token_count <= options.max_chunk_tokens) {
		// Fits in one chunk
		const pp = try allocator.dupe(u8, parent_path);
		try out.append(allocator, .{
			.section_path = section_path,
			.heading = heading,
			.text = content,
			.parent_path = pp,
			.text_allocated = false,
			.page = page,
			.source_line = source_line,
		});
		return;
	}

	// Split at paragraph boundaries
	var paragraphs = try splitParagraphs(allocator, content);

	if (paragraphs.len <= 1) {
		// No \n\n boundaries found — try splitting on single \n instead
		allocator.free(paragraphs);
		paragraphs = try splitOnSingleNewline(allocator, content);

		if (paragraphs.len <= 1) {
			// Can't split further — emit as-is
			allocator.free(paragraphs);
			const pp = try allocator.dupe(u8, parent_path);
			try out.append(allocator, .{
				.section_path = section_path,
				.heading = heading,
				.text = content,
				.parent_path = pp,
				.text_allocated = false,
				.page = page,
				.source_line = source_line,
			});
			return;
		}
	}
	defer allocator.free(paragraphs);

	// Group paragraphs into chunks that fit within max_chunk_tokens.
	// Each sub-chunk gets its own section_path dupe (except the first which
	// takes ownership of the original).
	var group_start: usize = 0;
	var group_tokens: usize = 0;
	var is_first_group = true;

	for (paragraphs, 0..) |para, idx| {
		const para_tokens = estimateTokens(para, options.tokens_per_byte);
		if (!is_first_group and group_tokens + para_tokens > options.max_chunk_tokens) {
			// Emit current group [group_start..idx)
			// The first group reuses the original section_path
			const sp = if (group_start == 0) section_path else try allocator.dupe(u8, section_path);
			const pp = try allocator.dupe(u8, parent_path);
			try out.append(allocator, .{
				.section_path = sp,
				.heading = heading,
				.text = buildGroupText(paragraphs[group_start..idx]),
				.parent_path = pp,
				.text_allocated = false,
				.page = page,
				.source_line = source_line,
			});
			group_start = idx;
			group_tokens = para_tokens;
			is_first_group = false;
		} else {
			group_tokens += para_tokens;
			if (group_start == 0 and idx == 0) {
				is_first_group = false;
			}
		}
	}
	// Emit final group
	if (group_start < paragraphs.len) {
		const sp = if (group_start == 0) section_path else try allocator.dupe(u8, section_path);
		const pp = try allocator.dupe(u8, parent_path);
		try out.append(allocator, .{
			.section_path = sp,
			.heading = heading,
			.text = buildGroupText(paragraphs[group_start..]),
			.parent_path = pp,
			.text_allocated = false,
			.page = page,
			.source_line = source_line,
		});
	}
}

/// Get the text span covering multiple paragraphs (they are contiguous slices
/// from the original content, separated by \n\n). We return the span from
/// the start of the first paragraph to the end of the last.
fn buildGroupText(paragraphs: []const []const u8) []const u8 {
	if (paragraphs.len == 0) return "";
	const start = paragraphs[0].ptr;
	const last = paragraphs[paragraphs.len - 1];
	const end = last.ptr + last.len;
	const len = @intFromPtr(end) - @intFromPtr(start);
	return start[0..len];
}

/// Merge adjacent small proto-chunks that share the same parent_path.
/// Consumes ownership of the input proto_chunks' allocated fields.
fn mergeSmallChunks(
	allocator: std.mem.Allocator,
	proto_chunks: []const ProtoChunk,
	options: ChunkOptions,
) ![]ProtoChunk {
	if (proto_chunks.len == 0) return try allocator.alloc(ProtoChunk, 0);

	var result: std.ArrayListUnmanaged(ProtoChunk) = .{};
	defer result.deinit(allocator);

	var i: usize = 0;
	while (i < proto_chunks.len) {
		const current = proto_chunks[i];
		var current_tokens = estimateTokens(current.text, options.tokens_per_byte);

		if (current_tokens >= options.min_chunk_tokens) {
			try result.append(allocator, current);
			i += 1;
			continue;
		}

		// Try to merge with subsequent small siblings that share the same parent
		var merge_end = i + 1;
		while (merge_end < proto_chunks.len) {
			const next = proto_chunks[merge_end];
			const next_tokens = estimateTokens(next.text, options.tokens_per_byte);
			if (next_tokens >= options.min_chunk_tokens) break;
			if (!std.mem.eql(u8, current.parent_path, next.parent_path)) break;
			if (current_tokens + next_tokens > options.max_chunk_tokens) break;
			current_tokens += next_tokens;
			merge_end += 1;
		}

		if (merge_end == i + 1) {
			// No merging possible — emit as-is
			try result.append(allocator, current);
			i += 1;
		} else {
			// Merge proto_chunks[i..merge_end]
			// Build merged text by joining with \n\n
			var text_len: usize = 0;
			for (proto_chunks[i..merge_end], 0..) |pc, j| {
				if (j > 0) text_len += 2; // "\n\n"
				text_len += pc.text.len;
			}
			const merged_text = try allocator.alloc(u8, text_len);
			var pos: usize = 0;
			for (proto_chunks[i..merge_end], 0..) |pc, j| {
				if (j > 0) {
					merged_text[pos] = '\n';
					merged_text[pos + 1] = '\n';
					pos += 2;
				}
				@memcpy(merged_text[pos..][0..pc.text.len], pc.text);
				pos += pc.text.len;
			}

			// Free section_path and parent_path of merged-away chunks (not the first)
			for (proto_chunks[i + 1 .. merge_end]) |pc| {
				allocator.free(pc.section_path);
				allocator.free(pc.parent_path);
				if (pc.text_allocated) allocator.free(pc.text);
			}

			try result.append(allocator, .{
				.section_path = current.section_path,
				.heading = current.heading,
				.text = merged_text,
				.parent_path = current.parent_path,
				.text_allocated = true,
				.page = current.page,
				.source_line = current.source_line,
			});
			i = merge_end;
		}
	}

	return try result.toOwnedSlice(allocator);
}

/// Convert a parsed Document into a flat slice of Chunks.
/// Caller must free via `freeChunks`.
pub fn chunk(allocator: std.mem.Allocator, doc: document.Document, options: ChunkOptions) ![]document.Chunk {
	// Phase 1: recursively produce proto-chunks
	var proto_list: std.ArrayListUnmanaged(ProtoChunk) = .{};
	defer proto_list.deinit(allocator);

	for (doc.sections) |section| {
		try chunkSection(allocator, section, "", options, &proto_list);
	}

	const proto_chunks = try proto_list.toOwnedSlice(allocator);
	defer allocator.free(proto_chunks);

	// Phase 2: merge small adjacent siblings
	const merged = try mergeSmallChunks(allocator, proto_chunks, options);
	defer {
		for (merged) |pc| {
			allocator.free(pc.parent_path);
			allocator.free(pc.section_path);
			if (pc.text_allocated) allocator.free(pc.text);
		}
		allocator.free(merged);
	}

	// Phase 3: build final Chunk array with sequential indices and byte offsets
	const chunks = try allocator.alloc(document.Chunk, merged.len);
	errdefer allocator.free(chunks);

	var byte_offset: u64 = 0;
	for (merged, 0..) |pc, idx| {
		const text_owned = try allocator.dupe(u8, pc.text);
		const path_owned = try allocator.dupe(u8, pc.section_path);
		const heading_owned: ?[]const u8 = if (pc.heading) |h| try allocator.dupe(u8, h) else null;

		chunks[idx] = .{
			.document_path = try allocator.dupe(u8, doc.path),
			.section_path = path_owned,
			.heading = heading_owned,
			.text = text_owned,
			.start_byte = byte_offset,
			.end_byte = byte_offset + text_owned.len,
			.chunk_index = @intCast(idx),
			.page = pc.page,
			.source_line = pc.source_line,
		};
		byte_offset += text_owned.len;
	}

	return chunks;
}

/// Free all memory owned by a chunk slice returned from `chunk()`.
pub fn freeChunks(allocator: std.mem.Allocator, chunks: []document.Chunk) void {
	for (chunks) |c| {
		allocator.free(c.document_path);
		allocator.free(c.section_path);
		if (c.heading) |h| allocator.free(h);
		allocator.free(c.text);
	}
	allocator.free(chunks);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeDoc(sections: []const document.Section) document.Document {
	return .{
		.path = "/test/doc.md",
		.format = .md,
		.title = "Test Doc",
		.metadata = &.{},
		.sections = sections,
	};
}

test "leaf sections become chunks" {
	const sections = &[_]document.Section{
		.{ .heading = "Introduction", .level = 1, .content = "Hello world.", .children = &.{} },
		.{ .heading = "Conclusion", .level = 1, .content = "Goodbye world.", .children = &.{} },
	};
	const doc = makeDoc(sections);
	const chunks = try chunk(testing.allocator, doc, .{ .min_chunk_tokens = 1 });
	defer freeChunks(testing.allocator, chunks);

	try testing.expectEqual(@as(usize, 2), chunks.len);
	try testing.expectEqualStrings("Hello world.", chunks[0].text);
	try testing.expectEqualStrings("Goodbye world.", chunks[1].text);
	try testing.expectEqualStrings("Introduction", chunks[0].heading.?);
	try testing.expectEqualStrings("Conclusion", chunks[1].heading.?);
	try testing.expectEqualStrings("Introduction", chunks[0].section_path);
	try testing.expectEqualStrings("Conclusion", chunks[1].section_path);
}

test "nested sections produce breadcrumb paths" {
	const leaf = document.Section{
		.heading = "Sub Sub X",
		.level = 3,
		.content = "Deeply nested.",
		.children = &.{},
	};
	const mid = document.Section{
		.heading = "Sub A",
		.level = 2,
		.content = "",
		.children = &.{leaf},
	};
	const top = document.Section{
		.heading = "Section 1",
		.level = 1,
		.content = "",
		.children = &.{mid},
	};
	const doc = makeDoc(&.{top});
	const chunks = try chunk(testing.allocator, doc, .{});
	defer freeChunks(testing.allocator, chunks);

	try testing.expectEqual(@as(usize, 1), chunks.len);
	try testing.expectEqualStrings("Section 1 > Sub A > Sub Sub X", chunks[0].section_path);
	try testing.expectEqualStrings("Deeply nested.", chunks[0].text);
}

test "parent with preamble emits separate chunk" {
	const child = document.Section{
		.heading = "Details",
		.level = 2,
		.content = "Child content.",
		.children = &.{},
	};
	const parent_sec = document.Section{
		.heading = "Overview",
		.level = 1,
		.content = "Preamble text here.",
		.children = &.{child},
	};
	const doc = makeDoc(&.{parent_sec});
	const chunks = try chunk(testing.allocator, doc, .{});
	defer freeChunks(testing.allocator, chunks);

	try testing.expectEqual(@as(usize, 2), chunks.len);
	try testing.expectEqualStrings("Preamble text here.", chunks[0].text);
	try testing.expectEqualStrings("Overview", chunks[0].section_path);
	try testing.expectEqualStrings("Child content.", chunks[1].text);
	try testing.expectEqualStrings("Overview > Details", chunks[1].section_path);
}

test "large section splits at paragraphs" {
	// Build content with 10 paragraphs, each 100 bytes
	const para = "A" ** 100;
	const content = (para ++ "\n\n") ** 9 ++ para; // 10 paragraphs

	const sections = &[_]document.Section{
		.{ .heading = "Big", .level = 1, .content = content, .children = &.{} },
	};
	const doc = makeDoc(sections);
	// Set max_chunk_tokens low enough that each paragraph is roughly one chunk
	// 100 bytes * 0.25 = 25 tokens per paragraph; set max to 30
	const chunks = try chunk(testing.allocator, doc, .{
		.max_chunk_tokens = 30,
		.min_chunk_tokens = 1,
		.tokens_per_byte = 0.25,
	});
	defer freeChunks(testing.allocator, chunks);

	// Should produce 10 chunks (one per paragraph)
	try testing.expectEqual(@as(usize, 10), chunks.len);
	// All should have the same section path
	for (chunks) |c| {
		try testing.expectEqualStrings("Big", c.section_path);
		try testing.expectEqualStrings("Big", c.heading.?);
	}
}

test "small section merging" {
	// 5 tiny sibling sections, each under min_chunk_tokens
	const sections = &[_]document.Section{
		.{ .heading = "A", .level = 1, .content = "tiny a", .children = &.{} },
		.{ .heading = "B", .level = 1, .content = "tiny b", .children = &.{} },
		.{ .heading = "C", .level = 1, .content = "tiny c", .children = &.{} },
		.{ .heading = "D", .level = 1, .content = "tiny d", .children = &.{} },
		.{ .heading = "E", .level = 1, .content = "tiny e", .children = &.{} },
	};
	const doc = makeDoc(sections);
	const chunks = try chunk(testing.allocator, doc, .{
		.max_chunk_tokens = 1500,
		.min_chunk_tokens = 100, // 6 bytes * 0.25 = 1.5 tokens, way under 100
		.tokens_per_byte = 0.25,
	});
	defer freeChunks(testing.allocator, chunks);

	// All 5 should be merged into 1 chunk (total ~7.5 tokens, under 100)
	try testing.expectEqual(@as(usize, 1), chunks.len);
	// Merged chunk uses the first heading
	try testing.expectEqualStrings("A", chunks[0].heading.?);
	// Text contains all content joined
	try testing.expect(std.mem.indexOf(u8, chunks[0].text, "tiny a") != null);
	try testing.expect(std.mem.indexOf(u8, chunks[0].text, "tiny e") != null);
}

test "empty sections skipped" {
	const sections = &[_]document.Section{
		.{ .heading = "Empty", .level = 1, .content = "", .children = &.{} },
		.{ .heading = "Also Empty", .level = 1, .content = "   ", .children = &.{} },
		.{ .heading = "Real", .level = 1, .content = "Actual content.", .children = &.{} },
	};
	const doc = makeDoc(sections);
	const chunks = try chunk(testing.allocator, doc, .{});
	defer freeChunks(testing.allocator, chunks);

	try testing.expectEqual(@as(usize, 1), chunks.len);
	try testing.expectEqualStrings("Actual content.", chunks[0].text);
}

test "single section document" {
	const sections = &[_]document.Section{
		.{ .heading = "Only", .level = 1, .content = "The one and only.", .children = &.{} },
	};
	const doc = makeDoc(sections);
	const chunks = try chunk(testing.allocator, doc, .{});
	defer freeChunks(testing.allocator, chunks);

	try testing.expectEqual(@as(usize, 1), chunks.len);
	try testing.expectEqualStrings("The one and only.", chunks[0].text);
	try testing.expectEqual(@as(u32, 0), chunks[0].chunk_index);
}

test "byte offsets are sequential and non-overlapping" {
	const sections = &[_]document.Section{
		.{ .heading = "A", .level = 1, .content = "First chunk text.", .children = &.{} },
		.{ .heading = "B", .level = 1, .content = "Second chunk text.", .children = &.{} },
		.{ .heading = "C", .level = 1, .content = "Third chunk text.", .children = &.{} },
	};
	const doc = makeDoc(sections);
	const chunks = try chunk(testing.allocator, doc, .{ .min_chunk_tokens = 1 });
	defer freeChunks(testing.allocator, chunks);

	try testing.expectEqual(@as(usize, 3), chunks.len);
	try testing.expectEqual(@as(u64, 0), chunks[0].start_byte);
	try testing.expectEqual(@as(u64, 17), chunks[0].end_byte); // "First chunk text." = 17 bytes
	// Each start_byte == previous end_byte
	for (chunks[1..], 0..) |c, i| {
		try testing.expectEqual(chunks[i].end_byte, c.start_byte);
	}
}

test "chunk index is sequential" {
	const child1 = document.Section{
		.heading = "Sub1",
		.level = 2,
		.content = "content 1",
		.children = &.{},
	};
	const child2 = document.Section{
		.heading = "Sub2",
		.level = 2,
		.content = "content 2",
		.children = &.{},
	};
	const parent_sec = document.Section{
		.heading = "Parent",
		.level = 1,
		.content = "preamble",
		.children = &.{ child1, child2 },
	};
	const doc = makeDoc(&.{parent_sec});
	const chunks = try chunk(testing.allocator, doc, .{});
	defer freeChunks(testing.allocator, chunks);

	for (chunks, 0..) |c, i| {
		try testing.expectEqual(@as(u32, @intCast(i)), c.chunk_index);
	}
}

test "null headings in breadcrumb are skipped" {
	const child = document.Section{
		.heading = "Visible",
		.level = 2,
		.content = "Some text.",
		.children = &.{},
	};
	// Level-0 section with null heading (document root wrapper)
	const root = document.Section{
		.heading = null,
		.level = 0,
		.content = "",
		.children = &.{child},
	};
	const doc = makeDoc(&.{root});
	const chunks = try chunk(testing.allocator, doc, .{});
	defer freeChunks(testing.allocator, chunks);

	try testing.expectEqual(@as(usize, 1), chunks.len);
	// The null heading should NOT appear in the breadcrumb
	try testing.expectEqualStrings("Visible", chunks[0].section_path);
}

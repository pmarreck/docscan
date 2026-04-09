//! RTF (Rich Text Format) parser for docscan.
//! Extracts text from RTF documents by walking the control-word markup,
//! skipping non-content groups (fonttbl, colortbl, stylesheet, pict, etc.),
//! decoding \'HH hex escapes (Windows-1252) and \uNNNN Unicode escapes,
//! and inferring headings via font-size heuristics (same approach as PDF).
//! Pure computation — no I/O. Receives byte slices, returns a Document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document = @import("document.zig");
const Document = document.Document;
const Section = document.Section;
const MetadataEntry = document.MetadataEntry;
const Format = document.Format;

// ── Windows-1252 decoding ────────────────────────────────────────────

/// Decode a Windows-1252 byte to a Unicode codepoint.
/// Windows-1252 is identical to ISO-8859-1 except for bytes 0x80-0x9F.
fn windows1252ToCodepoint(byte: u8) u21 {
	const win1252_special = [32]u21{
		0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80-87
		0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, // 88-8F
		0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90-97
		0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178, // 98-9F
	};

	if (byte >= 0x80 and byte <= 0x9F) {
		return win1252_special[byte - 0x80];
	}
	return @intCast(byte);
}

/// Encode a Unicode codepoint as UTF-8 into a buffer, returning the number of bytes written.
fn encodeUtf8(cp: u21, buf: *[4]u8) u3 {
	if (cp < 0x80) {
		buf[0] = @intCast(cp);
		return 1;
	} else if (cp < 0x800) {
		buf[0] = @intCast(0xC0 | (cp >> 6));
		buf[1] = @intCast(0x80 | (cp & 0x3F));
		return 2;
	} else if (cp < 0x10000) {
		buf[0] = @intCast(0xE0 | (cp >> 12));
		buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
		buf[2] = @intCast(0x80 | (cp & 0x3F));
		return 3;
	} else {
		buf[0] = @intCast(0xF0 | (cp >> 18));
		buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
		buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
		buf[3] = @intCast(0x80 | (cp & 0x3F));
		return 4;
	}
}

// ── Text span (for heading inference) ────────────────────────────────

/// A run of text at a specific font size and page, used for heading detection.
const TextSpan = struct {
	text: []const u8, // owned
	font_size: f32,
	page: u32,
};

// ── Flat section (intermediate structure before tree building) ────────

const FlatSection = struct {
	heading: ?[]const u8, // owned
	level: u8,
	content_buf: std.ArrayList(u8),
	page: ?u32 = null,

	fn deinit(self: *FlatSection, allocator: Allocator) void {
		if (self.heading) |h| allocator.free(h);
		self.content_buf.deinit(allocator);
	}
};

// ── RTF group-skip destinations ──────────────────────────────────────

/// Known non-content destination groups that should be skipped entirely.
fn isSkipDestination(word: []const u8) bool {
	const skip_list = [_][]const u8{
		"fonttbl",
		"colortbl",
		"stylesheet",
		"pict",
		"header",
		"headerl",
		"headerr",
		"headerf",
		"footer",
		"footerl",
		"footerr",
		"footerf",
		"footnote",
		"annotation",
		"atnid",
		"atnicn",
		"field",
		"fldinst",
		"bkmkstart",
		"bkmkend",
		"datafield",
		"objdata",
		"object",
		"nonshppict",
		"shp",
		"shpinst",
		"shprslt",
		"themedata",
		"colorschememapping",
		"datastore",
		"latentstyles",
		"listtable",
		"listoverridetable",
		"pgdsctbl",
		"rsidtbl",
		"mmathPr",
		"generator",
		"xmlnstbl",
	};
	for (skip_list) |s| {
		if (std.mem.eql(u8, word, s)) return true;
	}
	return false;
}

/// Metadata field names in the \info group.
fn isMetadataField(word: []const u8) bool {
	const fields = [_][]const u8{
		"title",
		"author",
		"subject",
		"category",
		"keywords",
		"comment",
		"company",
		"operator",
		"manager",
		"doccomm",
	};
	for (fields) |f| {
		if (std.mem.eql(u8, word, f)) return true;
	}
	return false;
}

// ── Parser state ─────────────────────────────────────────────────────

const ParserState = struct {
	font_size: f32, // in points (RTF uses half-points, we convert)
	uc_skip: u8, // number of chars to skip after \uNNNN (default 1)
	in_info: bool, // inside \info group
	info_field: ?[]const u8, // current metadata field name (e.g. "title")
	skip_depth: ?u32, // if set, skip everything until we return to this depth
	page: u32, // current page (1-based)
};

// ── Public API ───────────────────────────────────────────────────────

/// Parse an RTF byte buffer into a Document with inferred heading structure.
/// Caller owns the returned Document; free with `freeDocument`.
pub fn parse(allocator: Allocator, content: []const u8, path: []const u8) !Document {
	// Validate RTF magic
	if (content.len < 5 or !std.mem.startsWith(u8, content, "{\\rtf")) {
		return emptyDocument(allocator, path);
	}

	var spans = std.ArrayList(TextSpan){};
	defer {
		for (spans.items) |span| allocator.free(span.text);
		spans.deinit(allocator);
	}

	var metadata_list = std.ArrayList(MetadataEntry){};
	defer {
		// Only free on error — on success, ownership transfers to Document
	}
	errdefer {
		for (metadata_list.items) |m| {
			allocator.free(m.key);
			allocator.free(m.value);
		}
		metadata_list.deinit(allocator);
	}

	var title: ?[]const u8 = null;
	errdefer if (title) |t| allocator.free(t);

	// Parser state stack (for group nesting)
	var state_stack = std.ArrayList(ParserState){};
	defer state_stack.deinit(allocator);

	var state = ParserState{
		.font_size = 12.0,
		.uc_skip = 1,
		.in_info = false,
		.info_field = null,
		.skip_depth = null,
		.page = 1,
	};

	var depth: u32 = 0;

	// Text accumulator for the current span
	var text_buf = std.ArrayList(u8){};
	defer text_buf.deinit(allocator);

	// Metadata value accumulator
	var meta_buf = std.ArrayList(u8){};
	defer meta_buf.deinit(allocator);

	var current_font_size: f32 = 12.0;
	var current_page: u32 = 1;

	var i: usize = 0;
	while (i < content.len) {
		const c = content[i];

		// If we're in skip mode, just track braces and skip content.
		// skip_depth is the depth of the group being skipped; when a '}'
		// brings depth back to that level, we exit skip mode and let the
		// '}' be handled normally (popping state and decrementing depth).
		if (state.skip_depth) |sd| {
			if (c == '{') {
				depth += 1;
				i += 1;
				continue;
			} else if (c == '}') {
				if (depth == sd) {
					// We've reached the closing brace of the skipped group.
					// Exit skip mode and fall through to normal '}' handling.
					state.skip_depth = null;
				} else {
					depth -= 1;
					i += 1;
					continue;
				}
			} else {
				i += 1;
				continue;
			}
		}

		switch (c) {
			'{' => {
				// Push current state
				try state_stack.append(allocator, state);
				depth += 1;
				i += 1;
			},
			'}' => {
				// Flush metadata if we're leaving an info field group
				if (state.info_field != null and meta_buf.items.len > 0) {
					const field_name = state.info_field.?;
					const value = try allocator.dupe(u8, trimWhitespace(meta_buf.items));
					errdefer allocator.free(value);

					if (std.mem.eql(u8, field_name, "title") and title == null) {
						title = try allocator.dupe(u8, value);
					}

					const key = try allocator.dupe(u8, field_name);
					errdefer allocator.free(key);
					try metadata_list.append(allocator, MetadataEntry{
						.key = key,
						.value = value,
					});
					meta_buf.clearRetainingCapacity();
				}

				// Pop state
				if (state_stack.items.len > 0) {
					state = state_stack.pop().?;
				}
				if (depth > 0) depth -= 1;
				i += 1;
			},
			'\\' => {
				// Parse control word or control symbol
				i += 1;
				if (i >= content.len) break;

				const next = content[i];

				if (next == '\'') {
					// Hex escape: \'HH
					i += 1;
					if (i + 1 < content.len) {
						const hex_str = content[i .. i + 2];
						const byte = std.fmt.parseInt(u8, hex_str, 16) catch {
							i += 2;
							continue;
						};
						const cp = windows1252ToCodepoint(byte);
						var utf8_buf: [4]u8 = undefined;
						const len = encodeUtf8(cp, &utf8_buf);
						if (state.in_info and state.info_field != null) {
							try meta_buf.appendSlice(allocator, utf8_buf[0..len]);
						} else {
							try text_buf.appendSlice(allocator, utf8_buf[0..len]);
						}
						i += 2;
					}
					continue;
				}

				if (next == '{' or next == '}' or next == '\\') {
					// Escaped literal character
					if (state.in_info and state.info_field != null) {
						try meta_buf.append(allocator, next);
					} else {
						try text_buf.append(allocator, next);
					}
					i += 1;
					continue;
				}

				if (next == '*') {
					// Ignorable destination — skip if we don't understand the next group
					i += 1;
					// Skip whitespace
					while (i < content.len and content[i] == ' ') i += 1;
					// Parse the destination control word
					if (i < content.len and content[i] == '\\') {
						i += 1;
						const dest_word = parseControlWordName(content, &i);
						if (!isKnownDestination(dest_word)) {
							// Unknown destination — skip this entire group
							state.skip_depth = depth;
						}
					}
					continue;
				}

				if (next == '\n' or next == '\r') {
					// \<newline> is a paragraph break (same as \par)
					try flushSpan(allocator, &text_buf, current_font_size, current_page, &spans);
					try text_buf.append(allocator, '\n');
					i += 1;
					continue;
				}

				if (next == '~') {
					// Non-breaking space
					if (state.in_info and state.info_field != null) {
						try meta_buf.append(allocator, ' ');
					} else {
						try text_buf.append(allocator, '\xC2');
						try text_buf.append(allocator, '\xA0');
					}
					i += 1;
					continue;
				}

				if (next == '-') {
					// Optional hyphen (soft hyphen)
					i += 1;
					continue;
				}

				if (next == '_') {
					// Non-breaking hyphen
					if (state.in_info and state.info_field != null) {
						try meta_buf.append(allocator, '-');
					} else {
						try text_buf.append(allocator, '-');
					}
					i += 1;
					continue;
				}

				// Parse control word
				if (!std.ascii.isAlphabetic(next)) {
					// Unknown control symbol — skip
					i += 1;
					continue;
				}

				const word = parseControlWordName(content, &i);
				// Parse optional numeric parameter
				const param = parseControlWordParam(content, &i);

				// Consume the optional space delimiter after a control word
				if (i < content.len and content[i] == ' ') i += 1;

				// Handle specific control words
				if (std.mem.eql(u8, word, "par") or std.mem.eql(u8, word, "line")) {
					try flushSpan(allocator, &text_buf, current_font_size, current_page, &spans);
					try text_buf.append(allocator, '\n');
				} else if (std.mem.eql(u8, word, "tab")) {
					if (state.in_info and state.info_field != null) {
						try meta_buf.append(allocator, '\t');
					} else {
						try text_buf.append(allocator, '\t');
					}
				} else if (std.mem.eql(u8, word, "page")) {
					try flushSpan(allocator, &text_buf, current_font_size, current_page, &spans);
					state.page += 1;
					current_page = state.page;
				} else if (std.mem.eql(u8, word, "fs")) {
					if (param) |p| {
						// RTF font sizes are in half-points
						const new_size: f32 = @as(f32, @floatFromInt(p)) / 2.0;
						// Flush span if font size changes
						if (@abs(new_size - current_font_size) > 0.01) {
							try flushSpan(allocator, &text_buf, current_font_size, current_page, &spans);
							current_font_size = new_size;
						}
						state.font_size = new_size;
					}
				} else if (std.mem.eql(u8, word, "uc")) {
					if (param) |p| {
						state.uc_skip = if (p >= 0) @intCast(@as(u32, @bitCast(p))) else 1;
					}
				} else if (std.mem.eql(u8, word, "u")) {
					if (param) |p| {
						// Unicode escape: \uNNNN followed by uc_skip ANSI fallback chars
						const cp: u21 = if (p < 0) @intCast(@as(u32, @bitCast(p)) & 0x1FFFFF) else @intCast(@as(u32, @bitCast(p)));
						var utf8_buf: [4]u8 = undefined;
						const len = encodeUtf8(cp, &utf8_buf);
						if (state.in_info and state.info_field != null) {
							try meta_buf.appendSlice(allocator, utf8_buf[0..len]);
						} else {
							try text_buf.appendSlice(allocator, utf8_buf[0..len]);
						}
						// Skip uc_skip fallback characters
						var skip: u8 = state.uc_skip;
						while (skip > 0 and i < content.len) : (skip -= 1) {
							if (content[i] == '\\') {
								// The fallback might be a \'HH sequence
								if (i + 3 < content.len and content[i + 1] == '\'') {
									i += 4; // skip \'HH
								} else {
									i += 1;
								}
							} else if (content[i] == '{' or content[i] == '}') {
								break; // Don't skip group delimiters
							} else {
								i += 1;
							}
						}
					}
				} else if (std.mem.eql(u8, word, "info")) {
					state.in_info = true;
				} else if (std.mem.eql(u8, word, "bin")) {
					// Binary data: \binN — skip N bytes
					if (param) |p| {
						const skip_count: usize = if (p >= 0) @intCast(@as(u32, @bitCast(p))) else 0;
						i += skip_count;
					}
				} else if (state.in_info and isMetadataField(word)) {
					state.info_field = word;
					meta_buf.clearRetainingCapacity();
				} else if (isSkipDestination(word)) {
					// Skip this entire group
					state.skip_depth = depth;
				}
			},
			'\n', '\r' => {
				// RTF ignores bare CR/LF (they are not paragraph breaks)
				i += 1;
			},
			else => {
				// Plain text character
				if (state.in_info and state.info_field != null) {
					try meta_buf.append(allocator, c);
				} else if (state.skip_depth == null) {
					try text_buf.append(allocator, c);
				}
				i += 1;
			},
		}
	}

	// Flush any remaining text
	try flushSpan(allocator, &text_buf, current_font_size, current_page, &spans);

	// Build document structure from spans using font-size heading heuristic
	const sections = try inferStructure(allocator, spans.items);
	errdefer {
		for (sections) |s| freeSectionContents(allocator, s);
		allocator.free(sections);
	}

	const metadata = try metadata_list.toOwnedSlice(allocator);
	const path_dupe = try allocator.dupe(u8, path);

	return Document{
		.path = path_dupe,
		.format = .rtf,
		.title = title,
		.metadata = metadata,
		.sections = sections,
	};
}

/// Flush accumulated text buffer into a TextSpan.
fn flushSpan(
	allocator: Allocator,
	text_buf: *std.ArrayList(u8),
	font_size: f32,
	page: u32,
	spans: *std.ArrayList(TextSpan),
) !void {
	if (text_buf.items.len == 0) return;

	// Trim trailing whitespace for clean span boundaries
	var end = text_buf.items.len;
	while (end > 0 and (text_buf.items[end - 1] == ' ' or text_buf.items[end - 1] == '\t')) {
		end -= 1;
	}
	if (end == 0) {
		text_buf.clearRetainingCapacity();
		return;
	}

	const text = try allocator.dupe(u8, text_buf.items[0..end]);
	errdefer allocator.free(text);
	try spans.append(allocator, TextSpan{
		.text = text,
		.font_size = font_size,
		.page = page,
	});
	text_buf.clearRetainingCapacity();
}

/// Parse the alphabetic portion of a control word (after the backslash).
fn parseControlWordName(content: []const u8, pos: *usize) []const u8 {
	const start = pos.*;
	while (pos.* < content.len and std.ascii.isAlphabetic(content[pos.*])) {
		pos.* += 1;
	}
	return content[start..pos.*];
}

/// Parse an optional numeric parameter following a control word.
/// Returns null if no digits follow.
fn parseControlWordParam(content: []const u8, pos: *usize) ?i32 {
	if (pos.* >= content.len) return null;

	var negative = false;
	if (content[pos.*] == '-') {
		negative = true;
		pos.* += 1;
	}

	const start = pos.*;
	while (pos.* < content.len and std.ascii.isDigit(content[pos.*])) {
		pos.* += 1;
	}

	if (pos.* == start) {
		// No digits found; undo the negative sign consumption
		if (negative) pos.* -= 1;
		return null;
	}

	const val = std.fmt.parseInt(i32, content[start..pos.*], 10) catch return null;
	return if (negative) -val else val;
}

/// Check if a destination word is a "known" one we want to process.
fn isKnownDestination(word: []const u8) bool {
	// We only explicitly handle \info and its sub-fields
	const known = [_][]const u8{
		"info",
		"title",
		"author",
		"subject",
		"category",
		"keywords",
		"comment",
		"company",
		"operator",
	};
	for (known) |k| {
		if (std.mem.eql(u8, word, k)) return true;
	}
	return false;
}

/// Trim leading and trailing whitespace from a slice.
fn trimWhitespace(s: []const u8) []const u8 {
	var start: usize = 0;
	while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) {
		start += 1;
	}
	var end = s.len;
	while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) {
		end -= 1;
	}
	return s[start..end];
}

// ── Structure inference (mirrors PDF parser approach) ─────────────────

/// Infer document structure from text spans using font size heuristics.
/// Larger text = headings, dominant (most common) size = body text.
fn inferStructure(allocator: Allocator, spans: []const TextSpan) ![]const Section {
	if (spans.len == 0) return try allocator.alloc(Section, 0);

	// Find dominant font size (most common, by total character count)
	var size_counts = std.AutoHashMap(u32, usize).init(allocator);
	defer size_counts.deinit();

	for (spans) |span| {
		const key: u32 = @bitCast(span.font_size);
		const entry = try size_counts.getOrPut(key);
		if (entry.found_existing) {
			entry.value_ptr.* += span.text.len;
		} else {
			entry.value_ptr.* = span.text.len;
		}
	}

	var dominant_size: f32 = 12.0;
	var max_count: usize = 0;
	var iter = size_counts.iterator();
	while (iter.next()) |entry| {
		if (entry.value_ptr.* > max_count) {
			max_count = entry.value_ptr.*;
			dominant_size = @as(f32, @bitCast(entry.key_ptr.*));
		}
	}

	// Collect unique heading sizes (sizes significantly larger than dominant)
	const size_threshold = dominant_size * 1.15; // 15% larger = heading
	var heading_sizes = std.ArrayList(f32){};
	defer heading_sizes.deinit(allocator);

	for (spans) |span| {
		if (span.font_size >= size_threshold) {
			var found = false;
			for (heading_sizes.items) |hs| {
				if (@abs(hs - span.font_size) < 0.01) {
					found = true;
					break;
				}
			}
			if (!found) {
				try heading_sizes.append(allocator, span.font_size);
			}
		}
	}

	// Sort heading sizes descending (largest = level 1)
	std.mem.sort(f32, heading_sizes.items, {}, struct {
		fn f(_: void, a: f32, b: f32) bool {
			return a > b;
		}
	}.f);

	// Build flat sections
	var flat_sections = std.ArrayList(FlatSection){};
	defer {
		for (flat_sections.items) |*fs| fs.deinit(allocator);
		flat_sections.deinit(allocator);
	}

	var current: ?usize = null;

	for (spans) |span| {
		if (span.text.len == 0) continue;

		if (span.font_size >= size_threshold) {
			// This span is a heading
			const level = headingLevelForSize(span.font_size, heading_sizes.items);
			try flat_sections.append(allocator, FlatSection{
				.heading = try allocator.dupe(u8, span.text),
				.level = level,
				.content_buf = .{},
				.page = span.page,
			});
			current = flat_sections.items.len - 1;
		} else {
			// Body text
			if (current == null) {
				try flat_sections.append(allocator, FlatSection{
					.heading = null,
					.level = 0,
					.content_buf = .{},
					.page = span.page,
				});
				current = flat_sections.items.len - 1;
			}
			const fs = &flat_sections.items[current.?];
			if (fs.content_buf.items.len > 0) {
				try fs.content_buf.append(allocator, '\n');
			}
			try fs.content_buf.appendSlice(allocator, span.text);
		}
	}

	// Build hierarchical section tree
	if (flat_sections.items.len == 0) return try allocator.alloc(Section, 0);
	return try buildTree(allocator, flat_sections.items, 0, flat_sections.items.len);
}

fn headingLevelForSize(size: f32, heading_sizes: []const f32) u8 {
	for (heading_sizes, 0..) |hs, i| {
		if (@abs(hs - size) < 0.01) return @intCast(i + 1);
	}
	return 1;
}

/// Recursively build nested Section tree from flat sections.
fn buildTree(
	allocator: Allocator,
	flat: []const FlatSection,
	start: usize,
	end: usize,
) ![]const Section {
	var sections = std.ArrayList(Section){};
	errdefer {
		for (sections.items) |s| freeSectionContents(allocator, s);
		sections.deinit(allocator);
	}

	var i = start;
	while (i < end) {
		const fs = &flat[i];
		const content = try allocator.dupe(u8, fs.content_buf.items);
		errdefer allocator.free(content);

		const heading_dupe: ?[]const u8 = if (fs.heading) |h| try allocator.dupe(u8, h) else null;
		errdefer if (heading_dupe) |h| allocator.free(h);

		// Find range of children
		const child_start = i + 1;
		var child_end = child_start;
		if (fs.heading != null) {
			while (child_end < end) {
				if (flat[child_end].level <= fs.level) break;
				child_end += 1;
			}
		}

		const children = try buildTree(allocator, flat, child_start, child_end);
		errdefer {
			for (children) |child| freeSectionContents(allocator, child);
			allocator.free(children);
		}

		try sections.append(allocator, Section{
			.heading = heading_dupe,
			.level = fs.level,
			.content = content,
			.children = children,
			.page = fs.page,
		});

		i = child_end;
	}

	return try sections.toOwnedSlice(allocator);
}

// ── Memory management ────────────────────────────────────────────────

/// Create an empty document for invalid/unparseable files.
fn emptyDocument(allocator: Allocator, path: []const u8) !Document {
	const path_dupe = try allocator.dupe(u8, path);
	errdefer allocator.free(path_dupe);

	const metadata = try allocator.alloc(MetadataEntry, 0);

	return Document{
		.path = path_dupe,
		.format = .rtf,
		.title = null,
		.metadata = metadata,
		.sections = try allocator.alloc(Section, 0),
	};
}

/// Free the contents of a single Section recursively.
fn freeSectionContents(allocator: Allocator, section: Section) void {
	for (section.children) |child| {
		freeSectionContents(allocator, child);
	}
	if (section.children.len > 0) {
		allocator.free(section.children);
	}
	if (section.heading) |h| {
		allocator.free(h);
	}
	if (section.content.len > 0) {
		allocator.free(section.content);
	}
}

/// Recursively free all memory owned by a Document returned from `parse`.
pub fn freeDocument(allocator: Allocator, doc: Document) void {
	for (doc.sections) |section| {
		freeSectionContents(allocator, section);
	}
	if (doc.sections.len > 0) {
		allocator.free(doc.sections);
	}
	if (doc.title) |t| {
		allocator.free(t);
	}
	for (doc.metadata) |m| {
		allocator.free(m.key);
		allocator.free(m.value);
	}
	allocator.free(doc.metadata);
	allocator.free(doc.path);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "RTF: basic text extraction" {
	const input = "{\\rtf1 Hello World}";
	const doc = try parse(testing.allocator, input, "/test/basic.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.rtf, doc.format);
	try testing.expectEqualStrings("/test/basic.rtf", doc.path);
	try testing.expect(doc.sections.len > 0);

	// Should contain "Hello World" in the content
	var found = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "Hello World") != null) {
			found = true;
			break;
		}
	}
	try testing.expect(found);
}

test "RTF: paragraph breaks" {
	const input = "{\\rtf1 First\\par Second}";
	const doc = try parse(testing.allocator, input, "/test/para.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	// With same font size, all text ends up in one section.
	// The content should have both paragraphs separated by newline.
	var found_first = false;
	var found_second = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "First") != null) found_first = true;
		if (std.mem.indexOf(u8, s.content, "Second") != null) found_second = true;
	}
	try testing.expect(found_first);
	try testing.expect(found_second);
}

test "RTF: control words stripped, text preserved" {
	const input = "{\\rtf1 \\b Bold\\b0  text}";
	const doc = try parse(testing.allocator, input, "/test/bold.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "Bold") != null and
			std.mem.indexOf(u8, s.content, "text") != null)
		{
			found = true;
			break;
		}
	}
	try testing.expect(found);
}

test "RTF: hex character escape (Windows-1252)" {
	// \'e9 = é in Windows-1252 (U+00E9)
	const input = "{\\rtf1 caf\\'e9}";
	const doc = try parse(testing.allocator, input, "/test/hex.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "caf\xC3\xA9") != null) {
			found = true;
			break;
		}
	}
	try testing.expect(found);
}

test "RTF: Unicode escape" {
	// \u8212 = U+2014 em dash, followed by '?' as ANSI fallback
	const input = "{\\rtf1 \\u8212? dash}";
	const doc = try parse(testing.allocator, input, "/test/unicode.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found_dash = false;
	var found_text = false;
	for (doc.sections) |s| {
		// U+2014 em dash in UTF-8 is 0xE2 0x80 0x94
		if (std.mem.indexOf(u8, s.content, "\xE2\x80\x94") != null) found_dash = true;
		if (std.mem.indexOf(u8, s.content, "dash") != null) found_text = true;
	}
	try testing.expect(found_dash);
	try testing.expect(found_text);
}

test "RTF: skip non-content groups" {
	const input = "{\\rtf1 {\\fonttbl {\\f0 Times;}} {\\colortbl ;\\red0\\green0\\blue0;} Real text}";
	const doc = try parse(testing.allocator, input, "/test/skip.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found_real = false;
	var found_times = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "Real text") != null) found_real = true;
		if (std.mem.indexOf(u8, s.content, "Times") != null) found_times = true;
	}
	try testing.expect(found_real);
	try testing.expect(!found_times); // Font table content must not leak
}

test "RTF: nested groups handled correctly" {
	const input = "{\\rtf1 outer {inner {deepest}} back}";
	const doc = try parse(testing.allocator, input, "/test/nested.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "outer") != null and
			std.mem.indexOf(u8, s.content, "inner") != null and
			std.mem.indexOf(u8, s.content, "deepest") != null and
			std.mem.indexOf(u8, s.content, "back") != null)
		{
			found = true;
			break;
		}
	}
	try testing.expect(found);
}

test "RTF: page breaks increment page counter" {
	const input = "{\\rtf1 Page one\\page Page two}";
	const doc = try parse(testing.allocator, input, "/test/pages.rtf");
	defer freeDocument(testing.allocator, doc);

	// With same font size, both pages end up as body text.
	// But section pages should track correctly.
	try testing.expect(doc.sections.len > 0);

	// The first section should be page 1
	try testing.expectEqual(@as(?u32, 1), doc.sections[0].page);
}

test "RTF: font size heading detection" {
	// fs48 = 24pt (heading), fs24 = 12pt (body)
	const input = "{\\rtf1 {\\fs48 Big Title}\\par {\\fs24 Body text here. More body text to ensure this is the dominant size.}}";
	const doc = try parse(testing.allocator, input, "/test/heading.rtf");
	defer freeDocument(testing.allocator, doc);

	// Should have detected a heading
	var found_heading = false;
	for (doc.sections) |s| {
		if (s.heading != null and std.mem.indexOf(u8, s.heading.?, "Big Title") != null) {
			found_heading = true;
		}
	}
	try testing.expect(found_heading);
}

test "RTF: empty document" {
	const input = "{\\rtf1}";
	const doc = try parse(testing.allocator, input, "/test/empty.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.rtf, doc.format);
	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
}

test "RTF: invalid input returns empty document" {
	const input = "This is not RTF at all";
	const doc = try parse(testing.allocator, input, "/test/invalid.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.rtf, doc.format);
	try testing.expectEqual(@as(usize, 0), doc.sections.len);
}

test "RTF: metadata extraction from info group" {
	const input = "{\\rtf1 {\\info {\\title My Document} {\\author Peter}} Some text}";
	const doc = try parse(testing.allocator, input, "/test/meta.rtf");
	defer freeDocument(testing.allocator, doc);

	// Title should be extracted
	try testing.expect(doc.title != null);
	try testing.expectEqualStrings("My Document", doc.title.?);

	// Metadata should contain both title and author
	var found_title = false;
	var found_author = false;
	for (doc.metadata) |m| {
		if (std.mem.eql(u8, m.key, "title")) {
			try testing.expectEqualStrings("My Document", m.value);
			found_title = true;
		}
		if (std.mem.eql(u8, m.key, "author")) {
			try testing.expectEqualStrings("Peter", m.value);
			found_author = true;
		}
	}
	try testing.expect(found_title);
	try testing.expect(found_author);
}

test "RTF: line break via \\line" {
	const input = "{\\rtf1 Line one\\line Line two}";
	const doc = try parse(testing.allocator, input, "/test/linebrk.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found_one = false;
	var found_two = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "Line one") != null) found_one = true;
		if (std.mem.indexOf(u8, s.content, "Line two") != null) found_two = true;
	}
	try testing.expect(found_one);
	try testing.expect(found_two);
}

test "RTF: tab characters preserved" {
	const input = "{\\rtf1 before\\tab after}";
	const doc = try parse(testing.allocator, input, "/test/tab.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "before\tafter") != null) {
			found = true;
			break;
		}
	}
	try testing.expect(found);
}

test "RTF: escaped braces and backslash" {
	const input = "{\\rtf1 curly \\{ brace \\} and backslash \\\\}";
	const doc = try parse(testing.allocator, input, "/test/escaped.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found_brace = false;
	var found_backslash = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "{") != null) found_brace = true;
		if (std.mem.indexOf(u8, s.content, "\\") != null) found_backslash = true;
	}
	try testing.expect(found_brace);
	try testing.expect(found_backslash);
}

test "RTF: ignorable destination (\\*) skips unknown groups" {
	const input = "{\\rtf1 {\\*\\unknowndest some junk} Visible text}";
	const doc = try parse(testing.allocator, input, "/test/ignorable.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found_visible = false;
	var found_junk = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "Visible text") != null) found_visible = true;
		if (std.mem.indexOf(u8, s.content, "junk") != null) found_junk = true;
	}
	try testing.expect(found_visible);
	try testing.expect(!found_junk);
}

test "RTF: Windows-1252 special range (0x80-0x9F)" {
	// \'80 = Euro sign (U+20AC), \'93 = left double quote (U+201C)
	const input = "{\\rtf1 Price: \\'80" ++ "100 \\'93Hello\\'94}";
	const doc = try parse(testing.allocator, input, "/test/win1252special.rtf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	var found_euro = false;
	for (doc.sections) |s| {
		// Euro sign U+20AC in UTF-8 is 0xE2 0x82 0xAC
		if (std.mem.indexOf(u8, s.content, "\xE2\x82\xAC") != null) found_euro = true;
	}
	try testing.expect(found_euro);
}

//! PDF parser for docscan.
//! Extracts text content from PDF files and infers document structure
//! via font-size heuristics (larger text = headings, dominant size = body).
//! Uses pdf_objects.zig for low-level PDF infrastructure.
//! Pure computation — no I/O. Receives byte slices, returns a Document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document = @import("document.zig");
const Document = document.Document;
const Section = document.Section;
const MetadataEntry = document.MetadataEntry;
const Format = document.Format;
const pdf_objects = @import("pdf_objects.zig");
const PdfContext = pdf_objects.PdfContext;
const PdfValue = pdf_objects.PdfValue;
const PdfError = pdf_objects.PdfError;

/// ToUnicode CMap: maps glyph IDs (as u16) to Unicode text.
/// Built from PDF font /ToUnicode streams.
const CMap = struct {
	/// Single character mappings: glyph_id -> unicode codepoint(s)
	char_map: std.AutoHashMap(u16, []const u8),
	/// Range mappings: start_glyph -> (end_glyph, base_unicode)
	ranges: std.ArrayList(CMapRange),
	allocator: Allocator,

	const CMapRange = struct {
		start: u16,
		end: u16,
		base_unicode: u21, // first Unicode codepoint in range
	};

	fn init(allocator: Allocator) CMap {
		return .{
			.char_map = std.AutoHashMap(u16, []const u8).init(allocator),
			.ranges = std.ArrayList(CMapRange){},
			.allocator = allocator,
		};
	}

	fn deinit(self: *CMap) void {
		var iter = self.char_map.iterator();
		while (iter.next()) |entry| {
			self.allocator.free(entry.value_ptr.*);
		}
		self.char_map.deinit();
		self.ranges.deinit(self.allocator);
	}

	/// Look up a glyph ID and return the corresponding Unicode text, or null.
	fn lookup(self: *const CMap, glyph_id: u16) ?[]const u8 {
		if (self.char_map.get(glyph_id)) |text| return text;
		// Check ranges
		for (self.ranges.items) |range| {
			if (glyph_id >= range.start and glyph_id <= range.end) {
				// Would need to encode the unicode codepoint to UTF-8
				// For now, return null for range lookups (handled by caller)
				return null;
			}
		}
		return null;
	}

	/// Look up a glyph ID, returning Unicode codepoint for range-based mappings.
	fn lookupCodepoint(self: *const CMap, glyph_id: u16) ?u21 {
		// Check ranges first (lighter weight than string alloc)
		for (self.ranges.items) |range| {
			if (glyph_id >= range.start and glyph_id <= range.end) {
				const delta = glyph_id - range.start;
				return range.base_unicode + delta;
			}
		}
		return null;
	}
};

/// Parse a ToUnicode CMap stream into a CMap.
/// Handles beginbfchar/endbfchar and beginbfrange/endbfrange sections.
fn parseCMap(allocator: Allocator, data: []const u8) CMap {
	var cmap = CMap.init(allocator);

	var pos: usize = 0;
	while (pos < data.len) {
		// Find beginbfchar or beginbfrange (handle \n, \r\n, and \r line endings)
		if (pos + 11 <= data.len and std.mem.eql(u8, data[pos .. pos + 11], "beginbfchar")) {
			pos += 11;
			// Skip the line ending
			if (pos < data.len and data[pos] == '\r') pos += 1;
			if (pos < data.len and data[pos] == '\n') pos += 1;
			parseBfCharSection(allocator, data, &pos, &cmap);
		} else if (pos + 12 <= data.len and std.mem.eql(u8, data[pos .. pos + 12], "beginbfrange")) {
			pos += 12;
			if (pos < data.len and data[pos] == '\r') pos += 1;
			if (pos < data.len and data[pos] == '\n') pos += 1;
			parseBfRangeSection(allocator, data, &pos, &cmap);
		} else {
			pos += 1;
		}
	}

	return cmap;
}

/// Parse a bfchar section: lines of "<srcCode> <dstCode>" until endbfchar.
fn parseBfCharSection(allocator: Allocator, data: []const u8, pos: *usize, cmap: *CMap) void {
	while (pos.* < data.len) {
		// Skip whitespace
		while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\t' or data[pos.*] == '\n' or data[pos.*] == '\r')) {
			pos.* += 1;
		}
		if (pos.* >= data.len) return;

		// Check for endbfchar
		if (pos.* + 9 <= data.len and std.mem.eql(u8, data[pos.* .. pos.* + 9], "endbfchar")) {
			pos.* += 9;
			return;
		}

		// Parse <srcCode>
		const src = parseHexToken(data, pos) orelse return;
		// Skip whitespace
		while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\t')) {
			pos.* += 1;
		}
		// Parse <dstCode>
		const dst = parseHexToken(data, pos) orelse return;

		// Convert dst hex to UTF-8 string
		const utf8 = hexToUtf8(allocator, dst) catch continue;
		cmap.char_map.put(hexToU16(src), utf8) catch continue;
	}
}

/// Parse a bfrange section: lines of "<start> <end> <base>" until endbfrange.
fn parseBfRangeSection(allocator: Allocator, data: []const u8, pos: *usize, cmap: *CMap) void {
	_ = allocator;
	while (pos.* < data.len) {
		while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\t' or data[pos.*] == '\n' or data[pos.*] == '\r')) {
			pos.* += 1;
		}
		if (pos.* >= data.len) return;

		if (pos.* + 10 <= data.len and std.mem.eql(u8, data[pos.* .. pos.* + 10], "endbfrange")) {
			pos.* += 10;
			return;
		}

		const start = parseHexToken(data, pos) orelse return;
		while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\t')) pos.* += 1;
		const end_tok = parseHexToken(data, pos) orelse return;
		while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\t')) pos.* += 1;

		// The base can be a hex token <XXXX> or an array [<X> <Y> ...]
		if (pos.* < data.len and data[pos.*] == '<') {
			const base = parseHexToken(data, pos) orelse return;
			const base_cp = hexToU21(base);
			cmap.ranges.append(cmap.allocator, CMap.CMapRange{
				.start = hexToU16(start),
				.end = hexToU16(end_tok),
				.base_unicode = base_cp,
			}) catch continue;
		} else if (pos.* < data.len and data[pos.*] == '[') {
			// Array form — skip for now, less common
			while (pos.* < data.len and data[pos.*] != ']') pos.* += 1;
			if (pos.* < data.len) pos.* += 1;
		}
	}
}

/// Parse a hex token like <0042> and return the hex digits (without brackets).
fn parseHexToken(data: []const u8, pos: *usize) ?[]const u8 {
	if (pos.* >= data.len or data[pos.*] != '<') return null;
	pos.* += 1;
	const start = pos.*;
	while (pos.* < data.len and data[pos.*] != '>') pos.* += 1;
	const end_pos = pos.*;
	if (pos.* < data.len) pos.* += 1;
	if (start >= end_pos) return null;
	return data[start..end_pos];
}

/// Convert hex string (e.g. "0042") to u16.
fn hexToU16(hex: []const u8) u16 {
	var result: u16 = 0;
	for (hex) |c| {
		result <<= 4;
		if (c >= '0' and c <= '9') {
			result |= @as(u16, c - '0');
		} else if (c >= 'a' and c <= 'f') {
			result |= @as(u16, c - 'a' + 10);
		} else if (c >= 'A' and c <= 'F') {
			result |= @as(u16, c - 'A' + 10);
		}
	}
	return result;
}

/// Convert hex string to u21 (Unicode codepoint).
fn hexToU21(hex: []const u8) u21 {
	var result: u21 = 0;
	for (hex) |c| {
		result <<= 4;
		if (c >= '0' and c <= '9') {
			result |= @as(u21, c - '0');
		} else if (c >= 'a' and c <= 'f') {
			result |= @as(u21, c - 'a' + 10);
		} else if (c >= 'A' and c <= 'F') {
			result |= @as(u21, c - 'A' + 10);
		}
	}
	return result;
}

/// Convert hex-encoded Unicode codepoints to UTF-8 string.
/// Input is hex digits like "0042" (= U+0042 = 'B') or "00420043" (= "BC").
fn hexToUtf8(allocator: Allocator, hex: []const u8) ![]const u8 {
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);

	var i: usize = 0;
	while (i + 4 <= hex.len) {
		const cp = hexToU21(hex[i .. i + 4]);
		if (cp <= 0x7F) {
			try buf.append(allocator, @intCast(cp));
		} else if (cp <= 0x7FF) {
			try buf.append(allocator, @intCast(0xC0 | (cp >> 6)));
			try buf.append(allocator, @intCast(0x80 | (cp & 0x3F)));
		} else if (cp <= 0xFFFF) {
			try buf.append(allocator, @intCast(0xE0 | (cp >> 12)));
			try buf.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
			try buf.append(allocator, @intCast(0x80 | (cp & 0x3F)));
		}
		i += 4;
	}

	return try buf.toOwnedSlice(allocator);
}

/// Encode a single Unicode codepoint to UTF-8 bytes in the provided buffer.
/// Returns the number of bytes written (1-4).
fn encodeUtf8(cp: u21, buf: *[4]u8) u3 {
	if (cp <= 0x7F) {
		buf[0] = @intCast(cp);
		return 1;
	} else if (cp <= 0x7FF) {
		buf[0] = @intCast(0xC0 | (cp >> 6));
		buf[1] = @intCast(0x80 | (cp & 0x3F));
		return 2;
	} else if (cp <= 0xFFFF) {
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

/// Font-to-CMap mapping for a page's font resources.
const FontMap = std.StringHashMap(CMap);

/// A span of text extracted from a PDF content stream, with font metadata.
const TextSpan = struct {
	text: []const u8, // owned
	font_size: f32,
	page: u32,
	y_position: f32,
};

/// A flat section before nesting is applied.
const FlatSection = struct {
	heading: ?[]const u8, // owned
	level: u8,
	content_buf: std.ArrayList(u8),
	page: ?u32 = null, // 1-based page number from first span

	fn deinit(self: *FlatSection, gpa: Allocator) void {
		if (self.heading) |h| gpa.free(h);
		self.content_buf.deinit(gpa);
	}
};

/// Parse a PDF byte buffer into a Document with inferred heading structure.
/// Caller owns the returned Document; free with `freeDocument`.
pub fn parse(allocator: Allocator, content: []const u8, path: []const u8) !Document {
	// Initialize PDF context (xref, trailer)
	var ctx = PdfContext.init(allocator, content) catch {
		// If we can't parse the PDF structure at all, return an empty document
		return emptyDocument(allocator, path);
	};
	defer ctx.deinit();

	// Find the catalog (/Root) from the trailer
	const root_ref = if (ctx.trailer_dict) |td| pdf_objects.getDictRef(td, "Root") else null;
	if (root_ref == null) return emptyDocument(allocator, path);

	const catalog_val = (ctx.getObject(root_ref.?.obj) catch null) orelse return emptyDocument(allocator, path);
	defer pdf_objects.freePdfValue(allocator, catalog_val);
	if (catalog_val != .dict) return emptyDocument(allocator, path);

	// Find /Pages reference
	const pages_ref = pdf_objects.getDictRef(catalog_val.dict, "Pages") orelse return emptyDocument(allocator, path);

	// Collect text spans from all pages
	var spans = std.ArrayList(TextSpan){};
	defer {
		for (spans.items) |span| allocator.free(span.text);
		spans.deinit(allocator);
	}

	try collectPageSpans(allocator, &ctx, pages_ref.obj, &spans, 1);

	// Infer structure from font sizes
	const sections = try inferStructure(allocator, spans.items);
	errdefer {
		for (sections) |s| freeSectionContents(allocator, s);
		if (sections.len > 0) allocator.free(sections);
	}

	// Extract title from first heading or first text
	var title: ?[]const u8 = null;
	if (sections.len > 0 and sections[0].heading != null) {
		title = try allocator.dupe(u8, sections[0].heading.?);
	}
	errdefer if (title) |t| allocator.free(t);

	const path_dupe = try allocator.dupe(u8, path);
	errdefer allocator.free(path_dupe);

	return Document{
		.path = path_dupe,
		.format = .pdf,
		.title = title,
		.metadata = try allocator.alloc(MetadataEntry, 0),
		.sections = sections,
	};
}

/// Recursively collect text spans from a page tree node (Pages or Page).
fn collectPageSpans(allocator: Allocator, ctx: *PdfContext, obj_num: u64, spans: *std.ArrayList(TextSpan), page_counter: u32) PdfError!void {
	const obj = (ctx.getObject(obj_num) catch return) orelse return;
	defer pdf_objects.freePdfValue(allocator, obj);

	if (obj != .dict) return;

	const type_name = pdf_objects.getDictName(obj.dict, "Type");

	if (type_name != null and std.mem.eql(u8, type_name.?, "Pages")) {
		// Pages node — recurse into /Kids
		const kids = pdf_objects.getDictArray(obj.dict, "Kids") orelse return;
		var page_num = page_counter;
		for (kids) |kid| {
			if (kid == .reference) {
				try collectPageSpans(allocator, ctx, kid.reference.obj, spans, page_num);
				page_num += 1;
			}
		}
	} else if (type_name != null and std.mem.eql(u8, type_name.?, "Page")) {
		// Single page — extract text from /Contents
		try extractPageText(allocator, ctx, obj.dict, spans, page_counter);
	}
}

/// Extract text spans from a single page's content stream(s).
fn extractPageText(allocator: Allocator, ctx: *PdfContext, page_dict: []const pdf_objects.DictEntry, spans: *std.ArrayList(TextSpan), page_num: u32) PdfError!void {
	// Build font CMap table from page resources
	var font_maps = FontMap.init(allocator);
	defer {
		var iter = font_maps.iterator();
		while (iter.next()) |entry| {
			var cm = entry.value_ptr.*;
			cm.deinit();
		}
		font_maps.deinit();
	}
	buildFontMaps(allocator, ctx, page_dict, &font_maps);

	// Get the content stream reference
	// /Contents can be a single reference or an array of references
	for (page_dict) |entry| {
		if (!std.mem.eql(u8, entry.key, "Contents")) continue;

		if (entry.value == .reference) {
			const stream_data = (ctx.getStream(entry.value.reference.obj) catch return) orelse return;
			defer allocator.free(stream_data);
			try parseContentStream(allocator, stream_data, spans, page_num, &font_maps);
		} else if (entry.value == .array) {
			for (entry.value.array) |item| {
				if (item == .reference) {
					const stream_data = (ctx.getStream(item.reference.obj) catch continue) orelse continue;
					defer allocator.free(stream_data);
					try parseContentStream(allocator, stream_data, spans, page_num, &font_maps);
				}
			}
		}
		break;
	}
}

/// Build font-name-to-CMap mappings from a page's /Resources/Font dictionary.
fn buildFontMaps(allocator: Allocator, ctx: *PdfContext, page_dict: []const pdf_objects.DictEntry, font_maps: *FontMap) void {
	// Find /Resources dict (may be direct or indirect)
	const resources = pdf_objects.getDictDict(page_dict, "Resources") orelse {
		// Try indirect reference
		const res_ref = pdf_objects.getDictRef(page_dict, "Resources") orelse return;
		const res_val = (ctx.getObject(res_ref.obj) catch return) orelse return;
		defer pdf_objects.freePdfValue(allocator, res_val);
		if (res_val != .dict) return;
		buildFontMapsFromResources(allocator, ctx, res_val.dict, font_maps);
		return;
	};
	buildFontMapsFromResources(allocator, ctx, resources, font_maps);
}

fn buildFontMapsFromResources(allocator: Allocator, ctx: *PdfContext, resources: []const pdf_objects.DictEntry, font_maps: *FontMap) void {
	// Find /Font dict within resources
	const font_dict_or_ref = blk: {
		for (resources) |entry| {
			if (std.mem.eql(u8, entry.key, "Font")) {
				break :blk entry.value;
			}
		}
		return;
	};

	var font_dict: []const pdf_objects.DictEntry = undefined;
	var owned_font_dict: ?pdf_objects.PdfValue = null;

	if (font_dict_or_ref == .dict) {
		font_dict = font_dict_or_ref.dict;
	} else if (font_dict_or_ref == .reference) {
		const resolved = (ctx.getObject(font_dict_or_ref.reference.obj) catch return) orelse return;
		if (resolved != .dict) {
			pdf_objects.freePdfValue(allocator, resolved);
			return;
		}
		owned_font_dict = resolved;
		font_dict = resolved.dict;
	} else {
		return;
	}
	defer if (owned_font_dict) |v| pdf_objects.freePdfValue(allocator, v);

	// For each font in /Font dict, check for /ToUnicode
	for (font_dict) |font_entry| {
		const font_name = font_entry.key; // e.g. "F1"

		// Get the font object (may be direct dict or reference)
		var font_obj_dict: []const pdf_objects.DictEntry = undefined;
		var owned_font_obj: ?pdf_objects.PdfValue = null;

		if (font_entry.value == .dict) {
			font_obj_dict = font_entry.value.dict;
		} else if (font_entry.value == .reference) {
			const resolved = (ctx.getObject(font_entry.value.reference.obj) catch continue) orelse continue;
			if (resolved != .dict) {
				pdf_objects.freePdfValue(allocator, resolved);
				continue;
			}
			owned_font_obj = resolved;
			font_obj_dict = resolved.dict;
		} else {
			continue;
		}
		defer if (owned_font_obj) |v| pdf_objects.freePdfValue(allocator, v);

		// Check for /ToUnicode stream reference
		const tounicode_ref = pdf_objects.getDictRef(font_obj_dict, "ToUnicode") orelse continue;
		const cmap_data = (ctx.getStream(tounicode_ref.obj) catch continue) orelse continue;
		defer allocator.free(cmap_data);

		var cmap = parseCMap(allocator, cmap_data);
		font_maps.put(font_name, cmap) catch {
			cmap.deinit();
			continue;
		};
	}
}

/// Parse a PDF content stream and extract text spans.
/// Handles BT/ET blocks, Tf (font size), Tj/TJ (show text), Td/TD/Tm (positioning).
/// font_maps provides ToUnicode CMap lookups for hex-encoded glyph IDs.
fn parseContentStream(allocator: Allocator, stream: []const u8, spans: *std.ArrayList(TextSpan), page_num: u32, font_maps: ?*const FontMap) PdfError!void {
	var pos: usize = 0;
	var current_font_size: f32 = 12.0; // default
	var current_font_name: ?[]const u8 = null; // e.g., "F1" — points into stream data
	var last_name: ?[]const u8 = null; // last /Name token seen (for Tf matching)
	var y_pos: f32 = 0;
	var in_text_block = false;

	while (pos < stream.len) {
		pos = skipStreamWhitespace(stream, pos);
		if (pos >= stream.len) break;

		const ch = stream[pos];

		// PDF string: (text)
		if (ch == '(') {
			const str = extractStreamString(allocator, stream, &pos) catch continue;
			// Look ahead for Tj or '
			const next_pos = skipStreamWhitespace(stream, pos);
			if (next_pos < stream.len) {
				if (stream[next_pos] == 'T' and next_pos + 1 < stream.len and stream[next_pos + 1] == 'j') {
					pos = next_pos + 2;
					if (in_text_block and str.len > 0) {
						spans.append(allocator, TextSpan{
							.text = str,
							.font_size = current_font_size,
							.page = page_num,
							.y_position = y_pos,
						}) catch return PdfError.OutOfMemory;
						continue;
					}
				} else if (stream[next_pos] == '\'') {
					pos = next_pos + 1;
					if (in_text_block and str.len > 0) {
						spans.append(allocator, TextSpan{
							.text = str,
							.font_size = current_font_size,
							.page = page_num,
							.y_position = y_pos,
						}) catch return PdfError.OutOfMemory;
						continue;
					}
				}
			}
			allocator.free(str);
			continue;
		}

		// Hex string: <hex> — could be Tj operand with glyph IDs
		if (ch == '<' and pos + 1 < stream.len and stream[pos + 1] != '<') {
			const hex_text = extractHexStringText(allocator, stream, &pos, getCurrentCMap(font_maps, current_font_name)) catch continue;
			const next_pos = skipStreamWhitespace(stream, pos);
			if (next_pos < stream.len) {
				if (stream[next_pos] == 'T' and next_pos + 1 < stream.len and stream[next_pos + 1] == 'j') {
					pos = next_pos + 2;
					if (in_text_block and hex_text.len > 0) {
						spans.append(allocator, TextSpan{
							.text = hex_text,
							.font_size = current_font_size,
							.page = page_num,
							.y_position = y_pos,
						}) catch return PdfError.OutOfMemory;
						continue;
					}
				} else if (stream[next_pos] == '\'') {
					pos = next_pos + 1;
					if (in_text_block and hex_text.len > 0) {
						spans.append(allocator, TextSpan{
							.text = hex_text,
							.font_size = current_font_size,
							.page = page_num,
							.y_position = y_pos,
						}) catch return PdfError.OutOfMemory;
						continue;
					}
				}
			}
			allocator.free(hex_text);
			continue;
		}

		// PDF array: [...] — could be TJ operand
		if (ch == '[') {
			const arr_text = extractTJArray(allocator, stream, &pos, getCurrentCMap(font_maps, current_font_name)) catch continue;
			const next_pos = skipStreamWhitespace(stream, pos);
			if (next_pos + 1 < stream.len and stream[next_pos] == 'T' and stream[next_pos + 1] == 'J') {
				pos = next_pos + 2;
				if (in_text_block and arr_text.len > 0) {
					spans.append(allocator, TextSpan{
						.text = arr_text,
						.font_size = current_font_size,
						.page = page_num,
						.y_position = y_pos,
					}) catch return PdfError.OutOfMemory;
					continue;
				}
			}
			allocator.free(arr_text);
			continue;
		}

		// Check for operators/keywords
		if (ch == 'B' and pos + 1 < stream.len and stream[pos + 1] == 'T') {
			if (pos + 2 >= stream.len or isDelimiter(stream[pos + 2])) {
				in_text_block = true;
				// Per PDF spec, BT resets the text matrix and text line matrix
				// to identity. Td offsets are relative within a BT block.
				y_pos = 0;
				pos += 2;
				continue;
			}
		}

		if (ch == 'E' and pos + 1 < stream.len and stream[pos + 1] == 'T') {
			if (pos + 2 >= stream.len or isDelimiter(stream[pos + 2])) {
				in_text_block = false;
				pos += 2;
				continue;
			}
		}

		// Tf — set font: /FontName size Tf
		if (ch == 'T' and pos + 1 < stream.len and stream[pos + 1] == 'f') {
			if (pos + 2 >= stream.len or isDelimiter(stream[pos + 2])) {
				pos += 2;
				continue;
			}
		}

		// Td/TD — move text position
		if (ch == 'T' and pos + 1 < stream.len and (stream[pos + 1] == 'd' or stream[pos + 1] == 'D')) {
			if (pos + 2 >= stream.len or isDelimiter(stream[pos + 2])) {
				pos += 2;
				continue;
			}
		}

		// Tm — set text matrix
		if (ch == 'T' and pos + 1 < stream.len and stream[pos + 1] == 'm') {
			if (pos + 2 >= stream.len or isDelimiter(stream[pos + 2])) {
				pos += 2;
				continue;
			}
		}

		// T* — new line
		if (ch == 'T' and pos + 1 < stream.len and stream[pos + 1] == '*') {
			pos += 2;
			continue;
		}

		// Number — could be operand for Tf, Td, Tm etc.
		if (ch == '-' or ch == '+' or ch == '.' or (ch >= '0' and ch <= '9')) {
			const num = parseStreamNumber(stream, &pos);
			// Look ahead to see if this is a font size operand (number before Tf)
			const save_pos = pos;
			const ws_pos = skipStreamWhitespace(stream, pos);

			// Check for "number Tf" pattern — that's the font size
			// Full pattern: /FontName fontSize Tf
			if (ws_pos < stream.len and stream[ws_pos] == 'T' and ws_pos + 1 < stream.len and stream[ws_pos + 1] == 'f') {
				if (ws_pos + 2 >= stream.len or isDelimiter(stream[ws_pos + 2])) {
					current_font_size = num;
					current_font_name = last_name;
					pos = ws_pos + 2;
					continue;
				}
			}

			// Check for "number number Td/TD" pattern — second number is y offset
			if (ws_pos < stream.len and (stream[ws_pos] == '-' or stream[ws_pos] == '+' or stream[ws_pos] == '.' or (stream[ws_pos] >= '0' and stream[ws_pos] <= '9'))) {
				var peek_pos = ws_pos;
				const num2 = parseStreamNumber(stream, &peek_pos);
				const ws2 = skipStreamWhitespace(stream, peek_pos);
				if (ws2 < stream.len and stream[ws2] == 'T' and ws2 + 1 < stream.len and (stream[ws2 + 1] == 'd' or stream[ws2 + 1] == 'D')) {
					if (ws2 + 2 >= stream.len or isDelimiter(stream[ws2 + 2])) {
						y_pos += num2;
						pos = ws2 + 2;
						continue;
					}
				}

				// Check for Tm pattern: 6 numbers then Tm
				// a b c d e f Tm — font_size from d, y from f
				// We already parsed 2 numbers. Try to parse 4 more.
				var tm_pos = ws2;
				var tm_nums: [4]f32 = undefined;
				var tm_count: usize = 0;
				while (tm_count < 4) : (tm_count += 1) {
					tm_pos = skipStreamWhitespace(stream, tm_pos);
					if (tm_pos >= stream.len) break;
					if (stream[tm_pos] != '-' and stream[tm_pos] != '+' and stream[tm_pos] != '.' and (stream[tm_pos] < '0' or stream[tm_pos] > '9')) break;
					tm_nums[tm_count] = parseStreamNumber(stream, &tm_pos);
				}
				if (tm_count == 4) {
					const ws3 = skipStreamWhitespace(stream, tm_pos);
					if (ws3 < stream.len and stream[ws3] == 'T' and ws3 + 1 < stream.len and stream[ws3 + 1] == 'm') {
						if (ws3 + 2 >= stream.len or isDelimiter(stream[ws3 + 2])) {
							// Matrix [a b c d e f] — d is y-scale (font size), f is y-position
							const d_val = tm_nums[1]; // [a,b,c,d,e,f] = [num, num2, tm[0], tm[1], tm[2], tm[3]]
							const f_val = tm_nums[3];
							if (@abs(d_val) > 0.1) current_font_size = @abs(d_val);
							y_pos = f_val;
							pos = ws3 + 2;
							continue;
						}
					}
				}
			}

			pos = save_pos;
			continue;
		}

		// Name token (e.g., /F1 in "/F1 12 Tf")
		if (ch == '/') {
			// Capture the name (for font tracking via Tf)
			pos += 1;
			const name_start = pos;
			while (pos < stream.len and !isDelimiter(stream[pos])) pos += 1;
			// Remember the last name token for Tf operator matching
			last_name = stream[name_start..pos];
			continue;
		}

		// Skip unknown single-character operators or tokens
		pos += 1;
	}
}

/// Extract a string from PDF content stream parenthesized string.
fn extractStreamString(allocator: Allocator, data: []const u8, pos: *usize) ![]const u8 {
	var p = pos.* + 1; // skip '('
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);
	var depth: u32 = 1;

	while (p < data.len and depth > 0) {
		const c = data[p];
		if (c == '\\' and p + 1 < data.len) {
			p += 1;
			switch (data[p]) {
				'n' => {
					try buf.append(allocator, '\n');
					p += 1;
				},
				'r' => {
					try buf.append(allocator, '\r');
					p += 1;
				},
				't' => {
					try buf.append(allocator, '\t');
					p += 1;
				},
				'\\' => {
					try buf.append(allocator, '\\');
					p += 1;
				},
				'(' => {
					try buf.append(allocator, '(');
					p += 1;
				},
				')' => {
					try buf.append(allocator, ')');
					p += 1;
				},
				'0'...'7' => {
					var octal: u8 = data[p] - '0';
					p += 1;
					if (p < data.len and data[p] >= '0' and data[p] <= '7') {
						octal = octal * 8 + (data[p] - '0');
						p += 1;
						if (p < data.len and data[p] >= '0' and data[p] <= '7') {
							octal = octal * 8 + (data[p] - '0');
							p += 1;
						}
					}
					try buf.append(allocator, octal);
				},
				else => {
					try buf.append(allocator, data[p]);
					p += 1;
				},
			}
		} else if (c == '(') {
			depth += 1;
			try buf.append(allocator, c);
			p += 1;
		} else if (c == ')') {
			depth -= 1;
			if (depth > 0) try buf.append(allocator, c);
			p += 1;
		} else {
			try buf.append(allocator, c);
			p += 1;
		}
	}

	pos.* = p;
	return try buf.toOwnedSlice(allocator);
}

/// Get the CMap for the current font, if available.
fn getCurrentCMap(font_maps: ?*const FontMap, font_name: ?[]const u8) ?*const CMap {
	const maps = font_maps orelse return null;
	const name = font_name orelse return null;
	return maps.getPtr(name);
}

/// Extract text from a hex string like <0042004300440045>, decoding
/// glyph IDs via CMap if available, otherwise returning raw bytes.
fn extractHexStringText(allocator: Allocator, data: []const u8, pos: *usize, cmap: ?*const CMap) ![]const u8 {
	var p = pos.* + 1; // skip '<'
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);

	// Collect hex digits
	var hex_buf = std.ArrayList(u8){};
	defer hex_buf.deinit(allocator);
	while (p < data.len and data[p] != '>') {
		const c = data[p];
		if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
			try hex_buf.append(allocator, c);
		}
		p += 1;
	}
	if (p < data.len) p += 1; // skip '>'
	pos.* = p;

	// Decode hex string using CMap
	if (cmap) |cm| {
		var i: usize = 0;
		const hex = hex_buf.items;
		while (i + 2 <= hex.len) {
			// Try 2-byte (4 hex digit) glyph ID first
			if (i + 4 <= hex.len) {
				const glyph_id = hexToU16(hex[i .. i + 4]);
				if (cm.lookup(glyph_id)) |text| {
					try buf.appendSlice(allocator, text);
					i += 4;
					continue;
				}
				// Try range lookup
				if (cm.lookupCodepoint(glyph_id)) |cp| {
					var utf8_buf: [4]u8 = undefined;
					const n = encodeUtf8(cp, &utf8_buf);
					try buf.appendSlice(allocator, utf8_buf[0..n]);
					i += 4;
					continue;
				}
			}
			// Try 1-byte (2 hex digit) glyph ID
			const glyph_id_1 = hexToU16(hex[i .. i + 2]);
			if (cm.lookup(glyph_id_1)) |text| {
				try buf.appendSlice(allocator, text);
				i += 2;
				continue;
			}
			if (cm.lookupCodepoint(glyph_id_1)) |cp| {
				var utf8_buf: [4]u8 = undefined;
				const n = encodeUtf8(cp, &utf8_buf);
				try buf.appendSlice(allocator, utf8_buf[0..n]);
				i += 2;
				continue;
			}
			// No mapping found — skip this glyph
			i += 2;
		}
	} else {
		// No CMap — try to interpret as raw bytes (standard encoding)
		var i: usize = 0;
		const hex = hex_buf.items;
		while (i + 2 <= hex.len) {
			const byte_val = hexToU16(hex[i .. i + 2]);
			if (byte_val >= 0x20 and byte_val < 0x7F) {
				try buf.append(allocator, @intCast(byte_val));
			}
			i += 2;
		}
	}

	return try buf.toOwnedSlice(allocator);
}

/// Extract text from a TJ array: [(text) kern (text) kern ...]
/// Numbers represent kerning; large negative values insert spaces.
/// Hex strings (<XX>) are decoded via CMap if available.
fn extractTJArray(allocator: Allocator, data: []const u8, pos: *usize, cmap: ?*const CMap) ![]const u8 {
	var p = pos.* + 1; // skip '['
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);

	while (p < data.len and data[p] != ']') {
		const c = data[p];
		if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
			p += 1;
			continue;
		}
		if (c == '(') {
			const str = try extractStreamString(allocator, data, &p);
			defer allocator.free(str);
			try buf.appendSlice(allocator, str);
		} else if (c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9')) {
			// Kerning value: large negative numbers indicate word boundaries
			const kern = parseStreamNumber(data, &p);
			if (kern < -200) {
				try buf.append(allocator, ' ');
			}
		} else if (c == '<') {
			// Hex string in TJ array — decode via CMap if available
			const hex_text = extractHexStringText(allocator, data, &p, cmap) catch {
				// Skip on error
				while (p < data.len and data[p] != '>') p += 1;
				if (p < data.len) p += 1;
				continue;
			};
			defer allocator.free(hex_text);
			try buf.appendSlice(allocator, hex_text);
		} else {
			p += 1;
		}
	}
	if (p < data.len and data[p] == ']') p += 1;
	pos.* = p;
	return try buf.toOwnedSlice(allocator);
}

/// Parse a floating-point or integer number from stream content.
fn parseStreamNumber(data: []const u8, pos: *usize) f32 {
	var p = pos.*;
	var sign: f32 = 1;
	if (p < data.len and (data[p] == '-' or data[p] == '+')) {
		if (data[p] == '-') sign = -1;
		p += 1;
	}

	var int_part: f32 = 0;
	while (p < data.len and data[p] >= '0' and data[p] <= '9') {
		int_part = int_part * 10 + @as(f32, @floatFromInt(data[p] - '0'));
		p += 1;
	}

	if (p < data.len and data[p] == '.') {
		p += 1;
		var frac: f32 = 0;
		var divisor: f32 = 10;
		while (p < data.len and data[p] >= '0' and data[p] <= '9') {
			frac += @as(f32, @floatFromInt(data[p] - '0')) / divisor;
			divisor *= 10;
			p += 1;
		}
		pos.* = p;
		return sign * (int_part + frac);
	}

	pos.* = p;
	return sign * int_part;
}

fn skipStreamWhitespace(data: []const u8, start: usize) usize {
	var p = start;
	while (p < data.len and (data[p] == ' ' or data[p] == '\t' or data[p] == '\n' or data[p] == '\r')) p += 1;
	return p;
}

fn isDelimiter(c: u8) bool {
	return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
		c == '/' or c == '<' or c == '>' or c == '[' or c == ']' or
		c == '(' or c == ')' or c == '{' or c == '}';
}

// ── Structure Inference ────────────────────────────────────────────

/// Infer document structure from text spans using font size heuristics.
/// Larger text = headings, dominant (most common) size = body text.
fn inferStructure(allocator: Allocator, spans: []const TextSpan) ![]const Section {
	if (spans.len == 0) return try allocator.alloc(Section, 0);

	// Find dominant font size (most common, by total character count)
	var size_counts = std.AutoHashMap(u32, usize).init(allocator);
	defer size_counts.deinit();

	for (spans) |span| {
		const key = @as(u32, @bitCast(span.font_size));
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
			// Add if not already present
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
	var prev_y: f32 = 0;
	var prev_page: u32 = 0;
	var prev_font_size: f32 = 12.0;
	var has_prev_body: bool = false;

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
			has_prev_body = false;
		} else {
			// Body text — start new section on page change
			if (current == null or (has_prev_body and span.page != prev_page)) {
				try flat_sections.append(allocator, FlatSection{
					.heading = null,
					.level = 0,
					.content_buf = .{},
					.page = span.page,
				});
				current = flat_sections.items.len - 1;
				has_prev_body = false;
			}
			const fs = &flat_sections.items[current.?];
			if (fs.content_buf.items.len > 0) {
				// Decide separator: space (same line) vs newline (different line)
				if (has_prev_body) {
					const y_diff = @abs(span.y_position - prev_y);
					const line_threshold = prev_font_size * 1.2;
					if (y_diff < line_threshold) {
						try fs.content_buf.append(allocator, ' ');
					} else {
						try fs.content_buf.append(allocator, '\n');
					}
				} else {
					try fs.content_buf.append(allocator, '\n');
				}
			}
			try fs.content_buf.appendSlice(allocator, span.text);
			prev_y = span.y_position;
			prev_page = span.page;
			prev_font_size = span.font_size;
			has_prev_body = true;
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
	gpa: Allocator,
	flat: []const FlatSection,
	start: usize,
	end: usize,
) ![]const Section {
	var sections: std.ArrayList(Section) = .{};
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

		// Find range of children
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
			.page = fs.page,
		});

		i = child_end;
	}

	return try sections.toOwnedSlice(gpa);
}

fn emptyDocument(allocator: Allocator, path: []const u8) !Document {
	const path_dupe = try allocator.dupe(u8, path);
	return Document{
		.path = path_dupe,
		.format = .pdf,
		.title = null,
		.metadata = try allocator.alloc(MetadataEntry, 0),
		.sections = try allocator.alloc(Section, 0),
	};
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

// ── Test Helpers ───────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal valid PDF with text content at a given font size.
/// The PDF structure is: Catalog -> Pages -> Page -> Contents (uncompressed stream).
fn buildTestPdf(allocator: Allocator, pages: []const TestPage) ![]const u8 {
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);

	try buf.appendSlice(allocator, "%PDF-1.4\n");

	// Track object offsets for xref
	var obj_offsets = std.ArrayList(struct { num: u32, offset: usize }){};
	defer obj_offsets.deinit(allocator);

	// Object 1: Catalog
	try obj_offsets.append(allocator, .{ .num = 1, .offset = buf.items.len });
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

	// Object 2: Pages
	try obj_offsets.append(allocator, .{ .num = 2, .offset = buf.items.len });
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [");
	for (pages, 0..) |_, i| {
		const page_obj: u32 = @intCast(3 + i * 2); // page objects at 3, 5, 7, ...
		if (i > 0) try buf.append(allocator, ' ');
		try std.fmt.format(buf.writer(allocator), "{d} 0 R", .{page_obj});
	}
	try std.fmt.format(buf.writer(allocator), "] /Count {d} >>\nendobj\n", .{pages.len});

	// For each page, create Page + Contents objects
	for (pages, 0..) |page, i| {
		const page_obj: u32 = @intCast(3 + i * 2);
		const contents_obj: u32 = page_obj + 1;

		// Build content stream
		var stream_buf = std.ArrayList(u8){};
		defer stream_buf.deinit(allocator);

		for (page.text_items) |item| {
			try stream_buf.appendSlice(allocator, "BT\n");
			try std.fmt.format(stream_buf.writer(allocator), "/F1 {d} Tf\n", .{@as(u32, @intFromFloat(item.font_size))});
			try std.fmt.format(stream_buf.writer(allocator), "0 {d} Td\n", .{@as(i32, @intFromFloat(item.y_pos))});
			try stream_buf.appendSlice(allocator, "(");
			try stream_buf.appendSlice(allocator, item.text);
			try stream_buf.appendSlice(allocator, ") Tj\n");
			try stream_buf.appendSlice(allocator, "ET\n");
		}

		// Page object
		try obj_offsets.append(allocator, .{ .num = page_obj, .offset = buf.items.len });
		try std.fmt.format(buf.writer(allocator), "{d} 0 obj\n<< /Type /Page /Parent 2 0 R /Contents {d} 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>\nendobj\n", .{ page_obj, contents_obj });

		// Contents object (uncompressed stream)
		try obj_offsets.append(allocator, .{ .num = contents_obj, .offset = buf.items.len });
		try std.fmt.format(buf.writer(allocator), "{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ contents_obj, stream_buf.items.len });
		try buf.appendSlice(allocator, stream_buf.items);
		try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	}

	// Find max object number
	var max_obj: u32 = 0;
	for (obj_offsets.items) |o| {
		if (o.num > max_obj) max_obj = o.num;
	}

	// Xref table
	const xref_offset = buf.items.len;
	try buf.appendSlice(allocator, "xref\n");
	try std.fmt.format(buf.writer(allocator), "0 {d}\n", .{max_obj + 1});
	try buf.appendSlice(allocator, "0000000000 65535 f\n");

	var obj_idx: u32 = 1;
	while (obj_idx <= max_obj) : (obj_idx += 1) {
		var found = false;
		for (obj_offsets.items) |o| {
			if (o.num == obj_idx) {
				try std.fmt.format(buf.writer(allocator), "{d:0>10} 00000 n\n", .{o.offset});
				found = true;
				break;
			}
		}
		if (!found) {
			try buf.appendSlice(allocator, "0000000000 00000 f\n");
		}
	}

	try std.fmt.format(buf.writer(allocator), "trailer\n<< /Size {d} /Root 1 0 R >>\n", .{max_obj + 1});
	try std.fmt.format(buf.writer(allocator), "startxref\n{d}\n%%EOF", .{xref_offset});

	return try buf.toOwnedSlice(allocator);
}

const TestPage = struct {
	text_items: []const TestTextItem,
};

const TestTextItem = struct {
	text: []const u8,
	font_size: f32,
	y_pos: f32,
};

// ── Tests ──────────────────────────────────────────────────────────

test "extract text from single-page PDF" {
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "Hello World", .font_size = 12, .y_pos = 700 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/simple.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.pdf, doc.format);
	try testing.expectEqualStrings("/test/simple.pdf", doc.path);
	try testing.expect(doc.sections.len > 0);

	// Should find "Hello World" somewhere in the sections
	var found_text = false;
	for (doc.sections) |s| {
		if (s.content.len > 0 and std.mem.indexOf(u8, s.content, "Hello World") != null) {
			found_text = true;
			break;
		}
		if (s.heading) |h| {
			if (std.mem.indexOf(u8, h, "Hello World") != null) {
				found_text = true;
				break;
			}
		}
	}
	try testing.expect(found_text);
}

test "multi-page document — text from all pages" {
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "Page one content", .font_size = 12, .y_pos = 700 },
		} },
		.{ .text_items = &.{
			.{ .text = "Page two content", .font_size = 12, .y_pos = 700 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/multi.pdf");
	defer freeDocument(testing.allocator, doc);

	// Should find text from both pages
	var found_p1 = false;
	var found_p2 = false;
	for (doc.sections) |s| {
		if (std.mem.indexOf(u8, s.content, "Page one content") != null) found_p1 = true;
		if (std.mem.indexOf(u8, s.content, "Page two content") != null) found_p2 = true;
	}
	try testing.expect(found_p1);
	try testing.expect(found_p2);
}

test "font-size heading detection — large text becomes heading" {
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "Big Title", .font_size = 24, .y_pos = 750 },
			.{ .text = "Normal body text here.", .font_size = 12, .y_pos = 700 },
			.{ .text = "More body text.", .font_size = 12, .y_pos = 680 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/heading.pdf");
	defer freeDocument(testing.allocator, doc);

	// Should have at least one section with "Big Title" as heading
	try testing.expect(doc.sections.len > 0);
	try testing.expect(doc.sections[0].heading != null);
	try testing.expectEqualStrings("Big Title", doc.sections[0].heading.?);

	// Body text should be in the content
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Normal body text here.") != null);
}

test "no discernible headings — all same font size, single section" {
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "First paragraph.", .font_size = 12, .y_pos = 700 },
			.{ .text = "Second paragraph.", .font_size = 12, .y_pos = 680 },
			.{ .text = "Third paragraph.", .font_size = 12, .y_pos = 660 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/uniform.pdf");
	defer freeDocument(testing.allocator, doc);

	// All same size means no headings — everything is body text in one section
	try testing.expect(doc.sections.len >= 1);
	// Should have no headings
	for (doc.sections) |s| {
		try testing.expectEqual(@as(?[]const u8, null), s.heading);
	}
}

test "empty page / no text — graceful handling" {
	// Build a PDF with an empty content stream
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/empty.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
}

test "content stream TJ operator — array text extraction" {
	// Test the TJ array extraction directly
	const stream = "BT\n/F1 12 Tf\n[(Hello) -10 ( ) -5 (World)] TJ\nET\n";
	var spans = std.ArrayList(TextSpan){};
	defer {
		for (spans.items) |s| testing.allocator.free(s.text);
		spans.deinit(testing.allocator);
	}

	try parseContentStream(testing.allocator, stream, &spans, 0, null);

	try testing.expect(spans.items.len > 0);
	// The concatenated text should be "Hello World"
	try testing.expectEqualStrings("Hello World", spans.items[0].text);
}

test "multiple heading levels by font size" {
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "Chapter Title", .font_size = 28, .y_pos = 750 },
			.{ .text = "Section Heading", .font_size = 20, .y_pos = 700 },
			.{ .text = "Body text under section.", .font_size = 12, .y_pos = 680 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/levels.pdf");
	defer freeDocument(testing.allocator, doc);

	// Should have a top-level heading (Chapter Title) at level 1
	try testing.expect(doc.sections.len > 0);
	try testing.expect(doc.sections[0].heading != null);
	try testing.expectEqualStrings("Chapter Title", doc.sections[0].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[0].level);

	// Section Heading should be level 2 (child)
	try testing.expectEqual(@as(usize, 1), doc.sections[0].children.len);
	const child = doc.sections[0].children[0];
	try testing.expectEqualStrings("Section Heading", child.heading.?);
	try testing.expectEqual(@as(u8, 2), child.level);
}

test "TJ array — large kerning inserts space between words" {
	// In PDF, TJ array numbers are in thousandths of a text space unit.
	// Large negative values (> ~200) indicate a word boundary.
	const stream = "BT\n/F1 12 Tf\n[(Hello) -600 (World)] TJ\nET\n";
	var spans = std.ArrayList(TextSpan){};
	defer {
		for (spans.items) |s| testing.allocator.free(s.text);
		spans.deinit(testing.allocator);
	}

	try parseContentStream(testing.allocator, stream, &spans, 0, null);

	try testing.expect(spans.items.len > 0);
	// Large negative kerning (-600) should produce a space between "Hello" and "World"
	try testing.expectEqualStrings("Hello World", spans.items[0].text);
}

test "same-line spans get space separator, not newline" {
	// When two Tj operations have the same Y position, they should be
	// joined with a space, not a newline.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "The", .font_size = 12, .y_pos = 700 },
			.{ .text = "dominant", .font_size = 12, .y_pos = 700 },
			.{ .text = "sequence", .font_size = 12, .y_pos = 700 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/spacing.pdf");
	defer freeDocument(testing.allocator, doc);

	// Should have space-separated text, not newline-separated
	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	try testing.expect(content.len > 0);
	// Must contain "The dominant sequence" with spaces
	try testing.expect(std.mem.indexOf(u8, content, "The dominant sequence") != null);
}

test "different-line spans get newline separator" {
	// When spans have different Y positions (different lines), they should be
	// joined with a newline.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "Line one", .font_size = 12, .y_pos = 700 },
			.{ .text = "Line two", .font_size = 12, .y_pos = 680 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/newlines.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// Should contain a newline between lines, not a space
	try testing.expect(std.mem.indexOf(u8, content, "Line one\nLine two") != null);
}

test "CMap parsing — bfchar and bfrange sections" {
	const cmap_data =
		"/CIDInit /ProcSet findresource begin\n" ++
		"12 dict begin\n" ++
		"begincmap\n" ++
		"/CMapType 2 def\n" ++
		"1 begincodespacerange\n" ++
		"<00> <FF>\n" ++
		"endcodespacerange\n" ++
		"3 beginbfchar\n" ++
		"<01> <0042>\n" ++
		"<02> <0069>\n" ++
		"<03> <0074>\n" ++
		"endbfchar\n" ++
		"1 beginbfrange\n" ++
		"<04> <06> <0063>\n" ++
		"endbfrange\n" ++
		"endcmap\n";

	var cmap = parseCMap(testing.allocator, cmap_data);
	defer cmap.deinit();

	// bfchar mappings: 0x01 -> 'B', 0x02 -> 'i', 0x03 -> 't'
	try testing.expect(cmap.lookup(0x01) != null);
	try testing.expectEqualStrings("B", cmap.lookup(0x01).?);
	try testing.expect(cmap.lookup(0x02) != null);
	try testing.expectEqualStrings("i", cmap.lookup(0x02).?);
	try testing.expect(cmap.lookup(0x03) != null);
	try testing.expectEqualStrings("t", cmap.lookup(0x03).?);

	// bfrange mapping: 0x04 -> 'c' (U+0063), 0x05 -> 'd', 0x06 -> 'e'
	try testing.expectEqual(@as(?u21, 0x0063), cmap.lookupCodepoint(0x04));
	try testing.expectEqual(@as(?u21, 0x0064), cmap.lookupCodepoint(0x05));
	try testing.expectEqual(@as(?u21, 0x0065), cmap.lookupCodepoint(0x06));
}

test "hex string text extraction with CMap" {
	// Simulate hex-encoded glyph IDs with a CMap
	var cmap = CMap.init(testing.allocator);
	defer cmap.deinit();

	// Map glyph 0x01 -> "B", 0x02 -> "i", 0x03 -> "t"
	try cmap.char_map.put(0x01, try testing.allocator.dupe(u8, "B"));
	try cmap.char_map.put(0x02, try testing.allocator.dupe(u8, "i"));
	try cmap.char_map.put(0x03, try testing.allocator.dupe(u8, "t"));

	const data = "<010203>";
	var pos: usize = 0;
	const result = try extractHexStringText(testing.allocator, data, &pos, &cmap);
	defer testing.allocator.free(result);

	try testing.expectEqualStrings("Bit", result);
}

test "TJ array with hex strings decoded via CMap" {
	var cmap = CMap.init(testing.allocator);
	defer cmap.deinit();

	try cmap.char_map.put(0x01, try testing.allocator.dupe(u8, "H"));
	try cmap.char_map.put(0x02, try testing.allocator.dupe(u8, "i"));

	const data = "[<01> -10 <02>]";
	var pos: usize = 0;
	const result = try extractTJArray(testing.allocator, data, &pos, &cmap);
	defer testing.allocator.free(result);

	try testing.expectEqualStrings("Hi", result);
}

test "invalid PDF returns empty document" {
	const doc = try parse(testing.allocator, "this is not a PDF", "/test/bad.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
	try testing.expectEqual(Format.pdf, doc.format);
}

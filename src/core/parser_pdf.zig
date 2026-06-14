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
const encoding = @import("encoding.zig");
const wordfix = @import("wordfix.zig");

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
			.ranges = std.ArrayList(CMapRange).empty,
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
		const gop = cmap.char_map.fetchPut(hexToU16(src), utf8) catch {
			allocator.free(utf8);
			continue;
		};
		// Free old value if key already existed (prevents leak)
		if (gop) |old_entry| allocator.free(old_entry.value);
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
	var buf = std.ArrayList(u8).empty;
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
	x_position: f32,
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

/// Style of page numbering in a PDF /PageLabels entry.
const PageLabelStyle = enum {
	decimal,
	roman_lower,
	roman_upper,
	alpha_lower,
	alpha_upper,
	none,
};

/// A single entry from a PDF /PageLabels /Nums array.
/// Maps a range of physical page indices to a numbering style.
const PageLabelEntry = struct {
	start_index: u32, // 0-based physical page index where this range starts
	style: PageLabelStyle,
	start_number: u32, // first logical number in this range (default 1)
};

/// Parse a /PageLabels /Nums array into a slice of PageLabelEntry.
/// The array alternates: [index1, dict1, index2, dict2, ...].
/// Returns null if the array is empty or malformed.
/// Uses a fixed buffer -- returns a slice into it (max 32 entries).
fn parsePageLabelsFromArray(nums: []const PdfValue) ?[]const PageLabelEntry {
	const max_entries = 32;
	const S = struct {
		var buf: [max_entries]PageLabelEntry = undefined;
	};
	var count: usize = 0;
	var i: usize = 0;
	while (i + 1 < nums.len and count < max_entries) {
		// Expect integer, then dict
		const idx_val = nums[i];
		const dict_val = nums[i + 1];
		if (idx_val != .integer or dict_val != .dict) {
			i += 1;
			continue;
		}
		const start_idx: u32 = if (idx_val.integer >= 0) @intCast(@as(u64, @bitCast(idx_val.integer))) else 0;
		const dict = dict_val.dict;

		// Parse /S (style)
		var style: PageLabelStyle = .none;
		if (pdf_objects.getDictName(dict, "S")) |s| {
			if (s.len == 1) {
				style = switch (s[0]) {
					'D' => .decimal,
					'r' => .roman_lower,
					'R' => .roman_upper,
					'a' => .alpha_lower,
					'A' => .alpha_upper,
					else => .none,
				};
			}
		}

		// Parse /St (start number, default 1)
		const start_num: u32 = if (pdf_objects.getDictInt(dict, "St")) |st|
			if (st > 0) @intCast(@as(u64, @bitCast(st))) else 1
		else
			1;

		S.buf[count] = .{
			.start_index = start_idx,
			.style = style,
			.start_number = start_num,
		};
		count += 1;
		i += 2;
	}
	if (count == 0) return null;
	return S.buf[0..count];
}

/// Apply page labels to sections. For each section with a page_physical,
/// find the matching label range and compute page_logical, page_section, page_roman.
fn applyPageLabels(sections: []Section, labels: []const PageLabelEntry) void {
	if (labels.len == 0) return;
	for (sections) |*section| {
		const pp = section.page_physical orelse continue;
		// Convert 1-based physical page to 0-based index
		const page_index: u32 = pp -| 1;

		// Find the last label entry where start_index <= page_index
		var best: ?usize = null;
		for (labels, 0..) |entry, li| {
			if (entry.start_index <= page_index) {
				best = li;
			}
		}
		const label_idx = best orelse continue;
		const entry = labels[label_idx];

		section.page_logical = entry.start_number + (page_index - entry.start_index);
		section.page_section = @as(u32, @intCast(label_idx)) + 1;
		section.page_roman = (entry.style == .roman_lower or entry.style == .roman_upper);
	}
}

/// Parse /PageLabels from the catalog dictionary.
/// Resolves indirect references for the /PageLabels and /Nums values.
/// Returns a slice of PageLabelEntry, or null if no labels found.
fn parsePageLabels(ctx: *PdfContext, catalog: []const pdf_objects.DictEntry) ?[]const PageLabelEntry {
	// Look for /PageLabels -- it can be a dict directly or an indirect reference
	for (catalog) |entry| {
		if (!std.mem.eql(u8, entry.key, "PageLabels")) continue;

		var page_labels_dict: []const pdf_objects.DictEntry = undefined;
		var resolved_val: ?PdfValue = null;

		if (entry.value == .dict) {
			page_labels_dict = entry.value.dict;
		} else if (entry.value == .reference) {
			resolved_val = (ctx.getObject(entry.value.reference.obj) catch return null) orelse return null;
			if (resolved_val.? != .dict) {
				pdf_objects.freePdfValue(ctx.allocator, resolved_val.?);
				return null;
			}
			page_labels_dict = resolved_val.?.dict;
		} else {
			return null;
		}
		defer if (resolved_val) |rv| pdf_objects.freePdfValue(ctx.allocator, rv);

		// Look for /Nums array inside the PageLabels dict
		const nums = pdf_objects.getDictArray(page_labels_dict, "Nums") orelse return null;
		return parsePageLabelsFromArray(nums);
	}
	return null;
}

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
	var spans = std.ArrayList(TextSpan).empty;
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

	// Post-process: rejoin falsely-split words using dictionary lookup
	wordfix.applySections(allocator, sections);

	// Apply page labels from PDF catalog (if present)
	if (parsePageLabels(&ctx, catalog_val.dict)) |labels| {
		applyPageLabels(@constCast(sections), labels);
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
			allocator.free(entry.key_ptr.*);
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

	// Follow Do operators into form XObjects — this is how OCR'd PDFs
	// (e.g. from ocrmypdf) embed their invisible text layer.
	extractFormXObjectText(allocator, ctx, page_dict, spans, page_num, &font_maps);
}

/// Walk /Resources/XObject entries on a page. For each form XObject
/// (Subtype = /Form), parse its content stream for text spans.
fn extractFormXObjectText(allocator: Allocator, ctx: *PdfContext, page_dict: []const pdf_objects.DictEntry, spans: *std.ArrayList(TextSpan), page_num: u32, page_font_maps: *FontMap) void {
	// Find /Resources (direct or indirect)
	const resources = blk: {
		if (pdf_objects.getDictDict(page_dict, "Resources")) |r| break :blk r;
		const res_ref = pdf_objects.getDictRef(page_dict, "Resources") orelse return;
		const res_val = (ctx.getObject(res_ref.obj) catch return) orelse return;
		// Note: we can't defer free here because we need the dict to outlive this scope.
		// The resource dict is borrowed from the page object, which is managed by ctx.
		if (res_val != .dict) {
			pdf_objects.freePdfValue(allocator, res_val);
			return;
		}
		break :blk res_val.dict;
	};

	// Find /XObject sub-dictionary
	const xobject_dict = pdf_objects.getDictDict(resources, "XObject") orelse return;

	for (xobject_dict) |xobj_entry| {
		// Each entry maps a name to a reference to an XObject stream
		if (xobj_entry.value != .reference) continue;
		const obj_num = xobj_entry.value.reference.obj;

		// Get the XObject's dictionary to check Subtype
		const xobj_val = (ctx.getObject(obj_num) catch continue) orelse continue;
		defer pdf_objects.freePdfValue(allocator, xobj_val);
		if (xobj_val != .dict) continue;

		// Only process form XObjects (not images)
		const subtype = pdf_objects.getDictName(xobj_val.dict, "Subtype") orelse continue;
		if (!std.mem.eql(u8, subtype, "Form")) continue;

		// Get the form's content stream
		const stream_data = (ctx.getStream(obj_num) catch continue) orelse continue;
		defer allocator.free(stream_data);

		// Build font maps from the form's own /Resources if present,
		// falling back to the page's font maps
		var form_font_maps = FontMap.init(allocator);
		defer {
			var iter = form_font_maps.iterator();
			while (iter.next()) |fe| {
				allocator.free(fe.key_ptr.*);
				var cm = fe.value_ptr.*;
				cm.deinit();
			}
			form_font_maps.deinit();
		}
		if (pdf_objects.getDictDict(xobj_val.dict, "Resources")) |form_res| {
			buildFontMapsFromResources(allocator, ctx, form_res, &form_font_maps);
		}

		// Use form's own fonts if available, otherwise fall back to page fonts
		const effective_fonts = if (form_font_maps.count() > 0) &form_font_maps else page_font_maps;
		parseContentStream(allocator, stream_data, spans, page_num, effective_fonts) catch continue;
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

/// Build a CMap from a 256-entry byte-to-Unicode encoding table.
/// Populates char_map with UTF-8 strings for each byte value where the
/// encoding differs from a simple ASCII identity mapping or is a high byte.
fn buildCMapFromEncodingTable(allocator: Allocator, table: *const [256]u21) CMap {
    var cmap = CMap.init(allocator);

    // Populate mappings for bytes 0x80-0xFF (and any non-identity mappings below)
    for (0..256) |i| {
        const byte_val: u16 = @intCast(i);
        const cp = table[i];
        // Skip replacement character (undefined mapping)
        if (cp == 0xFFFD) continue;
        // Skip identity mappings for printable ASCII — these don't need CMap entries
        if (i < 0x80 and cp == i) continue;
        // Encode the Unicode codepoint to UTF-8 and store in char_map
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
        const owned = allocator.dupe(u8, utf8_buf[0..len]) catch continue;
        cmap.char_map.put(byte_val, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    return cmap;
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

		// Check for /ToUnicode stream reference (highest priority)
		const tounicode_ref = pdf_objects.getDictRef(font_obj_dict, "ToUnicode");
		if (tounicode_ref) |tu_ref| {
			const cmap_data = (ctx.getStream(tu_ref.obj) catch null) orelse null;
			if (cmap_data) |cd| {
				defer allocator.free(cd);
				// Skip oversized or empty CMap streams (likely corrupt)
				if (cd.len > 0 and cd.len <= 4 * 1024 * 1024) {
					var cmap = parseCMap(allocator, cd);
					const owned_name = allocator.dupe(u8, font_name) catch {
						cmap.deinit();
						continue;
					};
					font_maps.put(owned_name, cmap) catch {
						allocator.free(owned_name);
						cmap.deinit();
						continue;
					};
					continue; // successfully built CMap from ToUnicode
				}
			}
		}

		// Fallback: check /Encoding name for a known encoding table
		const enc_name = pdf_objects.getDictName(font_obj_dict, "Encoding");
		if (enc_name) |ename| {
			if (encoding.getEncodingTable(ename)) |table| {
				var cmap = buildCMapFromEncodingTable(allocator, table);
				const owned_name = allocator.dupe(u8, font_name) catch {
					cmap.deinit();
					continue;
				};
				font_maps.put(owned_name, cmap) catch {
					allocator.free(owned_name);
					cmap.deinit();
					continue;
				};
			}
		}
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
	var x_pos: f32 = 0;
	var in_text_block = false;
	while (pos < stream.len) {
		pos = skipStreamWhitespace(stream, pos);
		if (pos >= stream.len) break;

		const ch = stream[pos];

		// PDF string: (text)
		if (ch == '(') {
			const raw_str = extractStreamString(allocator, stream, &pos) catch continue;
			// Decode through CMap if available (needed for CID fonts in OCR'd PDFs)
			const cmap = getCurrentCMap(font_maps, current_font_name);
			const str = if (cmap) |cm| (decodeThroughCMap(allocator, raw_str, cm) orelse raw_str) else raw_str;
			const str_is_decoded = (str.ptr != raw_str.ptr);
			if (str_is_decoded) allocator.free(raw_str);
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
							.x_position = x_pos,
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
							.x_position = x_pos,
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
							.x_position = x_pos,
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
							.x_position = x_pos,
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
						.x_position = x_pos,
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
				x_pos = 0;
				pos += 2;				continue;
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
						x_pos += num; // num is tx (first operand)
						y_pos += num2;
						pos = ws2 + 2;						continue;
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
							// Matrix [a b c d e f] — d is y-scale (font size), e is x-position, f is y-position
							const d_val = tm_nums[1]; // [a,b,c,d,e,f] = [num, num2, tm[0], tm[1], tm[2], tm[3]]
							const e_val = tm_nums[2];
							const f_val = tm_nums[3];
							if (@abs(d_val) > 0.1) current_font_size = @abs(d_val);
							x_pos = e_val;
							y_pos = f_val;
							pos = ws3 + 2;
							continue;						}
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
	var buf = std.ArrayList(u8).empty;
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
					var octal: u16 = data[p] - '0';
					p += 1;
					if (p < data.len and data[p] >= '0' and data[p] <= '7') {
						octal = octal * 8 + (data[p] - '0');
						p += 1;
						if (p < data.len and data[p] >= '0' and data[p] <= '7') {
							octal = octal * 8 + (data[p] - '0');
							p += 1;
						}
					}
					try buf.append(allocator, @truncate(octal));
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

/// Decode raw bytes from a parenthesized string through a CMap.
/// CID fonts (Type0/Identity-H) use 2-byte character codes; single-byte
/// fonts use 1-byte codes. We try 2-byte first, then 1-byte fallback.
/// If no CMap matches are found, returns null (caller keeps the raw string).
fn decodeThroughCMap(allocator: Allocator, raw: []const u8, cmap: *const CMap) ?[]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var decoded_any = false;
	var i: usize = 0;

	while (i < raw.len) {
		// Try 2-byte glyph ID first (CID font)
		if (i + 2 <= raw.len) {
			const glyph_id: u16 = (@as(u16, raw[i]) << 8) | raw[i + 1];
			if (cmap.lookup(glyph_id)) |text| {
				buf.appendSlice(allocator, text) catch return null;
				decoded_any = true;
				i += 2;
				continue;
			}
			if (cmap.lookupCodepoint(glyph_id)) |cp| {
				var utf8_buf: [4]u8 = undefined;
				const n = encodeUtf8(cp, &utf8_buf);
				buf.appendSlice(allocator, utf8_buf[0..n]) catch return null;
				decoded_any = true;
				i += 2;
				continue;
			}
		}
		// Try 1-byte glyph ID
		const glyph_id_1: u16 = raw[i];
		if (cmap.lookup(glyph_id_1)) |text| {
			buf.appendSlice(allocator, text) catch return null;
			decoded_any = true;
			i += 1;
			continue;
		}
		if (cmap.lookupCodepoint(glyph_id_1)) |cp| {
			var utf8_buf: [4]u8 = undefined;
			const n = encodeUtf8(cp, &utf8_buf);
			buf.appendSlice(allocator, utf8_buf[0..n]) catch return null;
			decoded_any = true;
			i += 1;
			continue;
		}
		// No match — keep raw byte
		buf.append(allocator, raw[i]) catch return null;
		i += 1;
	}

	if (!decoded_any) {
		buf.deinit(allocator);
		return null;
	}
	return buf.toOwnedSlice(allocator) catch null;
}
/// Extract text from a hex string like <0042004300440045>, decoding
/// glyph IDs via CMap if available, otherwise returning raw bytes.
fn extractHexStringText(allocator: Allocator, data: []const u8, pos: *usize, cmap: ?*const CMap) ![]const u8 {
	var p = pos.* + 1; // skip '<'
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);

	// Collect hex digits
	var hex_buf = std.ArrayList(u8).empty;
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
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);

	while (p < data.len and data[p] != ']') {
		const c = data[p];
		if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
			p += 1;
			continue;
		}
		if (c == '(') {
			const raw_str = try extractStreamString(allocator, data, &p);
			// Decode through CMap for CID/encoded fonts (same as Tj handler)
			const str = if (cmap) |cm| (decodeThroughCMap(allocator, raw_str, cm) orelse raw_str) else raw_str;
			const str_is_decoded = (str.ptr != raw_str.ptr);
			if (str_is_decoded) allocator.free(raw_str);
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

/// Check if a slice contains only ASCII alphabetic characters.
fn isAlphaOnly(s: []const u8) bool {
	for (s) |c| {
		if (!std.ascii.isAlphabetic(c)) return false;
	}
	return s.len > 0;
}

fn isDelimiter(c: u8) bool {
	return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
		c == '/' or c == '<' or c == '>' or c == '[' or c == ']' or
		c == '(' or c == ')' or c == '{' or c == '}';
}

// ── Word Rejoining Post-Process ────────────────────────────────────

/// Walk all sections (recursively into children) and apply dictionary-based
/// word rejoining to fix false splits from PDF text extraction.

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
	var heading_sizes = std.ArrayList(f32).empty;
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
	var flat_sections = std.ArrayList(FlatSection).empty;
	defer {
		for (flat_sections.items) |*fs| fs.deinit(allocator);
		flat_sections.deinit(allocator);
	}

	var current: ?usize = null;
	var prev_y: f32 = 0;
	var prev_x: f32 = 0;
	var prev_text_len: usize = 0;
	var prev_page: u32 = 0;
	var prev_font_size: f32 = 12.0;
	var has_prev_body: bool = false;

	for (spans) |span| {
		if (span.text.len == 0) continue;

		// Check if this span qualifies as a heading by font size
		const is_heading = span.font_size >= size_threshold and blk: {
			// Filter micro-headings: short spans in marginally-larger
			// fonts are usually body text, not headings.
			const trimmed = std.mem.trim(u8, span.text, " \t\n\r");
			if (trimmed.len < 3) break :blk false;
			// Single-word spans need stricter checks
			const has_space = std.mem.indexOfScalar(u8, trimmed, ' ') != null;
			if (!has_space) {
				// Single word: require either all-caps or significantly
				// larger font (>1.5x dominant) to be a heading
				const is_all_caps = for (trimmed) |c| {
					if (c >= 'a' and c <= 'z') break false;
				} else true;
				if (!is_all_caps and span.font_size < dominant_size * 2.0)
					break :blk false;
			}
			break :blk true;
		};

		if (is_heading) {
			// This span is a heading
			const level = headingLevelForSize(span.font_size, heading_sizes.items);
			try flat_sections.append(allocator, FlatSection{
				.heading = try allocator.dupe(u8, span.text),
				.level = level,
				.content_buf = .empty,
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
					.content_buf = .empty,
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
						// Same line — only add space if needed
						const buf_len = fs.content_buf.items.len;
						const last_is_space = buf_len > 0 and fs.content_buf.items[buf_len - 1] == ' ';
						const cur_starts_space = span.text.len > 0 and span.text[0] == ' ';
						if (!last_is_space and !cur_starts_space) {
							// No existing space — check x gap to decide
							const estimated_prev_width = @as(f32, @floatFromInt(prev_text_len)) * prev_font_size * 0.4;
							const gap = span.x_position - (prev_x + estimated_prev_width);
							const space_threshold = prev_font_size * 0.25;
							if (gap > space_threshold) {
								try fs.content_buf.append(allocator, ' ');
							} else {
								// Gap below threshold — but check if concatenating
								// produces a non-word. If so, keep the space.
								// "for"+"an" = "foran" (not a word) → insert space
								// "sell"+"off" = "selloff" (a word) → no space
								const prev_start = if (buf_len > 20) buf_len - 20 else 0;
								const prev_word_start = blk: {
									var s = buf_len;
									while (s > prev_start) : (s -= 1) {
										if (fs.content_buf.items[s - 1] == ' ' or fs.content_buf.items[s - 1] == '\n') break;
									}
									break :blk s;
								};
								const prev_fragment = fs.content_buf.items[prev_word_start..buf_len];
								if (prev_fragment.len > 0 and prev_fragment.len + span.text.len <= 64) {
									var concat_buf: [64]u8 = undefined;
									@memcpy(concat_buf[0..prev_fragment.len], prev_fragment);
									const span_word_end = blk2: {
										var e: usize = 0;
										while (e < span.text.len and span.text[e] != ' ' and span.text[e] != '\n') : (e += 1) {}
										break :blk2 e;
									};
									const next_fragment = span.text[0..span_word_end];
									@memcpy(concat_buf[prev_fragment.len..prev_fragment.len + next_fragment.len], next_fragment);
									const combined = concat_buf[0..prev_fragment.len + next_fragment.len];
									if (!wordfix.isWord(combined) and prev_fragment.len >= 2 and next_fragment.len >= 2 and isAlphaOnly(prev_fragment) and isAlphaOnly(next_fragment)) {
										// Concatenation is not a word — this was a real space
										try fs.content_buf.append(allocator, ' ');
									}
								}
							}
						}
					} else {
						// Different line. A normal single-line advance is an intra-paragraph
						// WRAP -> join with a space (so citation tokens aren't split — the
						// ~47% recall fix); only a larger vertical gap is a paragraph /
						// structural boundary -> a lone '\n' (incitez's hard case-name stop).
						// Headings are already separated upstream by font-size section detection.
						const paragraph_threshold = prev_font_size * 2.2;
						if (y_diff < paragraph_threshold) {
							const blen = fs.content_buf.items.len;
							const last_ws = blen > 0 and (fs.content_buf.items[blen - 1] == ' ' or fs.content_buf.items[blen - 1] == '\n');
							if (!last_ws) try fs.content_buf.append(allocator, ' ');
						} else {
							try fs.content_buf.append(allocator, '\n');
						}
					}
				} else {
					try fs.content_buf.append(allocator, '\n');
				}
			}
			try fs.content_buf.appendSlice(allocator, span.text);
			prev_y = span.y_position;
			prev_x = span.x_position;
			prev_text_len = span.text.len;
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
			.page_physical = fs.page,
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
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);

	try buf.appendSlice(allocator, "%PDF-1.4\n");

	// Track object offsets for xref
	var obj_offsets = std.ArrayList(struct { num: u32, offset: usize }).empty;
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
		try buf.print(allocator, "{d} 0 R", .{page_obj});
	}
	try buf.print(allocator, "] /Count {d} >>\nendobj\n", .{pages.len});

	// For each page, create Page + Contents objects
	for (pages, 0..) |page, i| {
		const page_obj: u32 = @intCast(3 + i * 2);
		const contents_obj: u32 = page_obj + 1;

		// Build content stream
		var stream_buf = std.ArrayList(u8).empty;
		defer stream_buf.deinit(allocator);

		for (page.text_items) |item| {
			try stream_buf.appendSlice(allocator, "BT\n");
			try stream_buf.print(allocator, "/F1 {d} Tf\n", .{@as(u32, @intFromFloat(item.font_size))});
			try stream_buf.print(allocator, "{d} {d} Td\n", .{ @as(i32, @intFromFloat(item.x_pos)), @as(i32, @intFromFloat(item.y_pos)) });			try stream_buf.appendSlice(allocator, "(");
			try stream_buf.appendSlice(allocator, item.text);
			try stream_buf.appendSlice(allocator, ") Tj\n");
			try stream_buf.appendSlice(allocator, "ET\n");
		}

		// Page object
		try obj_offsets.append(allocator, .{ .num = page_obj, .offset = buf.items.len });
		try buf.print(allocator, "{d} 0 obj\n<< /Type /Page /Parent 2 0 R /Contents {d} 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>\nendobj\n", .{ page_obj, contents_obj });

		// Contents object (uncompressed stream)
		try obj_offsets.append(allocator, .{ .num = contents_obj, .offset = buf.items.len });
		try buf.print(allocator, "{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ contents_obj, stream_buf.items.len });
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
	try buf.print(allocator, "0 {d}\n", .{max_obj + 1});
	try buf.appendSlice(allocator, "0000000000 65535 f\n");

	var obj_idx: u32 = 1;
	while (obj_idx <= max_obj) : (obj_idx += 1) {
		var found = false;
		for (obj_offsets.items) |o| {
			if (o.num == obj_idx) {
				try buf.print(allocator, "{d:0>10} 00000 n\n", .{o.offset});
				found = true;
				break;
			}
		}
		if (!found) {
			try buf.appendSlice(allocator, "0000000000 00000 f\n");
		}
	}

	try buf.print(allocator, "trailer\n<< /Size {d} /Root 1 0 R >>\n", .{max_obj + 1});
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_offset});

	return try buf.toOwnedSlice(allocator);
}

const TestPage = struct {
	text_items: []const TestTextItem,
};

const TestTextItem = struct {
	text: []const u8,
	font_size: f32,
	y_pos: f32,
	x_pos: f32 = 0,
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
	var spans = std.ArrayList(TextSpan).empty;
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
	var spans = std.ArrayList(TextSpan).empty;
	defer {
		for (spans.items) |s| testing.allocator.free(s.text);
		spans.deinit(testing.allocator);
	}

	try parseContentStream(testing.allocator, stream, &spans, 0, null);

	try testing.expect(spans.items.len > 0);
	// Large negative kerning (-600) should produce a space between "Hello" and "World"
	try testing.expectEqualStrings("Hello World", spans.items[0].text);
}

test "same-line spans with word gaps get space separator" {
	// When Tj operations have the same Y position and a significant
	// horizontal gap, they should be joined with a space.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "The", .font_size = 12, .y_pos = 700, .x_pos = 0 },
			.{ .text = "dominant", .font_size = 12, .y_pos = 700, .x_pos = 28 },
			.{ .text = "sequence", .font_size = 12, .y_pos = 700, .x_pos = 84 },		} },
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
test "line wraps join with a space; a large vertical gap is a paragraph boundary" {
	// Structure-aware (citation pipeline 2026-06-14): a normal single-line advance is
	// an intra-paragraph wrap -> space (so citation tokens aren't split); only a large
	// vertical gap is a paragraph boundary -> a lone '\n'.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "Line one", .font_size = 12, .y_pos = 700 }, // wrap: 20pt gap (1.67x font)
			.{ .text = "Line two", .font_size = 12, .y_pos = 680 },
			.{ .text = "New paragraph", .font_size = 12, .y_pos = 620 }, // boundary: 60pt gap (5x font)
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/newlines.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// wrap -> space (joined), not a newline
	try testing.expect(std.mem.indexOf(u8, content, "Line one Line two") != null);
	// large gap -> paragraph boundary as a lone newline
	try testing.expect(std.mem.indexOf(u8, content, "two\nNew paragraph") != null);
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

test "intra-word kerning spans concatenate without space" {
	// When Tj operations are close together on the same line (small x gap),
	// they should concatenate directly — no space inserted.
	// This prevents "tw enty-four" from being split into "tw" + " " + "enty-four".
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			// "tw" at x=0, "enty-four" immediately after (x=12, which is 2 chars * 6pt)
			.{ .text = "tw", .font_size = 12, .y_pos = 700, .x_pos = 0 },
			.{ .text = "enty-four", .font_size = 12, .y_pos = 700, .x_pos = 12 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/kerning.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// Should be "twenty-four" without a space in the middle
	try testing.expect(std.mem.indexOf(u8, content, "twenty-four") != null);
	// Must NOT contain "tw enty"
	try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, content, "tw enty"));
}

test "micro-headings treated as body text" {
	// Single short words in a slightly larger font should NOT become headings.
	// e.g., "to" at 14pt when body is 12pt should stay body text.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "to", .font_size = 16, .y_pos = 750, .x_pos = 0 },
			.{ .text = "Normal body text here.", .font_size = 12, .y_pos = 700, .x_pos = 0 },
			.{ .text = "More body text.", .font_size = 12, .y_pos = 680, .x_pos = 0 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/microheading.pdf");
	defer freeDocument(testing.allocator, doc);

	// "to" should NOT be a heading — it's too short
	for (doc.sections) |s| {
		if (s.heading) |h| {
			// No heading should be just "to"
			try testing.expect(!std.mem.eql(u8, h, "to"));
		}
	}
}

test "narrow gap: 'a bout' becomes 'about' (below space threshold)" {
	// "a" at x=0, "bout" at x=5 (very close, ~0.4 * 12pt per char = 4.8pt for 'a')
	// Gap: 5 - (0 + 1*12*0.4) = 5 - 4.8 = 0.2pt → below threshold (12*0.25=3pt)
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "a", .font_size = 12, .y_pos = 700, .x_pos = 0 },
			.{ .text = "bout", .font_size = 12, .y_pos = 700, .x_pos = 5 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/narrow.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// Narrow gap + "about" is a word → concatenated
	try testing.expect(std.mem.indexOf(u8, content, "about") != null);
}

test "wide gap: 'a bout' stays 'a bout' (above space threshold)" {
	// "a" at x=0, "bout" at x=20 (wide gap for 12pt font)
	// Gap: 20 - (0 + 1*12*0.4) = 20 - 4.8 = 15.2pt → above threshold (12*0.25=3pt)
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "a", .font_size = 12, .y_pos = 700, .x_pos = 0 },
			.{ .text = "bout", .font_size = 12, .y_pos = 700, .x_pos = 20 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/wide.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// Wide gap → space inserted, stays as two words
	try testing.expect(std.mem.indexOf(u8, content, "a bout") != null);
}

test "narrow gap: 'for an' stays spaced when 'foran' is not a word" {
	// "for" at x=0, "an" at x=15 (close for 12pt: 3 chars * 4.8 = 14.4)
	// Gap: 15 - 14.4 = 0.6pt → below threshold
	// But "foran" is NOT a word → insert space anyway
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "for", .font_size = 12, .y_pos = 700, .x_pos = 0 },
			.{ .text = "an", .font_size = 12, .y_pos = 700, .x_pos = 15 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/foran.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// "foran" is not a word → space inserted despite narrow gap
	try testing.expect(std.mem.indexOf(u8, content, "for an") != null);
}

test "narrow gap: 'to me' stays spaced when 'tome' exists but gap data says space" {
	// "to" at x=0, "me" at x=10 (close for 12pt: 2 chars * 4.8 = 9.6)
	// Gap: 10 - 9.6 = 0.4pt → below threshold
	// "tome" IS a word, so gap data decides: narrow gap → no space → "tome"
	// This is the expected behavior: trust the physical layout
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "to", .font_size = 12, .y_pos = 700, .x_pos = 0 },
			.{ .text = "me", .font_size = 12, .y_pos = 700, .x_pos = 10 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/tome.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// Narrow gap + "tome" is a word → concatenated (trust gap data)
	try testing.expect(std.mem.indexOf(u8, content, "tome") != null);
}

// ── PageLabels tests ───────────────────────────────────────────────────

test "applyPageLabels — decimal labels set page_logical" {
	// Two sections at physical pages 1, 2
	// Label range: pages 0+ are decimal starting at 1
	var sections = [_]Section{
		.{ .heading = null, .level = 0, .content = "text", .children = &.{}, .page_physical = 1 },
		.{ .heading = null, .level = 0, .content = "text", .children = &.{}, .page_physical = 2 },
	};
	const labels = [_]PageLabelEntry{
		.{ .start_index = 0, .style = .decimal, .start_number = 1 },
	};
	applyPageLabels(&sections, &labels);

	try testing.expectEqual(@as(?u32, 1), sections[0].page_logical);
	try testing.expectEqual(@as(?u32, 2), sections[1].page_logical);
	try testing.expectEqual(@as(?u32, 1), sections[0].page_section);
	try testing.expectEqual(@as(?u32, 1), sections[1].page_section);
	try testing.expectEqual(false, sections[0].page_roman);
	try testing.expectEqual(false, sections[1].page_roman);
}

test "applyPageLabels — roman then decimal ranges" {
	// Pages 0-3: lowercase roman starting at 1 (i, ii, iii, iv)
	// Pages 4+: decimal starting at 1
	var sections = [_]Section{
		.{ .heading = null, .level = 0, .content = "preface", .children = &.{}, .page_physical = 1 },
		.{ .heading = null, .level = 0, .content = "intro", .children = &.{}, .page_physical = 4 },
		.{ .heading = null, .level = 0, .content = "ch1", .children = &.{}, .page_physical = 5 },
		.{ .heading = null, .level = 0, .content = "ch2", .children = &.{}, .page_physical = 7 },
	};
	const labels = [_]PageLabelEntry{
		.{ .start_index = 0, .style = .roman_lower, .start_number = 1 },
		.{ .start_index = 4, .style = .decimal, .start_number = 1 },
	};
	applyPageLabels(&sections, &labels);

	// Physical page 1 -> 0-based index 0, in range 0 (roman, start 1): logical = 1
	try testing.expectEqual(@as(?u32, 1), sections[0].page_logical);
	try testing.expectEqual(true, sections[0].page_roman);
	try testing.expectEqual(@as(?u32, 1), sections[0].page_section);

	// Physical page 4 -> 0-based index 3, in range 0 (roman, start 1): logical = 4
	try testing.expectEqual(@as(?u32, 4), sections[1].page_logical);
	try testing.expectEqual(true, sections[1].page_roman);
	try testing.expectEqual(@as(?u32, 1), sections[1].page_section);

	// Physical page 5 -> 0-based index 4, in range 1 (decimal, start 1): logical = 1
	try testing.expectEqual(@as(?u32, 1), sections[2].page_logical);
	try testing.expectEqual(false, sections[2].page_roman);
	try testing.expectEqual(@as(?u32, 2), sections[2].page_section);

	// Physical page 7 -> 0-based index 6, in range 1 (decimal, start 1): logical = 3
	try testing.expectEqual(@as(?u32, 3), sections[3].page_logical);
	try testing.expectEqual(false, sections[3].page_roman);
	try testing.expectEqual(@as(?u32, 2), sections[3].page_section);
}

test "applyPageLabels — no labels leaves page_logical null" {
	var sections = [_]Section{
		.{ .heading = null, .level = 0, .content = "text", .children = &.{}, .page_physical = 3 },
	};
	const labels = [_]PageLabelEntry{};
	applyPageLabels(&sections, &labels);
	try testing.expectEqual(@as(?u32, null), sections[0].page_logical);
}

test "applyPageLabels — null page_physical is skipped" {
	var sections = [_]Section{
		.{ .heading = null, .level = 0, .content = "text", .children = &.{} },
	};
	const labels = [_]PageLabelEntry{
		.{ .start_index = 0, .style = .decimal, .start_number = 1 },
	};
	applyPageLabels(&sections, &labels);
	try testing.expectEqual(@as(?u32, null), sections[0].page_logical);
}

test "applyPageLabels — start_number offset applied correctly" {
	// Range starting at page index 10, decimal, starting at 42
	var sections = [_]Section{
		.{ .heading = null, .level = 0, .content = "text", .children = &.{}, .page_physical = 13 },
	};
	const labels = [_]PageLabelEntry{
		.{ .start_index = 0, .style = .decimal, .start_number = 1 },
		.{ .start_index = 10, .style = .decimal, .start_number = 42 },
	};
	applyPageLabels(&sections, &labels);
	// Physical 13 -> 0-based index 12, in range 1 (start_index=10, start_number=42)
	// logical = 42 + (12 - 10) = 44
	try testing.expectEqual(@as(?u32, 44), sections[0].page_logical);
	try testing.expectEqual(@as(?u32, 2), sections[0].page_section);
}

test "parsePageLabelsFromArray — simple decimal" {
	// Simulate /Nums [ 0 << /S /D /St 1 >> ]
	const dict_entries = [_]pdf_objects.DictEntry{
		.{ .key = "S", .value = .{ .name = "D" } },
		.{ .key = "St", .value = .{ .integer = 1 } },
	};
	const nums_array = [_]PdfValue{
		.{ .integer = 0 },
		.{ .dict = &dict_entries },
	};
	const result = parsePageLabelsFromArray(&nums_array);
	try testing.expect(result != null);
	const labels = result.?;
	try testing.expectEqual(@as(usize, 1), labels.len);
	try testing.expectEqual(@as(u32, 0), labels[0].start_index);
	try testing.expectEqual(PageLabelStyle.decimal, labels[0].style);
	try testing.expectEqual(@as(u32, 1), labels[0].start_number);
}

test "parsePageLabelsFromArray — roman then decimal" {
	const dict0 = [_]pdf_objects.DictEntry{
		.{ .key = "S", .value = .{ .name = "r" } },
	};
	const dict1 = [_]pdf_objects.DictEntry{
		.{ .key = "S", .value = .{ .name = "D" } },
		.{ .key = "St", .value = .{ .integer = 1 } },
	};
	const nums_array = [_]PdfValue{
		.{ .integer = 0 },
		.{ .dict = &dict0 },
		.{ .integer = 4 },
		.{ .dict = &dict1 },
	};
	const result = parsePageLabelsFromArray(&nums_array);
	try testing.expect(result != null);
	const labels = result.?;
	try testing.expectEqual(@as(usize, 2), labels.len);
	try testing.expectEqual(@as(u32, 0), labels[0].start_index);
	try testing.expectEqual(PageLabelStyle.roman_lower, labels[0].style);
	try testing.expectEqual(@as(u32, 1), labels[0].start_number);
	try testing.expectEqual(@as(u32, 4), labels[1].start_index);
	try testing.expectEqual(PageLabelStyle.decimal, labels[1].style);
	try testing.expectEqual(@as(u32, 1), labels[1].start_number);
}

test "parsePageLabelsFromArray — empty array returns null" {
	const nums_array = [_]PdfValue{};
	const result = parsePageLabelsFromArray(&nums_array);
	try testing.expectEqual(@as(?[]const PageLabelEntry, null), result);
}

test "parsePageLabelsFromArray — upper roman and alpha styles" {
	const dict0 = [_]pdf_objects.DictEntry{
		.{ .key = "S", .value = .{ .name = "R" } },
	};
	const dict1 = [_]pdf_objects.DictEntry{
		.{ .key = "S", .value = .{ .name = "A" } },
		.{ .key = "St", .value = .{ .integer = 3 } },
	};
	const dict2 = [_]pdf_objects.DictEntry{
		.{ .key = "S", .value = .{ .name = "a" } },
	};
	const nums_array = [_]PdfValue{
		.{ .integer = 0 },
		.{ .dict = &dict0 },
		.{ .integer = 5 },
		.{ .dict = &dict1 },
		.{ .integer = 10 },
		.{ .dict = &dict2 },
	};
	const result = parsePageLabelsFromArray(&nums_array);
	try testing.expect(result != null);
	const labels = result.?;
	try testing.expectEqual(@as(usize, 3), labels.len);
	try testing.expectEqual(PageLabelStyle.roman_upper, labels[0].style);
	try testing.expectEqual(PageLabelStyle.alpha_upper, labels[1].style);
	try testing.expectEqual(@as(u32, 3), labels[1].start_number);
	try testing.expectEqual(PageLabelStyle.alpha_lower, labels[2].style);
}

test "PDF with PageLabels — integration" {
	// Build a PDF with page labels in the catalog
	const pdf = try buildTestPdfWithPageLabels(testing.allocator, &.{
		.{ .text_items = &.{.{ .text = "Preface", .font_size = 12, .y_pos = 700 }} },
		.{ .text_items = &.{.{ .text = "More preface", .font_size = 12, .y_pos = 700 }} },
		.{ .text_items = &.{.{ .text = "Chapter 1", .font_size = 12, .y_pos = 700 }} },
		.{ .text_items = &.{.{ .text = "Chapter 2", .font_size = 12, .y_pos = 700 }} },
	}, &.{
		// Pages 0-1: roman, starting at 1
		.{ .start_index = 0, .style_char = 'r', .start_number = 1 },
		// Pages 2+: decimal, starting at 1
		.{ .start_index = 2, .style_char = 'D', .start_number = 1 },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/pagelabels.pdf");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len > 0);

	// Find sections and verify page_logical / page_roman
	var found_roman = false;
	var found_decimal = false;
	for (doc.sections) |s| {
		if (s.page_physical) |pp| {
			if (pp <= 2) {
				// Roman section
				if (s.page_logical != null) {
					try testing.expect(s.page_roman);
					try testing.expectEqual(@as(?u32, 1), s.page_section);
					found_roman = true;
				}
			} else {
				// Decimal section
				if (s.page_logical != null) {
					try testing.expect(!s.page_roman);
					try testing.expectEqual(@as(?u32, 2), s.page_section);
					found_decimal = true;
				}
			}
		}
	}
	try testing.expect(found_roman);
	try testing.expect(found_decimal);
}

const TestPageLabelSpec = struct {
	start_index: u32,
	style_char: u8, // 'D', 'r', 'R', 'a', 'A'
	start_number: u32,
};

/// Build a test PDF with /PageLabels in the catalog.
fn buildTestPdfWithPageLabels(allocator: Allocator, pages: []const TestPage, label_specs: []const TestPageLabelSpec) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);

	try buf.appendSlice(allocator, "%PDF-1.4\n");

	// Track object offsets for xref
	var obj_offsets = std.ArrayList(struct { num: u32, offset: usize }).empty;
	defer obj_offsets.deinit(allocator);

	// Build /PageLabels /Nums array string
	var labels_buf = std.ArrayList(u8).empty;
	defer labels_buf.deinit(allocator);
	try labels_buf.appendSlice(allocator, "/PageLabels << /Nums [ ");
	for (label_specs) |spec| {
		try labels_buf.print(allocator, "{d} << /S /{c}", .{ spec.start_index, spec.style_char });
		if (spec.start_number != 1) {
			try labels_buf.print(allocator, " /St {d}", .{spec.start_number});
		}
		try labels_buf.appendSlice(allocator, " >> ");
	}
	try labels_buf.appendSlice(allocator, "] >> ");

	// Object 1: Catalog with /PageLabels
	try obj_offsets.append(allocator, .{ .num = 1, .offset = buf.items.len });
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
	try buf.appendSlice(allocator, labels_buf.items);
	try buf.appendSlice(allocator, ">>\nendobj\n");

	// Object 2: Pages
	try obj_offsets.append(allocator, .{ .num = 2, .offset = buf.items.len });
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [");
	for (pages, 0..) |_, i| {
		const page_obj: u32 = @intCast(3 + i * 2);
		if (i > 0) try buf.append(allocator, ' ');
		try buf.print(allocator, "{d} 0 R", .{page_obj});
	}
	try buf.print(allocator, "] /Count {d} >>\nendobj\n", .{pages.len});

	// For each page, create Page + Contents objects
	for (pages, 0..) |page, i| {
		const page_obj: u32 = @intCast(3 + i * 2);
		const contents_obj: u32 = page_obj + 1;

		// Build content stream
		var stream_buf = std.ArrayList(u8).empty;
		defer stream_buf.deinit(allocator);

		for (page.text_items) |item| {
			try stream_buf.appendSlice(allocator, "BT\n");
			try stream_buf.print(allocator, "/F1 {d} Tf\n", .{@as(u32, @intFromFloat(item.font_size))});
			try stream_buf.print(allocator, "{d} {d} Td\n", .{ @as(i32, @intFromFloat(item.x_pos)), @as(i32, @intFromFloat(item.y_pos)) });
			try stream_buf.appendSlice(allocator, "(");
			try stream_buf.appendSlice(allocator, item.text);
			try stream_buf.appendSlice(allocator, ") Tj\n");
			try stream_buf.appendSlice(allocator, "ET\n");
		}

		// Page object
		try obj_offsets.append(allocator, .{ .num = page_obj, .offset = buf.items.len });
		try buf.print(allocator, "{d} 0 obj\n<< /Type /Page /Parent 2 0 R /Contents {d} 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>\nendobj\n", .{ page_obj, contents_obj });

		// Contents object (uncompressed stream)
		try obj_offsets.append(allocator, .{ .num = contents_obj, .offset = buf.items.len });
		try buf.print(allocator, "{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ contents_obj, stream_buf.items.len });
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
	try buf.print(allocator, "0 {d}\n", .{max_obj + 1});
	try buf.appendSlice(allocator, "0000000000 65535 f\n");

	var obj_idx: u32 = 1;
	while (obj_idx <= max_obj) : (obj_idx += 1) {
		var found = false;
		for (obj_offsets.items) |o| {
			if (o.num == obj_idx) {
				try buf.print(allocator, "{d:0>10} 00000 n\n", .{o.offset});
				found = true;
				break;
			}
		}
		if (!found) {
			try buf.appendSlice(allocator, "0000000000 00000 f\n");
		}
	}

	try buf.print(allocator, "trailer\n<< /Size {d} /Root 1 0 R >>\n", .{max_obj + 1});
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_offset});

	return try buf.toOwnedSlice(allocator);
}

/// Build a synthetic PDF where text lives in a form XObject (like OCR'd PDFs).
/// The page content stream uses `Do` to reference the form, which contains the Tj ops.
fn buildTestPdfWithFormXObject(allocator: Allocator, form_text: []const u8) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var obj_offsets = std.ArrayList(struct { num: u32, offset: usize }).empty;
	defer obj_offsets.deinit(allocator);

	try buf.appendSlice(allocator, "%PDF-1.4\n");

	// Object 1: Catalog
	try obj_offsets.append(allocator, .{ .num = 1, .offset = buf.items.len });
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

	// Object 2: Pages
	try obj_offsets.append(allocator, .{ .num = 2, .offset = buf.items.len });
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

	// Object 5: Form XObject stream with the actual text
	var form_stream = std.ArrayList(u8).empty;
	defer form_stream.deinit(allocator);
	try form_stream.appendSlice(allocator, "BT\n/F1 12 Tf\n72 700 Td\n(");
	try form_stream.appendSlice(allocator, form_text);
	try form_stream.appendSlice(allocator, ") Tj\nET\n");

	try obj_offsets.append(allocator, .{ .num = 5, .offset = buf.items.len });
	try buf.print(allocator, "5 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Length {d} >>\nstream\n", .{form_stream.items.len});
	try buf.appendSlice(allocator, form_stream.items);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");

	// Object 4: Content stream — just references the form XObject via Do
	const content = "/OCR Do\n";
	try obj_offsets.append(allocator, .{ .num = 4, .offset = buf.items.len });
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{content.len});
	try buf.appendSlice(allocator, content);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");

	// Object 3: Page — references content stream and XObject
	try obj_offsets.append(allocator, .{ .num = 3, .offset = buf.items.len });
	try buf.appendSlice(allocator,
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> /XObject << /OCR 5 0 R >> >> >>\nendobj\n");

	// Xref
	var max_obj: u32 = 0;
	for (obj_offsets.items) |o| { if (o.num > max_obj) max_obj = o.num; }
	const xref_offset = buf.items.len;
	try buf.appendSlice(allocator, "xref\n");
	try buf.print(allocator, "0 {d}\n", .{max_obj + 1});
	try buf.appendSlice(allocator, "0000000000 65535 f\n");
	var obj_idx: u32 = 1;
	while (obj_idx <= max_obj) : (obj_idx += 1) {
		var found = false;
		for (obj_offsets.items) |o| {
			if (o.num == obj_idx) {
				try buf.print(allocator, "{d:0>10} 00000 n\n", .{o.offset});
				found = true;
				break;
			}
		}
		if (!found) try buf.appendSlice(allocator, "0000000000 00000 f\n");
	}
	try buf.print(allocator, "trailer\n<< /Size {d} /Root 1 0 R >>\n", .{max_obj + 1});
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_offset});
	return try buf.toOwnedSlice(allocator);
}

test "parse extracts text from form XObjects (OCR'd PDFs)" {
	const alloc = testing.allocator;
	const pdf = try buildTestPdfWithFormXObject(alloc, "Hello from OCR layer");
	defer alloc.free(pdf);
	const doc = try parse(alloc, pdf, "test-form-xobj.pdf");
	defer freeDocument(alloc, doc);
	// The text lives in a form XObject, not the main content stream.
	// Parser must follow Do into form XObjects to find it.
	try testing.expect(doc.sections.len > 0);
	var found = false;
	for (doc.sections) |sec| {
		if (std.mem.indexOf(u8, sec.content, "Hello from OCR layer") != null) {
			found = true;
			break;
		}
	}
	try testing.expect(found);
}

test "parse decodes MacRomanEncoding byte 0xDE as fi ligature" {
	const alloc = testing.allocator;
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(alloc);
	var offsets = std.ArrayList(struct { num: u32, offset: usize }).empty;
	defer offsets.deinit(alloc);

	try buf.appendSlice(alloc, "%PDF-1.4\n");

	try offsets.append(alloc, .{ .num = 1, .offset = buf.items.len });
	try buf.appendSlice(alloc, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

	try offsets.append(alloc, .{ .num = 2, .offset = buf.items.len });
	try buf.appendSlice(alloc, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

	// Content stream: (\xDEnally) Tj — byte 0xDE should become fi via MacRoman
	const stream = "BT\n/F1 12 Tf\n72 700 Td\n(\xDEnally) Tj\nET\n";
	try offsets.append(alloc, .{ .num = 4, .offset = buf.items.len });
	try buf.print(alloc, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(alloc, stream);
	try buf.appendSlice(alloc, "\nendstream\nendobj\n");

	// Page with MacRomanEncoding font
	try offsets.append(alloc, .{ .num = 3, .offset = buf.items.len });
	try buf.appendSlice(alloc,
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R" ++
		" /Resources << /Font << /F1 << /Type /Font /Subtype /Type1" ++
		" /BaseFont /Sabon-Roman /Encoding /MacRomanEncoding >> >> >> >>\nendobj\n");

	// Xref
	const xref_offset = buf.items.len;
	try buf.appendSlice(alloc, "xref\n");
	try buf.print(alloc, "0 5\n", .{});
	try buf.appendSlice(alloc, "0000000000 65535 f\n");
	var idx: u32 = 1;
	while (idx <= 4) : (idx += 1) {
		var found = false;
		for (offsets.items) |o| {
			if (o.num == idx) {
				try buf.print(alloc, "{d:0>10} 00000 n\n", .{o.offset});
				found = true;
				break;
			}
		}
		if (!found) try buf.appendSlice(alloc, "0000000000 00000 f\n");
	}
	try buf.print(alloc, "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF", .{xref_offset});

	const pdf = try buf.toOwnedSlice(alloc);
	defer alloc.free(pdf);
	const doc = try parse(alloc, pdf, "test-macroman.pdf");
	defer freeDocument(alloc, doc);

	try testing.expect(doc.sections.len > 0);
	const content = doc.sections[0].content;
	// After CMap decode + normalizeText ligature expansion
	try testing.expect(std.mem.indexOf(u8, content, "finally") != null);
}
test "pdf extraction preserves legal reporter intra-token spaces (no collapse)" {
	// Regression (incitez_web / Einstein 2026-06-13): pdf routes through the same
	// wordfix rejoin pass that collapsed "U. S." -> "US."; verify a born-digital
	// text-layer PDF keeps the reporter spacing intact.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "Compare 530 U. S. 238 and 5 F. 3d 1000.", .font_size = 12, .y_pos = 700 },
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/reporter.pdf");
	defer freeDocument(testing.allocator, doc);

	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);

	try testing.expect(std.mem.indexOf(u8, all.items, "530 U. S. 238") != null);
}

test "pdf structure-aware: citation split across a line wrap joins (recall); paragraph gap = boundary" {
	// Phase 1 (citation pipeline 2026-06-14): a citation token split by a layout
	// line-wrap must rejoin (the ~47% recall fix); a real paragraph gap stays a lone
	// '\n' boundary (incitez's hard case-name stop).
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "see Brown v.", .font_size = 12, .y_pos = 700 }, // wrap: 18pt gap
			.{ .text = "Board, 347 U. S. 483.", .font_size = 12, .y_pos = 682 },
			.{ .text = "Next paragraph.", .font_size = 12, .y_pos = 620 }, // boundary: 62pt gap
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/wrap.pdf");
	defer freeDocument(testing.allocator, doc);

	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;

	// wrap joined -> citation token intact across the line break
	try testing.expect(std.mem.indexOf(u8, c, "Brown v. Board, 347 U. S. 483.") != null);
	// paragraph boundary preserved as a lone newline
	try testing.expect(std.mem.indexOf(u8, c, "483.\nNext paragraph.") != null);
}

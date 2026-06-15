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
	/// True when this CMap is the WinAnsi (CP1252) *default* guess for a simple
	/// font that declared no recognized /Encoding. Such fonts' bytes are deferred
	/// for the decode-both charset heuristic (see resolveStopgapEncoding) rather
	/// than trusted; ToUnicode and explicitly-declared encodings leave this false.
	stopgap: bool = false,

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
	/// True while this span still holds RAW undecoded bytes from a stopgap font;
	/// resolveStopgapEncoding() picks the encoding, decodes in place, and clears this.
	raw: bool = false,
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

/// Decode-both charset heuristic for simple PDF fonts that hit the WinAnsi
/// (CP1252) stopgap. Their text bytes were kept RAW (TextSpan.raw); here we
/// decide ONE encoding for all of them: the implicit default (WINDOWS-1252)
/// unless an independently chardetz-detected charset decodes the same bytes to
/// higher-quality text (wordfix.textQuality is the independent judge — neither
/// the PDF's implicit claim nor the detector is trusted alone). Detection runs
/// over the concatenation of ALL stopgap bytes for confidence; each span is then
/// decoded with the winner. No-op when there are no stopgap spans.
fn resolveStopgapEncoding(allocator: Allocator, spans: *std.ArrayList(TextSpan)) void {
	var any_raw = false;
	var concat = std.ArrayList(u8).empty;
	defer concat.deinit(allocator);
	for (spans.items) |s| {
		if (!s.raw) continue;
		any_raw = true;
		concat.appendSlice(allocator, s.text) catch return;
	}
	if (!any_raw) return;

	// Default to WinAnsi (CP1252) — the historical stopgap behavior.
	var chosen: []const u8 = "WINDOWS-1252";
	if (encoding.detectEncoding(allocator, concat.items)) |det| {
		if (!std.mem.eql(u8, det, "WINDOWS-1252") and !std.mem.eql(u8, det, "ASCII")) {
			if (std.mem.eql(u8, det, "UTF-8") and std.unicode.utf8ValidateSlice(concat.items)) {
				// Valid multibyte UTF-8 is high-precision: trust it outright.
				chosen = det;
			} else {
				const win = encoding.toUtf8(allocator, concat.items, "WINDOWS-1252") catch null;
				const alt = encoding.toUtf8(allocator, concat.items, det) catch null;
				defer if (win) |w| allocator.free(w);
				defer if (alt) |a| allocator.free(a);
				if (win != null and alt != null and
					wordfix.textQuality(alt.?) > wordfix.textQuality(win.?))
				{
					chosen = det;
				}
			}
		}
	}

	// Decode each stopgap span with the chosen encoding, replacing its raw bytes.
	for (spans.items) |*s| {
		if (!s.raw) continue;
		const decoded = encoding.toUtf8(allocator, s.text, chosen) catch continue;
		allocator.free(s.text);
		s.text = decoded;
		s.raw = false;
	}
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

	// Decode-both charset heuristic: stopgap-font spans were kept as RAW bytes;
	// pick their encoding now (declared WinAnsi vs chardetz-detected, judged by
	// wordfix.textQuality) over ALL such bytes at once for detection confidence.
	resolveStopgapEncoding(allocator, &spans);

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
	// Find /Resources (direct or indirect). When resolved via an indirect reference,
	// getObject returns a freshly-allocated value we OWN and must free at function
	// end — the resources dict is borrowed from it throughout the XObject loop below.
	// A directly-inlined /Resources is borrowed from page_dict and must NOT be freed.
	var owned_res: ?pdf_objects.PdfValue = null;
	defer if (owned_res) |ov| pdf_objects.freePdfValue(allocator, ov);
	const resources = blk: {
		if (pdf_objects.getDictDict(page_dict, "Resources")) |r| break :blk r;
		const res_ref = pdf_objects.getDictRef(page_dict, "Resources") orelse return;
		const res_val = (ctx.getObject(res_ref.obj) catch return) orelse return;
		if (res_val != .dict) {
			pdf_objects.freePdfValue(allocator, res_val);
			return;
		}
		owned_res = res_val; // own it; the defer above frees it after the loop
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


/// Standard f-ligature glyph names → their component ASCII letters. Longest names
/// first doesn't matter (exact match). These are the ligatures whose ToUnicode is
/// routinely broken in real fonts (mapped to just "f"/"ff").
fn ligatureExpansion(name: []const u8) ?[]const u8 {
	const pairs = [_]struct { n: []const u8, e: []const u8 }{
		.{ .n = "ffi", .e = "ffi" }, .{ .n = "ffl", .e = "ffl" }, .{ .n = "ffj", .e = "ffj" },
		.{ .n = "fi", .e = "fi" },   .{ .n = "fl", .e = "fl" },   .{ .n = "ff", .e = "ff" },
		.{ .n = "ft", .e = "ft" },   .{ .n = "st", .e = "st" },   .{ .n = "fj", .e = "fj" },
	};
	for (pairs) |p| {
		if (std.mem.eql(u8, name, p.n)) return p.e;
	}
	return null;
}

/// Set cmap.char_map[code] = dup(value), freeing any prior value.
fn setCMapEntry(allocator: Allocator, cmap: *CMap, code: u16, value: []const u8) void {
	const owned = allocator.dupe(u8, value) catch return;
	const gop = cmap.char_map.getOrPut(code) catch {
		allocator.free(owned);
		return;
	};
	if (gop.found_existing) allocator.free(gop.value_ptr.*);
	gop.value_ptr.* = owned;
}

/// Repair f-ligature glyphs whose ToUnicode is broken (maps fi/fl/ffi to just
/// "f"/"ff" — common in real fonts; SCOTUS Century types do this → "defines"
/// becomes "defnes"). Recovers the component letters from two sources, matching
/// poppler's glyph-name recovery:
///   1. /Encoding /Differences glyph NAMES (authoritative, any code) — Custom fonts.
///   2. StandardEncoding ligature POSITIONS (174=fi, 175=fl, …) where the CMap
///      still holds a lone-"f"/"ff" stub — Builtin/Standard fonts with no
///      /Differences (e.g. the SCOTUS small-caps Century faces).
fn overrideLigatureDifferences(allocator: Allocator, ctx: *PdfContext, font_dict: []const pdf_objects.DictEntry, cmap: *CMap) void {
	// Pass 1: /Differences glyph names (authoritative for any code).
	pass1: {
		var owned: ?pdf_objects.PdfValue = null;
		defer if (owned) |o| pdf_objects.freePdfValue(allocator, o);
		const enc_dict: []const pdf_objects.DictEntry = b: {
			if (pdf_objects.getDictDict(font_dict, "Encoding")) |d| break :b d;
			const ref = pdf_objects.getDictRef(font_dict, "Encoding") orelse break :pass1;
			const val = (ctx.getObject(ref.obj) catch break :pass1) orelse break :pass1;
			if (val != .dict) {
				pdf_objects.freePdfValue(allocator, val);
				break :pass1;
			}
			owned = val;
			break :b val.dict;
		};
		const diffs = pdf_objects.getDictArray(enc_dict, "Differences") orelse break :pass1;
		var code: u16 = 0;
		for (diffs) |elem| {
			switch (elem) {
				.integer => |n| {
					if (n >= 0 and n <= 0xFFFF) code = @intCast(n);
				},
				.name => |nm| {
					if (ligatureExpansion(nm)) |exp| setCMapEntry(allocator, cmap, code, exp);
					code +%= 1;
				},
				else => {},
			}
		}
	}

	// Pass 2: StandardEncoding ligature positions still holding a broken "f"/"ff"
	// stub (Builtin/Standard fonts: no /Differences + broken ToUnicode).
	for (0..256) |i| {
		const exp: []const u8 = switch (encoding.standard_encoding_to_unicode[i]) {
			0xFB01 => "fi",
			0xFB02 => "fl",
			0xFB03 => "ffi",
			0xFB04 => "ffl",
			0xFB05, 0xFB06 => "st",
			else => continue,
		};
		const cur = cmap.char_map.get(@intCast(i)) orelse continue;
		if (std.mem.eql(u8, cur, "f") or std.mem.eql(u8, cur, "ff")) {
			setCMapEntry(allocator, cmap, @intCast(i), exp);
		}
	}
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
					// Recover f-ligatures from /Differences when ToUnicode maps them to "f".
					overrideLigatureDifferences(allocator, ctx, font_obj_dict, &cmap);
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

		// Map via the font's /Encoding table, DEFAULTING to WinAnsi (CP1252) for simple
		// fonts that declare no (or an unrecognized) encoding. This turns raw high bytes
		// (curly quotes 0x93/0x94, em dash 0x97, etc.) into proper UTF-8 instead of invalid
		// raw bytes. WinAnsi is the de-facto default for non-symbolic PDF text fonts;
		// deterministic (no charset guessing) and pure-Zig (works in the wasm slice, where
		// the uchardet charset detector is comptime-excluded).
		const enc_name = pdf_objects.getDictName(font_obj_dict, "Encoding");
		var is_stopgap = false;
		const enc_table: ?*const [256]u21 = blk: {
			if (enc_name) |ename| {
				if (encoding.getEncodingTable(ename)) |t| break :blk t;
			}
			// No declared/recognized /Encoding — WinAnsi is only a GUESS. Mark it
			// stopgap so resolveStopgapEncoding can override it via charset detection.
			is_stopgap = true;
			break :blk encoding.getEncodingTable("WinAnsiEncoding");
		};
		if (enc_table) |table| {
			var cmap = buildCMapFromEncodingTable(allocator, table);
			cmap.stopgap = is_stopgap;
			// Recover f-ligatures from /Differences (broken/absent ToUnicode case).
			overrideLigatureDifferences(allocator, ctx, font_obj_dict, &cmap);
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

/// Parse a PDF content stream and extract text spans.
/// Handles BT/ET blocks, Tf (font size), Tj/TJ (show text), Td/TD/Tm (positioning).
/// font_maps provides ToUnicode CMap lookups for hex-encoded glyph IDs.
fn parseContentStream(allocator: Allocator, stream: []const u8, spans: *std.ArrayList(TextSpan), page_num: u32, font_maps: ?*const FontMap) PdfError!void {
	var pos: usize = 0;
	var current_font_size: f32 = 12.0; // default; effective = tf_size * tm_scale
	var tf_size: f32 = 12.0; // last Tf point size
	var tm_scale: f32 = 1.0; // Tm d-component (text-matrix vertical scale)
	var tm_scale_x: f32 = 1.0; // Tm a-component (text-matrix horizontal scale)
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
			// Stopgap fonts (the WinAnsi default guess) defer decoding: keep the RAW
			// bytes so resolveStopgapEncoding can pick the encoding from the whole doc.
			const is_stopgap = if (cmap) |cm| cm.stopgap else false;
			const str = if (is_stopgap)
				raw_str
			else if (cmap) |cm|
				(decodeThroughCMap(allocator, raw_str, cm) orelse raw_str)
			else
				raw_str;
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
							.raw = is_stopgap,
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
							.raw = is_stopgap,
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
			const tj_cmap = getCurrentCMap(font_maps, current_font_name);
			const tj_is_stopgap = if (tj_cmap) |cm| cm.stopgap else false;
			const arr_text = extractTJArray(allocator, stream, &pos, tj_cmap) catch continue;
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
						.raw = tj_is_stopgap,
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
					tf_size = num;
					current_font_size = tf_size * tm_scale;
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
						// Td offsets are in TEXT space; map to user space via the text-matrix
						// scale. PDFs that bake the font size into Tm (e.g. `1 Tf` + `9 0 0 9 … Tm`,
						// like SCOTUS slip opinions) otherwise record line advances ~1/scale too
						// small, collapsing every line into one cluster (the reading-order scramble).
						x_pos += num * tm_scale_x; // num is tx (first operand)
						y_pos += num2 * tm_scale;
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
							// The Tm d-component is the vertical SCALE, not the font size; the
							// rendered size is Tf_size * d. groff positions via Tm [1 0 0 1 x y]
							// (d=1) and sizes via Tf, so do NOT overwrite the Tf size with d.
							tm_scale = if (@abs(d_val) > 0.01) @abs(d_val) else 1.0;
							// The Tm a-component is the horizontal scale; track it so Td x-offsets
							// (in text space) map to user-space movement, like tm_scale does for y.
							tm_scale_x = if (@abs(num) > 0.01) @abs(num) else 1.0;
							current_font_size = tf_size * tm_scale;
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
			// Stopgap fonts defer decoding (keep raw bytes for resolveStopgapEncoding);
			// kerning spaces below are ASCII (0x20), charset-agnostic, so they survive.
			const str = if (cmap) |cm|
				(if (cm.stopgap) raw_str else (decodeThroughCMap(allocator, raw_str, cm) orelse raw_str))
			else
				raw_str;
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

/// A visual line: runs (TextSpans) sharing a text baseline, in reading order
/// (left→right). `size` is the MEDIAN run font size — robust to erratic per-run
/// sizing (the Brann failure: 9.2–16.2 within one sentence), so heading detection
/// keys off the line, not any single outlier run.
const PdfLine = struct {
	runs: []TextSpan, // borrows from the sorted-spans backing array
	page: u32,
	y: f32, // representative baseline (runs share it within tolerance)
	size: f32, // median run font size
};

/// Result of clusterRunsIntoLines: the lines plus the owned backing array they
/// borrow from. Caller frees both with `freeLines`.
const ClusteredLines = struct {
	lines: []PdfLine,
	backing: []TextSpan,
};

fn freeLines(allocator: Allocator, cl: ClusteredLines) void {
	allocator.free(cl.lines);
	allocator.free(cl.backing);
}

fn lineXLessThan(_: void, a: TextSpan, b: TextSpan) bool {
	return a.x_position < b.x_position;
}

/// Median font size of a line's runs (even count → average of the two middles).
/// A bounded stack buffer keeps it pure; pathologically long lines (>256 runs)
/// median over the first 256, which is plenty representative.
fn medianRunSize(runs: []const TextSpan) f32 {
	if (runs.len == 0) return 12.0;
	var buf: [256]f32 = undefined;
	const n = @min(runs.len, buf.len);
	for (runs[0..n], 0..) |r, k| buf[k] = r.font_size;
	std.mem.sort(f32, buf[0..n], {}, comptime std.sort.asc(f32));
	if (n % 2 == 1) return buf[n / 2];
	return (buf[n / 2 - 1] + buf[n / 2]) / 2.0;
}

// ── Geometric reading-order reconstruction (Peter's 2-column gutter heuristic, 2026-06-15) ──
// Content-stream order is NOT reading order in real legal PDFs: SCOTUS slip opinions
// and OSG briefs emit positioned runs out of visual order, so reading them in stream
// order scrambles multi-column text and Tables of Authorities (incitez_web's ~82%
// citation-loss regression). This pass reconstructs reading order per page from glyph
// geometry, constrained to ≤2 columns (legal works are never 3-col):
//   1. Detect a central column GUTTER via an x-coverage histogram (a low-density
//      vertical channel in the middle third, with content on both sides).
//   2. Classify each visual line: one that CROSSES the gutter is full-width (a
//      single-column body line, a heading, or a ToA "name ……… page" dot-leader line
//      → read left→right). One that leaves a clean wide gap at the gutter is a
//      2-column line.
//   3. A 2-column REGION is a multi-line BAND of consecutive non-crossing lines with
//      content on both sides ("no single 2-column line" — Peter): read the whole left
//      column top→bottom, then the right. Isolated split lines are read as full-width.
// Falls back to pure y/x order when no gutter is found, so it is never worse than the
// prior content-stream behaviour on genuinely single-column pages.
const ReadOrder = struct {
	const bins: usize = 64;
	const valley_frac: f32 = 0.15; // gutter channel density < 15% of the busiest column bin
	const gap_frac: f32 = 0.04; // a real inter-column gap exceeds 4% of page width
	const margin: f32 = 1.0; // x slack (pt) around the gutter
	const min_lines_2col: usize = 2; // a 2-column band must span at least two lines
};

const Side = enum { all, left, right };

/// Estimated right edge of a run (no per-glyph widths are tracked, so reuse the
/// 0.4·font_size·len width heuristic that runSeparator uses).
fn estRunRight(s: TextSpan) f32 {
	return s.x_position + @as(f32, @floatFromInt(s.text.len)) * s.font_size * 0.4;
}

fn pageXBounds(page: []const TextSpan) struct { min: f32, max: f32 } {
	var mn: f32 = std.math.floatMax(f32);
	var mx: f32 = -std.math.floatMax(f32);
	for (page) |s| {
		if (s.x_position < mn) mn = s.x_position;
		const r = estRunRight(s);
		if (r > mx) mx = r;
	}
	return .{ .min = mn, .max = mx };
}

/// Detect a central column gutter: the lowest-density bin in the middle third of an
/// x-coverage histogram, accepted only if it is a clear whitespace channel (< a
/// fraction of the busiest bin) with content on both sides. Returns the gutter x or null.
fn detectGutter(allocator: Allocator, page: []const TextSpan) !?f32 {
	const b = pageXBounds(page);
	const w = b.max - b.min;
	if (w <= 0) return null;
	const nb = ReadOrder.bins;
	const cov = try allocator.alloc(f32, nb);
	defer allocator.free(cov);
	@memset(cov, 0);
	const binw = w / @as(f32, @floatFromInt(nb));
	if (binw <= 0) return null;
	for (page) |s| {
		const r = estRunRight(s);
		if (r <= s.x_position) continue;
		var bi: usize = @intFromFloat(@max(0.0, (s.x_position - b.min) / binw));
		const be: usize = @min(nb - 1, @as(usize, @intFromFloat(@max(0.0, (r - b.min) / binw))));
		if (bi > nb - 1) bi = nb - 1;
		while (bi <= be) : (bi += 1) cov[bi] += 1;
	}
	var peak: f32 = 0;
	for (cov) |c| {
		if (c > peak) peak = c;
	}
	if (peak <= 0) return null;
	const lo = nb / 3;
	const hi = (nb * 2) / 3;
	var valley_bin: usize = lo;
	var valley: f32 = std.math.floatMax(f32);
	var k: usize = lo;
	while (k <= hi and k < nb) : (k += 1) {
		if (cov[k] < valley) {
			valley = cov[k];
			valley_bin = k;
		}
	}
	if (valley > ReadOrder.valley_frac * peak) return null; // no clean channel → single column
	const gutter = b.min + (@as(f32, @floatFromInt(valley_bin)) + 0.5) * binw;
	var leftc: f32 = 0;
	var rightc: f32 = 0;
	for (page) |s| {
		if (estRunRight(s) <= gutter) {
			leftc += 1;
		} else if (s.x_position >= gutter) {
			rightc += 1;
		}
	}
	if (leftc < 1 or rightc < 1) return null;
	return gutter;
}

/// A line is "split" (a true 2-column line) when no run spans the gutter AND there
/// is a clean gap wider than gap_frac·page_w straddling it. A run that crosses the
/// gutter (full-width text, a dot-leader bridging name→page) makes the line full-width.
fn lineIsSplitIdx(page: []const TextSpan, ln: []const usize, gutter: f32, page_w: f32) bool {
	var left_max_right: f32 = -std.math.floatMax(f32);
	var right_min_left: f32 = std.math.floatMax(f32);
	var has_cross = false;
	for (ln) |k| {
		const s = page[k];
		const l = s.x_position;
		const r = estRunRight(s);
		if (l < gutter - ReadOrder.margin and r > gutter + ReadOrder.margin) has_cross = true;
		if (r <= gutter + ReadOrder.margin and r > left_max_right) left_max_right = r;
		if (l >= gutter - ReadOrder.margin and l < right_min_left) right_min_left = l;
	}
	if (has_cross) return false;
	if (left_max_right == -std.math.floatMax(f32) or right_min_left == std.math.floatMax(f32)) return false;
	return (right_min_left - left_max_right) > ReadOrder.gap_frac * page_w;
}

/// Append a line's runs (for the requested side, partitioned by run CENTER vs gutter)
/// to `out`, x-sorted. The center test guarantees a clean partition (no run dropped
/// or double-counted) for split lines.
fn emitLineIdx(allocator: Allocator, page: []const TextSpan, ln: []const usize, out: *std.ArrayList(TextSpan), side: Side, gutter: f32) !void {
	const buf = try allocator.alloc(usize, ln.len);
	defer allocator.free(buf);
	var n: usize = 0;
	for (ln) |k| {
		const s = page[k];
		const center = (s.x_position + estRunRight(s)) * 0.5;
		const keep = switch (side) {
			.all => true,
			.left => center < gutter,
			.right => center >= gutter,
		};
		if (keep) {
			buf[n] = k;
			n += 1;
		}
	}
	std.mem.sort(usize, buf[0..n], page, struct {
		fn lt(p: []const TextSpan, a: usize, b: usize) bool {
			return p[a].x_position < p[b].x_position;
		}
	}.lt);
	for (buf[0..n]) |k| try out.append(allocator, page[k]);
}

/// Reorder one page's runs into reading order (see ReadOrder above). Appends to `out`.
fn orderPage(allocator: Allocator, page: []const TextSpan, out: *std.ArrayList(TextSpan)) !void {
	if (page.len == 0) return;
	const ord = try allocator.alloc(usize, page.len);
	defer allocator.free(ord);
	for (ord, 0..) |*p, k| p.* = k;
	std.mem.sort(usize, ord, page, struct {
		fn lt(p: []const TextSpan, a: usize, b: usize) bool {
			if (p[a].y_position != p[b].y_position) return p[a].y_position > p[b].y_position; // top→bottom
			return p[a].x_position < p[b].x_position;
		}
	}.lt);

	const gutter_opt = try detectGutter(allocator, page);
	if (gutter_opt == null) {
		for (ord) |k| try out.append(allocator, page[k]);
		return;
	}
	const gutter = gutter_opt.?;
	const bounds = pageXBounds(page);
	const page_w = bounds.max - bounds.min;

	// Group the y-sorted indices into visual lines (same tolerance as clusterRunsIntoLines).
	var line_starts = std.ArrayList(usize).empty;
	defer line_starts.deinit(allocator);
	var line_ends = std.ArrayList(usize).empty;
	defer line_ends.deinit(allocator);
	var li: usize = 0;
	while (li < ord.len) {
		const start = li;
		const base_y = page[ord[li]].y_position;
		const base_f = page[ord[li]].font_size;
		li += 1;
		while (li < ord.len) {
			const tol = @max(page[ord[li]].font_size, base_f) * 0.5;
			if (@abs(page[ord[li]].y_position - base_y) > tol) break;
			li += 1;
		}
		try line_starts.append(allocator, start);
		try line_ends.append(allocator, li);
	}
	const nlines = line_starts.items.len;
	const is_split = try allocator.alloc(bool, nlines);
	defer allocator.free(is_split);
	for (0..nlines) |t| {
		is_split[t] = lineIsSplitIdx(page, ord[line_starts.items[t]..line_ends.items[t]], gutter, page_w);
	}

	var t: usize = 0;
	while (t < nlines) {
		if (!is_split[t]) {
			try emitLineIdx(allocator, page, ord[line_starts.items[t]..line_ends.items[t]], out, .all, gutter);
			t += 1;
			continue;
		}
		var u = t;
		while (u < nlines and is_split[u]) u += 1;
		if (u - t >= ReadOrder.min_lines_2col) {
			var s = t;
			while (s < u) : (s += 1) try emitLineIdx(allocator, page, ord[line_starts.items[s]..line_ends.items[s]], out, .left, gutter);
			s = t;
			while (s < u) : (s += 1) try emitLineIdx(allocator, page, ord[line_starts.items[s]..line_ends.items[s]], out, .right, gutter);
		} else {
			var s = t;
			while (s < u) : (s += 1) try emitLineIdx(allocator, page, ord[line_starts.items[s]..line_ends.items[s]], out, .all, gutter);
		}
		t = u;
	}
}

/// Reconstruct reading order across all pages. Returns a NEW owned array of shallow
/// TextSpan copies (text slices are shared, not duplicated — the caller frees only
/// the array). Pages are contiguous in the input and kept in page order.
fn reorderRunsByReading(allocator: Allocator, spans: []const TextSpan) ![]TextSpan {
	var out = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len);
	errdefer out.deinit(allocator);
	var i: usize = 0;
	while (i < spans.len) {
		const page = spans[i].page;
		var j = i;
		while (j < spans.len and spans[j].page == page) j += 1;
		try orderPage(allocator, spans[i..j], &out);
		i = j;
	}
	return out.toOwnedSlice(allocator);
}

/// Group spans into visual lines from runs ALREADY in reading order (inferStructure
/// runs reorderRunsByReading first, which reconstructs geometric reading order incl.
/// ≤2-column layouts). Clusters CONSECUTIVE runs whose baselines are within ~half the
/// larger run's height; a new line starts on any larger y jump (next line, or the top
/// of the next column in the reordered stream). Each line's runs are then x-sorted.
/// Pure; caller frees with `freeLines`.
fn clusterRunsIntoLines(allocator: Allocator, spans: []const TextSpan) !ClusteredLines {
	const backing = try allocator.dupe(TextSpan, spans);
	errdefer allocator.free(backing);

	var lines = std.ArrayList(PdfLine).empty;
	errdefer lines.deinit(allocator);

	var i: usize = 0;
	while (i < backing.len) {
		const start = i;
		const page = backing[i].page;
		const base_y = backing[i].y_position;
		i += 1;
		while (i < backing.len and backing[i].page == page) {
			const tol = @max(backing[i].font_size, backing[start].font_size) * 0.5;
			if (@abs(backing[i].y_position - base_y) > tol) break;
			i += 1;
		}
		const run_slice = backing[start..i];
		std.mem.sort(TextSpan, run_slice, {}, lineXLessThan);
		try lines.append(allocator, .{
			.runs = run_slice,
			.page = page,
			.y = base_y,
			.size = medianRunSize(run_slice),
		});
	}
	return .{ .lines = try lines.toOwnedSlice(allocator), .backing = backing };
}


/// Separator between two adjacent runs when joining a visual line.
const RunSep = enum { none, space };

fn lastNonSpace(s: []const u8) ?u8 {
	var i = s.len;
	while (i > 0) {
		i -= 1;
		if (s[i] != ' ' and s[i] != '\t') return s[i];
	}
	return null;
}

fn firstNonSpace(s: []const u8) ?u8 {
	for (s) |c| {
		if (c != ' ' and c != '\t') return c;
	}
	return null;
}

/// True when the boundary letters of two runs would merge into a NON-dictionary
/// word ("for"+"an" → "foran"). Used to keep a narrow real space when the x-gap
/// alone is ambiguous. Returns false if either side's boundary fragment is <2
/// letters or non-alphabetic (i.e. there's already a separator/punctuation).
fn joinedFragmentIsNonWord(prev_text: []const u8, next_text: []const u8) bool {
	var ps = prev_text.len;
	while (ps > 0 and isAlphaByte(prev_text[ps - 1])) ps -= 1;
	const pf = prev_text[ps..];
	var ne: usize = 0;
	while (ne < next_text.len and isAlphaByte(next_text[ne])) ne += 1;
	const nf = next_text[0..ne];
	if (pf.len < 2 or nf.len < 2) return false;
	if (pf.len + nf.len > 128) return false;
	var buf: [128]u8 = undefined;
	@memcpy(buf[0..pf.len], pf);
	@memcpy(buf[pf.len .. pf.len + nf.len], nf);
	return !wordfix.isWord(buf[0 .. pf.len + nf.len]);
}

fn isAlphaByte(c: u8) bool {
	return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// How to treat a line-break hyphen at a soft wrap: the previous line ended with
/// "<left>-" and the next line starts with "<right>". `.drop` = soft hyphenation,
/// remove the hyphen (the joined form is a dictionary word, OR the left fragment is
/// not a word — a proper-noun split like "Ada-rand"→"Adarand"); `.keep` = a real
/// compound (left IS a word but the join is not, e.g. "well-known"); `.not_applicable`
/// = not a clean alpha word-continuation (fall back to normal spacing). Only consulted
/// at an actual line wrap, so mid-line compounds ("e-mail", "x-ray") are untouched.
const WrapHyphen = enum { drop, keep, not_applicable };
fn wrapHyphenDecision(buf: []const u8, next: []const u8) WrapHyphen {
	if (buf.len == 0 or buf[buf.len - 1] != '-') return .not_applicable;
	var lstart = buf.len - 1; // index of the trailing hyphen
	while (lstart > 0 and isAlphaByte(buf[lstart - 1])) lstart -= 1;
	const left = buf[lstart .. buf.len - 1];
	var re: usize = 0;
	while (re < next.len and isAlphaByte(next[re])) re += 1;
	const right = next[0..re];
	if (left.len == 0 or right.len == 0) return .not_applicable;
	var cbuf: [128]u8 = undefined;
	if (left.len + right.len <= cbuf.len) {
		@memcpy(cbuf[0..left.len], left);
		@memcpy(cbuf[left.len .. left.len + right.len], right);
		if (wordfix.isWord(cbuf[0 .. left.len + right.len])) return .drop;
	}
	// Capitalization disambiguates the remaining cases (the dictionary can't: "Ada"/"rand"
	// are both words yet "Adarand" is a proper-noun split, while "well"/"known" are a real
	// compound). A hyphenated proper compound is Cap+Cap ("Smith-Jones") → keep the hyphen.
	if (std.ascii.isUpper(left[0]) and std.ascii.isUpper(right[0])) return .keep;
	if (!wordfix.isWord(left)) return .drop; // non-word left fragment (Bos-, BethEn-, e-) → soft split
	if (std.ascii.isUpper(left[0])) return .drop; // Capitalized word + lowercase tail = proper-noun split (Ada-rand)
	return .keep; // lowercase word, join is not a word → real compound (well-known, self-evident)
}

/// Detokenizer-aware separator between two runs. pdfminer decides spacing purely
/// by x-gap, which yields "word , comma"; we add punctuation attachment so closing
/// punctuation hugs the previous token and openers hug the next. Punctuation rules
/// win; otherwise a default space (runs are distinct fragments) unless their x
/// extents butt together (a mid-word split → no space; the dictionary rejoin pass
/// is the safety net). Runs keep their own leading/trailing spaces regardless.
fn runSeparator(prev: TextSpan, next: TextSpan) RunSep {
	const nf = firstNonSpace(next.text) orelse return .space;
	switch (nf) {
		',', '.', ';', ':', '!', '?', ')', ']', '}', '%', '\'' => return .none,
		else => {},
	}
	const pl = lastNonSpace(prev.text) orelse return .space;
	switch (pl) {
		'(', '[', '{', '-' => return .none,
		else => {},
	}
	// Sentence punctuation is always followed by a space before a word — never
	// "word,word" (Peter 2026-06-15). This overrides the x-gap, so a dropped-space tight
	// boundary ("Co.,Adam") is still separated. Only fires before a LETTER, so numbers
	// keep their punctuation tight ("1,000", "3.14", a decimal/thousands separator).
	if ((pl == ',' or pl == ';') and isAlphaByte(nf)) return .space;
	// x-gap: if next starts at/inside prev's estimated extent, they butt together.
	const prev_right = prev.x_position + @as(f32, @floatFromInt(prev.text.len)) * prev.font_size * 0.4;
	if (next.x_position - prev_right < next.font_size * 0.15) {
		// Tight gap usually means a mid-word split (no space). But if joining the
		// adjacent letter-fragments yields a NON-word ("for"+"an" = "foran"), it was
		// a real narrow space — keep it (dictionary heuristic from the pre-line-aware
		// path; the rejoin pass can't re-split a wrongly-merged word).
		if (joinedFragmentIsNonWord(prev.text, next.text)) return .space;
		return .none;
	}
	return .space;
}

/// Join a clustered line's runs into one string with detokenizer-aware spacing.
fn joinLineRuns(allocator: Allocator, line: PdfLine) ![]u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	for (line.runs, 0..) |run, idx| {
		if (idx > 0 and runSeparator(line.runs[idx - 1], run) == .space) {
			try buf.append(allocator, ' ');
		}
		try buf.appendSlice(allocator, run.text);
	}
	return buf.toOwnedSlice(allocator);
}

/// Replace Table-of-Authorities dot-leader runs with a lone newline (incitez 2026-06-15:
/// a structural separator so a citation walk-back stops there instead of welding entry
/// N's page refs onto entry N+1's name). Lexical equivalent of /(?:\.[ \t]*){5,}/ → "\n":
/// 5+ dots, each optionally followed by spaces/tabs. The 5+ threshold preserves 3-dot
/// "..." ellipses, Bluebook 4-dot "....", and reporter spacing ("U. S." never reaches a
/// run of 5). Preceding spaces are dropped so the boundary is a lone newline.
fn dotLeaderToNewline(allocator: Allocator, text: []const u8) ![]u8 {
	var out = std.ArrayList(u8).empty;
	errdefer out.deinit(allocator);
	var i: usize = 0;
	while (i < text.len) {
		if (text[i] == '.') {
			var j = i;
			var dots: usize = 0;
			while (j < text.len and (text[j] == '.' or text[j] == ' ' or text[j] == '\t')) {
				if (text[j] == '.') dots += 1;
				j += 1;
			}
			if (dots >= 5) {
				while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) _ = out.pop();
				try out.append(allocator, '\n');
				i = j;
				continue;
			}
			try out.appendSlice(allocator, text[i..j]);
			i = j;
			continue;
		}
		try out.append(allocator, text[i]);
		i += 1;
	}
	return out.toOwnedSlice(allocator);
}

/// Known Table-of-Authorities section headers, LONGEST-first so multi-word headers match
/// before their single-word prefixes ("Other Authorities" before "Authorities").
const toa_headers = [_][]const u8{
	"Constitutional Provisions", "Statutory Provisions", "Legislative Materials",
	"Legislative History", "Table of Authorities", "Other Authorities",
	"Federal Cases", "State Cases", "Authorities", "Regulations", "Treatises",
	"Miscellaneous", "Statutes", "Cases", "Rules",
};

/// Longest known ToA header that prefixes `s` at a word boundary (case-insensitive), or null.
fn matchToAHeader(s: []const u8) ?usize {
	for (toa_headers) |h| {
		if (s.len < h.len) continue;
		if (std.ascii.eqlIgnoreCase(s[0..h.len], h)) {
			const after: u8 = if (s.len > h.len) s[h.len] else ' ';
			if (after == ' ' or after == '\t' or after == ':' or after == '\n') return h.len;
		}
	}
	return null;
}

/// Put a ToA section header on its own line: at a line start, if the text begins with a
/// known header followed by (optional ':') a space and then a capital/digit (the first
/// entry), insert a newline after the header — a structural boundary a citation walk-back
/// can strip (incitez 2026-06-15). The capital/digit guard avoids splitting body prose
/// that merely starts with "Cases ...".
fn splitToAHeaders(allocator: Allocator, text: []const u8) ![]u8 {
	var out = std.ArrayList(u8).empty;
	errdefer out.deinit(allocator);
	var i: usize = 0;
	var at_line_start = true;
	while (i < text.len) {
		if (at_line_start) {
			if (matchToAHeader(text[i..])) |hlen| {
				var k = i + hlen;
				if (k < text.len and text[k] == ':') k += 1;
				if (k < text.len and (text[k] == ' ' or text[k] == '\t')) {
					var r = k;
					while (r < text.len and (text[r] == ' ' or text[r] == '\t')) r += 1;
					if (r < text.len and (std.ascii.isUpper(text[r]) or std.ascii.isDigit(text[r]))) {
						try out.appendSlice(allocator, text[i..k]);
						try out.append(allocator, '\n');
						i = r;
						continue; // at_line_start stays true: the entry begins a new line
					}
				}
			}
		}
		const c = text[i];
		try out.append(allocator, c);
		at_line_start = (c == '\n');
		i += 1;
	}
	return out.toOwnedSlice(allocator);
}
/// Infer document structure from text spans using font size heuristics.
/// Larger text = headings, dominant (most common) size = body text.
fn inferStructure(allocator: Allocator, run_spans: []const TextSpan) ![]const Section {
	if (run_spans.len == 0) return try allocator.alloc(Section, 0);

	// Line-aware re-section: collapse the raw runs into one synthetic span PER
	// VISUAL LINE (median font size, detokenizer-joined text) before any structure
	// inference. Real PDFs (e.g. the Brann brief) set per-run font sizes erratically
	// (9.2–16.2 within a sentence), which made the per-span heading detector below
	// misclassify mid-sentence runs as headings and shred the document into bogus
	// one-run sections. Keying off the per-LINE median fixes that; intra-line spacing
	// is already resolved by joinLineRuns. All logic below operates on these line
	// spans (the `spans` shadow), so it needs no further change.
	// Reconstruct geometric reading order (≤2-column gutter detection) before
	// clustering — the content stream is not reliably in reading order on real
	// multi-column legal PDFs (incitez_web 2026-06-15). See reorderRunsByReading.
	const ordered = try reorderRunsByReading(allocator, run_spans);
	defer allocator.free(ordered);
	const cl = try clusterRunsIntoLines(allocator, ordered);
	defer freeLines(allocator, cl);
	var line_spans = std.ArrayList(TextSpan).empty;
	defer {
		for (line_spans.items) |ls| allocator.free(ls.text);
		line_spans.deinit(allocator);
	}
	for (cl.lines) |line| {
		const joined = try joinLineRuns(allocator, line);
		defer allocator.free(joined);
		const text = try dotLeaderToNewline(allocator, joined); // ToA leaders → newline boundary
		try line_spans.append(allocator, .{
			.text = text,
			.font_size = line.size,
			.page = line.page,
			.y_position = line.y,
			.x_position = if (line.runs.len > 0) line.runs[0].x_position else 0,
		});
	}
	const spans = line_spans.items;
	// Dominant body font size = the mode by character count, BUCKETED to the nearest
	// point. The bucketing is the fix: real PDFs Tm-scale text so the body splits
	// across many fractional sizes (Brann's body is ~30 distinct sizes in 13.69–14.46,
	// none beating its single 5pt dot-leader spike of 7089 chars). Rounded, the body
	// band collapses into one "14" bucket (>20k chars) that dominates, while a normal
	// doc's body is unaffected. Computed over RAW runs (line medians would let a
	// 5pt-run-heavy line skew it). No magic floor — this targets the fractional-size
	// fragmentation root cause; validated across the unit tests + tools/fetch-corpus.sh.
	var size_counts = std.AutoHashMap(u32, usize).init(allocator);
	defer size_counts.deinit();

	for (run_spans) |span| {
		if (span.font_size <= 0) continue;
		const key: u32 = @intFromFloat(@round(span.font_size)); // bucket to nearest pt
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
			dominant_size = @floatFromInt(entry.key_ptr.*);
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

	// Adaptive line-gap: real PDFs set per-span font sizes erratically (e.g. a spurious
	// 5pt Tf between body spans), so a font-relative paragraph threshold is fragile. The
	// document's OWN modal vertical line advance is the reliable wrap-vs-paragraph signal.
	// Bucket consecutive same-page vertical advances (to the nearest point) over a sane
	// line-height range; if a clear, well-sampled mode emerges, a gap >= modal*1.5 is a
	// paragraph break. Otherwise (too few samples — synthetic/short docs) fall back to the
	// per-span font heuristic below.
	var modal_gap: f32 = 0;
	{
		var gap_counts = std.AutoHashMap(u32, usize).init(allocator);
		defer gap_counts.deinit();
		var have_prev_gap = false;
		var gap_prev_y: f32 = 0;
		var gap_prev_page: u32 = 0;
		for (spans) |span| {
			if (have_prev_gap and span.page == gap_prev_page) {
				const g = @abs(span.y_position - gap_prev_y);
				if (g >= 4.0 and g <= 72.0) {
					const bucket: u32 = @intFromFloat(@round(g));
					const e = try gap_counts.getOrPut(bucket);
					if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;
				}
			}
			gap_prev_y = span.y_position;
			gap_prev_page = span.page;
			have_prev_gap = true;
		}
		var best: usize = 0;
		var git = gap_counts.iterator();
		while (git.next()) |e| {
			if (e.value_ptr.* > best) {
				best = e.value_ptr.*;
				modal_gap = @floatFromInt(e.key_ptr.*);
			}
		}
		if (best < 4) modal_gap = 0; // need a clear, well-sampled mode to trust it
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
						// Adaptive when the document has a clear modal line height; else
						// fall back to the per-span font heuristic (short/synthetic docs).
						const paragraph_threshold = if (modal_gap > 0) modal_gap * 1.5 else prev_font_size * 2.2;
						if (y_diff < paragraph_threshold) {
							const blen = fs.content_buf.items.len;
							// A line-break hyphen joins a word across the wrap (incitez_web
							// 2026-06-15: case names like "Ada-\nrand"→"Adarand"). Drop a soft
							// hyphen, keep a real compound ("well-known"), no space either way.
							switch (wrapHyphenDecision(fs.content_buf.items, span.text)) {
								.drop => _ = fs.content_buf.pop(),
								.keep => {},
								.not_applicable => {
									const last_ws = blen > 0 and (fs.content_buf.items[blen - 1] == ' ' or fs.content_buf.items[blen - 1] == '\n');
									if (!last_ws) try fs.content_buf.append(allocator, ' ');
								},
							}
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
	// Put ToA section headers ("Cases", "Statutes", "Other Authorities", …) on their own
	// line: in a Table of Authorities the header is its own visual line but gets merged
	// onto entry 1 ("Cases Albritton v. Gandy"), bleeding into the party name. A lone \n
	// after the header is the same structural-boundary role as the dot-leader fix — it
	// lets a citation walk-back strip the header (incitez 2026-06-15).
	for (flat_sections.items) |*fs| {
		const split = try splitToAHeaders(allocator, fs.content_buf.items);
		defer allocator.free(split);
		fs.content_buf.clearRetainingCapacity();
		try fs.content_buf.appendSlice(allocator, split);
	}
	if (flat_sections.items.len == 0) return try allocator.alloc(Section, 0);
	return try buildTree(allocator, flat_sections.items, 0, flat_sections.items.len);
}

fn headingLevelForSize(size: f32, heading_sizes: []const f32) u8 {
	for (heading_sizes, 0..) |hs, i| {
		// Saturate: real documents never have 255 heading levels, but a pathological
		// PDF can declare >255 distinct font sizes (Brann's erratic sizing). Clamp to
		// the u8 max instead of overflowing the cast.
		if (@abs(hs - size) < 0.01) return @intCast(@min(i + 1, @as(usize, std.math.maxInt(u8))));
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
			try stream_buf.print(allocator, "{d} {d} Td\n", .{ @as(i32, @intFromFloat(item.x_pos)), @as(i32, @intFromFloat(item.y_pos)) });
			if (item.tj) {
				// Emit as a TJ array (kerning form): [(text)] TJ
				try stream_buf.appendSlice(allocator, "[(");
				try stream_buf.appendSlice(allocator, item.text);
				try stream_buf.appendSlice(allocator, ")] TJ\n");
			} else {
				try stream_buf.appendSlice(allocator, "(");
				try stream_buf.appendSlice(allocator, item.text);
				try stream_buf.appendSlice(allocator, ") Tj\n");
			}
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
	/// Emit this item as a TJ array `[(text)] TJ` instead of `(text) Tj`.
	tj: bool = false,
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

test "Tm positioning with identity scale keeps the Tf font size (not the Tm d-component)" {
	// Regression (incitez_web 2026-06-14): groff-style PDFs position text via
	// Tm [1 0 0 1 x y] (d = 1, an identity vertical SCALE) and set the point size via
	// Tf. Conflating the Tm d-component with the font size clobbered font_size to ~1,
	// which collapsed the wrap-vs-paragraph threshold so every line break became a
	// boundary and split citations. Effective size = Tf_size * Tm_d_scale.
	const stream =
		"BT\n/F1 10 Tf\n1 0 0 1 72 700 Tm\n(Roe v. Wade, 410) Tj\nET\n" ++
		"BT\n/F1 10 Tf\n1 0 0 1 72 688 Tm\n(U.S. 113) Tj\nET\n";
	var spans = std.ArrayList(TextSpan).empty;
	defer {
		for (spans.items) |s| testing.allocator.free(s.text);
		spans.deinit(testing.allocator);
	}

	try parseContentStream(testing.allocator, stream, &spans, 0, null);

	try testing.expect(spans.items.len >= 2);
	for (spans.items) |s| {
		try testing.expectApproxEqAbs(@as(f32, 10.0), s.font_size, 0.5);
	}
}

test "pdf adaptive wrap-join: a spurious small per-span font doesn't split lines (modal line-gap)" {
	// Real-brief pattern (Brann, incitez_web 2026-06-14): the generator emits a spurious
	// '5 Tf' before a body span. A font-relative paragraph threshold (prev_font*2.2 = 11pt)
	// then treats the normal single-line advance (16pt) as a boundary and splits the line
	// ("Albritton v.\nGandy..."), dropping the citation. The document's OWN modal line
	// advance (16pt here, x4) is the reliable signal: 16 = wrap (join), 32 = paragraph.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "First body line here", .font_size = 14, .y_pos = 700 },
			.{ .text = "second line of text", .font_size = 14, .y_pos = 684 }, // 16 gap (modal)
			.{ .text = "Albritton v.", .font_size = 5, .y_pos = 668 }, // spurious 5pt Tf, 16 gap
			.{ .text = "Gandy 531 So 2d 381", .font_size = 14, .y_pos = 652 }, // 16 gap AFTER the 5pt span
			.{ .text = "more body content here", .font_size = 14, .y_pos = 636 }, // 16 gap
			.{ .text = "New paragraph begins", .font_size = 14, .y_pos = 604 }, // 32 gap -> boundary
		} },
	});
	defer testing.allocator.free(pdf);

	const doc = try parse(testing.allocator, pdf, "/test/brann.pdf");
	defer freeDocument(testing.allocator, doc);

	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;

	// the line after the spurious 5pt span joins instead of splitting
	try testing.expect(std.mem.indexOf(u8, c, "Albritton v. Gandy 531 So 2d 381") != null);
	// the 32pt gap is preserved as a paragraph boundary (lone newline)
	try testing.expect(std.mem.indexOf(u8, c, "more body content here\nNew paragraph begins") != null);
}

test "pdf: undeclared simple-font high bytes map via WinAnsi (CP1252) to UTF-8, not raw" {
	// Peter/incitez_web 2026-06-14: PDF simple fonts declaring no /Encoding and no
	// ToUnicode emitted raw CP1252 bytes (0x93/0x94 curly quotes, 0x97 em dash) =>
	// invalid UTF-8. Default such fonts to WinAnsi so bytes become proper UTF-8.
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = "\x93Hello\x94 \x97 there", .font_size = 12, .y_pos = 700 },
		} },
	});
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/cp1252.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "\u{201C}Hello\u{201D}") != null);
	try testing.expect(std.mem.indexOf(u8, c, "\u{2014}") != null);
	try testing.expect(std.mem.indexOfScalar(u8, c, 0x93) == null);
}

test "decrypt blank-password PDFs (RC4-128, AES-128, AES-256/R6) and extract text" {
	// Standard Security Handler, empty USER password. Decryption logic vendored from
	// validate (pdf_decryptor.zig); fixtures are qpdf-encrypted copies of
	// legal-rfc2119-keywords.pdf, so correct decryption => the plaintext is recovered.
	const fixtures = [_][]const u8{
		@embedFile("fixtures/encrypted_rc4_128.pdf"),
		@embedFile("fixtures/encrypted_aes_128.pdf"),
		@embedFile("fixtures/encrypted_v5r6_aes256.pdf"),
	};
	for (fixtures) |pdf| {
		const doc = try parse(testing.allocator, pdf, "/test/enc.pdf");
		defer freeDocument(testing.allocator, doc);
		var all = std.ArrayList(u8).empty;
		defer all.deinit(testing.allocator);
		for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
		try testing.expect(std.mem.indexOf(u8, all.items, "Internet") != null);
		try testing.expect(std.mem.indexOf(u8, all.items, "Requirement") != null);
	}
}

test "pdf: stopgap font whose bytes are UTF-8 is decoded as UTF-8, not CP1252 mojibake" {
	// Peter 2026-06-14 decode-both heuristic: a simple font with no ToUnicode and no
	// /Encoding hits the WinAnsi (CP1252) stopgap. If its text bytes are actually UTF-8
	// (a very common real-world case), byte-wise CP1252 decoding mangles every accented
	// char into mojibake ("café" -> "cafÃ©"). The heuristic must detect the bytes are
	// UTF-8 (chardetz) and keep them — scored higher by wordfix.textQuality than the
	// garbled CP1252 decode.
	const utf8_text = "Café société résumé naïve façade — the Zürich café served " ++
		"crème brûlée and piña colada to every señor and señora at the soirée.";
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = utf8_text, .font_size = 12, .y_pos = 700 },
		} },
	});
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/utf8-stopgap.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	// Correct UTF-8 survived: the literal accented words are intact.
	try testing.expect(std.mem.indexOf(u8, c, "café") != null);
	try testing.expect(std.mem.indexOf(u8, c, "résumé") != null);
	// No CP1252 mojibake: "Ã©" (0xC3 0x83 0xC2 0xA9) is the tell-tale of é misread as CP1252.
	try testing.expect(std.mem.indexOf(u8, c, "Ã©") == null);
}

test "pdf: stopgap font UTF-8 bytes in a TJ array are decoded as UTF-8, not mojibake" {
	// Real PDFs (legal briefs especially) emit body text via TJ arrays for kerning,
	// not bare Tj. The decode-both heuristic must defer TJ text from stopgap fonts too,
	// else the common case stays garbled. Same UTF-8-as-CP1252 mojibake check, via TJ.
	const utf8_text = "Café société résumé naïve façade — the Zürich café served " ++
		"crème brûlée and piña colada to every señor and señora at the soirée.";
	const pdf = try buildTestPdf(testing.allocator, &.{
		.{ .text_items = &.{
			.{ .text = utf8_text, .font_size = 12, .y_pos = 700, .tj = true },
		} },
	});
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/utf8-stopgap-tj.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "café") != null);
	try testing.expect(std.mem.indexOf(u8, c, "résumé") != null);
	try testing.expect(std.mem.indexOf(u8, c, "Ã©") == null);
}

test "pdf: >255 distinct heading font sizes must not overflow the heading level" {
	// Brann (and any PDF with erratic/fractional sizing) declares >255 distinct
	// font sizes above the heading threshold. headingLevelForSize did
	// @intCast(i+1) into a u8 → panic in Debug / UB in ReleaseFast. The level
	// must saturate, not overflow. Regression: parse() must complete cleanly.
	var items = std.ArrayList(TestTextItem).empty;
	defer items.deinit(testing.allocator);
	// Dominant body size 12 (most common → threshold 13.8, 1.5x = 18).
	try items.append(testing.allocator, .{ .text = "body alpha", .font_size = 12, .y_pos = 700 });
	try items.append(testing.allocator, .{ .text = "body beta", .font_size = 12, .y_pos = 680 });
	try items.append(testing.allocator, .{ .text = "body gamma", .font_size = 12, .y_pos = 660 });
	// 256 distinct heading sizes (30..285), all well above 1.5x dominant so they
	// all qualify as headings; the smallest lands at heading_sizes index 255.
	var s: u32 = 30;
	while (s < 30 + 256) : (s += 1) {
		try items.append(testing.allocator, .{ .text = "Heading Text Here", .font_size = @floatFromInt(s), .y_pos = 640 });
	}
	const pdf = try buildTestPdf(testing.allocator, &.{.{ .text_items = items.items }});
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/manysizes.pdf");
	defer freeDocument(testing.allocator, doc);
	try testing.expect(doc.sections.len > 0);
}

/// Build a 1-page PDF whose /Resources is an INDIRECT reference (5 0 R) rather
/// than an inline dict. Real PDFs (e.g. the Brann brief) do this; buildTestPdf
/// always inlines /Resources, so only this shape exercises the getObject path in
/// extractFormXObjectText that leaked.
fn buildPdfIndirectResources(allocator: Allocator) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var offs: [6]usize = undefined;
	try buf.appendSlice(allocator, "%PDF-1.4\n");
	offs[1] = buf.items.len;
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
	offs[2] = buf.items.len;
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
	offs[3] = buf.items.len;
	// Page with INDIRECT /Resources (5 0 R).
	try buf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources 5 0 R >>\nendobj\n");
	const stream = "BT\n/F1 12 Tf\n100 700 Td\n(Hello world) Tj\nET\n";
	offs[4] = buf.items.len;
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(allocator, stream);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	offs[5] = buf.items.len;
	try buf.appendSlice(allocator, "5 0 obj\n<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>\nendobj\n");
	const xref_off = buf.items.len;
	try buf.appendSlice(allocator, "xref\n0 6\n0000000000 65535 f\n");
	var i: usize = 1;
	while (i <= 5) : (i += 1) {
		try buf.print(allocator, "{d:0>10} 00000 n\n", .{offs[i]});
	}
	try buf.appendSlice(allocator, "trailer\n<< /Size 6 /Root 1 0 R >>\n");
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_off});
	return try buf.toOwnedSlice(allocator);
}

test "pdf: indirect /Resources is freed, not leaked (extractFormXObjectText ownership)" {
	// Regression: extractFormXObjectText resolved an indirect /Resources via
	// getObject (a fresh allocation) but never freed it on the common early-return
	// paths — a per-page leak on real PDFs (~976 allocations on the 90-page Brann
	// brief). testing.allocator fails the test if parse() leaks; the sanity check
	// confirms extraction still works.
	const pdf = try buildPdfIndirectResources(testing.allocator);
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/indirect-res.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	try testing.expect(std.mem.indexOf(u8, all.items, "Hello world") != null);
}

test "pdf: parse() leak sweep over allocation-heavy document shapes" {
	// MFIC leak gate: parse() + freeDocument across the shapes whose resolution
	// paths allocate the most — direct/indirect /Resources, form XObjects,
	// encrypted streams, TJ arrays, multi-page. testing.allocator fails the test on
	// ANY leak. Extend this list whenever a new leak is found (add the repro here).
	const a = testing.allocator;

	// 1. Inline /Resources + a heading (the common synthetic shape).
	{
		const pdf = try buildTestPdf(a, &.{.{ .text_items = &.{
			.{ .text = "Big Heading", .font_size = 24, .y_pos = 740 },
			.{ .text = "alpha beta gamma body", .font_size = 12, .y_pos = 700 },
		} }});
		defer a.free(pdf);
		const doc = try parse(a, pdf, "/t/inline.pdf");
		freeDocument(a, doc);
	}
	// 2. Indirect /Resources (the leak fixed in this commit).
	{
		const pdf = try buildPdfIndirectResources(a);
		defer a.free(pdf);
		const doc = try parse(a, pdf, "/t/indirect.pdf");
		freeDocument(a, doc);
	}
	// 3. Form XObject (the extractFormXObjectText path).
	{
		const pdf = try buildTestPdfWithFormXObject(a, "Form layer text here");
		defer a.free(pdf);
		const doc = try parse(a, pdf, "/t/form.pdf");
		freeDocument(a, doc);
	}
	// 4. Encrypted PDFs (decryptor + crypt-filter allocations).
	for ([_][]const u8{
		@embedFile("fixtures/encrypted_rc4_128.pdf"),
		@embedFile("fixtures/encrypted_aes_128.pdf"),
		@embedFile("fixtures/encrypted_v5r6_aes256.pdf"),
	}) |enc| {
		const doc = try parse(a, enc, "/t/enc.pdf");
		freeDocument(a, doc);
	}
	// 5. TJ array + multi-page.
	{
		const pdf = try buildTestPdf(a, &.{
			.{ .text_items = &.{.{ .text = "page one TJ text", .font_size = 12, .y_pos = 700, .tj = true }} },
			.{ .text_items = &.{.{ .text = "page two body text", .font_size = 12, .y_pos = 700 }} },
		});
		defer a.free(pdf);
		const doc = try parse(a, pdf, "/t/tj.pdf");
		freeDocument(a, doc);
	}
}

test "clusterRunsIntoLines groups by baseline and median ignores per-run size outliers" {
	// Real Brann coordinates: two visual lines (~656, ~624), each split into runs
	// with wildly varying per-run font sizes (the failure that fooled per-span
	// heading detection). The clusterer must yield 2 lines, x-ordered runs, and a
	// MEDIAN size near the body (~14), not the 16.2 outlier.
	const spans = [_]TextSpan{
		.{ .text = "Following", .font_size = 14.0, .page = 1, .y_position = 656.40, .x_position = 117.84 },
		.{ .text = ", the plaintiff-", .font_size = 14.9, .page = 1, .y_position = 655.92, .x_position = 295.92 },
		.{ .text = ", Matrix Group", .font_size = 14.4, .page = 1, .y_position = 656.64, .x_position = 425.28 },
		// Second line, deliberately out of x order + with 9.2 and 16.2 outliers.
		.{ .text = "), obtained a", .font_size = 16.2, .page = 1, .y_position = 623.52, .x_position = 221.04 },
		.{ .text = "Limited", .font_size = 13.9, .page = 1, .y_position = 624.24, .x_position = 82.08 },
		.{ .text = ", Inc.", .font_size = 9.2, .page = 1, .y_position = 624.00, .x_position = 126.72 },
		.{ .text = "verdict", .font_size = 10.0, .page = 1, .y_position = 623.52, .x_position = 305.52 },
	};
	const cl = try clusterRunsIntoLines(testing.allocator, &spans);
	defer freeLines(testing.allocator, cl);

	try testing.expectEqual(@as(usize, 2), cl.lines.len);
	// Line 0 (~656): runs x-ordered.
	try testing.expectEqualStrings("Following", cl.lines[0].runs[0].text);
	try testing.expectEqualStrings(", the plaintiff-", cl.lines[0].runs[1].text);
	try testing.expectEqualStrings(", Matrix Group", cl.lines[0].runs[2].text);
	// Line 1 (~624): x-ordered → Limited(82), Inc(126), obtained(221), verdict(305).
	try testing.expectEqual(@as(usize, 4), cl.lines[1].runs.len);
	try testing.expectEqualStrings("Limited", cl.lines[1].runs[0].text);
	try testing.expectEqualStrings("verdict", cl.lines[1].runs[3].text);
	// Median of {9.2,10.0,13.9,16.2} = (10.0+13.9)/2 = 11.95 — NOT the 16.2 outlier.
	try testing.expect(cl.lines[1].size < 14.0);
	try testing.expect(cl.lines[1].size > 10.0);
}

test "joinLineRuns: closing punctuation and hyphen attach left (no spurious space)" {
	var runs = [_]TextSpan{
		.{ .text = "trial", .font_size = 14, .page = 1, .y_position = 656, .x_position = 117 },
		.{ .text = ", the plaintiff-", .font_size = 14, .page = 1, .y_position = 656, .x_position = 295 },
		.{ .text = "appellee", .font_size = 14, .page = 1, .y_position = 656, .x_position = 378 },
	};
	const line = PdfLine{ .runs = &runs, .page = 1, .y = 656, .size = 14 };
	const out = try joinLineRuns(testing.allocator, line);
	defer testing.allocator.free(out);
	// ", " hugs "trial"; "-" hugs "appellee" — no "trial , the plaintiff- appellee".
	try testing.expectEqualStrings("trial, the plaintiff-appellee", out);
}

test "joinLineRuns: opening bracket hugs next, closing punctuation hugs prev" {
	var runs = [_]TextSpan{
		.{ .text = "Inc. (", .font_size = 14, .page = 1, .y_position = 624, .x_position = 82 },
		.{ .text = "Matrix", .font_size = 14, .page = 1, .y_position = 624, .x_position = 126 },
		.{ .text = "), obtained", .font_size = 14, .page = 1, .y_position = 624, .x_position = 176 },
	};
	const line = PdfLine{ .runs = &runs, .page = 1, .y = 624, .size = 14 };
	const out = try joinLineRuns(testing.allocator, line);
	defer testing.allocator.free(out);
	try testing.expectEqualStrings("Inc. (Matrix), obtained", out);
}

test "joinLineRuns: distinct words with an x-gap get a single space" {
	var runs = [_]TextSpan{
		.{ .text = "Rawlings Sporting Goods", .font_size = 14.9, .page = 1, .y_position = 591, .x_position = 82.08 },
		.{ .text = "Company, Inc.", .font_size = 14.8, .page = 1, .y_position = 591, .x_position = 239.76 },
	};
	const line = PdfLine{ .runs = &runs, .page = 1, .y = 591, .size = 14.9 };
	const out = try joinLineRuns(testing.allocator, line);
	defer testing.allocator.free(out);
	try testing.expectEqualStrings("Rawlings Sporting Goods Company, Inc.", out);
}

test "joinLineRuns: a comma is always followed by a space before a word (no word,word)" {
	// Peter 2026-06-15: a comma never abuts the next word ("Co.,Adam" is wrong) — even
	// when the runs butt with a tight x-gap (the dropped-space case). Numbers (1,000)
	// keep no space because the rule only fires before a letter.
	var runs = [_]TextSpan{
		.{ .text = "Gas Co.,", .font_size = 12, .page = 1, .y_position = 700, .x_position = 100 },
		.{ .text = "Adam", .font_size = 12, .page = 1, .y_position = 700, .x_position = 104 }, // butting
	};
	const line = PdfLine{ .runs = &runs, .page = 1, .y = 700, .size = 12 };
	const out = try joinLineRuns(testing.allocator, line);
	defer testing.allocator.free(out);
	try testing.expectEqualStrings("Gas Co., Adam", out);
}

test "pdf: erratic per-run font sizes on one line stay one body section (line-aware)" {
	// The Brann root cause in miniature: a single visual line (same y) whose runs
	// carry erratic per-run font sizes — one spikes above the heading threshold
	// mid-sentence. Pre-line-aware, that run was misclassified as a heading and
	// split the line into bogus sections; now the per-LINE median keeps it body.
	const pdf = try buildTestPdf(testing.allocator, &.{.{ .text_items = &.{
		.{ .text = "The plaintiff", .font_size = 12, .y_pos = 700, .x_pos = 0 },
		.{ .text = "obtained a", .font_size = 17, .y_pos = 700, .x_pos = 120 }, // spike > threshold
		.{ .text = "verdict against", .font_size = 12, .y_pos = 700, .x_pos = 220 },
		.{ .text = "the defendant.", .font_size = 12, .y_pos = 700, .x_pos = 360 },
		.{ .text = "Second line of body text here.", .font_size = 12, .y_pos = 680, .x_pos = 0 },
		.{ .text = "Third line of body text here.", .font_size = 12, .y_pos = 660, .x_pos = 0 },
	} }});
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/erratic.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	// The whole first line is preserved as continuous body text, not split at the
	// size-17 "obtained a" run.
	try testing.expect(std.mem.indexOf(u8, c, "The plaintiff obtained a verdict against the defendant.") != null);
	// And "obtained a" did NOT become a heading.
	for (doc.sections) |s| {
		if (s.heading) |h| try testing.expect(std.mem.indexOf(u8, h, "obtained") == null);
	}
}

test "pdf: multi-column reading order is preserved (no cross-column interleave)" {
	// Regression (incitez_web 2026-06-15): the line-aware re-section globally sorted
	// spans by (page, y desc), so two columns sharing a y-band were merged into one
	// "line" and interleaved — scrambling reading order and gluing citations across
	// the column gap. The content stream already emits columns in reading order
	// (column-major here), so clustering must PRESERVE stream order, not re-sort by y.
	// Two columns, emitted column-major, at overlapping y-bands:
	const pdf = try buildTestPdf(testing.allocator, &.{.{ .text_items = &.{
		.{ .text = "The plaintiff timely filed", .font_size = 12, .y_pos = 700, .x_pos = 60 },
		.{ .text = "its opening brief today.", .font_size = 12, .y_pos = 684, .x_pos = 60 },
		.{ .text = "The respondent then", .font_size = 12, .y_pos = 700, .x_pos = 330 },
		.{ .text = "moved for a dismissal.", .font_size = 12, .y_pos = 684, .x_pos = 330 },
	} }});
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/twocol.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	// Column 1 must come entirely before column 2 (reading order), not interleaved.
	const c1 = std.mem.indexOf(u8, c, "opening brief today.") orelse 0;
	const c2 = std.mem.indexOf(u8, c, "The respondent then") orelse c.len;
	try testing.expect(c1 < c2);
	// The tell-tale cross-column splice must NOT appear.
	try testing.expect(std.mem.indexOf(u8, c, "filed The respondent") == null);
	try testing.expect(std.mem.indexOf(u8, c, "filed its") != null or std.mem.indexOf(u8, c, "filed\nits") != null);
}

/// Build a 1-page PDF with a Type1 font whose /Encoding /Differences names codes
/// 174=/fi, 175=/fl, but whose ToUnicode CMap is BROKEN (maps both to "f" only) —
/// exactly the real-world defect in SCOTUS slip-opinion Century fonts. The text
/// "de<0xAE>nes <0xAF>ag" should extract as "defines flag", but a build that trusts
/// the broken ToUnicode yields "defnes fag".
fn buildPdfBrokenLigatureToUnicode(allocator: Allocator) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var offs: [8]usize = undefined;
	try buf.appendSlice(allocator, "%PDF-1.4\n");
	offs[1] = buf.items.len;
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
	offs[2] = buf.items.len;
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
	offs[3] = buf.items.len;
	try buf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");
	// Content stream: "de" + 0xAE(fi) + "nes " + 0xAF(fl) + "ag"  → "defines flag".
	const stream = "BT\n/F1 12 Tf\n100 700 Td\n(de\xAEnes \xAFag) Tj\nET\n";
	offs[4] = buf.items.len;
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(allocator, stream);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	// Font: Differences names 174=/fi 175=/fl, but ToUnicode (obj 6) is broken.
	offs[5] = buf.items.len;
	try buf.appendSlice(allocator, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /CenturyExpanded /Encoding 7 0 R /ToUnicode 6 0 R >>\nendobj\n");
	// Broken ToUnicode: both ligature codes map to plain "f" (U+0066).
	const cmap =
		"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapType 2 def\n" ++
		"1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" ++
		"2 beginbfchar\n<AE> <0066>\n<AF> <0066>\nendbfchar\nendcmap\nend\nend\n";
	offs[6] = buf.items.len;
	try buf.print(allocator, "6 0 obj\n<< /Length {d} >>\nstream\n", .{cmap.len});
	try buf.appendSlice(allocator, cmap);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	// /Encoding as an INDIRECT object (like real SCOTUS fonts: /Encoding 1656 0 R).
	offs[7] = buf.items.len;
	try buf.appendSlice(allocator, "7 0 obj\n<< /Type /Encoding /Differences [174 /fi 175 /fl] >>\nendobj\n");
	const xref_off = buf.items.len;
	try buf.appendSlice(allocator, "xref\n0 8\n0000000000 65535 f\n");
	var i: usize = 1;
	while (i <= 7) : (i += 1) try buf.print(allocator, "{d:0>10} 00000 n\n", .{offs[i]});
	try buf.appendSlice(allocator, "trailer\n<< /Size 8 /Root 1 0 R >>\n");
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_off});
	return try buf.toOwnedSlice(allocator);
}

test "pdf: ligature glyphs recovered from /Differences when ToUnicode is broken" {
	// incitez_web 2026-06-15: SCOTUS Century fonts map the fi/fl ligature glyphs to
	// just "f" in ToUnicode ("defines"→"defnes"). The /Differences glyph name is the
	// reliable source; it must override the broken ToUnicode → component letters.
	const pdf = try buildPdfBrokenLigatureToUnicode(testing.allocator);
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/ligature.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "defines") != null);
	try testing.expect(std.mem.indexOf(u8, c, "flag") != null);
	try testing.expect(std.mem.indexOf(u8, c, "defnes") == null);
}

/// Build a 1-page PDF with a BUILTIN Type1 font (NO /Encoding, hence no
/// /Differences) whose ToUnicode CMap is BROKEN — codes 174/175 (the Adobe
/// StandardEncoding fi/fl ligature POSITIONS) both map to "f". This is the
/// SCOTUS small-caps Century case where pass-1 (glyph-name recovery) cannot
/// fire — only pass-2 (StandardEncoding position recovery) can. "de<AE>nes
/// <AF>ag" must still extract as "defines flag", not "defnes fag".
fn buildPdfBuiltinLigatureToUnicode(allocator: Allocator) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var offs: [7]usize = undefined;
	try buf.appendSlice(allocator, "%PDF-1.4\n");
	offs[1] = buf.items.len;
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
	offs[2] = buf.items.len;
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
	offs[3] = buf.items.len;
	try buf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");
	// Content stream: "de" + 0xAE(fi) + "nes " + 0xAF(fl) + "ag"  → "defines flag".
	const stream = "BT\n/F1 12 Tf\n100 700 Td\n(de\xAEnes \xAFag) Tj\nET\n";
	offs[4] = buf.items.len;
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(allocator, stream);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	// Builtin font: NO /Encoding at all (relies on the font's builtin StandardEncoding).
	offs[5] = buf.items.len;
	try buf.appendSlice(allocator, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /CenturyExpanded /ToUnicode 6 0 R >>\nendobj\n");
	// Broken ToUnicode: both ligature codes map to plain "f" (U+0066).
	const cmap =
		"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapType 2 def\n" ++
		"1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" ++
		"2 beginbfchar\n<AE> <0066>\n<AF> <0066>\nendbfchar\nendcmap\nend\nend\n";
	offs[6] = buf.items.len;
	try buf.print(allocator, "6 0 obj\n<< /Length {d} >>\nstream\n", .{cmap.len});
	try buf.appendSlice(allocator, cmap);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	const xref_off = buf.items.len;
	try buf.appendSlice(allocator, "xref\n0 7\n0000000000 65535 f\n");
	var i: usize = 1;
	while (i <= 6) : (i += 1) try buf.print(allocator, "{d:0>10} 00000 n\n", .{offs[i]});
	try buf.appendSlice(allocator, "trailer\n<< /Size 7 /Root 1 0 R >>\n");
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_off});
	return try buf.toOwnedSlice(allocator);
}

test "pdf: ligature glyphs recovered from StandardEncoding positions (Builtin font, no /Differences)" {
	// incitez_web 2026-06-15: real SCOTUS body fonts are BUILTIN (no /Differences),
	// so pass-1 glyph-name recovery cannot fire. Codes 174/175 are the Adobe
	// StandardEncoding fi/fl positions and the broken ToUnicode leaves a lone "f"
	// there — pass-2 (position recovery) must restore the components. Without
	// /Differences only pass-2 can change cmap[174] "f"→"fi", so "defines"
	// appearing proves pass-2 fired. Validated on legal-scotus-303-creative-2023.pdf.
	const pdf = try buildPdfBuiltinLigatureToUnicode(testing.allocator);
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/ligature-builtin.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "defines") != null);
	try testing.expect(std.mem.indexOf(u8, c, "flag") != null);
	try testing.expect(std.mem.indexOf(u8, c, "defnes") == null);
}

test "reorderRunsByReading: single-column runs sort top-to-bottom by y" {
	// Content stream emits these out of vertical order; reading order is by y desc.
	const spans = [_]TextSpan{
		.{ .text = "third", .font_size = 12, .page = 1, .y_position = 600, .x_position = 100 },
		.{ .text = "first", .font_size = 12, .page = 1, .y_position = 700, .x_position = 100 },
		.{ .text = "second", .font_size = 12, .page = 1, .y_position = 650, .x_position = 100 },
	};
	const out = try reorderRunsByReading(testing.allocator, &spans);
	defer testing.allocator.free(out);
	try testing.expectEqualStrings("first", out[0].text);
	try testing.expectEqualStrings("second", out[1].text);
	try testing.expectEqualStrings("third", out[2].text);
}

test "reorderRunsByReading: two-column page reads whole left column then right" {
	// 3 lines × 2 columns, content order row-major (the scramble). Left x=50 (clean
	// gap to right x=300). Reading order must be L1 L2 L3 then R1 R2 R3.
	const spans = [_]TextSpan{
		.{ .text = "L1", .font_size = 12, .page = 1, .y_position = 700, .x_position = 50 },
		.{ .text = "R1", .font_size = 12, .page = 1, .y_position = 700, .x_position = 300 },
		.{ .text = "L2", .font_size = 12, .page = 1, .y_position = 680, .x_position = 50 },
		.{ .text = "R2", .font_size = 12, .page = 1, .y_position = 680, .x_position = 300 },
		.{ .text = "L3", .font_size = 12, .page = 1, .y_position = 660, .x_position = 50 },
		.{ .text = "R3", .font_size = 12, .page = 1, .y_position = 660, .x_position = 300 },
	};
	const out = try reorderRunsByReading(testing.allocator, &spans);
	defer testing.allocator.free(out);
	const got = [_][]const u8{ out[0].text, out[1].text, out[2].text, out[3].text, out[4].text, out[5].text };
	const want = [_][]const u8{ "L1", "L2", "L3", "R1", "R2", "R3" };
	for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "reorderRunsByReading: full-width header above a two-column band stays in place" {
	// A full-width header line (crosses the gutter) atop a 2-column body band.
	// Reading order: header, then all left, then all right.
	var spans = std.ArrayList(TextSpan).empty;
	defer spans.deinit(testing.allocator);
	// header spans full width (x 50 → ~310 via long text), crosses the gutter
	try spans.append(testing.allocator, .{ .text = "HEADER SPANNING THE FULL PAGE WIDTH", .font_size = 12, .page = 1, .y_position = 720, .x_position = 50 });
	// 6 body lines per column so the gutter survives the header's coverage
	var i: usize = 0;
	while (i < 6) : (i += 1) {
		const y: f32 = 700 - @as(f32, @floatFromInt(i)) * 20;
		// row-major (scrambled) emission
		try spans.append(testing.allocator, .{ .text = "Lx", .font_size = 12, .page = 1, .y_position = y, .x_position = 50 });
		try spans.append(testing.allocator, .{ .text = "Rx", .font_size = 12, .page = 1, .y_position = y, .x_position = 300 });
	}
	const out = try reorderRunsByReading(testing.allocator, spans.items);
	defer testing.allocator.free(out);
	try testing.expect(std.mem.startsWith(u8, out[0].text, "HEADER"));
	// next 6 are all left, then 6 right
	for (out[1..7]) |s| try testing.expectEqualStrings("Lx", s.text);
	for (out[7..13]) |s| try testing.expectEqualStrings("Rx", s.text);
}

/// Build a 1-page PDF with two wrapped body lines: line 1 ends "...scrutiny, Ada-"
/// and line 2 starts "rand Constructors…" — a proper-noun case name hyphenated across
/// a line break. de-hyphenation must yield "Adarand", and the real compound "well-known"
/// (also wrapped) must KEEP its hyphen.
fn buildPdfWrapHyphen(allocator: Allocator) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var offs: [6]usize = undefined;
	try buf.appendSlice(allocator, "%PDF-1.4\n");
	offs[1] = buf.items.len;
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
	offs[2] = buf.items.len;
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
	offs[3] = buf.items.len;
	try buf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");
	// Four wrapped lines (each advance -15, within the wrap threshold): a proper-noun
	// split (Ada-/rand), a real compound (well-/known), and a dictionary split (over-/come).
	const stream =
		"BT\n/F1 12 Tf\n100 700 Td\n(known as strict scrutiny, Ada-) Tj\n" ++
		"0 -15 Td\n(rand Constructors, Inc. is a well-) Tj\n" ++
		"0 -15 Td\n(known firm that will over-) Tj\n" ++
		"0 -15 Td\n(come all challenges here.) Tj\nET\n";
	offs[4] = buf.items.len;
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(allocator, stream);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	offs[5] = buf.items.len;
	try buf.appendSlice(allocator, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");
	const xref_off = buf.items.len;
	try buf.appendSlice(allocator, "xref\n0 6\n0000000000 65535 f\n");
	var i: usize = 1;
	while (i <= 5) : (i += 1) try buf.print(allocator, "{d:0>10} 00000 n\n", .{offs[i]});
	try buf.appendSlice(allocator, "trailer\n<< /Size 6 /Root 1 0 R >>\n");
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_off});
	return try buf.toOwnedSlice(allocator);
}

test "pdf: line-break hyphen rejoined for proper nouns, kept for real compounds" {
	// incitez_web 2026-06-15: case names hyphenated across a line break ("Ada-\nrand")
	// were left as "Ada-rand" because dictionary de-hyphenation only fires when the
	// joined form is a dict word. At a wrap boundary we KNOW it's a line-break hyphen:
	// drop it for soft splits (joined is a word, or the left fragment is not a word →
	// proper noun), keep it for real compounds (left is a word, join is not).
	const pdf = try buildPdfWrapHyphen(testing.allocator);
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/wraphyphen.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "Adarand") != null); // proper-noun split rejoined
	try testing.expect(std.mem.indexOf(u8, c, "Ada-rand") == null);
	try testing.expect(std.mem.indexOf(u8, c, "overcome") != null); // dict split rejoined
	try testing.expect(std.mem.indexOf(u8, c, "well-known") != null); // real compound kept
	try testing.expect(std.mem.indexOf(u8, c, "wellknown") == null);
}

test "wrapHyphenDecision classifies line-break hyphens over a set" {
	const Case = struct { buf: []const u8, next: []const u8, want: WrapHyphen };
	const cases = [_]Case{
		// DROP — soft splits
		.{ .buf = "scrutiny, Ada-", .next = "rand Constructors", .want = .drop }, // proper noun, Cap+lower
		.{ .buf = "Group of Bos-", .next = "ton, Inc.", .want = .drop }, // non-word left
		.{ .buf = "v. BethEn-", .next = "ergy Mines", .want = .drop }, // non-word left
		.{ .buf = "will over-", .next = "come all", .want = .drop }, // joined IS a dict word
		.{ .buf = "send an e-", .next = "mail today", .want = .drop }, // single-letter left, not a word
		// KEEP — real compounds
		.{ .buf = "a well-", .next = "known firm", .want = .keep }, // lowercase compound
		.{ .buf = "is self-", .next = "evident now", .want = .keep }, // lowercase compound
		.{ .buf = "filed by Vornak-", .next = "Tessik LLP today", .want = .keep }, // Cap+Cap distinct names → keep hyphen
		// NOT_APPLICABLE — fall back to normal spacing
		.{ .buf = "no hyphen here", .next = "next word", .want = .not_applicable }, // no trailing hyphen
		.{ .buf = "page 5-", .next = "9 of brief", .want = .not_applicable }, // right not alphabetic
	};
	for (cases) |tc| try testing.expectEqual(tc.want, wrapHyphenDecision(tc.buf, tc.next));
}

/// Build a 1-page PDF with two Table-of-Authorities lines whose dot leaders connect
/// each case name to its page number. The leaders must become lone newlines so a
/// citation walk-back stops there (incitez 2026-06-15), not weld entry N's pages onto
/// entry N+1's name.
fn buildPdfDotLeaderToA(allocator: Allocator) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var offs: [6]usize = undefined;
	try buf.appendSlice(allocator, "%PDF-1.4\n");
	offs[1] = buf.items.len;
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
	offs[2] = buf.items.len;
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
	offs[3] = buf.items.len;
	try buf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");
	const stream =
		"BT\n/F1 12 Tf\n100 700 Td\n(Winn Lovett Grocery Co. v. Archer .......... 32) Tj\n" ++
		"0 -15 Td\n(Pierce v. Society of Sisters ............ 47) Tj\nET\n";
	offs[4] = buf.items.len;
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(allocator, stream);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	offs[5] = buf.items.len;
	try buf.appendSlice(allocator, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");
	const xref_off = buf.items.len;
	try buf.appendSlice(allocator, "xref\n0 6\n0000000000 65535 f\n");
	var i: usize = 1;
	while (i <= 5) : (i += 1) try buf.print(allocator, "{d:0>10} 00000 n\n", .{offs[i]});
	try buf.appendSlice(allocator, "trailer\n<< /Size 6 /Root 1 0 R >>\n");
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_off});
	return try buf.toOwnedSlice(allocator);
}

test "pdf: ToA dot-leaders become newline boundaries, not welds" {
	const pdf = try buildPdfDotLeaderToA(testing.allocator);
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/toa.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "Archer\n32") != null); // leader → newline boundary
	try testing.expect(std.mem.indexOf(u8, c, "Sisters\n47") != null);
	try testing.expect(std.mem.indexOf(u8, c, ".....") == null); // no 5+ dot leader survives
}

test "dotLeaderToNewline replaces 5+ dot leaders, preserves ellipses and reporter spacing" {
	const Case = struct { in: []const u8, want: []const u8 };
	const cases = [_]Case{
		.{ .in = "Warley .......... 19", .want = "Warley\n19" }, // leader → newline, no trailing space
		.{ .in = "Sisters . . . . . 47", .want = "Sisters\n47" }, // spaced dots, 5 → leader
		.{ .in = "see id. . . . here", .want = "see id. . . . here" }, // 4 dots (incl id.) — under 5, kept
		.{ .in = "ellipsis.... done", .want = "ellipsis.... done" }, // Bluebook 4-dot kept
		.{ .in = "trailing off...", .want = "trailing off..." }, // 3-dot ellipsis kept
		.{ .in = "530 U. S. 238 (2000)", .want = "530 U. S. 238 (2000)" }, // reporter spacing untouched
		.{ .in = "no dots here", .want = "no dots here" },
	};
	for (cases) |tc| {
		const got = try dotLeaderToNewline(testing.allocator, tc.in);
		defer testing.allocator.free(got);
		try testing.expectEqualStrings(tc.want, got);
	}
}

/// Two abutting runs "Gas" + "Co." at a camelCase boundary (the dropped-space site)
/// on one line, plus a single-token "BethEnergy" run. The run-joiner must insert a
/// space where the concatenation is a non-word ("GasCo") but leave a genuine
/// single-token camelCase name ("BethEnergy") alone.
fn buildPdfCamelRunBoundary(allocator: Allocator) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var offs: [6]usize = undefined;
	try buf.appendSlice(allocator, "%PDF-1.4\n");
	offs[1] = buf.items.len;
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
	offs[2] = buf.items.len;
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
	offs[3] = buf.items.len;
	try buf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");
	// "Gas" then "Co." as separate runs butting together (14pt advance ≈ width of "Gas"),
	// then a single-run "BethEnergy" on the next line.
	const stream =
		"BT\n/F1 12 Tf\n100 700 Td\n(Natural Carbonic Gas) Tj\n14 0 Td\n(Co., 220 U. S. 61) Tj\n" ++
		"0 -15 Td\n(Pauley v. BethEnergy Mines) Tj\nET\n";
	offs[4] = buf.items.len;
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(allocator, stream);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	offs[5] = buf.items.len;
	try buf.appendSlice(allocator, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");
	const xref_off = buf.items.len;
	try buf.appendSlice(allocator, "xref\n0 6\n0000000000 65535 f\n");
	var i: usize = 1;
	while (i <= 5) : (i += 1) try buf.print(allocator, "{d:0>10} 00000 n\n", .{offs[i]});
	try buf.appendSlice(allocator, "trailer\n<< /Size 6 /Root 1 0 R >>\n");
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_off});
	return try buf.toOwnedSlice(allocator);
}

test "pdf: dropped space at a camelCase run boundary is restored, single-token name kept" {
	// incitez_web 2026-06-15: "GasCo."→"Gas Co." (a dropped run-boundary space) is fixed
	// because isWord("GasCo") is now false → the run-joiner inserts a space. A genuine
	// single-token camelCase name ("BethEnergy") has no run boundary and must NOT split.
	const pdf = try buildPdfCamelRunBoundary(testing.allocator);
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/camel.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "Gas Co.") != null); // dropped space restored
	try testing.expect(std.mem.indexOf(u8, c, "GasCo") == null);
	try testing.expect(std.mem.indexOf(u8, c, "BethEnergy") != null); // single token kept
	try testing.expect(std.mem.indexOf(u8, c, "Beth Energy") == null);
}

test "splitToAHeaders puts ToA section headers on their own line" {
	const Case = struct { in: []const u8, want: []const u8 };
	const cases = [_]Case{
		.{ .in = "Cases Albritton v. Gandy, 531", .want = "Cases\nAlbritton v. Gandy, 531" },
		.{ .in = "Statutes 10 U. C. 9 1059", .want = "Statutes\n10 U. C. 9 1059" }, // entry starts with a digit
		.{ .in = "Other Authorities Restatement (Second)", .want = "Other Authorities\nRestatement (Second)" }, // multi-word header
		.{ .in = "Cases: Brown v. Board", .want = "Cases:\nBrown v. Board" }, // header with colon
		.{ .in = "Cases involving negligence here", .want = "Cases involving negligence here" }, // lowercase rest → body prose, not split
		.{ .in = "These cases show", .want = "These cases show" }, // not at a header at line start
		.{ .in = "line one\nCases Smith v. Jones", .want = "line one\nCases\nSmith v. Jones" }, // header after a newline
	};
	for (cases) |tc| {
		const got = try splitToAHeaders(testing.allocator, tc.in);
		defer testing.allocator.free(got);
		try testing.expectEqualStrings(tc.want, got);
	}
}

/// Build a 1-page PDF whose Table of Authorities has the section header "Cases" on its own
/// visual line, then the first entry below it. The header must end up on its own line.
fn buildPdfToAHeader(allocator: Allocator) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);
	var offs: [6]usize = undefined;
	try buf.appendSlice(allocator, "%PDF-1.4\n");
	offs[1] = buf.items.len;
	try buf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
	offs[2] = buf.items.len;
	try buf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
	offs[3] = buf.items.len;
	try buf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");
	const stream =
		"BT\n/F1 12 Tf\n100 700 Td\n(Cases) Tj\n" ++
		"0 -15 Td\n(Albritton v. Gandy, 531 So. 2d 381) Tj\nET\n";
	offs[4] = buf.items.len;
	try buf.print(allocator, "4 0 obj\n<< /Length {d} >>\nstream\n", .{stream.len});
	try buf.appendSlice(allocator, stream);
	try buf.appendSlice(allocator, "\nendstream\nendobj\n");
	offs[5] = buf.items.len;
	try buf.appendSlice(allocator, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");
	const xref_off = buf.items.len;
	try buf.appendSlice(allocator, "xref\n0 6\n0000000000 65535 f\n");
	var i: usize = 1;
	while (i <= 5) : (i += 1) try buf.print(allocator, "{d:0>10} 00000 n\n", .{offs[i]});
	try buf.appendSlice(allocator, "trailer\n<< /Size 6 /Root 1 0 R >>\n");
	try buf.print(allocator, "startxref\n{d}\n%%EOF", .{xref_off});
	return try buf.toOwnedSlice(allocator);
}

test "pdf: ToA section header is not welded onto the first entry" {
	const pdf = try buildPdfToAHeader(testing.allocator);
	defer testing.allocator.free(pdf);
	const doc = try parse(testing.allocator, pdf, "/test/toahdr.pdf");
	defer freeDocument(testing.allocator, doc);
	var all = std.ArrayList(u8).empty;
	defer all.deinit(testing.allocator);
	for (doc.sections) |s| try all.appendSlice(testing.allocator, s.content);
	const c = all.items;
	try testing.expect(std.mem.indexOf(u8, c, "Cases\nAlbritton") != null); // header on its own line
	try testing.expect(std.mem.indexOf(u8, c, "Cases Albritton") == null); // not welded
}

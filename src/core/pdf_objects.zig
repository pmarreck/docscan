//! Low-level PDF file format infrastructure for docscan.
//! Handles xref table parsing, object lookup, stream decompression,
//! and PDF value parsing (dicts, arrays, strings, names, references, numbers).
//! Pure computation — no I/O. Operates on in-memory byte slices.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Public Types ────────────────────────────────────────────────────

pub const XrefEntry = struct {
	offset: u64,
	gen: u16,
	in_use: bool,
};

pub const DictEntry = struct {
	key: []const u8,
	value: PdfValue,
};

pub const ObjRef = struct {
	obj: u32,
	gen: u16,
};

pub const PdfValue = union(enum) {
	integer: i64,
	real: f64,
	boolean: bool,
	name: []const u8,
	string: []const u8,
	array: []const PdfValue,
	dict: []const DictEntry,
	reference: ObjRef,
	null_val: void,
};

pub const PdfError = error{
	InvalidPdf,
	UnsupportedFeature,
	DecompressionFailed,
	MalformedObject,
	MalformedValue,
	OutOfMemory,
};

// ── PdfContext ──────────────────────────────────────────────────────

/// Top-level context for accessing objects within a PDF file held in memory.
/// Parses the xref table on init and provides object/stream lookup.
pub const PdfContext = struct {
	data: []const u8,
	xref: std.AutoHashMap(u32, XrefEntry),
	trailer_dict: ?[]const DictEntry,
	allocator: Allocator,

	/// Parse a PDF byte buffer: locate startxref, parse xref table, store trailer.
	pub fn init(allocator: Allocator, data: []const u8) PdfError!PdfContext {
		var ctx = PdfContext{
			.data = data,
			.xref = std.AutoHashMap(u32, XrefEntry).init(allocator),
			.trailer_dict = null,
			.allocator = allocator,
		};
		errdefer ctx.xref.deinit();

		const xref_offset = findStartxref(data) orelse return PdfError.InvalidPdf;
		try parseXrefSection(&ctx, xref_offset);
		return ctx;
	}

	pub fn deinit(self: *PdfContext) void {
		if (self.trailer_dict) |dict| {
			for (dict) |entry| {
				freePdfValue(self.allocator, entry.value);
				self.allocator.free(entry.key);
			}
			self.allocator.free(dict);
		}
		self.xref.deinit();
	}

	/// Look up and parse an indirect object by object number.
	/// Caller must free the returned value with `freePdfValue`.
	pub fn getObject(self: *PdfContext, obj_num: u32) PdfError!?PdfValue {
		const entry = self.xref.get(obj_num) orelse return null;
		if (!entry.in_use) return null;

		const offset: usize = @intCast(entry.offset);
		if (offset >= self.data.len) return PdfError.InvalidPdf;

		// Skip "N G obj" header
		const obj_body_start = findObjBody(self.data, offset) orelse return PdfError.MalformedObject;
		var pos = obj_body_start;
		const val = parsePdfValue(self.allocator, self.data, &pos) catch return PdfError.MalformedObject;
		return val;
	}

	/// Get decompressed stream data for an object (must be a stream object).
	/// Caller owns the returned slice.
	pub fn getStream(self: *PdfContext, obj_num: u32) PdfError!?[]const u8 {
		const entry = self.xref.get(obj_num) orelse return null;
		if (!entry.in_use) return null;

		const offset: usize = @intCast(entry.offset);
		if (offset >= self.data.len) return PdfError.InvalidPdf;

		const obj_body_start = findObjBody(self.data, offset) orelse return PdfError.MalformedObject;
		var pos = obj_body_start;

		// Parse the stream dictionary
		const dict_val = parsePdfValue(self.allocator, self.data, &pos) catch return PdfError.MalformedObject;
		defer freePdfValue(self.allocator, dict_val);

		if (dict_val != .dict) return PdfError.MalformedObject;

		// Find "stream" keyword after the dict
		pos = skipWhitespace(self.data, pos);
		const stream_start = findStreamStart(self.data, pos) orelse return PdfError.MalformedObject;

		// Determine length
		const length = getDictInt(dict_val.dict, "Length") orelse {
			// Try to find endstream
			const end_pos = std.mem.indexOf(u8, self.data[stream_start..], "endstream") orelse
				return PdfError.MalformedObject;
			return try decompressStream(self.allocator, self.data[stream_start .. stream_start + end_pos], dict_val.dict);
		};

		const len: usize = @intCast(length);
		if (stream_start + len > self.data.len) return PdfError.InvalidPdf;
		const stream_data = self.data[stream_start .. stream_start + len];

		return try decompressStream(self.allocator, stream_data, dict_val.dict);
	}

	/// Follow a reference to get the target object's value.
	/// Caller must free the returned value with `freePdfValue`.
	pub fn resolveRef(self: *PdfContext, val: PdfValue) PdfError!?PdfValue {
		if (val != .reference) return val;
		return self.getObject(val.reference.obj);
	}
};

// ── Startxref / Xref Parsing ───────────────────────────────────────

/// Scan the last 1KB of the file for "startxref" and return the xref offset.
pub fn findStartxref(data: []const u8) ?u64 {
	const search_len: usize = @min(data.len, 1024);
	const search_region = data[data.len - search_len ..];

	// Find last occurrence of "startxref"
	var last_pos: ?usize = null;
	var i: usize = 0;
	while (i + 9 <= search_region.len) : (i += 1) {
		if (std.mem.eql(u8, search_region[i .. i + 9], "startxref")) {
			last_pos = i;
		}
	}

	const pos = last_pos orelse return null;

	// Skip "startxref" and whitespace, then parse the offset number
	var p = pos + 9;
	while (p < search_region.len and (search_region[p] == ' ' or search_region[p] == '\n' or search_region[p] == '\r' or search_region[p] == '\t')) {
		p += 1;
	}

	// Parse decimal number
	var offset: u64 = 0;
	var found_digit = false;
	while (p < search_region.len and search_region[p] >= '0' and search_region[p] <= '9') {
		offset = offset * 10 + (search_region[p] - '0');
		found_digit = true;
		p += 1;
	}

	if (!found_digit) return null;
	return offset;
}

/// Parse a traditional xref section at the given offset in the PDF data.
fn parseXrefSection(ctx: *PdfContext, offset: u64) PdfError!void {
	const off: usize = @intCast(offset);
	if (off + 4 > ctx.data.len) return PdfError.InvalidPdf;

	// Check for "xref" keyword
	if (!std.mem.eql(u8, ctx.data[off .. off + 4], "xref")) return PdfError.InvalidPdf;

	var pos: usize = off + 4;
	pos = skipWhitespace(ctx.data, pos);

	// Parse subsections: "first_obj count\n" followed by count entries
	while (pos < ctx.data.len) {
		// Check if we hit "trailer"
		if (pos + 7 <= ctx.data.len and std.mem.eql(u8, ctx.data[pos .. pos + 7], "trailer")) {
			pos += 7;
			pos = skipWhitespace(ctx.data, pos);
			// Parse trailer dictionary
			const dict_val = parsePdfValue(ctx.allocator, ctx.data, &pos) catch return PdfError.MalformedObject;
			if (dict_val == .dict) {
				ctx.trailer_dict = dict_val.dict;
			} else {
				freePdfValue(ctx.allocator, dict_val);
			}
			return;
		}

		// Parse "first_obj count"
		const first_obj = parseUint(ctx.data, &pos) orelse return PdfError.InvalidPdf;
		pos = skipWhitespace(ctx.data, pos);
		const count = parseUint(ctx.data, &pos) orelse return PdfError.InvalidPdf;
		pos = skipWhitespace(ctx.data, pos);

		// Parse entries. Standard format is 20 bytes:
		// "OOOOOOOOOO GGGGG f \r\n" but many generators produce
		// "OOOOOOOOOO GGGGG f\n" (19 bytes) or other minor variants.
		// We parse flexibly: offset(digits) SP gen(digits) SP flag EOL
		var i: u32 = 0;
		while (i < count) : (i += 1) {
			// Skip any leading whitespace between entries
			// (some generators put extra newlines)
			while (pos < ctx.data.len and (ctx.data[pos] == '\n' or ctx.data[pos] == '\r')) {
				pos += 1;
			}

			if (pos + 16 > ctx.data.len) return PdfError.InvalidPdf;

			// Parse offset (up to 10 digits, but flexibly)
			var entry_offset: u64 = 0;
			var digit_count: usize = 0;
			while (pos + digit_count < ctx.data.len and ctx.data[pos + digit_count] >= '0' and ctx.data[pos + digit_count] <= '9') {
				entry_offset = entry_offset * 10 + (ctx.data[pos + digit_count] - '0');
				digit_count += 1;
			}
			if (digit_count == 0) return PdfError.InvalidPdf;
			pos += digit_count;

			// Skip space(s)
			while (pos < ctx.data.len and ctx.data[pos] == ' ') pos += 1;

			// Parse generation number
			var gen: u64 = 0;
			digit_count = 0;
			while (pos + digit_count < ctx.data.len and ctx.data[pos + digit_count] >= '0' and ctx.data[pos + digit_count] <= '9') {
				gen = gen * 10 + (ctx.data[pos + digit_count] - '0');
				digit_count += 1;
			}
			if (digit_count == 0) return PdfError.InvalidPdf;
			pos += digit_count;

			// Skip space(s)
			while (pos < ctx.data.len and ctx.data[pos] == ' ') pos += 1;

			// Parse in-use flag (f or n)
			if (pos >= ctx.data.len) return PdfError.InvalidPdf;
			const flag = ctx.data[pos];
			pos += 1;
			const in_use = flag == 'n';

			// Skip trailing whitespace/line ending
			while (pos < ctx.data.len and (ctx.data[pos] == ' ' or ctx.data[pos] == '\r' or ctx.data[pos] == '\n')) {
				pos += 1;
			}

			const obj_num: u32 = first_obj + i;
			ctx.xref.put(obj_num, XrefEntry{
				.offset = entry_offset,
				.gen = @intCast(gen),
				.in_use = in_use,
			}) catch return PdfError.OutOfMemory;
		}
	}
}

// ── Object Parsing ─────────────────────────────────────────────────

/// Find the start of an object's body after "N G obj".
fn findObjBody(data: []const u8, offset: usize) ?usize {
	var pos = offset;

	// Skip the object number
	while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') pos += 1;
	pos = skipWhitespace(data, pos);

	// Skip the generation number
	while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') pos += 1;
	pos = skipWhitespace(data, pos);

	// Expect "obj"
	if (pos + 3 > data.len) return null;
	if (!std.mem.eql(u8, data[pos .. pos + 3], "obj")) return null;
	pos += 3;
	pos = skipWhitespace(data, pos);

	return pos;
}

/// Find the byte offset where stream data begins (after "stream\r\n" or "stream\n").
fn findStreamStart(data: []const u8, pos: usize) ?usize {
	if (pos + 6 > data.len) return null;
	if (!std.mem.eql(u8, data[pos .. pos + 6], "stream")) return null;
	var p = pos + 6;
	if (p < data.len and data[p] == '\r') p += 1;
	if (p < data.len and data[p] == '\n') p += 1;
	return p;
}

// ── PDF Value Parsing ──────────────────────────────────────────────

/// Parse a single PDF value at the given position. Advances pos past the value.
/// All returned slices reference the original data buffer (zero-copy for names/strings
/// where possible, but escaped strings are allocated).
pub fn parsePdfValue(allocator: Allocator, data: []const u8, pos: *usize) PdfError!PdfValue {
	const p = skipWhitespace(data, pos.*);
	pos.* = p;
	if (p >= data.len) return PdfError.MalformedValue;

	const ch = data[p];

	// Boolean
	if (p + 4 <= data.len and std.mem.eql(u8, data[p .. p + 4], "true")) {
		pos.* = p + 4;
		return PdfValue{ .boolean = true };
	}
	if (p + 5 <= data.len and std.mem.eql(u8, data[p .. p + 5], "false")) {
		pos.* = p + 5;
		return PdfValue{ .boolean = false };
	}

	// Null
	if (p + 4 <= data.len and std.mem.eql(u8, data[p .. p + 4], "null")) {
		pos.* = p + 4;
		return PdfValue{ .null_val = {} };
	}

	// Name: /Something
	if (ch == '/') {
		return parseName(data, pos);
	}

	// String literal: (text)
	if (ch == '(') {
		return parseStringLiteral(allocator, data, pos);
	}

	// Hex string: <hex>
	if (ch == '<') {
		if (p + 1 < data.len and data[p + 1] == '<') {
			return parseDict(allocator, data, pos);
		}
		return parseHexString(allocator, data, pos);
	}

	// Array: [...]
	if (ch == '[') {
		return parseArray(allocator, data, pos);
	}

	// Number or reference (N G R)
	if (ch == '-' or ch == '+' or ch == '.' or (ch >= '0' and ch <= '9')) {
		return parseNumberOrRef(allocator, data, pos);
	}

	return PdfError.MalformedValue;
}

/// Parse a PDF name token: /Name
fn parseName(data: []const u8, pos: *usize) PdfValue {
	var p = pos.* + 1; // skip '/'
	const start = p;
	while (p < data.len) {
		const c = data[p];
		if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
			c == '/' or c == '<' or c == '>' or c == '[' or c == ']' or
			c == '(' or c == ')' or c == '{' or c == '}' or c == '%')
		{
			break;
		}
		p += 1;
	}
	pos.* = p;
	return PdfValue{ .name = data[start..p] };
}

/// Parse a PDF literal string: (text with \escapes and (balanced parens))
fn parseStringLiteral(allocator: Allocator, data: []const u8, pos: *usize) PdfError!PdfValue {
	var p = pos.* + 1; // skip '('
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);
	var depth: u32 = 1;

	while (p < data.len and depth > 0) {
		const c = data[p];
		if (c == '\\' and p + 1 < data.len) {
			p += 1;
			const esc = data[p];
			switch (esc) {
				'n' => {
					buf.append(allocator, '\n') catch return PdfError.OutOfMemory;
					p += 1;
				},
				'r' => {
					buf.append(allocator, '\r') catch return PdfError.OutOfMemory;
					p += 1;
				},
				't' => {
					buf.append(allocator, '\t') catch return PdfError.OutOfMemory;
					p += 1;
				},
				'b' => {
					buf.append(allocator, 0x08) catch return PdfError.OutOfMemory;
					p += 1;
				},
				'f' => {
					buf.append(allocator, 0x0C) catch return PdfError.OutOfMemory;
					p += 1;
				},
				'\\' => {
					buf.append(allocator, '\\') catch return PdfError.OutOfMemory;
					p += 1;
				},
				'(' => {
					buf.append(allocator, '(') catch return PdfError.OutOfMemory;
					p += 1;
				},
				')' => {
					buf.append(allocator, ')') catch return PdfError.OutOfMemory;
					p += 1;
				},
				'0'...'7' => {
					// Octal escape: 1-3 digits
					var octal: u8 = esc - '0';
					p += 1;
					if (p < data.len and data[p] >= '0' and data[p] <= '7') {
						octal = octal * 8 + (data[p] - '0');
						p += 1;
						if (p < data.len and data[p] >= '0' and data[p] <= '7') {
							octal = octal * 8 + (data[p] - '0');
							p += 1;
						}
					}
					buf.append(allocator, octal) catch return PdfError.OutOfMemory;
				},
				'\r' => {
					// Backslash + CR (+ optional LF) = line continuation
					p += 1;
					if (p < data.len and data[p] == '\n') p += 1;
				},
				'\n' => {
					// Backslash + LF = line continuation
					p += 1;
				},
				else => {
					// Unknown escape — just include the char
					buf.append(allocator, esc) catch return PdfError.OutOfMemory;
					p += 1;
				},
			}
		} else if (c == '(') {
			depth += 1;
			buf.append(allocator, c) catch return PdfError.OutOfMemory;
			p += 1;
		} else if (c == ')') {
			depth -= 1;
			if (depth > 0) {
				buf.append(allocator, c) catch return PdfError.OutOfMemory;
			}
			p += 1;
		} else {
			buf.append(allocator, c) catch return PdfError.OutOfMemory;
			p += 1;
		}
	}

	pos.* = p;
	const slice = buf.toOwnedSlice(allocator) catch return PdfError.OutOfMemory;
	return PdfValue{ .string = slice };
}

/// Parse a PDF hex string: <48656C6C6F>
fn parseHexString(allocator: Allocator, data: []const u8, pos: *usize) PdfError!PdfValue {
	var p = pos.* + 1; // skip '<'
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);

	var high_nibble: ?u4 = null;
	while (p < data.len and data[p] != '>') {
		const c = data[p];
		p += 1;
		// Skip whitespace within hex strings
		if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

		const nibble: u4 = if (c >= '0' and c <= '9')
			@intCast(c - '0')
		else if (c >= 'a' and c <= 'f')
			@intCast(c - 'a' + 10)
		else if (c >= 'A' and c <= 'F')
			@intCast(c - 'A' + 10)
		else
			return PdfError.MalformedValue;

		if (high_nibble) |h| {
			const byte: u8 = (@as(u8, h) << 4) | @as(u8, nibble);
			buf.append(allocator, byte) catch return PdfError.OutOfMemory;
			high_nibble = null;
		} else {
			high_nibble = nibble;
		}
	}
	// Odd number of nibbles: pad with 0
	if (high_nibble) |h| {
		buf.append(allocator, @as(u8, h) << 4) catch return PdfError.OutOfMemory;
	}

	if (p < data.len and data[p] == '>') p += 1;
	pos.* = p;
	const slice = buf.toOwnedSlice(allocator) catch return PdfError.OutOfMemory;
	return PdfValue{ .string = slice };
}

/// Parse a PDF dictionary: << /Key Value ... >>
fn parseDict(allocator: Allocator, data: []const u8, pos: *usize) PdfError!PdfValue {
	var p = pos.* + 2; // skip '<<'
	var entries = std.ArrayList(DictEntry){};
	errdefer {
		for (entries.items) |entry| {
			allocator.free(entry.key);
			freePdfValue(allocator, entry.value);
		}
		entries.deinit(allocator);
	}

	while (true) {
		p = skipWhitespace(data, p);
		if (p >= data.len) return PdfError.MalformedValue;

		// Check for '>>'
		if (p + 1 < data.len and data[p] == '>' and data[p + 1] == '>') {
			p += 2;
			break;
		}

		// Key must be a name
		if (data[p] != '/') return PdfError.MalformedValue;
		const key_val = parseName(data, &p);
		const key_copy = allocator.dupe(u8, key_val.name) catch return PdfError.OutOfMemory;
		errdefer allocator.free(key_copy);

		// Value
		const value = try parsePdfValue(allocator, data, &p);
		errdefer freePdfValue(allocator, value);

		entries.append(allocator, DictEntry{
			.key = key_copy,
			.value = value,
		}) catch return PdfError.OutOfMemory;
	}

	pos.* = p;
	const slice = entries.toOwnedSlice(allocator) catch return PdfError.OutOfMemory;
	return PdfValue{ .dict = slice };
}

/// Parse a PDF array: [ value value ... ]
fn parseArray(allocator: Allocator, data: []const u8, pos: *usize) PdfError!PdfValue {
	var p = pos.* + 1; // skip '['
	var items = std.ArrayList(PdfValue){};
	errdefer {
		for (items.items) |item| freePdfValue(allocator, item);
		items.deinit(allocator);
	}

	while (true) {
		p = skipWhitespace(data, p);
		if (p >= data.len) return PdfError.MalformedValue;

		if (data[p] == ']') {
			p += 1;
			break;
		}

		const val = try parsePdfValue(allocator, data, &p);
		errdefer freePdfValue(allocator, val);
		items.append(allocator, val) catch return PdfError.OutOfMemory;
	}

	pos.* = p;
	const slice = items.toOwnedSlice(allocator) catch return PdfError.OutOfMemory;
	return PdfValue{ .array = slice };
}

/// Parse a number, which might be part of an indirect reference (N G R).
fn parseNumberOrRef(allocator: Allocator, data: []const u8, pos: *usize) PdfError!PdfValue {
	const start = pos.*;
	var p = start;

	// Determine if it's a number or could be a reference
	var is_negative = false;
	if (p < data.len and (data[p] == '+' or data[p] == '-')) {
		is_negative = data[p] == '-';
		p += 1;
	}

	var int_part: i64 = 0;
	var has_int = false;
	while (p < data.len and data[p] >= '0' and data[p] <= '9') {
		int_part = int_part * 10 + (data[p] - '0');
		has_int = true;
		p += 1;
	}

	// Check for real number (decimal point)
	if (p < data.len and data[p] == '.') {
		p += 1;
		var frac: f64 = 0;
		var frac_divisor: f64 = 10;
		while (p < data.len and data[p] >= '0' and data[p] <= '9') {
			frac += @as(f64, @floatFromInt(data[p] - '0')) / frac_divisor;
			frac_divisor *= 10;
			p += 1;
		}
		var result = @as(f64, @floatFromInt(int_part)) + frac;
		if (is_negative) result = -result;
		pos.* = p;
		return PdfValue{ .real = result };
	}

	if (!has_int) return PdfError.MalformedValue;
	if (is_negative) {
		pos.* = p;
		return PdfValue{ .integer = -int_part };
	}

	// Could be an indirect reference: "N G R"
	// Save position and try to parse generation + 'R'
	const after_first = p;
	const saved_p = p;
	p = skipWhitespace(data, p);

	if (p < data.len and data[p] >= '0' and data[p] <= '9') {
		var gen: u16 = 0;
		var has_gen = false;
		while (p < data.len and data[p] >= '0' and data[p] <= '9') {
			gen = gen * 10 + @as(u16, @intCast(data[p] - '0'));
			has_gen = true;
			p += 1;
		}

		if (has_gen) {
			const after_gen = p;
			_ = after_gen;
			p = skipWhitespace(data, p);
			if (p < data.len and data[p] == 'R') {
				// It's a reference!
				_ = allocator;
				pos.* = p + 1;
				return PdfValue{ .reference = ObjRef{ .obj = @intCast(int_part), .gen = gen } };
			}
		}
	}

	// Not a reference — revert to just the integer
	_ = saved_p;
	pos.* = after_first;
	return PdfValue{ .integer = int_part };
}

// ── Stream Decompression ───────────────────────────────────────────

/// Decompress stream data according to the stream dictionary's /Filter.
/// Supports FlateDecode (zlib). Unfiltered streams are returned as-is (duped).
fn decompressStream(allocator: Allocator, stream_data: []const u8, dict: []const DictEntry) PdfError![]const u8 {
	const filter = getDictName(dict, "Filter");

	if (filter == null) {
		// No filter — return a copy of the raw data
		return allocator.dupe(u8, stream_data) catch return PdfError.OutOfMemory;
	}

	if (std.mem.eql(u8, filter.?, "FlateDecode")) {
		return inflateZlib(allocator, stream_data);
	}

	// Unsupported filter
	return PdfError.UnsupportedFeature;
}

/// Decompress zlib-wrapped deflate data (PDF FlateDecode).
fn inflateZlib(allocator: Allocator, compressed: []const u8) PdfError![]const u8 {
	var reader: std.Io.Reader = .fixed(compressed);
	var aw: std.Io.Writer.Allocating = .init(allocator);
	errdefer aw.deinit();

	var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
	_ = decompress.reader.streamRemaining(&aw.writer) catch return PdfError.DecompressionFailed;

	return aw.toOwnedSlice() catch return PdfError.OutOfMemory;
}

// ── Dictionary Helpers ─────────────────────────────────────────────

/// Look up a name value in a dictionary (returns the name string or null).
pub fn getDictName(dict: []const DictEntry, key: []const u8) ?[]const u8 {
	for (dict) |entry| {
		if (std.mem.eql(u8, entry.key, key)) {
			if (entry.value == .name) return entry.value.name;
			return null;
		}
	}
	return null;
}

/// Look up an integer value in a dictionary.
pub fn getDictInt(dict: []const DictEntry, key: []const u8) ?i64 {
	for (dict) |entry| {
		if (std.mem.eql(u8, entry.key, key)) {
			if (entry.value == .integer) return entry.value.integer;
			return null;
		}
	}
	return null;
}

/// Look up a reference value in a dictionary.
pub fn getDictRef(dict: []const DictEntry, key: []const u8) ?ObjRef {
	for (dict) |entry| {
		if (std.mem.eql(u8, entry.key, key)) {
			if (entry.value == .reference) return entry.value.reference;
			return null;
		}
	}
	return null;
}

/// Look up a dictionary value in a dictionary (nested dict).
pub fn getDictDict(dict: []const DictEntry, key: []const u8) ?[]const DictEntry {
	for (dict) |entry| {
		if (std.mem.eql(u8, entry.key, key)) {
			if (entry.value == .dict) return entry.value.dict;
			return null;
		}
	}
	return null;
}

/// Look up an array value in a dictionary.
pub fn getDictArray(dict: []const DictEntry, key: []const u8) ?[]const PdfValue {
	for (dict) |entry| {
		if (std.mem.eql(u8, entry.key, key)) {
			if (entry.value == .array) return entry.value.array;
			return null;
		}
	}
	return null;
}

// ── Memory Management ──────────────────────────────────────────────

/// Free a PdfValue and all its owned sub-values recursively.
pub fn freePdfValue(allocator: Allocator, value: PdfValue) void {
	switch (value) {
		.string => |s| allocator.free(s),
		.array => |arr| {
			for (arr) |item| freePdfValue(allocator, item);
			allocator.free(arr);
		},
		.dict => |entries| {
			for (entries) |entry| {
				allocator.free(entry.key);
				freePdfValue(allocator, entry.value);
			}
			allocator.free(entries);
		},
		// Names reference original data (zero-copy), integers/reals/booleans/refs/null own nothing
		.name, .integer, .real, .boolean, .reference, .null_val => {},
	}
}

// ── Utility ────────────────────────────────────────────────────────

fn skipWhitespace(data: []const u8, start: usize) usize {
	var p = start;
	while (p < data.len) {
		const c = data[p];
		if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0) {
			p += 1;
		} else if (c == '%') {
			// PDF comment — skip to end of line
			while (p < data.len and data[p] != '\n' and data[p] != '\r') p += 1;
		} else {
			break;
		}
	}
	return p;
}

fn parseUint(data: []const u8, pos: *usize) ?u32 {
	var p = pos.*;
	var result: u32 = 0;
	var found = false;
	while (p < data.len and data[p] >= '0' and data[p] <= '9') {
		result = result * 10 + (data[p] - '0');
		found = true;
		p += 1;
	}
	if (!found) return null;
	pos.* = p;
	return result;
}

fn parseFixedUint(digits: []const u8) ?u64 {
	var result: u64 = 0;
	for (digits) |c| {
		if (c < '0' or c > '9') return null;
		result = result * 10 + (c - '0');
	}
	return result;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "findStartxref — finds offset in minimal PDF trailer" {
	const trailer =
		\\xref
		\\0 1
		\\0000000000 65535 f
		\\trailer
		\\<< /Size 1 >>
		\\startxref
		\\0
		\\%%EOF
	;
	const offset = findStartxref(trailer);
	try testing.expect(offset != null);
	try testing.expectEqual(@as(u64, 0), offset.?);
}

test "findStartxref — finds larger offset" {
	const data = "some content\nstartxref\n12345\n%%EOF";
	const offset = findStartxref(data);
	try testing.expect(offset != null);
	try testing.expectEqual(@as(u64, 12345), offset.?);
}

test "findStartxref — returns null on garbage" {
	const data = "this is not a pdf at all";
	try testing.expectEqual(@as(?u64, null), findStartxref(data));
}

test "parse PDF integer value" {
	const data = "42 rest";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expectEqual(PdfValue{ .integer = 42 }, val);
}

test "parse PDF negative integer" {
	const data = "-7";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expectEqual(PdfValue{ .integer = -7 }, val);
}

test "parse PDF real number" {
	const data = "3.14 rest";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .real);
	try testing.expect(@abs(val.real - 3.14) < 0.001);
}

test "parse PDF name" {
	const data = "/Type rest";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .name);
	try testing.expectEqualStrings("Type", val.name);
}

test "parse PDF boolean true" {
	const data = "true";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expectEqual(PdfValue{ .boolean = true }, val);
}

test "parse PDF boolean false" {
	const data = "false";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expectEqual(PdfValue{ .boolean = false }, val);
}

test "parse PDF null" {
	const data = "null";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .null_val);
}

test "parse PDF string literal — simple" {
	const data = "(Hello World)";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .string);
	try testing.expectEqualStrings("Hello World", val.string);
}

test "parse PDF string literal — escapes" {
	const data = "(Line1\\nLine2\\\\end)";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .string);
	try testing.expectEqualStrings("Line1\nLine2\\end", val.string);
}

test "parse PDF string literal — balanced parens" {
	const data = "(outer (inner) end)";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .string);
	try testing.expectEqualStrings("outer (inner) end", val.string);
}

test "parse PDF string literal — octal escape" {
	// \101 = 'A' (65 decimal)
	const data = "(\\101)";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .string);
	try testing.expectEqualStrings("A", val.string);
}

test "parse PDF hex string" {
	const data = "<48656C6C6F>";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .string);
	try testing.expectEqualStrings("Hello", val.string);
}

test "parse PDF hex string — odd nibbles pad with 0" {
	// <ABC> = 0xAB, 0xC0
	const data = "<ABC>";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .string);
	try testing.expectEqual(@as(u8, 0xAB), val.string[0]);
	try testing.expectEqual(@as(u8, 0xC0), val.string[1]);
}

test "parse PDF array" {
	const data = "[1 2 /Name]";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .array);
	try testing.expectEqual(@as(usize, 3), val.array.len);
	try testing.expectEqual(PdfValue{ .integer = 1 }, val.array[0]);
	try testing.expectEqual(PdfValue{ .integer = 2 }, val.array[1]);
	try testing.expect(val.array[2] == .name);
	try testing.expectEqualStrings("Name", val.array[2].name);
}

test "parse PDF dictionary" {
	const data = "<< /Type /Page /Count 3 >>";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .dict);
	try testing.expectEqual(@as(usize, 2), val.dict.len);

	try testing.expectEqualStrings("Type", val.dict[0].key);
	try testing.expect(val.dict[0].value == .name);
	try testing.expectEqualStrings("Page", val.dict[0].value.name);

	try testing.expectEqualStrings("Count", val.dict[1].key);
	try testing.expectEqual(PdfValue{ .integer = 3 }, val.dict[1].value);
}

test "parse PDF indirect reference" {
	const data = "5 0 R";
	var pos: usize = 0;
	const val = try parsePdfValue(testing.allocator, data, &pos);
	defer freePdfValue(testing.allocator, val);
	try testing.expect(val == .reference);
	try testing.expectEqual(@as(u32, 5), val.reference.obj);
	try testing.expectEqual(@as(u16, 0), val.reference.gen);
}

test "parse xref table — traditional format" {
	const pdf = "xref\n0 3\n0000000000 65535 f \n0000000010 00000 n \n0000000100 00000 n \ntrailer\n<< /Size 3 >>\nstartxref\n0\n%%EOF";

	var ctx = PdfContext{
		.data = pdf,
		.xref = std.AutoHashMap(u32, XrefEntry).init(testing.allocator),
		.trailer_dict = null,
		.allocator = testing.allocator,
	};
	defer ctx.deinit();

	try parseXrefSection(&ctx, 0);

	try testing.expectEqual(@as(u32, 3), ctx.xref.count());

	const e0 = ctx.xref.get(0).?;
	try testing.expectEqual(@as(u64, 0), e0.offset);
	try testing.expect(!e0.in_use);

	const e1 = ctx.xref.get(1).?;
	try testing.expectEqual(@as(u64, 10), e1.offset);
	try testing.expect(e1.in_use);

	const e2 = ctx.xref.get(2).?;
	try testing.expectEqual(@as(u64, 100), e2.offset);
	try testing.expect(e2.in_use);

	// Trailer should be parsed
	try testing.expect(ctx.trailer_dict != null);
}

test "PdfContext.init + getObject — simple object lookup" {
	const pdf = try buildMinimalPdf(testing.allocator, &.{
		.{ .num = 1, .body = "<< /Type /Catalog /Pages 2 0 R >>" },
	}, "<< /Size 2 /Root 1 0 R >>");
	defer testing.allocator.free(pdf);

	var ctx = try PdfContext.init(testing.allocator, pdf);
	defer ctx.deinit();

	const obj = (try ctx.getObject(1)).?;
	defer freePdfValue(testing.allocator, obj);

	try testing.expect(obj == .dict);
	const type_val = getDictName(obj.dict, "Type");
	try testing.expect(type_val != null);
	try testing.expectEqualStrings("Catalog", type_val.?);
}

/// Build a minimal valid PDF with given objects and trailer dict for testing.
/// Each TestObj has an object number and a body string (the part between "N G obj" and "endobj").
const TestObj = struct {
	num: u32,
	body: []const u8,
};

fn buildMinimalPdf(allocator: Allocator, objects: []const TestObj, trailer_dict: []const u8) ![]const u8 {
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);

	try buf.appendSlice(allocator, "%PDF-1.4\n");

	// Track object offsets
	var offsets = std.ArrayList(struct { num: u32, offset: usize }){};
	defer offsets.deinit(allocator);

	for (objects) |obj| {
		try offsets.append(allocator, .{ .num = obj.num, .offset = buf.items.len });
		try std.fmt.format(buf.writer(allocator), "{d} 0 obj\n", .{obj.num});
		try buf.appendSlice(allocator, obj.body);
		try buf.appendSlice(allocator, "\nendobj\n");
	}

	// Find max object number for xref table size
	var max_obj: u32 = 0;
	for (offsets.items) |o| {
		if (o.num > max_obj) max_obj = o.num;
	}

	const xref_offset = buf.items.len;
	try buf.appendSlice(allocator, "xref\n");
	try std.fmt.format(buf.writer(allocator), "0 {d}\n", .{max_obj + 1});

	// Entry 0: free head
	try buf.appendSlice(allocator, "0000000000 65535 f\n");

	// Entries 1..max_obj
	var obj_idx: u32 = 1;
	while (obj_idx <= max_obj) : (obj_idx += 1) {
		var found = false;
		for (offsets.items) |o| {
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

	try buf.appendSlice(allocator, "trailer\n");
	try buf.appendSlice(allocator, trailer_dict);
	try buf.appendSlice(allocator, "\n");
	try std.fmt.format(buf.writer(allocator), "startxref\n{d}\n%%EOF", .{xref_offset});

	return try buf.toOwnedSlice(allocator);
}

test "FlateDecode stream decompression" {
	// "Hello PDF Stream" compressed with zlib (pre-computed)
	const compressed = &[_]u8{
		0x78, 0x9c, 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
		0x08, 0x70, 0x71, 0x53, 0x08, 0x2e, 0x29, 0x4a,
		0x4d, 0xcc, 0x05, 0x00, 0x2d, 0x63, 0x05, 0x7b,
	};
	const expected_text = "Hello PDF Stream";

	// Build the stream object body manually (dict + stream data)
	var body_buf = std.ArrayList(u8){};
	defer body_buf.deinit(testing.allocator);
	try std.fmt.format(body_buf.writer(testing.allocator), "<< /Length {d} /Filter /FlateDecode >>\nstream\n", .{compressed.len});
	try body_buf.appendSlice(testing.allocator, compressed);
	try body_buf.appendSlice(testing.allocator, "\nendstream");

	const pdf = try buildMinimalPdf(testing.allocator, &.{
		.{ .num = 1, .body = body_buf.items },
	}, "<< /Size 2 >>");
	defer testing.allocator.free(pdf);

	var ctx = try PdfContext.init(testing.allocator, pdf);
	defer ctx.deinit();

	const stream = (try ctx.getStream(1)).?;
	defer testing.allocator.free(stream);

	try testing.expectEqualStrings(expected_text, stream);
}

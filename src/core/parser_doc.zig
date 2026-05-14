//! DOC (Word 97-2003) parser for docscan.
//! Extracts text from legacy .doc files using the OLE2 container format.
//! Parses the FIB (File Information Block), determines which Table stream to use,
//! reads the CLX (Complex File Information) to find piece descriptors, and
//! reassembles text from compressed (Windows-1252) or uncompressed (UTF-16LE) pieces.
//! Heading detection uses heuristics since full STSH parsing is extremely complex.
//! Pure computation — no I/O. Receives byte slices, returns a Document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document = @import("document.zig");
const Document = document.Document;
const Section = document.Section;
const MetadataEntry = document.MetadataEntry;
const Format = document.Format;
const wordfix = @import("wordfix.zig");
const ole2 = @import("ole2.zig");
/// Errors specific to DOC parsing.
pub const DocError = error{
	InvalidDoc,
	InvalidFIB,
	NoWordDocumentStream,
	UnsupportedVersion,
};

/// File Information Block (FIB) — key fields extracted from the WordDocument stream.
pub const FIB = struct {
	wIdent: u16, // magic 0xA5EC for Word 97+
	nFib: u16, // FIB version
	flags: u16, // FIB flags (bit 9 = fWhichTblStm)
	/// Which table stream to use: false → "0Table", true → "1Table"
	fWhichTblStm: bool,
	/// Offset of CLX (Complex part) in the Table stream
	fcClx: u32,
	/// Size of CLX in the Table stream
	lcbClx: u32,
	/// Character count of main document text
	ccpText: u32,
};

/// Parse the FIB from the beginning of the WordDocument stream.
/// The FIB is at least 68 bytes for the base, but we need more for the
/// table references in FibRgFcLcb97.
pub fn parseFIB(word_doc: []const u8) !FIB {
	if (word_doc.len < 68) return DocError.InvalidFIB;

	const wIdent = readU16(word_doc, 0);
	if (wIdent != 0xA5EC) return DocError.InvalidFIB;

	const nFib = readU16(word_doc, 2);
	const flags = readU16(word_doc, 10);

	// Bit 9 (0x0200): fWhichTblStm — which table stream
	const fWhichTblStm = (flags & 0x0200) != 0;

	// The CLX offset/size are in FibRgFcLcb97, which varies by version.
	// For Word 97 (nFib=193), the base FIB is 32 bytes, then FibRgW97 (28 bytes at offset 32),
	// then FibRgLw97 (88 bytes at offset 60 in some layouts).
	// The actual FibRgFcLcb97 structure starts at a variable offset.
	//
	// For a simpler approach: we know these offsets for common Word versions.
	// ccpText is at offset 0x004C (76) in most Word 97+ documents.
	// fcClx is typically at offset 0x01A2 (418).
	// lcbClx is typically at offset 0x01A6 (422).
	//
	// However, the exact layout depends on the nFib value and csw/cslw/cbRgFcLcb fields.
	// Let's parse it properly:

	// FibBase: bytes 0..31 (32 bytes)
	// csw: u16 at offset 32 (count of u16s in FibRgW)
	if (word_doc.len < 34) return DocError.InvalidFIB;
	const csw = readU16(word_doc, 32);
	const fibRgW_end: usize = 34 + @as(usize, csw) * 2;

	if (word_doc.len < fibRgW_end + 2) return DocError.InvalidFIB;
	// cslw: u16 at fibRgW_end (count of u32s in FibRgLw)
	const cslw = readU16(word_doc, fibRgW_end);
	const fibRgLw_start: usize = fibRgW_end + 2;
	const fibRgLw_end: usize = fibRgLw_start + @as(usize, cslw) * 4;

	// ccpText is at FibRgLw97 offset 0x000C (index 3 of u32 array)
	var ccpText: u32 = 0;
	if (cslw > 3) {
		ccpText = readU32(word_doc, fibRgLw_start + 0x0C);
	}

	if (word_doc.len < fibRgLw_end + 2) return DocError.InvalidFIB;
	// cbRgFcLcb: u16 at fibRgLw_end (count of u64 pairs in FibRgFcLcb)
	const cbRgFcLcb = readU16(word_doc, fibRgLw_end);
	const fibRgFcLcb_start: usize = fibRgLw_end + 2;

	// In FibRgFcLcb97, fcClx is at pair index 66 (each pair is 8 bytes: fc u32 + lcb u32)
	// fcClx offset = fibRgFcLcb_start + 66 * 8
	// lcbClx offset = fibRgFcLcb_start + 66 * 8 + 4
	var fcClx: u32 = 0;
	var lcbClx: u32 = 0;

	if (cbRgFcLcb > 66) {
		const clx_offset = fibRgFcLcb_start + 66 * 8;
		if (word_doc.len >= clx_offset + 8) {
			fcClx = readU32(word_doc, clx_offset);
			lcbClx = readU32(word_doc, clx_offset + 4);
		}
	}

	return FIB{
		.wIdent = wIdent,
		.nFib = nFib,
		.flags = flags,
		.fWhichTblStm = fWhichTblStm,
		.fcClx = fcClx,
		.lcbClx = lcbClx,
		.ccpText = ccpText,
	};
}

/// A piece descriptor from the CLX piece table.
const PieceDescriptor = struct {
	/// Character position in the final text (start)
	cp_start: u32,
	/// Character position in the final text (end, exclusive)
	cp_end: u32,
	/// File offset in the WordDocument stream (with compression flag in bit 30)
	fc: u32,
	/// If true, text is compressed (1 byte per char, Windows-1252)
	compressed: bool,
};

/// Parse the CLX from the Table stream to extract piece descriptors.
/// The CLX contains Pcdt (piece table descriptor) entries.
/// Returns an allocated slice of PieceDescriptors.
pub fn parsePieceTable(allocator: Allocator, table_stream: []const u8, fcClx: u32, lcbClx: u32) ![]PieceDescriptor {
	if (lcbClx == 0) return try allocator.alloc(PieceDescriptor, 0);
	if (fcClx + lcbClx > table_stream.len) return DocError.InvalidDoc;

	const clx = table_stream[fcClx..][0..lcbClx];

	// The CLX contains:
	// - Zero or more Prc entries (type byte = 0x01)
	// - One Pcdt entry (type byte = 0x02)
	var pos: usize = 0;

	// Skip Prc entries
	while (pos < clx.len) {
		if (clx[pos] == 0x01) {
			// Prc: 1 byte type + 2 byte cbGrpprl + variable data
			pos += 1;
			if (pos + 2 > clx.len) return DocError.InvalidDoc;
			const cb = readU16(clx, pos);
			pos += 2 + @as(usize, cb);
		} else {
			break;
		}
	}

	// We should now be at the Pcdt
	if (pos >= clx.len or clx[pos] != 0x02) return DocError.InvalidDoc;
	pos += 1;

	// Pcdt: 4 byte lcb (size of PlcPcd that follows)
	if (pos + 4 > clx.len) return DocError.InvalidDoc;
	const lcb_plcpcd = readU32(clx, pos);
	pos += 4;

	if (pos + lcb_plcpcd > clx.len) return DocError.InvalidDoc;
	const plcpcd = clx[pos..][0..lcb_plcpcd];

	// PlcPcd: array of (n+1) CP values (u32) followed by n Pcd entries (8 bytes each)
	// n = (lcb - 4) / (4 + 8) -- but actually:
	// Total size = (n+1)*4 + n*8 = 4n + 4 + 8n = 12n + 4
	// So n = (lcb - 4) / 12
	if (lcb_plcpcd < 4) return DocError.InvalidDoc;
	const n = (lcb_plcpcd - 4) / 12;
	if (n == 0) return try allocator.alloc(PieceDescriptor, 0);

	var pieces = try allocator.alloc(PieceDescriptor, n);
	errdefer allocator.free(pieces);

	// Read CPs (n+1 values)
	for (0..n) |i| {
		const cp_start = readU32(plcpcd, i * 4);
		const cp_end = readU32(plcpcd, (i + 1) * 4);

		// Read Pcd entry: 2 byte flags + 4 byte fc + 2 byte prm
		const pcd_offset = (n + 1) * 4 + i * 8;
		if (pcd_offset + 8 > plcpcd.len) return DocError.InvalidDoc;
		// Pcd bytes: [flags:2][fc:4][prm:2]
		const fc_raw = readU32(plcpcd, pcd_offset + 2);

		// Bit 30 of fc indicates compression
		const compressed = (fc_raw & (1 << 30)) != 0;
		// Clear bit 30 to get actual offset
		const fc = fc_raw & ~@as(u32, 1 << 30);

		pieces[i] = PieceDescriptor{
			.cp_start = cp_start,
			.cp_end = cp_end,
			.fc = fc,
			.compressed = compressed,
		};
	}

	return pieces;
}

/// Decode a Windows-1252 byte to a Unicode codepoint.
/// Windows-1252 is identical to ISO-8859-1 except for bytes 0x80-0x9F.
fn windows1252ToCodepoint(byte: u8) u21 {
	// Bytes 0x80-0x9F map to specific Unicode codepoints
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

/// Decode compressed text (Windows-1252, 1 byte per char) to UTF-8.
fn decodeCompressedText(allocator: Allocator, data: []const u8) ![]u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);

	for (data) |byte| {
		const cp = windows1252ToCodepoint(byte);
		var utf8_buf: [4]u8 = undefined;
		const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
		try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
	}

	return try buf.toOwnedSlice(allocator);
}

/// Extract text from a WordDocument stream using the piece table from the Table stream.
/// Returns UTF-8 encoded text.
fn extractTextFromPieces(
	allocator: Allocator,
	word_doc: []const u8,
	pieces: []const PieceDescriptor,
) ![]u8 {
	var text_buf = std.ArrayList(u8).empty;
	errdefer text_buf.deinit(allocator);

	for (pieces) |piece| {
		const char_count = piece.cp_end - piece.cp_start;
		if (char_count == 0) continue;

		if (piece.compressed) {
			// Compressed: 1 byte per character, Windows-1252
			// The fc for compressed text needs to be divided by 2 to get the actual byte offset
			const byte_offset = piece.fc / 2;
			const byte_count = char_count;
			if (byte_offset + byte_count > word_doc.len) continue;

			const raw = word_doc[byte_offset..][0..byte_count];
			const decoded = try decodeCompressedText(allocator, raw);
			defer allocator.free(decoded);
			try text_buf.appendSlice(allocator, decoded);
		} else {
			// Uncompressed: 2 bytes per character, UTF-16LE
			const byte_offset = piece.fc;
			const byte_count = char_count * 2;
			if (byte_offset + byte_count > word_doc.len) continue;

			const raw = word_doc[byte_offset..][0..byte_count];
			const decoded = try ole2.utf16leToUtf8(allocator, raw);
			defer allocator.free(decoded);
			try text_buf.appendSlice(allocator, decoded);
		}
	}

	return try text_buf.toOwnedSlice(allocator);
}

/// Try to extract text by scanning the WordDocument stream directly.
/// This is a fallback when no piece table is available — it scans for
/// readable text starting at the standard offset (0x200).
fn extractTextDirect(allocator: Allocator, word_doc: []const u8) !?[]const u8 {
	// In simple documents, text may start at offset 0x200 (512)
	// Try UTF-16LE first, then fall back to scanning for ASCII text

	if (word_doc.len < 0x200) return null;

	// Strategy 1: Try to interpret as UTF-16LE from offset 0x200
	const text_start: usize = 0x200;
	const remaining = word_doc[text_start..];

	// Look for a run of valid UTF-16LE characters
	if (remaining.len >= 2) {
		const max_scan = @min(remaining.len, 64 * 1024); // Limit scan to 64KB
		var end: usize = 0;
		var valid_chars: usize = 0;

		while (end + 1 < max_scan) {
			const ch = std.mem.readInt(u16, remaining[end..][0..2], .little);
			if (ch == 0) break; // null terminator
			// Check if it's a printable or whitespace character
			if ((ch >= 0x20 and ch < 0xFFFE) or ch == 0x0D or ch == 0x0A or ch == 0x09) {
				valid_chars += 1;
				end += 2;
			} else {
				break;
			}
		}

		if (valid_chars > 5) {
			// Looks like valid UTF-16LE text
			return try ole2.utf16leToUtf8(allocator, remaining[0..end]);
		}
	}

	// Strategy 2: Scan for ASCII/Latin-1 text anywhere in the document
	var text_buf = std.ArrayList(u8).empty;
	defer text_buf.deinit(allocator);

	var in_text_run = false;
	var run_start: usize = 0;
	const min_run_length: usize = 20; // Minimum run to consider as text

	for (word_doc, 0..) |byte, i| {
		const is_text = (byte >= 0x20 and byte < 0x7F) or byte == '\n' or byte == '\r' or byte == '\t';
		if (is_text) {
			if (!in_text_run) {
				run_start = i;
				in_text_run = true;
			}
		} else {
			if (in_text_run) {
				const run_len = i - run_start;
				if (run_len >= min_run_length) {
					if (text_buf.items.len > 0) {
						try text_buf.append(allocator, '\n');
					}
					try text_buf.appendSlice(allocator, word_doc[run_start..i]);
				}
				in_text_run = false;
			}
		}
	}

	// Handle last run
	if (in_text_run) {
		const run_len = word_doc.len - run_start;
		if (run_len >= min_run_length) {
			if (text_buf.items.len > 0) {
				try text_buf.append(allocator, '\n');
			}
			try text_buf.appendSlice(allocator, word_doc[run_start..word_doc.len]);
		}
	}

	if (text_buf.items.len > 0) {
		return try text_buf.toOwnedSlice(allocator);
	}

	return null;
}

/// Apply heuristic heading detection to extracted text.
/// Since full STSH (stylesheet hierarchy) parsing is extremely complex,
/// this uses simple patterns to identify likely headings:
/// - Short lines in ALL CAPS (likely headings)
/// - Lines matching "Section N", "Article N", "Chapter N" patterns
/// - Lines matching common numbered section patterns (1., 1.1, I., A.)
fn splitIntoSections(allocator: Allocator, text: []const u8) ![]const Section {
	if (text.len == 0) {
		return try allocator.alloc(Section, 0);
	}

	var sections = std.ArrayList(Section).empty;
	errdefer {
		for (sections.items) |s| freeSectionContents(allocator, s);
		sections.deinit(allocator);
	}

	// Split text into lines and group by headings
	var lines = std.mem.splitSequence(u8, text, "\n");
	var current_heading: ?[]const u8 = null;
	var current_level: u8 = 0;
	var content_buf = std.ArrayList(u8).empty;
	defer content_buf.deinit(allocator);

	while (lines.next()) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len == 0) {
			// Blank line — keep in content
			if (content_buf.items.len > 0) {
				try content_buf.append(allocator, '\n');
			}
			continue;
		}

		const heading_info = detectHeading(trimmed);
		if (heading_info.is_heading) {
			// Flush current section
			if (current_heading != null or content_buf.items.len > 0) {
				const content = try allocator.dupe(u8, content_buf.items);
				errdefer allocator.free(content);

				const heading_dupe: ?[]const u8 = if (current_heading) |h|
					try allocator.dupe(u8, h)
				else
					null;
				errdefer if (heading_dupe) |h| allocator.free(h);

				try sections.append(allocator, Section{
					.heading = heading_dupe,
					.level = current_level,
					.content = content,
					.children = try allocator.alloc(Section, 0),
				});
			}

			current_heading = trimmed;
			current_level = heading_info.level;
			content_buf.clearRetainingCapacity();
		} else {
			if (content_buf.items.len > 0) {
				try content_buf.append(allocator, '\n');
			}
			try content_buf.appendSlice(allocator, trimmed);
		}
	}

	// Flush final section
	{
		const content = try allocator.dupe(u8, content_buf.items);
		errdefer allocator.free(content);

		const heading_dupe: ?[]const u8 = if (current_heading) |h|
			try allocator.dupe(u8, h)
		else
			null;
		errdefer if (heading_dupe) |h| allocator.free(h);

		try sections.append(allocator, Section{
			.heading = heading_dupe,
			.level = current_level,
			.content = content,
			.children = try allocator.alloc(Section, 0),
		});
	}

	return try sections.toOwnedSlice(allocator);
}

/// Heading detection result.
const HeadingInfo = struct {
	is_heading: bool,
	level: u8,
};

/// Detect if a line looks like a heading using heuristics.
fn detectHeading(line: []const u8) HeadingInfo {
	if (line.len == 0 or line.len > 120) return .{ .is_heading = false, .level = 0 };

	// Pattern: "Chapter N" / "CHAPTER N"
	if (startsWithCaseInsensitive(line, "chapter ") and line.len < 40) {
		return .{ .is_heading = true, .level = 1 };
	}

	// Pattern: "Section N" / "SECTION N"
	if (startsWithCaseInsensitive(line, "section ") and line.len < 40) {
		return .{ .is_heading = true, .level = 1 };
	}

	// Pattern: "Article N" / "ARTICLE N"
	if (startsWithCaseInsensitive(line, "article ") and line.len < 40) {
		return .{ .is_heading = true, .level = 1 };
	}

	// Pattern: "Part N" / "PART N"
	if (startsWithCaseInsensitive(line, "part ") and line.len < 40) {
		return .{ .is_heading = true, .level = 1 };
	}

	// Pattern: Short ALL CAPS line (likely heading)
	if (line.len >= 3 and line.len <= 80 and isAllCaps(line)) {
		return .{ .is_heading = true, .level = 1 };
	}

	// Pattern: Numbered section "1." "1.1" "1.1.1" at start
	if (isNumberedSection(line)) |level| {
		return .{ .is_heading = true, .level = level };
	}

	return .{ .is_heading = false, .level = 0 };
}

/// Check if text starts with a case-insensitive prefix.
fn startsWithCaseInsensitive(text: []const u8, prefix: []const u8) bool {
	if (text.len < prefix.len) return false;
	for (text[0..prefix.len], prefix) |a, b| {
		if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
	}
	return true;
}

/// Check if a line is ALL CAPS (ASCII letters, with at least 3 uppercase letters).
fn isAllCaps(line: []const u8) bool {
	var upper_count: usize = 0;
	var lower_count: usize = 0;
	for (line) |c| {
		if (std.ascii.isUpper(c)) {
			upper_count += 1;
		} else if (std.ascii.isLower(c)) {
			lower_count += 1;
		}
		// digits, spaces, punctuation are OK
	}
	return upper_count >= 3 and lower_count == 0;
}

/// Check if a line starts with a numbered section pattern (e.g., "1.", "1.1", "1.1.1").
/// Returns the heading level based on the depth of numbering.
fn isNumberedSection(line: []const u8) ?u8 {
	if (line.len < 2) return null;

	// Must start with a digit
	if (!std.ascii.isDigit(line[0])) return null;

	var i: usize = 0;
	var level: u8 = 1;

	// Parse initial digits
	while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}

	if (i >= line.len) return null;

	// After digits, expect either '.' or end with space
	if (line[i] == '.') {
		i += 1;
		// Could be more levels: "1.1", "1.1.1"
		while (i < line.len and std.ascii.isDigit(line[i])) {
			while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
			level += 1;
			if (i < line.len and line[i] == '.') {
				i += 1;
			} else {
				break;
			}
		}
	} else {
		return null; // No dot after digits
	}

	// After the number, there should be a space and some text
	if (i < line.len and line[i] == ' ') {
		// The rest should be short enough to be a heading (not a sentence)
		const rest = std.mem.trim(u8, line[i..], " \t");
		if (rest.len > 0 and rest.len <= 100) {
			return level;
		}
	}

	return null;
}

/// Clean extracted text: normalize line endings, trim excess whitespace.
fn cleanText(allocator: Allocator, raw: []const u8) ![]u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);

	var i: usize = 0;
	var last_was_newline = false;
	var consecutive_newlines: u32 = 0;

	while (i < raw.len) {
		const c = raw[i];
		if (c == '\r') {
			// CR or CRLF → LF
			if (i + 1 < raw.len and raw[i + 1] == '\n') {
				i += 1; // skip LF in CRLF
			}
			consecutive_newlines += 1;
			if (consecutive_newlines <= 2) {
				try buf.append(allocator, '\n');
			}
			last_was_newline = true;
			i += 1;
		} else if (c == '\n') {
			consecutive_newlines += 1;
			if (consecutive_newlines <= 2) {
				try buf.append(allocator, '\n');
			}
			last_was_newline = true;
			i += 1;
		} else if (c == 0x07 or c == 0x0C or c == 0x01 or c == 0x08) {
			// Control characters commonly found in .doc: skip
			// 0x07 = cell/row mark, 0x0C = page break,
			// 0x01 = inline picture, 0x08 = drawn object
			i += 1;
		} else if (c == 0x0B) {
			// Vertical tab → line break
			try buf.append(allocator, '\n');
			i += 1;
		} else if (c == 0x13 or c == 0x14 or c == 0x15) {
			// Field begin/separator/end markers — skip
			i += 1;
		} else {
			if (last_was_newline) {
				consecutive_newlines = 0;
			}
			last_was_newline = false;
			try buf.append(allocator, c);
			i += 1;
		}
	}

	// Trim trailing whitespace
	var end = buf.items.len;
	while (end > 0 and (buf.items[end - 1] == '\n' or buf.items[end - 1] == ' ' or buf.items[end - 1] == '\t')) {
		end -= 1;
	}

	const result = try allocator.dupe(u8, buf.items[0..end]);
	buf.deinit(allocator);
	return result;
}

/// Parse a .doc file (as a byte slice) into a Document.
/// Caller owns the returned Document; free with `freeDocument`.
pub fn parse(allocator: Allocator, content: []const u8, path: []const u8) !Document {
	// Parse OLE2 header
	const header = ole2.parseHeader(allocator, content) catch {
		// Not a valid OLE2 file — return empty document
		return emptyDocument(allocator, path);
	};
	defer ole2.freeHeader(allocator, header);

	// Read WordDocument stream
	const word_doc_opt = ole2.readStream(allocator, content, header, "WordDocument") catch {
		return emptyDocument(allocator, path);
	};

	if (word_doc_opt == null) {
		return emptyDocument(allocator, path);
	}
	const word_doc = word_doc_opt.?;
	defer allocator.free(word_doc);

	// Parse FIB
	const fib = parseFIB(word_doc) catch {
		// Can't parse FIB — try direct text extraction
		return extractFallback(allocator, word_doc, path);
	};

	// Determine which table stream to use
	const table_name: []const u8 = if (fib.fWhichTblStm) "1Table" else "0Table";
	const table_stream_opt = ole2.readStream(allocator, content, header, table_name) catch null;

	var text: ?[]const u8 = null;
	defer if (text) |t| allocator.free(t);

	// Try piece table extraction if we have the table stream and CLX info
	if (table_stream_opt) |table_stream| {
		defer allocator.free(table_stream);

		if (fib.fcClx > 0 and fib.lcbClx > 0) {
			const pieces = parsePieceTable(allocator, table_stream, fib.fcClx, fib.lcbClx) catch null;
			if (pieces) |p| {
				defer allocator.free(p);
				if (p.len > 0) {
					text = extractTextFromPieces(allocator, word_doc, p) catch null;
				}
			}
		}
	}

	// Fallback: direct text extraction
	if (text == null) {
		text = extractTextDirect(allocator, word_doc) catch null;
	}

	if (text == null or text.?.len == 0) {
		if (text) |t| allocator.free(t);
		text = null;
		return emptyDocument(allocator, path);
	}

	// Clean the text
	const cleaned = try cleanText(allocator, text.?);
	defer allocator.free(cleaned);

	if (cleaned.len == 0) {
		return emptyDocument(allocator, path);
	}

	// Split into sections with heuristic heading detection
	const sections = try splitIntoSections(allocator, cleaned);
	errdefer {
		for (sections) |s| freeSectionContents(allocator, s);
		if (sections.len > 0) allocator.free(sections);
	}

	// Extract title from first heading, if any
	var title: ?[]const u8 = null;
	for (sections) |s| {
		if (s.heading != null and s.level <= 1) {
			title = try allocator.dupe(u8, s.heading.?);
			break;
		}
	}
	errdefer if (title) |t| allocator.free(t);

	const path_dupe = try allocator.dupe(u8, path);
	errdefer allocator.free(path_dupe);

	const metadata = try allocator.alloc(MetadataEntry, 0);

	wordfix.applySections(allocator, sections);

	return Document{		.path = path_dupe,
		.format = .doc,
		.title = title,
		.metadata = metadata,
		.sections = sections,
	};
}

/// Create an empty document for invalid/unparseable files.
fn emptyDocument(allocator: Allocator, path: []const u8) !Document {
	const path_dupe = try allocator.dupe(u8, path);
	errdefer allocator.free(path_dupe);

	const metadata = try allocator.alloc(MetadataEntry, 0);

	return Document{
		.path = path_dupe,
		.format = .doc,
		.title = null,
		.metadata = metadata,
		.sections = try allocator.alloc(Section, 0),
	};
}

/// Fallback text extraction when FIB can't be parsed.
fn extractFallback(allocator: Allocator, word_doc: []const u8, path: []const u8) !Document {
	const text = try extractTextDirect(allocator, word_doc) orelse {
		return emptyDocument(allocator, path);
	};
	defer allocator.free(text);

	const cleaned = try cleanText(allocator, text);
	defer allocator.free(cleaned);

	if (cleaned.len == 0) {
		return emptyDocument(allocator, path);
	}

	const sections = try splitIntoSections(allocator, cleaned);
	errdefer {
		for (sections) |s| freeSectionContents(allocator, s);
		if (sections.len > 0) allocator.free(sections);
	}

	const path_dupe = try allocator.dupe(u8, path);
	errdefer allocator.free(path_dupe);

	const metadata = try allocator.alloc(MetadataEntry, 0);

	return Document{
		.path = path_dupe,
		.format = .doc,
		.title = null,
		.metadata = metadata,
		.sections = sections,
	};
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

// ── Utility functions ─────────────────────────────────────────────────

fn readU16(data: []const u8, offset: usize) u16 {
	return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
	return std.mem.readInt(u32, data[offset..][0..4], .little);
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

// -- Unit tests for individual parsing functions --

test "DOC: FIB parsing — valid Word magic" {
	// Build a minimal FIB with the Word 97 magic
	var fib_data = [_]u8{0} ** 600;
	// wIdent = 0xA5EC
	std.mem.writeInt(u16, fib_data[0..2], 0xA5EC, .little);
	// nFib = 193 (Word 97)
	std.mem.writeInt(u16, fib_data[2..4], 193, .little);
	// flags with fWhichTblStm = 1 (bit 9)
	std.mem.writeInt(u16, fib_data[10..12], 0x0200, .little);
	// csw (at offset 32)
	std.mem.writeInt(u16, fib_data[32..34], 14, .little); // FibRgW97 has 14 u16 values
	// cslw (at offset 34 + 14*2 = 62)
	std.mem.writeInt(u16, fib_data[62..64], 22, .little); // FibRgLw97 has 22 u32 values
	// ccpText at FibRgLw start + 0x0C = 64 + 0x0C = 76
	std.mem.writeInt(u32, fib_data[76..80], 42, .little);
	// cbRgFcLcb (at offset 64 + 22*4 = 152)
	std.mem.writeInt(u16, fib_data[152..154], 88, .little); // 88 pairs for Word 97

	// fcClx at pair index 66: offset = 154 + 66*8 = 682 — exceeds our buffer
	// Use a bigger buffer or fewer pairs
	// For this test, just verify the basic FIB fields

	const fib = try parseFIB(&fib_data);
	try testing.expectEqual(@as(u16, 0xA5EC), fib.wIdent);
	try testing.expectEqual(@as(u16, 193), fib.nFib);
	try testing.expect(fib.fWhichTblStm);
	try testing.expectEqual(@as(u32, 42), fib.ccpText);
}

test "DOC: FIB parsing — invalid magic" {
	var bad_data = [_]u8{0} ** 200;
	std.mem.writeInt(u16, bad_data[0..2], 0x1234, .little);
	try testing.expectError(DocError.InvalidFIB, parseFIB(&bad_data));
}

test "DOC: FIB parsing — data too short" {
	var short_data = [_]u8{0} ** 30;
	try testing.expectError(DocError.InvalidFIB, parseFIB(&short_data));
}

test "DOC: FIB parsing — fWhichTblStm = 0 (0Table)" {
	var fib_data = [_]u8{0} ** 600;
	std.mem.writeInt(u16, fib_data[0..2], 0xA5EC, .little);
	std.mem.writeInt(u16, fib_data[2..4], 193, .little);
	std.mem.writeInt(u16, fib_data[10..12], 0x0000, .little); // no fWhichTblStm
	std.mem.writeInt(u16, fib_data[32..34], 14, .little);
	std.mem.writeInt(u16, fib_data[62..64], 22, .little);
	std.mem.writeInt(u16, fib_data[152..154], 0, .little);

	const fib = try parseFIB(&fib_data);
	try testing.expect(!fib.fWhichTblStm);
}

test "DOC: Windows-1252 decoding" {
	// Test basic ASCII range
	const ascii = "Hello World";
	const decoded = try decodeCompressedText(testing.allocator, ascii);
	defer testing.allocator.free(decoded);
	try testing.expectEqualStrings("Hello World", decoded);
}

test "DOC: Windows-1252 special characters" {
	// 0x93 = left double quote (U+201C → "\xE2\x80\x9C")
	// 0x94 = right double quote (U+201D → "\xE2\x80\x9D")
	const input = [_]u8{ 0x93, 'H', 'i', 0x94 };
	const decoded = try decodeCompressedText(testing.allocator, &input);
	defer testing.allocator.free(decoded);
	try testing.expectEqualStrings("\xe2\x80\x9cHi\xe2\x80\x9d", decoded);
}

test "DOC: Windows-1252 euro sign" {
	// 0x80 = Euro sign (U+20AC → "\xE2\x82\xAC")
	const input = [_]u8{0x80};
	const decoded = try decodeCompressedText(testing.allocator, &input);
	defer testing.allocator.free(decoded);
	try testing.expectEqualStrings("\xe2\x82\xac", decoded);
}

test "DOC: heading detection — chapter pattern" {
	const result = detectHeading("Chapter 1");
	try testing.expect(result.is_heading);
	try testing.expectEqual(@as(u8, 1), result.level);

	const result2 = detectHeading("CHAPTER 2: OVERVIEW");
	try testing.expect(result2.is_heading);
}

test "DOC: heading detection — section pattern" {
	const result = detectHeading("Section 3");
	try testing.expect(result.is_heading);
	try testing.expectEqual(@as(u8, 1), result.level);
}

test "DOC: heading detection — all caps" {
	const result = detectHeading("INTRODUCTION");
	try testing.expect(result.is_heading);
	try testing.expectEqual(@as(u8, 1), result.level);
}

test "DOC: heading detection — numbered section" {
	const r1 = detectHeading("1. Overview");
	try testing.expect(r1.is_heading);
	try testing.expectEqual(@as(u8, 1), r1.level);

	const r2 = detectHeading("1.1 Details");
	try testing.expect(r2.is_heading);
	try testing.expectEqual(@as(u8, 2), r2.level);

	const r3 = detectHeading("2.3.1 Sub-details");
	try testing.expect(r3.is_heading);
	try testing.expectEqual(@as(u8, 3), r3.level);
}

test "DOC: heading detection — normal text not detected" {
	const result = detectHeading("This is a normal sentence that should not be detected as a heading.");
	try testing.expect(!result.is_heading);
}

test "DOC: heading detection — empty line" {
	const result = detectHeading("");
	try testing.expect(!result.is_heading);
}

test "DOC: text cleaning — CR/LF normalization" {
	const input = "Hello\r\nWorld\rFoo\nBar";
	const cleaned = try cleanText(testing.allocator, input);
	defer testing.allocator.free(cleaned);
	try testing.expectEqualStrings("Hello\nWorld\nFoo\nBar", cleaned);
}

test "DOC: text cleaning — control character removal" {
	const input = "Hello\x07World\x0CEnd";
	const cleaned = try cleanText(testing.allocator, input);
	defer testing.allocator.free(cleaned);
	try testing.expectEqualStrings("HelloWorldEnd", cleaned);
}

test "DOC: text cleaning — excessive newlines collapsed" {
	const input = "Hello\n\n\n\n\nWorld";
	const cleaned = try cleanText(testing.allocator, input);
	defer testing.allocator.free(cleaned);
	try testing.expectEqualStrings("Hello\n\nWorld", cleaned);
}

test "DOC: section splitting — single section no headings" {
	const text = "This is just plain text without any headings.";
	const sections = try splitIntoSections(testing.allocator, text);
	defer {
		for (sections) |s| freeSectionContents(testing.allocator, s);
		testing.allocator.free(sections);
	}

	try testing.expectEqual(@as(usize, 1), sections.len);
	try testing.expectEqual(@as(?[]const u8, null), sections[0].heading);
	try testing.expect(std.mem.indexOf(u8, sections[0].content, "plain text") != null);
}

test "DOC: section splitting — with chapter headings" {
	const text = "INTRODUCTION\nSome intro text here.\nCHAPTER ONE\nFirst chapter content.";
	const sections = try splitIntoSections(testing.allocator, text);
	defer {
		for (sections) |s| freeSectionContents(testing.allocator, s);
		testing.allocator.free(sections);
	}

	// Should have at least 2 sections (INTRODUCTION + CHAPTER ONE)
	try testing.expect(sections.len >= 2);

	// First section should be INTRODUCTION
	try testing.expect(sections[0].heading != null);
	try testing.expectEqualStrings("INTRODUCTION", sections[0].heading.?);
}

test "DOC: piece table parsing" {
	// Build a minimal CLX with one piece
	var clx_buf: [200]u8 = undefined;
	@memset(&clx_buf, 0);

	// Pcdt type byte
	clx_buf[0] = 0x02;
	// lcb of PlcPcd (1 piece: 2*4 CPs + 1*8 Pcd = 16 bytes)
	std.mem.writeInt(u32, clx_buf[1..5], 16, .little);
	// CP[0] = 0
	std.mem.writeInt(u32, clx_buf[5..9], 0, .little);
	// CP[1] = 10
	std.mem.writeInt(u32, clx_buf[9..13], 10, .little);
	// Pcd: flags=0, fc=0x200 with compression bit set (bit 30)
	std.mem.writeInt(u16, clx_buf[13..15], 0, .little); // flags
	std.mem.writeInt(u32, clx_buf[15..19], 0x200 | (1 << 30), .little); // fc
	std.mem.writeInt(u16, clx_buf[19..21], 0, .little); // prm

	const pieces = try parsePieceTable(testing.allocator, &clx_buf, 0, 21);
	defer testing.allocator.free(pieces);

	try testing.expectEqual(@as(usize, 1), pieces.len);
	try testing.expectEqual(@as(u32, 0), pieces[0].cp_start);
	try testing.expectEqual(@as(u32, 10), pieces[0].cp_end);
	try testing.expect(pieces[0].compressed);
	try testing.expectEqual(@as(u32, 0x200), pieces[0].fc);
}

test "DOC: parse invalid file returns empty document" {
	const garbage = "This is not a .doc file at all";
	const doc = try parse(testing.allocator, garbage, "/test/invalid.doc");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.doc, doc.format);
	try testing.expectEqualStrings("/test/invalid.doc", doc.path);
	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
}

test "DOC: parse empty data returns empty document" {
	const doc = try parse(testing.allocator, "", "/test/empty.doc");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.doc, doc.format);
	try testing.expectEqual(@as(usize, 0), doc.sections.len);
}

test "DOC: extract compressed text from pieces" {
	// Simulate a WordDocument stream with compressed text at offset 0x100
	var word_doc = [_]u8{0} ** 0x200;
	const text = "Hello DOC World";
	// For compressed text, fc is stored as fc*2 in the piece (since we divide by 2)
	// So if fc = 0x200, the actual byte offset = 0x200/2 = 0x100
	@memcpy(word_doc[0x100..][0..text.len], text);

	const pieces = [_]PieceDescriptor{.{
		.cp_start = 0,
		.cp_end = @intCast(text.len),
		.fc = 0x200, // Will be divided by 2 = 0x100
		.compressed = true,
	}};

	const result = try extractTextFromPieces(testing.allocator, &word_doc, &pieces);
	defer testing.allocator.free(result);

	try testing.expectEqualStrings("Hello DOC World", result);
}

test "DOC: extract uncompressed (UTF-16LE) text from pieces" {
	// Simulate a WordDocument stream with UTF-16LE text at offset 0x100
	var word_doc = [_]u8{0} ** 0x200;
	// "Hi" in UTF-16LE: 'H' 0x00 'i' 0x00
	word_doc[0x100] = 'H';
	word_doc[0x101] = 0;
	word_doc[0x102] = 'i';
	word_doc[0x103] = 0;

	const pieces = [_]PieceDescriptor{.{
		.cp_start = 0,
		.cp_end = 2,
		.fc = 0x100,
		.compressed = false,
	}};

	const result = try extractTextFromPieces(testing.allocator, &word_doc, &pieces);
	defer testing.allocator.free(result);

	try testing.expectEqualStrings("Hi", result);
}

test "DOC: integration with OLE2 — text extraction from synthetic .doc" {
	// Build a synthetic .doc file:
	// - OLE2 container with "WordDocument" stream
	// - WordDocument contains a valid FIB header + text at offset 0x200

	// First, build the WordDocument stream content
	var word_doc_buf = [_]u8{0} ** 1024;

	// FIB header
	std.mem.writeInt(u16, word_doc_buf[0..2], 0xA5EC, .little); // wIdent
	std.mem.writeInt(u16, word_doc_buf[2..4], 193, .little); // nFib
	std.mem.writeInt(u16, word_doc_buf[10..12], 0x0000, .little); // flags
	std.mem.writeInt(u16, word_doc_buf[32..34], 14, .little); // csw
	std.mem.writeInt(u16, word_doc_buf[62..64], 22, .little); // cslw
	std.mem.writeInt(u16, word_doc_buf[152..154], 0, .little); // cbRgFcLcb

	// Put some text at the standard offset (0x200) as UTF-16LE
	const test_text = "Hello from a DOC file";
	var text_offset: usize = 0x200;
	for (test_text) |c| {
		word_doc_buf[text_offset] = c;
		word_doc_buf[text_offset + 1] = 0;
		text_offset += 2;
	}

	// Build OLE2 container
	const ole2_file = try ole2.buildTestOle2(testing.allocator, "WordDocument", &word_doc_buf);
	defer testing.allocator.free(ole2_file);

	// Parse as .doc
	const doc = try parse(testing.allocator, ole2_file, "/test/synthetic.doc");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.doc, doc.format);
	try testing.expectEqualStrings("/test/synthetic.doc", doc.path);

	// Should have extracted some text
	try testing.expect(doc.sections.len > 0);

	// Check that the text was found somewhere in the sections
	var found = false;
	for (doc.sections) |s| {
		if (s.content.len > 0) {
			if (std.mem.indexOf(u8, s.content, "Hello from a DOC file") != null) {
				found = true;
				break;
			}
		}
	}
	try testing.expect(found);
}

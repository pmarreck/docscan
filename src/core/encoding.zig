//! Character encoding detection and conversion for docscan.
//! Provides three layers of encoding support:
//! 1. Pre-computed CMap tables for known PDF font encodings (WinAnsi, MacRoman, etc.)
//! 2. Heuristic charset detection via chardetz (pure-Zig uchardet reimplementation).
//! 3. Conversion routines from detected encodings to UTF-8 (single-byte codepages
//!    via codepages.zig + UTF-16/UTF-32; CJK multibyte is detected but not yet
//!    transcoded).

const std = @import("std");
const Allocator = std.mem.Allocator;
// chardetz: pure-Zig charset detector (universalchardet/uchardet reimplementation).
// No C dependency, compiles to wasm32-freestanding — so detection now works in the
// browser slice too, unlike the old C++ uchardet it replaces.
const chardetz = @import("chardetz");
// codepages: generated single-byte codepage→Unicode tables (iconv-verified).
const codepages = @import("codepages.zig");

/// Detect the character encoding of a byte buffer using chardetz.
/// Returns the charset name (e.g. "WINDOWS-1252", "KOI8-R", "UTF-8") or null if
/// detection is inconclusive (empty input or no confident match). The name is a
/// static string owned by chardetz; the allocator is taken for API parity with
/// chardetz.detect (the current detection path is allocation-free).
pub fn detectEncoding(allocator: Allocator, data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    const name = chardetz.detect(allocator, data);
    if (name.len == 0) return null;
    return name;
}

/// Convert bytes from a named encoding to UTF-8.
/// Handles: UTF-8/ASCII (passthrough), UTF-16/UTF-32 (BOM- and name-directed),
/// WINDOWS-1252, ISO-8859-1, MAC-ROMAN, and every single-byte codepage in
/// codepages.zig (Cyrillic/Greek/Hebrew/Arabic/Thai/Turkish/Vietnamese/…).
/// Falls back to Latin-1 for unrecognised single-byte names. Bytes undefined in
/// the source charset are dropped (matching iconv //IGNORE).
pub fn toUtf8(allocator: Allocator, data: []const u8, encoding: []const u8) ![]const u8 {
    if (asciiEqlIgnoreCase(encoding, "UTF-8") or
        asciiEqlIgnoreCase(encoding, "ASCII") or
        asciiEqlIgnoreCase(encoding, "US-ASCII"))
    {
        return allocator.dupe(u8, data);
    }
    // UTF-16 / UTF-32 (name- or BOM-directed; handles surrogate pairs).
    if (utf16or32(encoding)) |variant| {
        return convertUtf16or32(allocator, data, variant);
    }
    if (asciiEqlIgnoreCase(encoding, "WINDOWS-1252")) {
        return convertWithTable(allocator, data, &win1252_to_unicode);
    }
    if (asciiEqlIgnoreCase(encoding, "X-MAC-ROMAN") or
        asciiEqlIgnoreCase(encoding, "MAC-ROMAN") or
        asciiEqlIgnoreCase(encoding, "MACROMAN") or
        asciiEqlIgnoreCase(encoding, "MACINTOSH"))
    {
        return convertWithTable(allocator, data, &macroman_to_unicode);
    }
    if (asciiEqlIgnoreCase(encoding, "ISO-8859-1") or
        asciiEqlIgnoreCase(encoding, "LATIN1") or
        asciiEqlIgnoreCase(encoding, "ISO_8859-1"))
    {
        // ISO-8859-1 is identity mapping to Unicode codepoints 0x00-0xFF
        return convertLatin1ToUtf8(allocator, data);
    }
    // Single-byte legacy codepages (generated tables, iconv-verified).
    if (codepages.tableFor(encoding)) |table| {
        return convertWithTable(allocator, data, table);
    }
    // Fallback: treat as Latin-1
    return convertLatin1ToUtf8(allocator, data);
}

/// The four concrete UTF-16/UTF-32 byte orders we decode.
const WideEnc = enum { utf16le, utf16be, utf32le, utf32be };

/// Classify a UTF-16/UTF-32 charset name (case-insensitive). The bare "UTF-16"/
/// "UTF-32" forms default to little-endian but are overridden by a BOM in
/// convertUtf16or32. Returns null for any non-UTF-16/32 name.
fn utf16or32(name: []const u8) ?WideEnc {
    if (asciiEqlIgnoreCase(name, "UTF-16LE") or asciiEqlIgnoreCase(name, "UTF16LE")) return .utf16le;
    if (asciiEqlIgnoreCase(name, "UTF-16BE") or asciiEqlIgnoreCase(name, "UTF16BE")) return .utf16be;
    if (asciiEqlIgnoreCase(name, "UTF-16") or asciiEqlIgnoreCase(name, "UTF16")) return .utf16le;
    if (asciiEqlIgnoreCase(name, "UTF-32LE") or asciiEqlIgnoreCase(name, "UTF32LE")) return .utf32le;
    if (asciiEqlIgnoreCase(name, "UTF-32BE") or asciiEqlIgnoreCase(name, "UTF32BE")) return .utf32be;
    if (asciiEqlIgnoreCase(name, "UTF-32") or asciiEqlIgnoreCase(name, "UTF32")) return .utf32le;
    return null;
}

/// Decode UTF-16 or UTF-32 to UTF-8. A leading BOM overrides the name's
/// endianness and is stripped. UTF-16 surrogate pairs are combined; lone
/// surrogates and out-of-range scalars are skipped.
fn convertUtf16or32(allocator: Allocator, data: []const u8, enc: WideEnc) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    const is32 = (enc == .utf32le or enc == .utf32be);
    var little = (enc == .utf16le or enc == .utf32le);
    var off: usize = 0;
    if (is32) {
        if (data.len >= 4 and data[0] == 0xFF and data[1] == 0xFE and data[2] == 0x00 and data[3] == 0x00) {
            little = true;
            off = 4;
        } else if (data.len >= 4 and data[0] == 0x00 and data[1] == 0x00 and data[2] == 0xFE and data[3] == 0xFF) {
            little = false;
            off = 4;
        }
        var i = off;
        while (i + 4 <= data.len) : (i += 4) {
            const cp: u32 = if (little)
                @as(u32, data[i]) | (@as(u32, data[i + 1]) << 8) | (@as(u32, data[i + 2]) << 16) | (@as(u32, data[i + 3]) << 24)
            else
                @as(u32, data[i + 3]) | (@as(u32, data[i + 2]) << 8) | (@as(u32, data[i + 1]) << 16) | (@as(u32, data[i]) << 24);
            try appendScalar(allocator, &buf, cp);
        }
    } else {
        if (data.len >= 2 and data[0] == 0xFF and data[1] == 0xFE) {
            little = true;
            off = 2;
        } else if (data.len >= 2 and data[0] == 0xFE and data[1] == 0xFF) {
            little = false;
            off = 2;
        }
        var i = off;
        while (i + 2 <= data.len) {
            const w0: u16 = if (little)
                @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8)
            else
                @as(u16, data[i + 1]) | (@as(u16, data[i]) << 8);
            i += 2;
            var cp: u32 = w0;
            if (w0 >= 0xD800 and w0 <= 0xDBFF) {
                // High surrogate: needs a following low surrogate.
                if (i + 2 > data.len) break;
                const w1: u16 = if (little)
                    @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8)
                else
                    @as(u16, data[i + 1]) | (@as(u16, data[i]) << 8);
                if (w1 >= 0xDC00 and w1 <= 0xDFFF) {
                    cp = 0x10000 + ((@as(u32, w0 - 0xD800) << 10) | (w1 - 0xDC00));
                    i += 2;
                } else {
                    continue; // lone high surrogate — skip
                }
            } else if (w0 >= 0xDC00 and w0 <= 0xDFFF) {
                continue; // lone low surrogate — skip
            }
            try appendScalar(allocator, &buf, cp);
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Append a Unicode scalar to `buf` as UTF-8; skip invalid scalars (surrogates
/// or > U+10FFFF) rather than failing the whole conversion.
fn appendScalar(allocator: Allocator, buf: *std.ArrayList(u8), cp: u32) !void {
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return;
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return;
    try buf.appendSlice(allocator, tmp[0..n]);
}

// ── Encoding Tables ─────────────────────────────────────────────────

/// Windows-1252 special range (0x80-0x9F) mapped to Unicode codepoints.
/// For 0xA0-0xFF the mapping is identity (same as Latin-1/Unicode).
/// Undefined positions map to U+FFFD (replacement character).
pub const win1252_special: [32]u21 = .{
    0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80-87
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD, // 88-8F
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90-97
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178, // 98-9F
};

/// Full Windows-1252 byte-to-Unicode table (256 entries).
/// Bytes 0x00-0x7F map to themselves; 0x80-0x9F use special mapping;
/// 0xA0-0xFF map to themselves (same as Latin-1).
pub const win1252_to_unicode: [256]u21 = blk: {
    var table: [256]u21 = undefined;
    for (0..128) |i| table[i] = @intCast(i);
    for (0..32) |i| table[0x80 + i] = win1252_special[i];
    for (0xA0..256) |i| table[i] = @intCast(i);
    break :blk table;
};

/// MacRoman byte-to-Unicode table (256 entries).
/// 0x00-0x7F are ASCII; 0x80-0xFF have Mac-specific mappings.
pub const macroman_to_unicode: [256]u21 = blk: {
    var table: [256]u21 = undefined;
    for (0..128) |i| table[i] = @intCast(i);
    // 0x80-0xFF MacRoman high-byte mappings
    const hi: [128]u21 = .{
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1, // 80-87
        0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8, // 88-8F
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3, // 90-97
        0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC, // 98-9F
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF, // A0-A7
        0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8, // A8-AF
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211, // B0-B7
        0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x2126, 0x00E6, 0x00F8, // B8-BF
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB, // C0-C7
        0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153, // C8-CF
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA, // D0-D7
        0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02, // D8-DF
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1, // E0-E7
        0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4, // E8-EF
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC, // F0-F7
        0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7, // F8-FF
    };
    for (0..128) |i| table[0x80 + i] = hi[i];
    break :blk table;
};

/// Adobe StandardEncoding byte-to-Unicode table.
/// Mostly matches ASCII in the printable range; has specific mappings for 0x80-0xFF.
pub const standard_encoding_to_unicode: [256]u21 = blk: {
    var table: [256]u21 = undefined;
    // 0x00-0x1F: undefined / control
    for (0..0x20) |i| table[i] = @intCast(i);
    // 0x20-0x7E: mostly ASCII
    for (0x20..0x7F) |i| table[i] = @intCast(i);
    table[0x7F] = 0xFFFD; // undefined

    // Adobe Standard Encoding high bytes (0x80-0xFF)
    const hi: [128]u21 = .{
        0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // 80-87
        0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // 88-8F
        0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // 90-97
        0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // 98-9F
        0xFFFD, 0x00A1, 0x00A2, 0x00A3, 0x2044, 0x00A5, 0x0192, 0x00A7, // A0-A7
        0x00A4, 0x0027, 0x201C, 0x00AB, 0x2039, 0x203A, 0xFB01, 0xFB02, // A8-AF
        0xFFFD, 0x2013, 0x2020, 0x2021, 0x00B7, 0xFFFD, 0x00B6, 0x2022, // B0-B7
        0x201A, 0x201E, 0x201D, 0x00BB, 0x2026, 0x2030, 0xFFFD, 0x00BF, // B8-BF
        0xFFFD, 0x0060, 0x00B4, 0x02C6, 0x02DC, 0x00AF, 0x02D8, 0x02D9, // C0-C7
        0x00A8, 0xFFFD, 0x02DA, 0x00B8, 0xFFFD, 0x02DD, 0x02DB, 0x02C7, // C8-CF
        0x2014, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // D0-D7
        0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // D8-DF
        0xFFFD, 0x00C6, 0xFFFD, 0x00AA, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // E0-E7
        0x0141, 0x00D8, 0x0152, 0x00BA, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // E8-EF
        0xFFFD, 0x00E6, 0xFFFD, 0xFFFD, 0xFFFD, 0x0131, 0xFFFD, 0xFFFD, // F0-F7
        0x0142, 0x00F8, 0x0153, 0x00DF, 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD, // F8-FF
    };
    for (0..128) |i| table[0x80 + i] = hi[i];

    // Standard Encoding also has some differences in the ASCII range:
    // 0x27 -> U+2019 (right single quotation mark) instead of apostrophe
    // 0x60 -> U+2018 (left single quotation mark) instead of grave accent
    table[0x27] = 0x2019;
    table[0x60] = 0x2018;
    break :blk table;
};

/// PDFDocEncoding byte-to-Unicode table.
/// Identical to Latin-1 except for 0x80-0x9F and a few other positions.
pub const pdfdoc_encoding_to_unicode: [256]u21 = blk: {
    var table: [256]u21 = undefined;
    // Start with identity (Latin-1)
    for (0..256) |i| table[i] = @intCast(i);

    // Override 0x80-0x9F with PDFDocEncoding specifics
    table[0x80] = 0x2022; // bullet
    table[0x81] = 0x2020; // dagger
    table[0x82] = 0x2021; // double dagger
    table[0x83] = 0x2026; // ellipsis
    table[0x84] = 0x2014; // em dash
    table[0x85] = 0x2013; // en dash
    table[0x86] = 0x0192; // florin
    table[0x87] = 0x2044; // fraction slash
    table[0x88] = 0x2039; // left single guillemet
    table[0x89] = 0x203A; // right single guillemet
    table[0x8A] = 0x2212; // minus
    table[0x8B] = 0x2030; // per mille
    table[0x8C] = 0x201E; // double low-9 quotation mark
    table[0x8D] = 0x201C; // left double quotation mark
    table[0x8E] = 0x201D; // right double quotation mark
    table[0x8F] = 0x2018; // left single quotation mark
    table[0x90] = 0x2019; // right single quotation mark
    table[0x91] = 0x201A; // single low-9 quotation mark
    table[0x92] = 0x2122; // trademark
    table[0x93] = 0xFB01; // fi ligature
    table[0x94] = 0xFB02; // fl ligature
    table[0x95] = 0x0141; // L with stroke
    table[0x96] = 0x0152; // OE ligature
    table[0x97] = 0x0160; // S with caron
    table[0x98] = 0x0178; // Y with diaeresis
    table[0x99] = 0x017D; // Z with caron
    table[0x9A] = 0x0131; // dotless i
    table[0x9B] = 0x0142; // l with stroke
    table[0x9C] = 0x0153; // oe ligature
    table[0x9D] = 0x0161; // s with caron
    table[0x9E] = 0x017E; // z with caron
    table[0x9F] = 0xFFFD; // undefined
    // 0x7F: also undefined in PDFDocEncoding
    table[0x7F] = 0xFFFD;
    // 0x18-0x1F have special mappings in PDFDocEncoding
    table[0x18] = 0x02D8; // breve
    table[0x19] = 0x02C7; // caron
    table[0x1A] = 0x02C6; // circumflex accent
    table[0x1B] = 0x02D9; // dot above
    table[0x1C] = 0x02DD; // double acute accent
    table[0x1D] = 0x02DB; // ogonek
    table[0x1E] = 0x02DA; // ring above
    table[0x1F] = 0x02DC; // tilde
    // 0xAD: soft hyphen (same as Unicode, identity is correct)
    break :blk table;
};

// ── Conversion Helpers ──────────────────────────────────────────────

/// Convert a byte buffer to UTF-8 using a 256-entry byte-to-codepoint table.
fn convertWithTable(allocator: Allocator, data: []const u8, table: *const [256]u21) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    for (data) |byte| {
        const cp = table[byte];
        if (cp == 0xFFFD) continue; // skip undefined mappings
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
        try buf.appendSlice(allocator, utf8_buf[0..len]);
    }

    return try buf.toOwnedSlice(allocator);
}

/// Convert Latin-1 (ISO-8859-1) bytes to UTF-8.
/// Latin-1 byte values map directly to Unicode codepoints.
fn convertLatin1ToUtf8(allocator: Allocator, data: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    for (data) |byte| {
        if (byte < 0x80) {
            try buf.append(allocator, byte);
        } else {
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(byte), &utf8_buf) catch continue;
            try buf.appendSlice(allocator, utf8_buf[0..len]);
        }
    }

    return try buf.toOwnedSlice(allocator);
}

/// Case-insensitive ASCII comparison (avoids pulling in std.ascii.eqlIgnoreCase
/// which may or may not exist across Zig versions).
fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Look up a PDF encoding name and return the corresponding byte-to-Unicode table.
/// Returns null for unknown/unsupported encoding names.
pub fn getEncodingTable(name: []const u8) ?*const [256]u21 {
    if (std.mem.eql(u8, name, "WinAnsiEncoding")) return &win1252_to_unicode;
    if (std.mem.eql(u8, name, "MacRomanEncoding")) return &macroman_to_unicode;
    if (std.mem.eql(u8, name, "StandardEncoding")) return &standard_encoding_to_unicode;
    if (std.mem.eql(u8, name, "PDFDocEncoding")) return &pdfdoc_encoding_to_unicode;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "encoding: Windows-1252 smart quotes convert to UTF-8" {
    // 0x93 = left double quotation mark (U+201C), 0x94 = right double quotation mark (U+201D)
    const input = &[_]u8{ 0x93, 0x94 };
    const result = try convertWithTable(testing.allocator, input, &win1252_to_unicode);
    defer testing.allocator.free(result);
    // U+201C = E2 80 9C, U+201D = E2 80 9D
    try testing.expectEqualStrings("\xe2\x80\x9c\xe2\x80\x9d", result);
}

test "encoding: Windows-1252 euro sign (0x80) converts to UTF-8" {
    const input = &[_]u8{0x80};
    const result = try convertWithTable(testing.allocator, input, &win1252_to_unicode);
    defer testing.allocator.free(result);
    // U+20AC = E2 82 AC
    try testing.expectEqualStrings("\xe2\x82\xac", result);
}

test "encoding: Windows-1252 em-dash (0x97) converts to UTF-8" {
    const input = &[_]u8{0x97};
    const result = try convertWithTable(testing.allocator, input, &win1252_to_unicode);
    defer testing.allocator.free(result);
    // U+2014 = E2 80 94
    try testing.expectEqualStrings("\xe2\x80\x94", result);
}

test "encoding: Windows-1252 ASCII passthrough" {
    const input = "Hello, world!";
    const result = try convertWithTable(testing.allocator, input, &win1252_to_unicode);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello, world!", result);
}

test "encoding: MacRoman high bytes convert correctly" {
    // MacRoman 0x80 = U+00C4 (A with diaeresis)
    const input = &[_]u8{0x80};
    const result = try convertWithTable(testing.allocator, input, &macroman_to_unicode);
    defer testing.allocator.free(result);
    // U+00C4 = C3 84
    try testing.expectEqualStrings("\xc3\x84", result);
}

test "encoding: MacRoman curly quotes" {
    // MacRoman 0xD2 = U+201C (left double quote), 0xD3 = U+201D (right double quote)
    const input = &[_]u8{ 0xD2, 0xD3 };
    const result = try convertWithTable(testing.allocator, input, &macroman_to_unicode);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\xe2\x80\x9c\xe2\x80\x9d", result);
}

test "encoding: Latin-1 to UTF-8 conversion" {
    // 0xE9 = e with acute (U+00E9), 0xFC = u with diaeresis (U+00FC)
    const input = &[_]u8{ 0xE9, 0xFC };
    const result = try convertLatin1ToUtf8(testing.allocator, input);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\xc3\xa9\xc3\xbc", result);
}

test "encoding: toUtf8 dispatches correctly" {
    // Windows-1252 smart quotes
    const input = &[_]u8{ 0x93, 0x94 };
    const result = try toUtf8(testing.allocator, input, "WINDOWS-1252");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\xe2\x80\x9c\xe2\x80\x9d", result);
}

test "encoding: toUtf8 UTF-8 passthrough" {
    const input = "already UTF-8 \xe2\x80\x9c";
    const result = try toUtf8(testing.allocator, input, "UTF-8");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(input, result);
}

test "encoding: getEncodingTable returns correct tables" {
    try testing.expect(getEncodingTable("WinAnsiEncoding") != null);
    try testing.expect(getEncodingTable("MacRomanEncoding") != null);
    try testing.expect(getEncodingTable("StandardEncoding") != null);
    try testing.expect(getEncodingTable("PDFDocEncoding") != null);
    try testing.expect(getEncodingTable("BogusEncoding") == null);
}

test "encoding: asciiEqlIgnoreCase" {
    try testing.expect(asciiEqlIgnoreCase("UTF-8", "utf-8"));
    try testing.expect(asciiEqlIgnoreCase("WINDOWS-1252", "windows-1252"));
    try testing.expect(!asciiEqlIgnoreCase("UTF-8", "ASCII"));
    try testing.expect(!asciiEqlIgnoreCase("short", "longer"));
}

test "encoding: StandardEncoding apostrophe and grave" {
    // StandardEncoding maps 0x27 -> U+2019 (right single quote)
    // and 0x60 -> U+2018 (left single quote)
    const input_apos = &[_]u8{0x27};
    const result_apos = try convertWithTable(testing.allocator, input_apos, &standard_encoding_to_unicode);
    defer testing.allocator.free(result_apos);
    // U+2019 = E2 80 99
    try testing.expectEqualStrings("\xe2\x80\x99", result_apos);

    const input_grave = &[_]u8{0x60};
    const result_grave = try convertWithTable(testing.allocator, input_grave, &standard_encoding_to_unicode);
    defer testing.allocator.free(result_grave);
    // U+2018 = E2 80 98
    try testing.expectEqualStrings("\xe2\x80\x98", result_grave);
}

test "encoding: PDFDocEncoding smart quotes" {
    // PDFDocEncoding 0x8D = U+201C (left double quote), 0x8E = U+201D (right double quote)
    const input = &[_]u8{ 0x8D, 0x8E };
    const result = try convertWithTable(testing.allocator, input, &pdfdoc_encoding_to_unicode);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\xe2\x80\x9c\xe2\x80\x9d", result);
}

test "encoding: detectEncoding is callable and stable on ASCII" {
    // chardetz should classify plain ASCII without crashing; result may be
    // "ASCII"/"UTF-8" or null — we only assert it does not crash.
    const ascii_text = "Hello, world! This is plain text.";
    _ = detectEncoding(testing.allocator, ascii_text);
}

test "encoding: detectEncoding returns null for empty input" {
    try testing.expectEqual(@as(?[]const u8, null), detectEncoding(testing.allocator, ""));
}

test "encoding: toUtf8 transcodes KOI8-R Cyrillic" {
    // "Привет" in KOI8-R.
    const koi8 = &[_]u8{ 0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4 };
    const out = try toUtf8(testing.allocator, koi8, "KOI8-R");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Привет", out);
}

test "encoding: toUtf8 transcodes WINDOWS-1251 Cyrillic" {
    const cp1251 = &[_]u8{ 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2 };
    const out = try toUtf8(testing.allocator, cp1251, "WINDOWS-1251");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Привет", out);
}

test "encoding: toUtf8 transcodes ISO-8859-7 Greek" {
    const grk = &[_]u8{ 0xE1, 0xE2, 0xE3 };
    const out = try toUtf8(testing.allocator, grk, "ISO-8859-7");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("αβγ", out);
}

test "encoding: toUtf8 TIS-620 aliases ISO-8859-11 (Thai)" {
    // 0xA1 = THAI CHARACTER KO KAI (U+0E01) in both.
    const thai = &[_]u8{0xA1};
    const a = try toUtf8(testing.allocator, thai, "TIS-620");
    defer testing.allocator.free(a);
    const b = try toUtf8(testing.allocator, thai, "ISO-8859-11");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expectEqualStrings("\xe0\xb8\x81", a); // U+0E01
}

test "encoding: toUtf8 UTF-16LE with BOM" {
    const u16le = &[_]u8{ 0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00 }; // BOM + "Hi"
    const out = try toUtf8(testing.allocator, u16le, "UTF-16");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hi", out);
}

test "encoding: toUtf8 UTF-16BE with BOM" {
    const u16be = &[_]u8{ 0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69 }; // BOM + "Hi"
    const out = try toUtf8(testing.allocator, u16be, "UTF-16");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hi", out);
}

test "encoding: toUtf8 UTF-16LE surrogate pair (emoji)" {
    // U+1F600 = surrogate pair D83D DE00 → LE bytes 3D D8 00 DE.
    const pair = &[_]u8{ 0x3D, 0xD8, 0x00, 0xDE };
    const out = try toUtf8(testing.allocator, pair, "UTF-16LE");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\xf0\x9f\x98\x80", out); // 😀
}

test "encoding: toUtf8 UTF-32LE with BOM" {
    const u32le = &[_]u8{ 0xFF, 0xFE, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x69, 0x00, 0x00, 0x00 };
    const out = try toUtf8(testing.allocator, u32le, "UTF-32");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hi", out);
}

test "encoding: Windows-1252 undefined bytes (0x81) are skipped" {
    // 0x81 is undefined in Windows-1252 — should be skipped
    const input = &[_]u8{ 'A', 0x81, 'B' };
    const result = try convertWithTable(testing.allocator, input, &win1252_to_unicode);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("AB", result);
}

test "encoding: mixed ASCII and high bytes in Windows-1252" {
    // "Hello" + em-dash + "world"
    const input = "Hello" ++ &[_]u8{0x97} ++ "world";
    const result = try convertWithTable(testing.allocator, input, &win1252_to_unicode);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello\xe2\x80\x94world", result);
}

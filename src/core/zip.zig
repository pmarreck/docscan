//! In-memory ZIP archive reader for docscan.
//! Parses ZIP archives from byte slices and extracts entries by name.
//! Supports stored (method 0) and deflated (method 8) entries.
//! Pure computation — no I/O. Receives byte slices, returns byte slices.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ZipError = error{
	InvalidZip,
	UnsupportedCompression,
	DecompressionFailed,
	CorruptEntry,
};

/// Signature bytes for ZIP structures.
const eocd_sig = [4]u8{ 'P', 'K', 5, 6 };
const central_dir_sig = [4]u8{ 'P', 'K', 1, 2 };
const local_header_sig = [4]u8{ 'P', 'K', 3, 4 };

/// Extract the content of a named entry from a ZIP archive in memory.
/// Returns null if the entry is not found. Caller owns the returned slice.
pub fn extractEntry(allocator: Allocator, archive: []const u8, name: []const u8) !?[]const u8 {
	const eocd = findEocd(archive) orelse return ZipError.InvalidZip;

	const cd_offset = readU32(archive, eocd + 16);
	const cd_count = readU16(archive, eocd + 10);

	var pos: usize = cd_offset;
	var i: u16 = 0;
	while (i < cd_count) : (i += 1) {
		if (pos + 46 > archive.len) return ZipError.InvalidZip;
		if (!std.mem.eql(u8, archive[pos..][0..4], &central_dir_sig))
			return ZipError.InvalidZip;

		const compression = readU16(archive, pos + 10);
		const fname_len = readU16(archive, pos + 28);
		const extra_len = readU16(archive, pos + 30);
		const comment_len = readU16(archive, pos + 32);
		const local_offset = readU32(archive, pos + 42);

		const fname_start = pos + 46;
		if (fname_start + fname_len > archive.len) return ZipError.InvalidZip;
		const entry_name = archive[fname_start .. fname_start + fname_len];

		if (std.mem.eql(u8, entry_name, name)) {
			return try extractFromLocalHeader(allocator, archive, local_offset, compression);
		}

		pos = fname_start + fname_len + extra_len + comment_len;
	}

	return null;
}

/// List all entry names in a ZIP archive. Caller owns the returned slice
/// and each string within it; free with `freeEntryList`.
pub fn listEntries(allocator: Allocator, archive: []const u8) ![][]const u8 {
	const eocd = findEocd(archive) orelse return ZipError.InvalidZip;

	const cd_offset = readU32(archive, eocd + 16);
	const cd_count = readU16(archive, eocd + 10);

	var names = std.ArrayList([]const u8).empty;
	errdefer {
		for (names.items) |n| allocator.free(n);
		names.deinit(allocator);
	}

	var pos: usize = cd_offset;
	var i: u16 = 0;
	while (i < cd_count) : (i += 1) {
		if (pos + 46 > archive.len) return ZipError.InvalidZip;
		if (!std.mem.eql(u8, archive[pos..][0..4], &central_dir_sig))
			return ZipError.InvalidZip;

		const fname_len = readU16(archive, pos + 28);
		const extra_len = readU16(archive, pos + 30);
		const comment_len = readU16(archive, pos + 32);

		const fname_start = pos + 46;
		if (fname_start + fname_len > archive.len) return ZipError.InvalidZip;

		const name_copy = try allocator.dupe(u8, archive[fname_start .. fname_start + fname_len]);
		errdefer allocator.free(name_copy);
		try names.append(allocator, name_copy);

		pos = fname_start + fname_len + extra_len + comment_len;
	}

	return try names.toOwnedSlice(allocator);
}

/// Free an entry list returned by `listEntries`.
pub fn freeEntryList(allocator: Allocator, entries: [][]const u8) void {
	for (entries) |e| allocator.free(e);
	allocator.free(entries);
}

// ── Internal helpers ─────────────────────────────────────────────────

/// Find the End of Central Directory record by scanning backwards.
fn findEocd(archive: []const u8) ?usize {
	if (archive.len < 22) return null; // minimum EOCD size
	// EOCD can have a trailing comment (up to 65535 bytes)
	const search_start: usize = if (archive.len > 22 + 65535) archive.len - 22 - 65535 else 0;
	var pos: usize = archive.len - 22;
	while (pos >= search_start) {
		if (std.mem.eql(u8, archive[pos..][0..4], &eocd_sig)) {
			return pos;
		}
		if (pos == 0) break;
		pos -= 1;
	}
	return null;
}

/// Extract file data from a local file header at the given offset.
fn extractFromLocalHeader(allocator: Allocator, archive: []const u8, offset: u32, compression: u16) ![]const u8 {
	if (offset + 30 > archive.len) return ZipError.InvalidZip;
	if (!std.mem.eql(u8, archive[offset..][0..4], &local_header_sig))
		return ZipError.InvalidZip;

	const compressed_size = readU32(archive, offset + 18);
	const fname_len = readU16(archive, offset + 26);
	const extra_len = readU16(archive, offset + 28);

	const data_start: usize = offset + 30 + fname_len + extra_len;
	if (data_start + compressed_size > archive.len) return ZipError.InvalidZip;

	const compressed_data = archive[data_start .. data_start + compressed_size];

	if (compression == 0) {
		// Stored — just copy
		return try allocator.dupe(u8, compressed_data);
	} else if (compression == 8) {
		// Deflate — decompress using Zig's flate decompressor
		return try inflateData(allocator, compressed_data);
	} else {
		return ZipError.UnsupportedCompression;
	}
}

/// Decompress raw deflate data using Zig's std.compress.flate.
fn inflateData(allocator: Allocator, compressed: []const u8) ![]const u8 {
	var reader: std.Io.Reader = .fixed(compressed);
	var aw: std.Io.Writer.Allocating = .init(allocator);
	errdefer aw.deinit();

	var decompress: std.compress.flate.Decompress = .init(&reader, .raw, &.{});
	_ = decompress.reader.streamRemaining(&aw.writer) catch return ZipError.DecompressionFailed;

	return try aw.toOwnedSlice();
}

// Little-endian readers shared across the binary-format parsers.
const endian = @import("endian.zig");
const readU16 = endian.readU16;
const readU32 = endian.readU32;

// ── ZIP builder for tests ────────────────────────────────────────────

pub const TestEntry = struct {
	name: []const u8,
	data: []const u8,
	/// If non-null, use this as the compressed data (with method 8).
	/// If null, store uncompressed (method 0).
	compressed: ?[]const u8 = null,
};

/// Build a minimal in-memory ZIP archive for testing.
pub fn buildTestZip(allocator: Allocator, entries: []const TestEntry) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(allocator);

	// Track local header offsets for central directory
	var offsets = std.ArrayList(u32).empty;
	defer offsets.deinit(allocator);

	// Write local file headers + data
	for (entries) |entry| {
		try offsets.append(allocator, @intCast(buf.items.len));
		const method: u16 = if (entry.compressed != null) 8 else 0;
		const file_data = entry.compressed orelse entry.data;

		// Local file header (30 bytes + filename)
		try buf.appendSlice(allocator, &local_header_sig);
		try appendU16(&buf, allocator, 20); // version needed
		try appendU16(&buf, allocator, 0); // flags
		try appendU16(&buf, allocator, method); // compression method
		try appendU16(&buf, allocator, 0); // mod time
		try appendU16(&buf, allocator, 0); // mod date
		try appendU32(&buf, allocator, 0); // crc32
		try appendU32(&buf, allocator, @intCast(file_data.len)); // compressed size
		try appendU32(&buf, allocator, @intCast(entry.data.len)); // uncompressed size
		try appendU16(&buf, allocator, @intCast(entry.name.len)); // filename length
		try appendU16(&buf, allocator, 0); // extra field length
		try buf.appendSlice(allocator, entry.name);
		try buf.appendSlice(allocator, file_data);
	}

	// Central directory
	const cd_start: u32 = @intCast(buf.items.len);
	for (entries, 0..) |entry, idx| {
		const method: u16 = if (entry.compressed != null) 8 else 0;
		const file_data = entry.compressed orelse entry.data;

		try buf.appendSlice(allocator, &central_dir_sig);
		try appendU16(&buf, allocator, 20); // version made by
		try appendU16(&buf, allocator, 20); // version needed
		try appendU16(&buf, allocator, 0); // flags
		try appendU16(&buf, allocator, method); // compression method
		try appendU16(&buf, allocator, 0); // mod time
		try appendU16(&buf, allocator, 0); // mod date
		try appendU32(&buf, allocator, 0); // crc32
		try appendU32(&buf, allocator, @intCast(file_data.len)); // compressed size
		try appendU32(&buf, allocator, @intCast(entry.data.len)); // uncompressed size
		try appendU16(&buf, allocator, @intCast(entry.name.len)); // filename length
		try appendU16(&buf, allocator, 0); // extra field length
		try appendU16(&buf, allocator, 0); // comment length
		try appendU16(&buf, allocator, 0); // disk number
		try appendU16(&buf, allocator, 0); // internal attrs
		try appendU32(&buf, allocator, 0); // external attrs
		try appendU32(&buf, allocator, offsets.items[idx]); // local header offset
		try buf.appendSlice(allocator, entry.name);
	}
	const cd_end: u32 = @intCast(buf.items.len);

	// End of Central Directory Record
	try buf.appendSlice(allocator, &eocd_sig);
	try appendU16(&buf, allocator, 0); // disk number
	try appendU16(&buf, allocator, 0); // disk with CD
	try appendU16(&buf, allocator, @intCast(entries.len)); // entries on this disk
	try appendU16(&buf, allocator, @intCast(entries.len)); // total entries
	try appendU32(&buf, allocator, cd_end - cd_start); // CD size
	try appendU32(&buf, allocator, cd_start); // CD offset
	try appendU16(&buf, allocator, 0); // comment length

	return try buf.toOwnedSlice(allocator);
}

fn appendU16(buf: *std.ArrayList(u8), allocator: Allocator, value: u16) !void {
	const bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, value));
	try buf.appendSlice(allocator, &bytes);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: Allocator, value: u32) !void {
	const bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, value));
	try buf.appendSlice(allocator, &bytes);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "extract stored entry from ZIP" {
	const archive = try buildTestZip(testing.allocator, &.{
		.{ .name = "hello.txt", .data = "Hello, World!" },
	});
	defer testing.allocator.free(archive);

	const result = try extractEntry(testing.allocator, archive, "hello.txt");
	defer if (result) |r| testing.allocator.free(r);

	try testing.expect(result != null);
	try testing.expectEqualStrings("Hello, World!", result.?);
}

test "extract deflated entry from ZIP" {
	// Known raw deflate encoding of "Hello world\n" from Zig stdlib tests
	const deflated = &[_]u8{
		0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
		0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
	};
	const archive = try buildTestZip(testing.allocator, &.{
		.{ .name = "data.txt", .data = "Hello world\n", .compressed = deflated },
	});
	defer testing.allocator.free(archive);

	const result = try extractEntry(testing.allocator, archive, "data.txt");
	defer if (result) |r| testing.allocator.free(r);

	try testing.expect(result != null);
	try testing.expectEqualStrings("Hello world\n", result.?);
}

test "list entries returns all names" {
	const archive = try buildTestZip(testing.allocator, &.{
		.{ .name = "a.txt", .data = "aaa" },
		.{ .name = "b.txt", .data = "bbb" },
		.{ .name = "dir/c.txt", .data = "ccc" },
	});
	defer testing.allocator.free(archive);

	const names = try listEntries(testing.allocator, archive);
	defer freeEntryList(testing.allocator, names);

	try testing.expectEqual(@as(usize, 3), names.len);
	try testing.expectEqualStrings("a.txt", names[0]);
	try testing.expectEqualStrings("b.txt", names[1]);
	try testing.expectEqualStrings("dir/c.txt", names[2]);
}

test "missing entry returns null" {
	const archive = try buildTestZip(testing.allocator, &.{
		.{ .name = "exists.txt", .data = "data" },
	});
	defer testing.allocator.free(archive);

	const result = try extractEntry(testing.allocator, archive, "nonexistent.txt");
	try testing.expectEqual(@as(?[]const u8, null), result);
}

test "invalid ZIP returns error" {
	const bad_data = "This is not a ZIP file at all";
	const result = extractEntry(testing.allocator, bad_data, "anything");
	try testing.expectError(ZipError.InvalidZip, result);
}

test "extract multiple entries from same archive" {
	const archive = try buildTestZip(testing.allocator, &.{
		.{ .name = "first.txt", .data = "First file content" },
		.{ .name = "second.txt", .data = "Second file content" },
		.{ .name = "third.txt", .data = "Third file content" },
	});
	defer testing.allocator.free(archive);

	const r1 = (try extractEntry(testing.allocator, archive, "first.txt")).?;
	defer testing.allocator.free(r1);
	try testing.expectEqualStrings("First file content", r1);

	const r2 = (try extractEntry(testing.allocator, archive, "second.txt")).?;
	defer testing.allocator.free(r2);
	try testing.expectEqualStrings("Second file content", r2);

	const r3 = (try extractEntry(testing.allocator, archive, "third.txt")).?;
	defer testing.allocator.free(r3);
	try testing.expectEqualStrings("Third file content", r3);
}

test "extract entry with path separators" {
	const archive = try buildTestZip(testing.allocator, &.{
		.{ .name = "word/document.xml", .data = "<doc>content</doc>" },
		.{ .name = "docProps/core.xml", .data = "<core>meta</core>" },
	});
	defer testing.allocator.free(archive);

	const doc = (try extractEntry(testing.allocator, archive, "word/document.xml")).?;
	defer testing.allocator.free(doc);
	try testing.expectEqualStrings("<doc>content</doc>", doc);

	const core = (try extractEntry(testing.allocator, archive, "docProps/core.xml")).?;
	defer testing.allocator.free(core);
	try testing.expectEqualStrings("<core>meta</core>", core);
}

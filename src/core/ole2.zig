//! OLE2 (Compound Binary File Format) container reader for docscan.
//! Parses the Microsoft Compound Document format used by .doc, .xls, .ppt files.
//! Extracts named streams (e.g., "WordDocument", "0Table", "1Table") from the
//! binary container. Uses FAT chain following to assemble stream data from sectors.
//! Pure computation — no I/O. Receives byte slices, returns parsed structures.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// OLE2 magic number: D0 CF 11 E0 A1 B1 1A E1
pub const ole2_magic = [8]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

/// Special FAT entry values.
pub const FAT_END_OF_CHAIN: u32 = 0xFFFFFFFE;
pub const FAT_FREE_SECTOR: u32 = 0xFFFFFFFF;
pub const FAT_FAT_SECTOR: u32 = 0xFFFFFFFD;
pub const FAT_DIFAT_SECTOR: u32 = 0xFFFFFFFC;

pub const Ole2Error = error{
	InvalidMagic,
	InvalidHeader,
	SectorOverflow,
	StreamNotFound,
	CorruptFAT,
};

/// Parsed OLE2 file header.
pub const Ole2Header = struct {
	sector_size: u32, // typically 512
	mini_sector_size: u32, // typically 64
	fat_sector_count: u32, // number of FAT sectors
	fat_sectors: []const u32, // sector numbers containing the FAT (allocated)
	dir_start: u32, // first directory sector
	mini_fat_start: u32, // first mini FAT sector
	mini_stream_cutoff: u32, // typically 4096
	difat_start: u32, // first DIFAT sector
	difat_count: u32, // number of DIFAT sectors
};

/// A directory entry in the OLE2 container.
pub const DirEntry = struct {
	name: []const u8, // UTF-8 name (allocated)
	object_type: u8, // 1=storage, 2=stream, 5=root
	start_sector: u32,
	size: u32,
};

/// Parse the OLE2 header from the first 512 bytes.
/// The returned fat_sectors slice is allocated and must be freed by the caller.
pub fn parseHeader(allocator: Allocator, data: []const u8) !Ole2Header {
	if (data.len < 512) return Ole2Error.InvalidHeader;

	// Check magic
	if (!std.mem.eql(u8, data[0..8], &ole2_magic)) return Ole2Error.InvalidMagic;

	// Byte order mark at offset 28-29 should be 0xFFFE (little-endian)
	const byte_order = readU16(data, 28);
	if (byte_order != 0xFFFE) return Ole2Error.InvalidHeader;

	// Sector size: 2^(value at offset 30)
	const sector_size_power = readU16(data, 30);
	if (sector_size_power < 7 or sector_size_power > 16) return Ole2Error.InvalidHeader;
	const sector_size: u32 = @as(u32, 1) << @intCast(sector_size_power);

	// Mini sector size: 2^(value at offset 32)
	const mini_sector_size_power = readU16(data, 32);
	const mini_sector_size: u32 = @as(u32, 1) << @intCast(mini_sector_size_power);

	// Total FAT sectors (offset 44)
	const fat_sector_count = readU32(data, 44);

	// Directory start sector (offset 48)
	const dir_start = readU32(data, 48);

	// Mini FAT start sector (offset 60)
	const mini_fat_start = readU32(data, 60);

	// Mini stream cutoff (offset 56) — typically 4096
	const mini_stream_cutoff = readU32(data, 56);

	// DIFAT start sector (offset 68)
	const difat_start = readU32(data, 68);

	// DIFAT count (offset 72)
	const difat_count = readU32(data, 72);

	// Read FAT sector numbers from the header DIFAT (bytes 76..511)
	// Up to 109 entries in the header itself
	const max_header_difat: u32 = 109;
	const count = @min(fat_sector_count, max_header_difat);

	var fat_sectors = try allocator.alloc(u32, count);
	errdefer allocator.free(fat_sectors);

	for (0..count) |i| {
		const offset: usize = 76 + i * 4;
		fat_sectors[i] = readU32(data, offset);
	}

	// If there are more than 109 FAT sectors, we'd need to follow the DIFAT chain.
	// For v1, support up to 109 FAT sectors (covers files up to ~7MB with 512-byte sectors).
	// TODO: Follow DIFAT chain for larger files.

	return Ole2Header{
		.sector_size = sector_size,
		.mini_sector_size = mini_sector_size,
		.fat_sector_count = count,
		.fat_sectors = fat_sectors,
		.dir_start = dir_start,
		.mini_fat_start = mini_fat_start,
		.mini_stream_cutoff = mini_stream_cutoff,
		.difat_start = difat_start,
		.difat_count = difat_count,
	};
}

/// Free an Ole2Header returned by parseHeader.
pub fn freeHeader(allocator: Allocator, header: Ole2Header) void {
	allocator.free(header.fat_sectors);
}

/// Convert a sector number to a byte offset in the file.
/// Sector 0 starts immediately after the 512-byte header.
fn sectorOffset(sector: u32, sector_size: u32) usize {
	return 512 + @as(usize, sector) * @as(usize, sector_size);
}

/// Read the entire FAT table from the file.
/// Returns an allocated slice of u32 FAT entries.
fn readFAT(allocator: Allocator, data: []const u8, header: Ole2Header) ![]u32 {
	const entries_per_sector = header.sector_size / 4;
	const total_entries = header.fat_sector_count * entries_per_sector;

	var fat = try allocator.alloc(u32, total_entries);
	errdefer allocator.free(fat);

	for (0..header.fat_sector_count) |i| {
		const sec = header.fat_sectors[i];
		const offset = sectorOffset(sec, header.sector_size);
		if (offset + header.sector_size > data.len) return Ole2Error.SectorOverflow;

		for (0..entries_per_sector) |j| {
			const entry_offset = offset + j * 4;
			fat[i * entries_per_sector + j] = readU32(data, entry_offset);
		}
	}

	return fat;
}

/// Count the total bytes in a FAT chain by following it to the end.
fn countChainBytes(fat: []const u32, start_sector: u32, sector_size: u32) !u32 {
	var count: u32 = 0;
	var current: u32 = start_sector;
	const max_iterations: usize = fat.len + 1;
	var iterations: usize = 0;

	while (current != FAT_END_OF_CHAIN) {
		iterations += 1;
		if (iterations > max_iterations) return Ole2Error.CorruptFAT;
		if (current >= fat.len) return Ole2Error.CorruptFAT;
		count += 1;
		current = fat[current];
	}

	return count * sector_size;
}

/// Follow a FAT chain starting at a given sector, collecting sector data
/// into a contiguous buffer.
fn readChain(allocator: Allocator, data: []const u8, fat: []const u32, start_sector: u32, sector_size: u32, stream_size: u32) ![]u8 {
	var result = try allocator.alloc(u8, stream_size);
	errdefer allocator.free(result);

	var written: usize = 0;
	var current: u32 = start_sector;
	const max_iterations: usize = fat.len + 1; // safety limit
	var iterations: usize = 0;

	while (current != FAT_END_OF_CHAIN and written < stream_size) {
		iterations += 1;
		if (iterations > max_iterations) return Ole2Error.CorruptFAT;

		const offset = sectorOffset(current, sector_size);
		const to_copy = @min(sector_size, stream_size - @as(u32, @intCast(written)));

		if (offset + to_copy > data.len) return Ole2Error.SectorOverflow;

		@memcpy(result[written..][0..to_copy], data[offset..][0..to_copy]);
		written += to_copy;

		if (current >= fat.len) return Ole2Error.CorruptFAT;
		current = fat[current];
	}

	return result;
}

/// Parse a directory entry from 128 bytes of data.
/// Returns an allocated DirEntry with a UTF-8 name.
fn parseDirEntry(allocator: Allocator, entry_data: []const u8) !?DirEntry {
	if (entry_data.len < 128) return null;

	const object_type = entry_data[66];
	if (object_type == 0) return null; // Empty entry

	// Name: UTF-16LE at bytes 0..63, name size in bytes at offset 64
	const name_size_bytes = readU16(entry_data, 64);
	if (name_size_bytes < 2 or name_size_bytes > 64) return null;

	// Convert UTF-16LE name to UTF-8
	const name_u16_len = (name_size_bytes / 2) - 1; // -1 to skip null terminator
	const name = try utf16leToUtf8(allocator, entry_data[0 .. name_u16_len * 2]);
	errdefer allocator.free(name);

	const start_sector = readU32(entry_data, 116);
	const size = readU32(entry_data, 120);

	return DirEntry{
		.name = name,
		.object_type = object_type,
		.start_sector = start_sector,
		.size = size,
	};
}

/// Read all directory entries from the directory stream.
fn readDirEntries(allocator: Allocator, data: []const u8, fat: []const u32, header: Ole2Header) ![]DirEntry {
	// Read directory chain — follow FAT chain to discover total size
	const chain_size = try countChainBytes(fat, header.dir_start, header.sector_size);
	const dir_data = try readChain(allocator, data, fat, header.dir_start, header.sector_size, chain_size);
	defer allocator.free(dir_data);

	// Each directory entry is 128 bytes.
	const entry_count = dir_data.len / 128;
	var entries = std.ArrayList(DirEntry){};
	errdefer {
		for (entries.items) |e| allocator.free(e.name);
		entries.deinit(allocator);
	}

	for (0..entry_count) |i| {
		const entry_start = i * 128;
		if (entry_start + 128 > dir_data.len) break;
		if (try parseDirEntry(allocator, dir_data[entry_start..][0..128])) |entry| {
			try entries.append(allocator, entry);
		}
	}

	return try entries.toOwnedSlice(allocator);
}

/// Read a named stream from the OLE2 container.
/// Returns null if the stream is not found. Caller owns the returned slice.
pub fn readStream(allocator: Allocator, data: []const u8, header: Ole2Header, stream_name: []const u8) !?[]const u8 {
	const fat = try readFAT(allocator, data, header);
	defer allocator.free(fat);

	const entries = try readDirEntries(allocator, data, fat, header);
	defer {
		for (entries) |e| allocator.free(e.name);
		allocator.free(entries);
	}

	for (entries) |entry| {
		if (std.mem.eql(u8, entry.name, stream_name)) {
			if (entry.size == 0) {
				return try allocator.alloc(u8, 0);
			}
			// For mini streams (size < mini_stream_cutoff), read from mini stream
			// container — but only if a mini FAT actually exists.
			if (entry.size < header.mini_stream_cutoff and entry.object_type == 2 and
				header.mini_fat_start != FAT_END_OF_CHAIN)
			{
				return try readMiniStream(allocator, data, fat, entries, header, entry);
			}
			return try readChain(allocator, data, fat, entry.start_sector, header.sector_size, entry.size);
		}
	}

	return null;
}

/// Read a stream that's stored in the mini stream (size < mini_stream_cutoff).
/// Mini streams are stored in the root entry's data, with a separate mini FAT.
fn readMiniStream(
	allocator: Allocator,
	data: []const u8,
	fat: []const u32,
	entries: []const DirEntry,
	header: Ole2Header,
	stream_entry: DirEntry,
) ![]u8 {
	// The root entry's stream data IS the mini stream container
	const root_entry = for (entries) |e| {
		if (e.object_type == 5) break e;
	} else return Ole2Error.CorruptFAT;

	// Read the root entry's full data (the mini stream container)
	const mini_stream_data = try readChain(allocator, data, fat, root_entry.start_sector, header.sector_size, root_entry.size);
	defer allocator.free(mini_stream_data);

	// Read the mini FAT
	if (header.mini_fat_start == FAT_END_OF_CHAIN) return Ole2Error.CorruptFAT;
	const mini_fat_data = try readChain(allocator, data, fat, header.mini_fat_start, header.sector_size, header.sector_size);
	defer allocator.free(mini_fat_data);

	const mini_fat_entries_count = mini_fat_data.len / 4;
	var mini_fat = try allocator.alloc(u32, mini_fat_entries_count);
	defer allocator.free(mini_fat);
	for (0..mini_fat_entries_count) |i| {
		mini_fat[i] = readU32(mini_fat_data, i * 4);
	}

	// Follow mini FAT chain, reading from mini stream container
	var result = try allocator.alloc(u8, stream_entry.size);
	errdefer allocator.free(result);

	var written: usize = 0;
	var current: u32 = stream_entry.start_sector;
	const max_iter = mini_fat_entries_count + 1;
	var iter: usize = 0;

	while (current != FAT_END_OF_CHAIN and written < stream_entry.size) {
		iter += 1;
		if (iter > max_iter) return Ole2Error.CorruptFAT;

		const mini_offset: usize = @as(usize, current) * @as(usize, header.mini_sector_size);
		const to_copy = @min(header.mini_sector_size, stream_entry.size - @as(u32, @intCast(written)));

		if (mini_offset + to_copy > mini_stream_data.len) return Ole2Error.SectorOverflow;

		@memcpy(result[written..][0..to_copy], mini_stream_data[mini_offset..][0..to_copy]);
		written += to_copy;

		if (current >= mini_fat_entries_count) return Ole2Error.CorruptFAT;
		current = mini_fat[current];
	}

	return result;
}

/// List all stream names in the OLE2 container.
/// Caller owns the returned slice and each name string; free with freeStreamList.
pub fn listStreams(allocator: Allocator, data: []const u8, header: Ole2Header) ![][]const u8 {
	const fat = try readFAT(allocator, data, header);
	defer allocator.free(fat);

	const entries = try readDirEntries(allocator, data, fat, header);
	defer {
		for (entries) |e| allocator.free(e.name);
		allocator.free(entries);
	}

	var names = std.ArrayList([]const u8){};
	errdefer {
		for (names.items) |n| allocator.free(n);
		names.deinit(allocator);
	}

	for (entries) |entry| {
		if (entry.object_type == 2) { // streams only
			const name_copy = try allocator.dupe(u8, entry.name);
			try names.append(allocator, name_copy);
		}
	}

	return try names.toOwnedSlice(allocator);
}

/// Free a stream name list returned by listStreams.
pub fn freeStreamList(allocator: Allocator, list: [][]const u8) void {
	for (list) |name| allocator.free(name);
	allocator.free(list);
}

// ── Utility functions ─────────────────────────────────────────────────

/// Read a little-endian u16 from a byte slice at the given offset.
fn readU16(data: []const u8, offset: usize) u16 {
	return std.mem.readInt(u16, data[offset..][0..2], .little);
}

/// Read a little-endian u32 from a byte slice at the given offset.
fn readU32(data: []const u8, offset: usize) u32 {
	return std.mem.readInt(u32, data[offset..][0..4], .little);
}

/// Convert a UTF-16LE byte slice to a UTF-8 string.
/// Caller owns the returned slice.
pub fn utf16leToUtf8(allocator: Allocator, utf16_bytes: []const u8) ![]const u8 {
	const len = utf16_bytes.len / 2;
	var buf = std.ArrayList(u8){};
	errdefer buf.deinit(allocator);

	var i: usize = 0;
	while (i < len) : (i += 1) {
		const code_unit: u16 = std.mem.readInt(u16, utf16_bytes[i * 2 ..][0..2], .little);

		// Handle surrogate pairs
		if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
			// High surrogate
			if (i + 1 < len) {
				const low: u16 = std.mem.readInt(u16, utf16_bytes[(i + 1) * 2 ..][0..2], .little);
				if (low >= 0xDC00 and low <= 0xDFFF) {
					const codepoint: u21 = @intCast((@as(u32, code_unit - 0xD800) << 10) + @as(u32, low - 0xDC00) + 0x10000);
					var utf8_buf: [4]u8 = undefined;
					const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
					try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
					i += 1;
					continue;
				}
			}
			continue; // Invalid surrogate pair, skip
		}

		// Regular BMP character
		const codepoint: u21 = @intCast(code_unit);
		var utf8_buf: [4]u8 = undefined;
		const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
		try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
	}

	return try buf.toOwnedSlice(allocator);
}

// ── Test OLE2 file builder ────────────────────────────────────────────

/// Build a minimal OLE2 file containing a single named stream with the given content.
/// Used for testing. The structure:
///   Sector 0: FAT sector (self-referencing + directory chain + data chain)
///   Sector 1: Directory sector (root entry + stream entry)
///   Sector 2+: Data sectors for the stream content
pub fn buildTestOle2(allocator: Allocator, stream_name: []const u8, stream_data: []const u8) ![]u8 {
	const sector_size: u32 = 512;
	const entries_per_sector = sector_size / 4;

	// Calculate how many data sectors we need
	const data_sectors = if (stream_data.len == 0)
		@as(u32, 0)
	else
		@as(u32, @intCast((stream_data.len + sector_size - 1) / sector_size));

	// Layout:
	//   Header:  bytes 0..511
	//   Sector 0: FAT sector
	//   Sector 1: Directory sector
	//   Sector 2..2+data_sectors-1: Data sectors
	const total_sectors = 2 + data_sectors;
	const file_size = 512 + @as(usize, total_sectors) * sector_size;

	var buf = try allocator.alloc(u8, file_size);
	errdefer allocator.free(buf);
	@memset(buf, 0);

	// ── Header (512 bytes) ──

	// Magic
	@memcpy(buf[0..8], &ole2_magic);

	// Minor version (offset 24): 0x003E
	std.mem.writeInt(u16, buf[24..26], 0x003E, .little);
	// Major version (offset 26): 0x0003
	std.mem.writeInt(u16, buf[26..28], 0x0003, .little);
	// Byte order (offset 28): 0xFFFE (little-endian)
	std.mem.writeInt(u16, buf[28..30], 0xFFFE, .little);
	// Sector size power (offset 30): 9 → 512 bytes
	std.mem.writeInt(u16, buf[30..32], 9, .little);
	// Mini sector size power (offset 32): 6 → 64 bytes
	std.mem.writeInt(u16, buf[32..34], 6, .little);

	// Total FAT sectors (offset 44): 1
	std.mem.writeInt(u32, buf[44..48], 1, .little);
	// Directory first sector (offset 48): sector 1
	std.mem.writeInt(u32, buf[48..52], 1, .little);
	// Mini stream cutoff (offset 56): 4096
	std.mem.writeInt(u32, buf[56..60], 4096, .little);
	// Mini FAT first sector (offset 60): end of chain (no mini FAT)
	std.mem.writeInt(u32, buf[60..64], FAT_END_OF_CHAIN, .little);
	// Mini FAT sector count (offset 64): 0
	std.mem.writeInt(u32, buf[64..68], 0, .little);
	// DIFAT first sector (offset 68): end of chain
	std.mem.writeInt(u32, buf[68..72], FAT_END_OF_CHAIN, .little);
	// DIFAT sector count (offset 72): 0
	std.mem.writeInt(u32, buf[72..76], 0, .little);

	// First DIFAT entry (offset 76): sector 0 is the FAT sector
	std.mem.writeInt(u32, buf[76..80], 0, .little);
	// Fill remaining 108 DIFAT entries with FREE
	for (1..109) |i| {
		std.mem.writeInt(u32, buf[80 + (i - 1) * 4 ..][0..4], FAT_FREE_SECTOR, .little);
	}

	// ── Sector 0: FAT ──
	const fat_offset: usize = 512;

	// Sector 0: FAT sector marker
	std.mem.writeInt(u32, buf[fat_offset..][0..4], FAT_FAT_SECTOR, .little);
	// Sector 1: Directory — end of chain
	std.mem.writeInt(u32, buf[fat_offset + 4 ..][0..4], FAT_END_OF_CHAIN, .little);

	// Data sectors: chain them together
	for (0..data_sectors) |i| {
		const fat_entry_offset = fat_offset + (2 + i) * 4;
		if (i + 1 < data_sectors) {
			// Point to next data sector
			std.mem.writeInt(u32, buf[fat_entry_offset..][0..4], @intCast(3 + i), .little);
		} else {
			// Last data sector: end of chain
			std.mem.writeInt(u32, buf[fat_entry_offset..][0..4], FAT_END_OF_CHAIN, .little);
		}
	}

	// Fill remaining FAT entries with FREE
	for ((2 + data_sectors)..entries_per_sector) |i| {
		const fat_entry_offset = fat_offset + i * 4;
		std.mem.writeInt(u32, buf[fat_entry_offset..][0..4], FAT_FREE_SECTOR, .little);
	}

	// ── Sector 1: Directory ──
	const dir_offset: usize = 512 + sector_size;

	// Root entry (128 bytes)
	try writeDirEntry(buf[dir_offset..][0..128], "Root Entry", 5, 0, 0);

	// Stream entry (128 bytes)
	const stream_start_sector: u32 = if (data_sectors > 0) 2 else 0;
	try writeDirEntry(buf[dir_offset + 128 ..][0..128], stream_name, 2, stream_start_sector, @intCast(stream_data.len));

	// ── Data sectors ──
	if (data_sectors > 0) {
		const data_start: usize = 512 + 2 * sector_size;
		const to_copy = @min(stream_data.len, @as(usize, data_sectors) * sector_size);
		@memcpy(buf[data_start..][0..to_copy], stream_data[0..to_copy]);
	}

	return buf;
}

/// Write a directory entry at the given 128-byte location.
fn writeDirEntry(dest: *[128]u8, name: []const u8, object_type: u8, start_sector: u32, size: u32) !void {
	@memset(dest, 0);

	// Name as UTF-16LE (including null terminator)
	const name_chars = @min(name.len, 31); // max 31 chars + null
	for (0..name_chars) |i| {
		dest[i * 2] = name[i];
		dest[i * 2 + 1] = 0;
	}
	// Null terminator
	dest[name_chars * 2] = 0;
	dest[name_chars * 2 + 1] = 0;

	// Name size in bytes (including null terminator)
	const name_size: u16 = @intCast((name_chars + 1) * 2);
	std.mem.writeInt(u16, dest[64..66], name_size, .little);

	// Object type
	dest[66] = object_type;

	// Color: black (0) — for red-black tree
	dest[67] = 1; // red

	// Left/right/child SIDs: all 0xFFFFFFFF (none)
	std.mem.writeInt(u32, dest[68..72], 0xFFFFFFFF, .little);
	std.mem.writeInt(u32, dest[72..76], 0xFFFFFFFF, .little);
	std.mem.writeInt(u32, dest[76..80], 0xFFFFFFFF, .little);

	// Start sector
	std.mem.writeInt(u32, dest[116..120], start_sector, .little);

	// Size
	std.mem.writeInt(u32, dest[120..124], size, .little);
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "OLE2: parse header — verify sector size and FAT sector count" {
	const ole2 = try buildTestOle2(testing.allocator, "TestStream", "Hello, OLE2!");
	defer testing.allocator.free(ole2);

	const header = try parseHeader(testing.allocator, ole2);
	defer freeHeader(testing.allocator, header);

	try testing.expectEqual(@as(u32, 512), header.sector_size);
	try testing.expectEqual(@as(u32, 64), header.mini_sector_size);
	try testing.expectEqual(@as(u32, 1), header.fat_sector_count);
	try testing.expectEqual(@as(u32, 1), header.dir_start);
}

test "OLE2: read stream — extract named stream content" {
	const test_data = "Hello, OLE2! This is test stream content.";
	const ole2 = try buildTestOle2(testing.allocator, "TestStream", test_data);
	defer testing.allocator.free(ole2);

	const header = try parseHeader(testing.allocator, ole2);
	defer freeHeader(testing.allocator, header);

	const stream = try readStream(testing.allocator, ole2, header, "TestStream");
	try testing.expect(stream != null);
	defer testing.allocator.free(stream.?);

	try testing.expectEqualStrings(test_data, stream.?);
}

test "OLE2: missing stream returns null" {
	const ole2 = try buildTestOle2(testing.allocator, "TestStream", "data");
	defer testing.allocator.free(ole2);

	const header = try parseHeader(testing.allocator, ole2);
	defer freeHeader(testing.allocator, header);

	const stream = try readStream(testing.allocator, ole2, header, "NonExistent");
	try testing.expectEqual(@as(?[]const u8, null), stream);
}

test "OLE2: invalid magic returns error" {
	var bad_data = [_]u8{0} ** 512;
	bad_data[0] = 0xFF; // Wrong magic

	const result = parseHeader(testing.allocator, &bad_data);
	try testing.expectError(Ole2Error.InvalidMagic, result);
}

test "OLE2: list streams — verify stream names" {
	const ole2 = try buildTestOle2(testing.allocator, "WordDocument", "some content");
	defer testing.allocator.free(ole2);

	const header = try parseHeader(testing.allocator, ole2);
	defer freeHeader(testing.allocator, header);

	const streams = try listStreams(testing.allocator, ole2, header);
	defer freeStreamList(testing.allocator, streams);

	// Should contain our stream (root entry is a storage, not listed)
	try testing.expectEqual(@as(usize, 1), streams.len);
	try testing.expectEqualStrings("WordDocument", streams[0]);
}

test "OLE2: data too short for header" {
	var short_data = [_]u8{0} ** 100;
	const result = parseHeader(testing.allocator, &short_data);
	try testing.expectError(Ole2Error.InvalidHeader, result);
}

test "OLE2: UTF-16LE to UTF-8 conversion" {
	// "Hello" in UTF-16LE
	const utf16 = [_]u8{
		'H', 0, 'e', 0, 'l', 0, 'l', 0, 'o', 0,
	};
	const result = try utf16leToUtf8(testing.allocator, &utf16);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings("Hello", result);
}

test "OLE2: UTF-16LE conversion with non-ASCII" {
	// "é" is U+00E9, in UTF-16LE: 0xE9, 0x00
	const utf16 = [_]u8{ 0xE9, 0x00 };
	const result = try utf16leToUtf8(testing.allocator, &utf16);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings("\xC3\xA9", result); // é in UTF-8
}

test "OLE2: multi-sector stream" {
	// Create data larger than one sector (512 bytes)
	var big_data: [1200]u8 = undefined;
	for (&big_data, 0..) |*b, i| {
		b.* = @intCast(i % 256);
	}

	const ole2 = try buildTestOle2(testing.allocator, "BigStream", &big_data);
	defer testing.allocator.free(ole2);

	const header = try parseHeader(testing.allocator, ole2);
	defer freeHeader(testing.allocator, header);

	const stream = try readStream(testing.allocator, ole2, header, "BigStream");
	try testing.expect(stream != null);
	defer testing.allocator.free(stream.?);

	try testing.expectEqual(@as(usize, 1200), stream.?.len);
	try testing.expectEqualSlices(u8, &big_data, stream.?);
}

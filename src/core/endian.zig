//! Little-endian integer readers shared by the binary-format parsers
//! (OLE2 / ZIP / .doc). Thin wrappers over `std.mem.readInt` that keep call
//! sites terse while naming the endianness in exactly one place.
const std = @import("std");

/// Read a little-endian u16 from a byte slice at the given offset.
pub fn readU16(data: []const u8, offset: usize) u16 {
	return std.mem.readInt(u16, data[offset..][0..2], .little);
}

/// Read a little-endian u32 from a byte slice at the given offset.
pub fn readU32(data: []const u8, offset: usize) u32 {
	return std.mem.readInt(u32, data[offset..][0..4], .little);
}

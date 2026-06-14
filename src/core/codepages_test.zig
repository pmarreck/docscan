//! MFIC differential test: every single-byte conversion path in encoding.zig
//! (the codepages.zig tables + WINDOWS-1252/ISO-8859-1) is checked, byte by byte,
//! against an INDEPENDENT oracle — GNU/Apple `iconv` — captured offline in
//! fixtures/codepages_iconv_oracle.tsv by tools/gen_codepages.sh.
//!
//! Why this is MFIC, not a rubber stamp: the embedded tables are written
//! mechanically from the Unicode Consortium MAPPINGS files (VISCII from perl's
//! Encode); the oracle is iconv. Generator != checker — two independent
//! authorities. The sweep is Mechanical (all 256 bytes × 22 charsets), the
//! oracle is Independent (Apple libiconv, not the producer), it is Falsifiable
//! (any single-byte disagreement fails the build), and it is a Control wired
//! into `./test`. The fixture is committed so the gate is hermetic — no iconv or
//! network at test time. (MAC-ROMAN is excluded; see tools/gen_codepages.sh.)

const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding.zig");

/// iconv's independent view of all supported single-byte charsets (see header).
const oracle = @embedFile("fixtures/codepages_iconv_oracle.tsv");

test "codepages: every byte of every single-byte charset matches the iconv oracle" {
    var lines = std.mem.splitScalar(u8, oracle, '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const byte_hex = fields.next() orelse continue;
        const cp_hex = fields.next() orelse continue;

        const byte = try std.fmt.parseInt(u8, byte_hex, 16);
        const cp = try std.fmt.parseInt(u21, cp_hex, 16);

        const input = [_]u8{byte};
        const got = try encoding.toUtf8(testing.allocator, &input, name);
        defer testing.allocator.free(got);

        if (cp == 0xFFFD) {
            // Byte undefined in the source charset → toUtf8 drops it (== iconv //IGNORE).
            testing.expectEqual(@as(usize, 0), got.len) catch |e| {
                std.debug.print("\nFFFD mismatch: {s} byte 0x{s} expected drop, got {d} byte(s)\n", .{ name, byte_hex, got.len });
                return e;
            };
        } else {
            var want: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &want) catch unreachable;
            testing.expectEqualStrings(want[0..n], got) catch |e| {
                std.debug.print("\nmismatch: {s} byte 0x{s} expected U+{s}\n", .{ name, byte_hex, cp_hex });
                return e;
            };
        }
        checked += 1;
    }
    // Guard against a vacuous pass (truncated/empty fixture): 22 charsets × 256.
    try testing.expect(checked >= 5000);
}

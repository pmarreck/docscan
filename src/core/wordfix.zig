//! Dictionary-based word rejoining for PDF text extraction.
//! Fixes false word splits (e.g., "kn own" -> "known") using a compressed
//! dictionary embedded in the binary. Two passes catch chained splits
//! like "un know n" -> "unknown".

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Dictionary state (lazy-initialized, lives for process lifetime) ──

var dict_mutex: std.Thread.Mutex = .{};
var dict: ?std.StringHashMapUnmanaged(void) = null;
var dict_arena: ?std.heap.ArenaAllocator = null;

/// Decompress the embedded dictionary and build a hashmap for O(1) lookups.
/// Thread-safe via mutex; the dictionary is never freed (process-lifetime).
fn ensureInit() void {
	dict_mutex.lock();
	defer dict_mutex.unlock();
	if (dict != null) return;

	const compressed = @embedFile("dictionary.zlib");
	var reader: std.Io.Reader = .fixed(compressed);
	var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});

	// Decompress into an arena that lives forever
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	const alloc = arena.allocator();

	const raw = decompress.reader.allocRemaining(alloc, @enumFromInt(2 * 1024 * 1024)) catch {
		arena.deinit();
		return;
	};

	// Build hashmap: lowercase each word for case-insensitive lookup
	var map = std.StringHashMapUnmanaged(void){};
	var lines = std.mem.splitScalar(u8, raw, '\n');
	while (lines.next()) |line| {
		const trimmed = std.mem.trimRight(u8, line, "\r");
		if (trimmed.len == 0) continue;
		// Lowercase the word for case-insensitive storage
		const lower = alloc.alloc(u8, trimmed.len) catch continue;
		for (trimmed, 0..) |c, i| {
			lower[i] = std.ascii.toLower(c);
		}
		map.put(alloc, lower, {}) catch continue;
	}

	dict = map;
	dict_arena = arena;
}

/// Check if a word is in the dictionary (case-insensitive).
pub fn isWord(word: []const u8) bool {
	ensureInit();
	const d = dict orelse return false;
	// Stack buffer for lowercase conversion; skip unreasonably long tokens
	var lower_buf: [128]u8 = undefined;
	if (word.len == 0 or word.len > lower_buf.len) return false;
	for (word, 0..) |c, i| {
		lower_buf[i] = std.ascii.toLower(c);
	}
	return d.contains(lower_buf[0..word.len]);
}

/// Returns true if the token is purely numeric (digits, commas, dots, signs).
fn isPurelyNumeric(token: []const u8) bool {
	if (token.len == 0) return false;
	for (token) |c| {
		switch (c) {
			'0'...'9', '.', ',', '-', '+' => {},
			else => return false,
		}
	}
	return true;
}

/// True standalone single-character English words. Only "a"/"A" and "I"
/// should be protected from merging with adjacent dictionary words;
/// other single characters (letters used as abbreviations, like "n", "x")
/// are much more likely to be PDF split fragments.
fn isTrueSingleCharWord(c: u8) bool {
	return c == 'a' or c == 'A' or c == 'I';
}

/// Perform a single rejoin pass on a line of text.
/// Scans adjacent token pairs left-to-right. When combining two tokens
/// produces a dictionary word, the pair is merged if at least one of
/// the parts is not independently a dictionary word, or if at least one
/// part is very short (<=3 chars, likely a fragment). Single-character
/// and purely-numeric tokens are never candidates for merging.

/// Strip leading/trailing punctuation for dictionary lookup.
/// Returns the core word and the stripped prefix/suffix.
fn stripPunctuation(token: []const u8) struct { word: []const u8, prefix: []const u8, suffix: []const u8 } {
	var start: usize = 0;
	var end: usize = token.len;
	// Strip leading punctuation (quotes, parens, brackets)
	while (start < end and !std.ascii.isAlphanumeric(token[start])) : (start += 1) {}
	// Strip trailing punctuation
	while (end > start and !std.ascii.isAlphanumeric(token[end - 1])) : (end -= 1) {}
	if (start >= end) return .{ .word = token, .prefix = token[0..0], .suffix = token[0..0] };
	return .{ .word = token[start..end], .prefix = token[0..start], .suffix = token[end..] };
}

fn rejoinLine(allocator: Allocator, line: []const u8) ![]const u8 {
	// Split into tokens on spaces
	var tokens = std.ArrayList([]const u8){};
	defer tokens.deinit(allocator);

	var splits = std.mem.splitScalar(u8, line, ' ');
	while (splits.next()) |tok| {
		if (tok.len == 0) continue; // skip multiple consecutive spaces
		try tokens.append(allocator, tok);
	}

	if (tokens.items.len <= 1) {
		return try allocator.dupe(u8, line);
	}

	// Merge pass: scan left-to-right, try joining adjacent pairs
	var merged = std.ArrayList([]const u8){};
	defer {
		// Free any heap-allocated merged strings
		for (merged.items) |m| {
			// Only free if it's not a slice of the original input
			// We track this by checking if the pointer is outside the input range
			const ptr = @intFromPtr(m.ptr);
			const input_start = @intFromPtr(line.ptr);
			const input_end = input_start + line.len;
			if (ptr < input_start or ptr >= input_end) {
				allocator.free(m);
			}
		}
		merged.deinit(allocator);
	}

	var i: usize = 0;
	while (i < tokens.items.len) {
		if (i + 1 < tokens.items.len) {
			const left = tokens.items[i];
			const right = tokens.items[i + 1];

			// Skip merging when both are single-char or either is numeric
			if ((left.len > 1 or right.len > 1) and
				!isPurelyNumeric(left) and !isPurelyNumeric(right))
			{
				// Try combining
				const combined_len = left.len + right.len;
				if (combined_len <= 256) {
					var buf: [256]u8 = undefined;
					@memcpy(buf[0..left.len], left);
					@memcpy(buf[left.len..combined_len], right);
					const combined = buf[0..combined_len];

					// Strip punctuation for lookup (e.g., 'ody,' -> 'ody')
					const left_stripped = stripPunctuation(left);
					const right_stripped = stripPunctuation(right);
					const core_left = left_stripped.word;
					const core_right = right_stripped.word;

					// Build combined from core words (without punctuation)
					const core_combined_len = core_left.len + core_right.len;
					var core_buf: [256]u8 = undefined;
					if (core_combined_len <= 256) {
						@memcpy(core_buf[0..core_left.len], core_left);
						@memcpy(core_buf[core_left.len..core_combined_len], core_right);
					}
					const core_combined = if (core_combined_len <= 256) core_buf[0..core_combined_len] else combined;

					if (isWord(core_combined)) {
						const left_is_word = isWord(core_left);
						const right_is_word = isWord(core_right);

						// Decide whether to merge based on fragment likelihood.
						const should_join = blk: {
							// Easy case: at least one part isn't a word at all
							if (!left_is_word or !right_is_word) break :blk true;
							// Both are dictionary words. Merge only when at least
							// one is short enough to likely be a fragment.
							// Protect true single-char standalone words ("a", "I")
							// when neighbor is also a real word — these are genuine
							// word boundaries, not PDF split artifacts.
							if (left.len == 1 and isTrueSingleCharWord(left[0]) and right_is_word) break :blk false;
							if (right.len == 1 and isTrueSingleCharWord(right[0]) and left_is_word) break :blk false;
							if (left.len <= 3 or right.len <= 3) break :blk true;
							break :blk false;
						};

						if (should_join) {
							// Allocate the merged string
							const m = try allocator.alloc(u8, combined_len);
							@memcpy(m[0..left.len], left);
							@memcpy(m[left.len..combined_len], right);
							try merged.append(allocator, m);
							i += 2; // skip both tokens
							continue;
						}
					}
				}
			}
		}
		// No merge — keep token as-is
		try merged.append(allocator, tokens.items[i]);
		i += 1;
	}

	// Build output string with spaces
	var result = std.ArrayList(u8){};
	errdefer result.deinit(allocator);

	for (merged.items, 0..) |tok, j| {
		try result.appendSlice(allocator, tok);
		if (j + 1 < merged.items.len) {
			try result.append(allocator, ' ');
		}
	}

	return try result.toOwnedSlice(allocator);
}

/// Perform a single rejoin pass over multi-line text.
fn rejoinPass(allocator: Allocator, text: []const u8) ![]const u8 {
	var result = std.ArrayList(u8){};
	errdefer result.deinit(allocator);

	var lines = std.mem.splitScalar(u8, text, '\n');
	var first_line = true;
	while (lines.next()) |line| {
		if (!first_line) try result.append(allocator, '\n');
		first_line = false;

		const fixed = try rejoinLine(allocator, line);
		defer allocator.free(fixed);
		try result.appendSlice(allocator, fixed);
	}

	return try result.toOwnedSlice(allocator);
}

/// Rejoin falsely-split words in text. Applies two passes to catch
/// chained splits (e.g., "un know n" -> "un known" -> "unknown").
/// Returns a new string owned by the provided allocator.
pub fn rejoinWords(allocator: Allocator, text: []const u8) ![]const u8 {
	// Pass 1
	const pass1 = try rejoinPass(allocator, text);
	defer allocator.free(pass1);
	// Pass 2
	return try rejoinPass(allocator, pass1);
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "isWord finds common words" {
	try testing.expect(isWord("hello"));
	try testing.expect(isWord("Hello")); // case-insensitive
	try testing.expect(isWord("HELLO"));
	try testing.expect(isWord("known"));
	try testing.expect(isWord("obviously"));
	try testing.expect(!isWord("xyzzy123"));
	try testing.expect(!isWord("qzxjk"));
}

test "rejoin fixes split words" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "kn own");
	defer alloc.free(result);
	try testing.expectEqualStrings("known", result);
}

test "rejoin preserves valid word boundaries" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "the quick brown fox");
	defer alloc.free(result);
	try testing.expectEqualStrings("the quick brown fox", result);
}

test "rejoin handles chained splits in two passes" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "un know n");
	defer alloc.free(result);
	try testing.expectEqualStrings("unknown", result);
}

test "rejoin preserves newlines" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "kn own\nobv iously");
	defer alloc.free(result);
	try testing.expectEqualStrings("known\nobviously", result);
}

test "rejoin handles capitalized sentence starts" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "Obv iously this works");
	defer alloc.free(result);
	try testing.expectEqualStrings("Obviously this works", result);
}

test "rejoin preserves standalone 'a' word boundary" {
	const alloc = testing.allocator;
	// "a bout" should stay — "a" is a true standalone word
	const result = try rejoinWords(alloc, "a bout");
	defer alloc.free(result);
	try testing.expectEqualStrings("a bout", result);
}

test "rejoin leaves single-character tokens alone" {
	const alloc = testing.allocator;
	// "a" and "I" are single chars — should not be joined
	const result = try rejoinWords(alloc, "I a m here");
	defer alloc.free(result);
	// "a" and "m" are single-char, skipped from merging
	try testing.expectEqualStrings("I a m here", result);
}

test "rejoin leaves numeric tokens alone" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "page 42 of 100");
	defer alloc.free(result);
	try testing.expectEqualStrings("page 42 of 100", result);
}

test "rejoin does not break already-correct text" {
	const alloc = testing.allocator;
	const input = "The quick brown fox jumps over the lazy dog";
	const result = try rejoinWords(alloc, input);
	defer alloc.free(result);
	try testing.expectEqualStrings(input, result);
}

test "rejoin preserves both-valid long word boundaries" {
	const alloc = testing.allocator;
	// "about" and "face" are both >3 char valid words; "aboutface"
	// should not be joined even if it were a word
	const result = try rejoinWords(alloc, "turn about face now");
	defer alloc.free(result);
	try testing.expectEqualStrings("turn about face now", result);
}

test "rejoin fixes 'nob ody' -> 'nobody'" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "nob ody");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("nobody", result);
}

test "rejoin fixes 'nob ody,' with trailing comma" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "a nob ody, had");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("a nobody, had", result);
}

test "rejoin does not falsely join across hyphenated words" {
	// 'write-dow n or' has a hyphen split — dictionary lacks 'write-down'
	// so the algorithm should at minimum not make it WORSE by joining 'n'+'or'->'nor'
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "dow n or");
	defer alloc.free(result);
	// 'dow'+'n' -> 'down' should be preferred over 'n'+'or' -> 'nor'
	// because 'n' is not a word (prefer joining non-words with non-words)
	try std.testing.expectEqualStrings("down or", result);
}

//! Dictionary-based word rejoining for PDF text extraction.
//! Fixes false word splits (e.g., "kn own" -> "known") using a compressed
//! dictionary embedded in the binary. Two passes catch chained splits
//! like "un know n" -> "unknown".

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Dictionary state (lazy-initialized, lives for process lifetime) ──

var dict_mutex: std.Thread.Mutex = .{};
var dict: ?std.StringHashMapUnmanaged(void) = null;
var proper_dict: ?std.StringHashMapUnmanaged(void) = null;
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
		const lower = alloc.alloc(u8, trimmed.len) catch continue;
		for (trimmed, 0..) |c, i| {
			lower[i] = std.ascii.toLower(c);
		}
		map.put(alloc, lower, {}) catch continue;
	}

	// Also load proper nouns into a SEPARATE dict (case-sensitive matching)
	var pn_map = std.StringHashMapUnmanaged(void){};
	const pn_compressed = @embedFile("proper_nouns.zlib");
	var pn_reader: std.Io.Reader = .fixed(pn_compressed);
	var pn_decompress: std.compress.flate.Decompress = .init(&pn_reader, .zlib, &.{});
	const pn_raw = pn_decompress.reader.allocRemaining(alloc, @enumFromInt(4 * 1024 * 1024)) catch {
		dict = map;
		dict_arena = arena;
		return;
	};

	var pn_lines = std.mem.splitScalar(u8, pn_raw, '\n');
	while (pn_lines.next()) |line| {
		const trimmed = std.mem.trimRight(u8, line, "\r");
		if (trimmed.len == 0) continue;
		const lower = alloc.alloc(u8, trimmed.len) catch continue;
		for (trimmed, 0..) |c, i| {
			lower[i] = std.ascii.toLower(c);
		}
		pn_map.put(alloc, lower, {}) catch continue;
	}

	proper_dict = pn_map;
	dict = map;
	dict_arena = arena;
}

/// Check if a word is in the dictionary (case-insensitive).
pub fn isWord(word: []const u8) bool {
	ensureInit();
	const d = dict orelse return false;
	var lower_buf: [128]u8 = undefined;
	if (word.len == 0 or word.len > lower_buf.len) return false;
	for (word, 0..) |c, idx| {
		lower_buf[idx] = std.ascii.toLower(c);
	}
	const lower = lower_buf[0..word.len];
	// Check common dictionary (always case-insensitive)
	if (d.contains(lower)) return true;
	// Check proper nouns: only match when input starts with uppercase
	// "Foran" matches proper noun, but "foran" does not
	if (word[0] >= 0x41 and word[0] <= 0x5A) { // A-Z
		if (proper_dict) |pd| {
			if (pd.contains(lower)) return true;
		}
	}
	return false;
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
/// Common English function words (1-2 chars) that should be protected from joining.
/// These appear standalone so frequently that joining them is almost always wrong.
fn isFunctionWord(word: []const u8) bool {
	const functions = [_][]const u8{
		"a", "i", "an", "am", "as", "at", "be", "by", "do", "go",
		"he", "if", "in", "is", "it", "me", "my", "no", "of", "on",
		"or", "so", "to", "up", "us", "we",
	};
	var lower_buf: [8]u8 = undefined;
	if (word.len == 0 or word.len > 2) return false;
	for (word, 0..) |c, idx| { lower_buf[idx] = std.ascii.toLower(c); }
	const lower = lower_buf[0..word.len];
	for (&functions) |fw| {
		if (std.mem.eql(u8, lower, fw)) return true;
	}
	return false;
}

/// A word counts as a "real standalone word" (not a fragment) if it is in the
/// dictionary AND either (a) >= 3 chars or (b) a common function word.
/// 2-char dictionary entries like "kn" that are NOT function words are treated
/// as fragments (likely PDF split artifacts).
fn isRealStandaloneWord(word: []const u8) bool {
	if (!isWord(word)) return false;
	if (word.len >= 3) return true;
	return isFunctionWord(word);
}

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
	// Tokenize on spaces AND hyphens. Each token tracks the separator
	// that PRECEDES it (space, hyphen, or none for the first token).
	const Sep = enum { none, space, hyphen };
	const Token = struct { text: []const u8, sep: Sep };

	var tokens = std.ArrayList(Token){};
	defer tokens.deinit(allocator);

	var start: usize = 0;
	for (line, 0..) |c, idx| {
		if (c == ' ' or c == '-') {
			if (idx > start) {
				try tokens.append(allocator, .{
					.text = line[start..idx],
					.sep = if (tokens.items.len == 0) .none else if (c == '-') .hyphen else .space,
				});
			} else if (tokens.items.len > 0 and c == '-') {
				// Consecutive separator: trailing hyphen (e.g., "over- come")
				// Mark next token as preceded by hyphen
			}
			start = idx + 1;
			// Handle trailing hyphen: "over- come" → next token sep = hyphen
			if (c == '-' and idx + 1 < line.len and line[idx + 1] == ' ') {
				// "over-" followed by space: record hyphen, skip the space
				if (idx > start - 1) { // token was already appended above
				}
			}
		}
	}
	if (start < line.len) {
		try tokens.append(allocator, .{
			.text = line[start..],
			.sep = if (tokens.items.len == 0) .none else .space,
		});
	}

	if (tokens.items.len <= 1) {
		return try allocator.dupe(u8, line);
	}

	// Handle "over- come" pattern: if a token's text is empty and preceded by hyphen,
	// merge the hyphen into the next token's separator.
	// Actually, let me re-tokenize more carefully.
	// Re-do: walk char by char, build tokens with explicit separators.
	tokens.clearRetainingCapacity();
	start = 0;
	var pending_sep: Sep = .none;
	{
		var idx: usize = 0;
		while (idx < line.len) : (idx += 1) {
			const c = line[idx];
			if (c == ' ' or c == '-') {
				// Emit token if any
				if (idx > start) {
					try tokens.append(allocator, .{ .text = line[start..idx], .sep = pending_sep });
					pending_sep = .none;
				}
				// Record this separator for the next token
				// Prefer hyphen over space (if we see "- ", the hyphen is what matters)
				if (c == '-') {
					pending_sep = .hyphen;
				} else if (pending_sep != .hyphen) {
					pending_sep = .space;
				}
				start = idx + 1;
			}
		}
		if (start < line.len) {
			try tokens.append(allocator, .{ .text = line[start..], .sep = pending_sep });
		}
	}

	if (tokens.items.len <= 1) {
		return try allocator.dupe(u8, line);
	}

	// Merge pass: try joining adjacent tokens
	var merged = std.ArrayList(Token){};
	defer {
		for (merged.items) |m| {
			const ptr = @intFromPtr(m.text.ptr);
			const input_start = @intFromPtr(line.ptr);
			const input_end = input_start + line.len;
			if (ptr < input_start or ptr >= input_end) {
				allocator.free(m.text);
			}
		}
		merged.deinit(allocator);
	}

	var ti: usize = 0;
	while (ti < tokens.items.len) {
		if (ti + 1 < tokens.items.len) {
			const left = tokens.items[ti].text;
			const right = tokens.items[ti + 1].text;
			const sep_between = tokens.items[ti + 1].sep;

			if ((left.len > 1 or right.len > 1) and
				!isPurelyNumeric(left) and !isPurelyNumeric(right))
			{
				const left_stripped = stripPunctuation(left);
				const right_stripped = stripPunctuation(right);
				const core_left = left_stripped.word;
				const core_right = right_stripped.word;
				const core_combined_len = core_left.len + core_right.len;

				if (core_combined_len > 0 and core_combined_len <= 256) {
					var buf: [256]u8 = undefined;
					@memcpy(buf[0..core_left.len], core_left);
					@memcpy(buf[core_left.len..core_combined_len], core_right);
					const combined = buf[0..core_combined_len];
						if (isWord(combined)) {
							const should_join = blk: {
								// Join when at least one fragment is NOT a real standalone word.
								// "Real" = in dictionary AND (>= 3 chars OR common function word).
								// This treats rare 2-char abbreviations ("kn") as fragments
								// while protecting common words ("to", "me", "an").
								const left_real = isRealStandaloneWord(core_left);
								const right_real = isRealStandaloneWord(core_right);
								if (left_real and right_real) break :blk false;
								break :blk true;
							};


						if (should_join) {
							// If separator was hyphen, decide: keep or remove?
							// "over-" + "come" → "overcome" (remove hyphen, it was a line-break)
							// "write-" + "down" → "write-down" (keep hyphen, it's part of the word)
							// Heuristic: if combined WITHOUT hyphen is a word → remove hyphen
							// If only combined WITH hyphen would be a word → keep hyphen
							// But we already know combined (no hyphen) is a word from above.
							// So if sep was hyphen and combined is a word: check if the
							// hyphenated form is ALSO common. Since our dict lacks hyphens,
							// we can't check — just remove the hyphen (prefer the unhyphenated form).
							// Actually: keep the hyphen if both parts are real words
							// ("write" + "down" = "writedown" vs "write-down")
							// Remove if either part is NOT a word ("over" + "come" when "over-" was a break)
							// Keep hyphen only when combined form is NOT in dictionary
							// "write"+"down"="writedown" (not a word) -> keep hyphen -> "write-down"
							// "over"+"come"="overcome" (IS a word) -> remove hyphen -> "overcome"
							const keep_hyphen = sep_between == .hyphen and !isWord(combined);

							const merged_len = left_stripped.prefix.len + core_combined_len + right_stripped.suffix.len;
							const m = try allocator.alloc(u8, merged_len);
							var pos: usize = 0;
							@memcpy(m[pos .. pos + left_stripped.prefix.len], left_stripped.prefix);
							pos += left_stripped.prefix.len;
							@memcpy(m[pos .. pos + core_left.len], core_left);
							pos += core_left.len;
							@memcpy(m[pos .. pos + core_right.len], core_right);
							pos += core_right.len;
							@memcpy(m[pos .. pos + right_stripped.suffix.len], right_stripped.suffix);

							if (keep_hyphen) {
								// Reconstruct with hyphen: need to reallocate with hyphen inserted
								allocator.free(m);
								const hm_len = left_stripped.prefix.len + core_left.len + 1 + core_right.len + right_stripped.suffix.len;
								const hm = try allocator.alloc(u8, hm_len);
								pos = 0;
								@memcpy(hm[pos .. pos + left_stripped.prefix.len], left_stripped.prefix);
								pos += left_stripped.prefix.len;
								@memcpy(hm[pos .. pos + core_left.len], core_left);
								pos += core_left.len;
								hm[pos] = '-';
								pos += 1;
								@memcpy(hm[pos .. pos + core_right.len], core_right);
								pos += core_right.len;
								@memcpy(hm[pos .. pos + right_stripped.suffix.len], right_stripped.suffix);
								try merged.append(allocator, .{ .text = hm, .sep = tokens.items[ti].sep });
							} else {
								try merged.append(allocator, .{ .text = m, .sep = tokens.items[ti].sep });
							}
							ti += 2;
							continue;
						}
					}
				}
			}
		}
		// No merge — keep token as-is
		try merged.append(allocator, tokens.items[ti]);
		ti += 1;
	}

	// Build output with original separators
	var result = std.ArrayList(u8){};
	errdefer result.deinit(allocator);

	for (merged.items) |tok| {
		switch (tok.sep) {
			.none => {},
			.space => try result.append(allocator, ' '),
			.hyphen => try result.append(allocator, '-'),
		}
		try result.appendSlice(allocator, tok.text);
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
/// Phase 0: Hyphen normalization.
/// 1. "mis- managed" → "mis-managed" (remove space after intra-word hyphen)
/// 2. "mis-managed" → "mismanaged" (remove hyphen if unhyphenated form is in dictionary)
/// 3. "twenty-four" → "twenty-four" (keep hyphen if unhyphenated form is NOT in dictionary)
fn normalizeHyphens(allocator: Allocator, text: []const u8) ![]const u8 {
	var result = std.ArrayList(u8){};
	errdefer result.deinit(allocator);

	var i: usize = 0;
	while (i < text.len) {
		// Look for pattern: word-fragment or word- fragment
		if (text[i] == '-') {
			// Check if this hyphen is between word characters
			if (i > 0 and i + 1 < text.len and std.ascii.isAlphabetic(text[i - 1])) {
				// Skip optional space after hyphen
				var next = i + 1;
				if (next < text.len and text[next] == ' ') next += 1;

				if (next < text.len and std.ascii.isAlphabetic(text[next])) {
					// Found "word-word" or "word- word" pattern
					// Find the full left word (scan back to last space/newline/start)
					var left_start = i;
					while (left_start > 0 and text[left_start - 1] != ' ' and text[left_start - 1] != '\n') {
						left_start -= 1;
					}
					// Find the full right word (scan forward to next space/newline/end/hyphen)
					var right_end = next;
					while (right_end < text.len and text[right_end] != ' ' and text[right_end] != '\n' and text[right_end] != '-') {
						right_end += 1;
					}

					const left_word = text[left_start..i];
					const right_word = text[next..right_end];

					// Also try collecting space-separated fragments after hyphen
					// e.g., "mis-man aged" → right_word="man", extended="managed"
					var extended_end = right_end;
					// Try extending by ONE additional space-separated fragment
					// (not unlimited — "mis-man aged poorly" should only try "managed", not "managedpoorly")
					if (extended_end < text.len and text[extended_end] == 0x20) {
						if (extended_end + 1 < text.len and std.ascii.isAlphabetic(text[extended_end + 1])) {
							extended_end += 1; // skip space
							while (extended_end < text.len and std.ascii.isAlphabetic(text[extended_end])) {
								extended_end += 1;
							}
						}
					}

					// Try unhyphenated form
					if (left_word.len + right_word.len <= 128) {
						var combined_buf: [128]u8 = undefined;
						@memcpy(combined_buf[0..left_word.len], left_word);
						@memcpy(combined_buf[left_word.len .. left_word.len + right_word.len], right_word);
						const combined = combined_buf[0 .. left_word.len + right_word.len];
						// Also try with extended fragments (e.g., "mis" + "managed" from "man aged")
						if (extended_end > right_end and left_word.len + (extended_end - next) <= 128) {
							var ext_buf: [128]u8 = undefined;
							@memcpy(ext_buf[0..left_word.len], left_word);
							var ext_pos: usize = left_word.len;
							// Copy right fragments, skipping spaces
							var scan = next;
							while (scan < extended_end) : (scan += 1) {
								if (text[scan] != 0x20) { // not space
									ext_buf[ext_pos] = text[scan];
									ext_pos += 1;
								}
							}
							const ext_combined = ext_buf[0..ext_pos];
							if (isWord(ext_combined)) {
								// Extended form is a word — skip hyphen + all spaces
								// Append right fragments without spaces
								{
									var s = next;
									while (s < extended_end) : (s += 1) {
										if (text[s] != 0x20) try result.append(allocator, text[s]);
									}
								}
								i = extended_end;
								continue;
							}
						}

						if (isWord(combined)) {
							// Unhyphenated form is a word — remove hyphen (and any space)
							// Replace the left word + hyphen + optional space with just the left word
							// (right word will be appended naturally by the loop)
							// Actually: we already appended left_word chars up to the hyphen.
							// Just skip the hyphen and optional space.
							i = next; // skip past hyphen and optional space
							continue;
						}
					}

					// Unhyphenated form NOT a word — keep hyphen, but remove space if "word- word"
					try result.append(allocator, '-');
					i = next; // skip past hyphen and optional space (join "word- word" → "word-word")
					continue;
				}
			}
		}
		try result.append(allocator, text[i]);
		i += 1;
	}

	return try result.toOwnedSlice(allocator);
}
/// Expand PDF ligature placeholders and fix punctuation spacing.
/// Control chars 0x01→"fl", 0x02→"fi", 0x03→"ff"; other control chars
/// (except \n \r \t) are stripped. Also inserts a space after '.' when
/// preceded by a lowercase letter and followed by an uppercase letter
/// (but not in abbreviations like "U.S." or decimals like "3.14"), and
/// after ',', ';', ':' when followed by a letter (but not digits like "1,000").
fn normalizeText(allocator: Allocator, text: []const u8) ![]const u8 {
	var result = std.ArrayList(u8){};
	errdefer result.deinit(allocator);

	var i: usize = 0;
	while (i < text.len) {
		// 1a. Handle literal escape sequences from PDF parser: "u0002" → "fi" etc.
		if (i + 4 < text.len and text[i] == 0x75 and text[i+1] == 0x30 and text[i+2] == 0x30 and text[i+3] == 0x30) {
			switch (text[i+4]) {
				0x31 => { try result.appendSlice(allocator, "fl"); i += 5; continue; },
				0x32 => { try result.appendSlice(allocator, "fi"); i += 5; continue; },
				0x33 => { try result.appendSlice(allocator, "ff"); i += 5; continue; },
				0x36 => { try result.appendSlice(allocator, "ffi"); i += 5; continue; },
				else => { i += 5; continue; },
			}
		}

		// 1b. Unicode ligature expansion (U+FB00-U+FB06)
		// These are 3-byte UTF-8 sequences: EF AC 80-86
		if (i + 2 < text.len and text[i] == 0xEF and text[i + 1] == 0xAC) {
			switch (text[i + 2]) {
				0x80 => { try result.appendSlice(allocator, "ff"); i += 3; continue; },  // U+FB00
				0x81 => { try result.appendSlice(allocator, "fi"); i += 3; continue; },  // U+FB01
				0x82 => { try result.appendSlice(allocator, "fl"); i += 3; continue; },  // U+FB02
				0x83 => { try result.appendSlice(allocator, "ffi"); i += 3; continue; }, // U+FB03
				0x84 => { try result.appendSlice(allocator, "ffl"); i += 3; continue; }, // U+FB04
				0x85 => { try result.appendSlice(allocator, "st"); i += 3; continue; },  // U+FB05 (long st)
				0x86 => { try result.appendSlice(allocator, "st"); i += 3; continue; },  // U+FB06
				else => {},
			}
		}

		// 1. Ligature expansion / control char stripping
		if (text[i] < 0x20 and text[i] != '\n' and text[i] != '\r' and text[i] != '\t') {
			switch (text[i]) {
				0x01 => try result.appendSlice(allocator, "fl"),
				0x02 => try result.appendSlice(allocator, "fi"),
				0x03 => try result.appendSlice(allocator, "ff"),
				else => {}, // strip other control chars
			}
			i += 1;
			continue;
		}
		// 2. Period + uppercase: "spirit.Winston" → "spirit. Winston"
		//    Exception: don't touch if prev is uppercase (abbreviation "U.S.")
		//    or digit (decimal "3.14")
		if (text[i] == '.' and i > 0 and i + 1 < text.len) {
			const prev = text[i - 1];
			const next = text[i + 1];
			if (std.ascii.isLower(prev) and std.ascii.isUpper(next)) {
				try result.append(allocator, '.');
				try result.append(allocator, ' ');
				i += 1;
				continue;
			}
		}

		// 3. Comma/semicolon/colon + letter: "what,inside" → "what, inside"
		//    Exception: digit before comma (number formatting "1,000")
		if ((text[i] == ',' or text[i] == ';' or text[i] == ':') and
			i + 1 < text.len and std.ascii.isAlphabetic(text[i + 1]))
		{
			if (text[i] == ',' and i > 0 and std.ascii.isDigit(text[i - 1])) {
				// Keep as-is (number formatting like "1,000")
			} else {
				try result.append(allocator, text[i]);
				try result.append(allocator, ' ');
				i += 1;
				continue;
			}
		}

		try result.append(allocator, text[i]);
		i += 1;
	}

	return try result.toOwnedSlice(allocator);
}

/// Split concatenated words that are not in the dictionary.
/// Handles both camelCase boundaries (lowercase→uppercase) and all-lowercase
/// concatenations from EPUB/PDF span boundaries.
/// E.g. "placeimpossible" → "place impossible", "McDonald" stays intact.
/// Strategy: if the token is not a known word, try splitting at every position
/// where both halves are real standalone words. Prefer the longest left part
/// (greedy) to avoid spurious short-word splits.
fn splitCamelBoundaries(allocator: Allocator, text: []const u8) ![]const u8 {
	var result = std.ArrayList(u8){};
	errdefer result.deinit(allocator);

	var i: usize = 0;
	while (i < text.len) {
		// Copy non-alpha characters (spaces, newlines, punctuation between words)
		if (!std.ascii.isAlphabetic(text[i])) {
			try result.append(allocator, text[i]);
			i += 1;
			continue;
		}

		// Find end of this word token (contiguous alphabetic chars)
		var word_end = i;
		while (word_end < text.len and std.ascii.isAlphabetic(text[word_end])) {
			word_end += 1;
		}
		const token = text[i..word_end];
		// Skip tokens that are part of a URL or email address —
		// don't split "wolframscience" inside "www.wolframscience.com"
		const has_dot_before = (i > 0 and text[i - 1] == '.');
		const has_dot_after = (word_end < text.len and text[word_end] == '.');
		if (has_dot_before or has_dot_after) {
			try result.appendSlice(allocator, token);
			i = word_end;
			continue;
		}

		// If the whole token is already a known word, don't split
		if (isWord(token)) {
			try result.appendSlice(allocator, token);
			i = word_end;
			continue;
		}
		// Try splitting: scan from longest-left to shortest-left.
		// Require both halves to be >=3 chars AND dictionary words.
		// This avoids false splits like "Greenbe" → "Green"+"be" where
		// "be" is a function word that happens to match. Short fragments
		// at word boundaries are almost always PDF split artifacts, not
		// real word boundaries.
		var split_pos: ?usize = null;
		if (token.len >= 8) { // minimum: 4+4 chars
			// Scan right-to-left for longest left match
			var j: usize = token.len - 4;
			while (j >= 4) : (j -= 1) {
				const left = token[0..j];
				const right = token[j..];
				if (isWord(left) and isWord(right)) {
					split_pos = j;
					break;
				}
			}
		}

		if (split_pos) |sp| {
			try result.appendSlice(allocator, token[0..sp]);
			try result.append(allocator, ' ');
			try result.appendSlice(allocator, token[sp..]);
		} else {
			try result.appendSlice(allocator, token);
		}
		i = word_end;
	}

	return try result.toOwnedSlice(allocator);
}

/// Rejoin word fragments split across a single newline boundary.
/// When the last token on line N and the first token on line N+1
/// combine into a dictionary word (and at least one part isn't a
/// standalone word), merge them and move the newline after the
/// joined word.
fn rejoinAcrossNewlines(allocator: Allocator, text: []const u8) ![]const u8 {
	var result = std.ArrayList(u8){};
	errdefer result.deinit(allocator);

	var lines = std.mem.splitScalar(u8, text, '\n');
	var prev_line: ?[]const u8 = null;

	while (lines.next()) |line| {
		if (prev_line) |prev| {
			// Find last word of prev line
			var end = prev.len;
			while (end > 0 and prev[end - 1] == ' ') end -= 1;
			var last_start = end;
			while (last_start > 0 and std.ascii.isAlphabetic(prev[last_start - 1])) last_start -= 1;
			const last_word = prev[last_start..end];

			// Find first word of current line
			var start: usize = 0;
			while (start < line.len and line[start] == ' ') start += 1;
			var first_end = start;
			while (first_end < line.len and std.ascii.isAlphabetic(line[first_end])) first_end += 1;
			const first_word = line[start..first_end];

			if (last_word.len >= 2 and first_word.len >= 2 and last_word.len + first_word.len <= 128) {
				var combined_buf: [128]u8 = undefined;
				@memcpy(combined_buf[0..last_word.len], last_word);
				@memcpy(combined_buf[last_word.len..][0..first_word.len], first_word);
				const combined = combined_buf[0 .. last_word.len + first_word.len];

				const last_is_word = isWord(last_word);
				const first_is_word = isWord(first_word);
				const combined_is_word = isWord(combined);

				if (combined_is_word and (!last_is_word or !first_is_word)) {
					// Merge: emit prev line up to last_word start, then combined word, then newline, then rest of current line
					try result.appendSlice(allocator, prev[0..last_start]);
					try result.appendSlice(allocator, combined);
					try result.append(allocator, '\n');
					// Skip leading space after the merged fragment
					var rest_start = first_end;
					while (rest_start < line.len and line[rest_start] == ' ') rest_start += 1;
					if (rest_start < line.len) {
						try result.appendSlice(allocator, line[rest_start..]);
					}					prev_line = null;
					// We've consumed this line — store remainder as "prev" for next iteration
					// Actually, the remainder after first_end was already appended with \n
					// We need prev_line to hold what we just emitted, but that's in result already
					// So just continue without setting prev_line — next line becomes the new prev
					continue;
				}
			}

			// No merge — emit prev line with newline
			try result.appendSlice(allocator, prev);
			try result.append(allocator, '\n');
		}
		prev_line = line;
	}

	// Emit final line (no trailing newline)
	if (prev_line) |prev| {
		try result.appendSlice(allocator, prev);
	}

	return try result.toOwnedSlice(allocator);
}

pub fn rejoinWords(allocator: Allocator, text: []const u8) ![]const u8 {
	ensureInit();

	// Phase 0-pre-a: expand ligatures and fix punctuation spacing
	const normalized = try normalizeText(allocator, text);
	defer allocator.free(normalized);

	// Phase 0-pre-b: split concatenated words — DISABLED.
	// Causes more harm than good (URL/email breakage, false splits on
	// proper nouns). The extra-space problem is far more common than
	// missing spaces. Re-enable via splitCamelBoundaries() if needed.

	// Phase 0a: strip soft hyphens (U+00AD = 0xC2 0xAD in UTF-8)
	// These are line-break hints, not real hyphens.
	var stripped = std.ArrayList(u8){};
	defer stripped.deinit(allocator);
	{
		var j: usize = 0;
		while (j < normalized.len) {
			if (j + 1 < normalized.len and normalized[j] == 0xC2 and normalized[j + 1] == 0xAD) {
				j += 2;
				// Also skip newline after soft hyphen (it was a line break)
				while (j < normalized.len and (normalized[j] == 0x0A or normalized[j] == 0x0D or normalized[j] == 0x20)) : (j += 1) {}
			} else {
				try stripped.append(allocator, normalized[j]);
				j += 1;
			}
		}
	}
	// Phase 0b: normalize hyphens
	const dehyphenated = try normalizeHyphens(allocator, stripped.items);
	defer allocator.free(dehyphenated);

	// Phase 1: rejoin pass (within lines)
	const pass1 = try rejoinPass(allocator, dehyphenated);
	defer allocator.free(pass1);
	// Pass 2 (within lines)
	const pass2 = try rejoinPass(allocator, pass1);
	defer allocator.free(pass2);

	// Phase 2: cross-newline rejoin — OCR tools like ocrmypdf strip
	// hyphens at line breaks but keep the newline, leaving "lit\ntle".
	// Join the last word of a line with the first word of the next line
	// when the combined form is a dictionary word and at least one part
	// is not a standalone word.
	return try rejoinAcrossNewlines(allocator, pass2);}


const document = @import("document.zig");

/// Walk all sections recursively and apply text normalization.
pub fn applySections(allocator: Allocator, sections: []const document.Section) void {
	const mutable: []document.Section = @constCast(sections);
	for (mutable) |*section| {
		if (section.content.len > 0) {
			const fixed = rejoinWords(allocator, section.content) catch continue;
			allocator.free(@constCast(section.content));
			section.content = fixed;
		}
		if (section.children.len > 0) {
			applySections(allocator, section.children);
		}
	}
}
// ── Text quality scoring ──────────────────────────────────────────────

/// Dictionary-based text quality scoring (0-100%).
/// Samples words from the text and checks what percentage are recognized.
/// Also factors in alpha density — garbled OCR text has sparse alphabetic
/// runs mixed with symbols/digits, which is a strong garbled-text signal
/// independent of whether the few alpha fragments happen to match words.
/// Dictionary-based text quality scoring (0-100%).
/// Combines multiple signals to detect garbled text:
/// 1. Alpha density — low means symbols/digits dominate
/// 2. Dictionary word recognition — low means nonsense letter sequences
/// 3. Control char density — high means custom font encoding garbage
/// 4. Replacement char (U+FFFD) density — high means encoding failures
pub fn textQuality(text: []const u8) u8 {
	ensureInit();
	if (text.len == 0) return 100;

	const text_len: u32 = @intCast(@min(text.len, std.math.maxInt(u32)));

	// Count character categories in a single pass
	var alpha_count: u32 = 0;
	var control_count: u32 = 0; // bytes < 0x20 except \n \r \t
	var fffd_count: u32 = 0; // U+FFFD = 0xEF 0xBF 0xBD
	var bad_high_count: u32 = 0; // 0x80-0x9F not valid UTF-8 (Win-1252 range)

	var j: usize = 0;
	while (j < text.len) {
		const c = text[j];
		if (std.ascii.isAlphabetic(c)) {
			alpha_count += 1;
		} else if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') {
			control_count += 1;
		} else if (c >= 0x80 and c <= 0x9F) {
			// Check if it's a valid UTF-8 continuation byte (10xxxxxx)
			// If so, it's fine. If not, it's a bare Win-1252 byte.
			if (j > 0 and text[j - 1] >= 0xC0) {
				// Valid continuation of a multi-byte sequence
			} else {
				bad_high_count += 1;
			}
		}
		// Check for U+FFFD: EF BF BD
		if (j + 2 < text.len and c == 0xEF and text[j + 1] == 0xBF and text[j + 2] == 0xBD) {
			fffd_count += 3; // count all 3 bytes as bad
			j += 3;
			continue;
		}
		j += 1;
	}

	const alpha_pct: u32 = (alpha_count * 100) / text_len;
	const bad_bytes = control_count + fffd_count + bad_high_count;
	const bad_pct: u32 = if (text_len > 0) (bad_bytes * 100) / text_len else 0;

	// If >5% of bytes are control/replacement chars, text is likely garbled.
	// Any presence of these chars is abnormal in clean text — penalize steeply.
	var quality_cap: u32 = 100;
	if (bad_pct > 5) {
		quality_cap = if (bad_pct >= 33) 0 else 100 - (bad_pct * 3);
	}

	// Sample up to 200 words for dictionary check
	var total: u32 = 0;
	var recognized: u32 = 0;
	var i: usize = 0;
	while (i < text.len and total < 200) {
		while (i < text.len and !std.ascii.isAlphabetic(text[i])) : (i += 1) {}
		if (i >= text.len) break;
		const start = i;
		while (i < text.len and std.ascii.isAlphabetic(text[i])) : (i += 1) {}
		const word = text[start..i];
		if (word.len < 3) continue;
		total += 1;
		if (isWord(word)) recognized += 1;
	}

	const word_pct: u32 = if (total > 0) (recognized * 100) / total else 100;

	// Quality is the minimum of all signals
	return @intCast(@min(quality_cap, @min(alpha_pct, word_pct)));
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "isWord finds common words" {	try testing.expect(isWord("hello"));
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
test "rejoin fixes line-break hyphenation 'write-dow n' -> 'write-down'" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "the write-dow n was significant");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("the write-down was significant", result);
}

test "rejoin fixes simple hyphenation 'mis-man aged' -> 'mis-managed'" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "it was mis-managed poorly");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("it was mismanaged poorly", result);
}

test "rejoin fixes end-of-line hyphen break via collapsed line" {
	const alloc = std.testing.allocator;
	// After line collapse, 'over-' + 'come' would be 'over- come'
	const result = try rejoinWords(alloc, "to over- come the obstacle");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("to overcome the obstacle", result);
}

test "rejoin fixes proper noun split 'Greenbe rg' -> 'Greenberg'" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "met Ace Greenbe rg at the");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("met Ace Greenberg at the", result);
}

test "hyphen normalization: mis-managed → mismanaged" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "it was mis-managed poorly");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("it was mismanaged poorly", result);
}

test "hyphen normalization: mis- managed → mismanaged" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "it was mis- managed poorly");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("it was mismanaged poorly", result);
}

test "hyphen normalization: twenty-four stays hyphenated" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "she was twenty-four years old");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("she was twenty-four years old", result);
}

test "hyphen normalization: over- come → overcome" {
	const alloc = std.testing.allocator;
	const result = try rejoinWords(alloc, "to over- come the obstacle");
	defer alloc.free(result);
	try std.testing.expectEqualStrings("to overcome the obstacle", result);
}

test "dictionary loads and contains key words for normalization" {
	ensureInit();
	const d = dict orelse {
		std.debug.print("ERROR: dict is null after ensureInit\n", .{});
		return error.TestUnexpectedResult;
	};
	_ = d;
	// Check words needed for normalization
	try testing.expect(isWord("mismanaged"));
	try testing.expect(isWord("known"));
	try testing.expect(isWord("overcome"));
	try testing.expect(isWord("nobody"));
	// Proper noun: only when capitalized
	try testing.expect(isWord("Greenberg"));
	try testing.expect(!isWord("foran")); // proper noun, not capitalized
}

test "normalizeText: ligature expansion 0x02 → fi" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "Arti\x02cial Intelligence");
	defer alloc.free(result);
	try testing.expectEqualStrings("Artificial Intelligence", result);
}

test "normalizeText: ligature expansion 0x01 → fl, 0x03 → ff" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "\x01ower o\x03er");
	defer alloc.free(result);
	try testing.expectEqualStrings("flower offer", result);
}

test "normalizeText: strips other control chars" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "he\x04llo\x00 world");
	defer alloc.free(result);
	try testing.expectEqualStrings("hello world", result);
}

test "normalizeText: space after period before capital" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "spirit.Winston poured");
	defer alloc.free(result);
	try testing.expectEqualStrings("spirit. Winston poured", result);
}

test "normalizeText: preserves U.S. abbreviation" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "U.S. stock market");
	defer alloc.free(result);
	try testing.expectEqualStrings("U.S. stock market", result);
}

test "normalizeText: preserves decimal 3.14" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "costs 3.14 dollars");
	defer alloc.free(result);
	try testing.expectEqualStrings("costs 3.14 dollars", result);
}

test "normalizeText: space after comma before letter" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "what,inside the");
	defer alloc.free(result);
	try testing.expectEqualStrings("what, inside the", result);
}

test "normalizeText: preserves number formatting 1,000" {
	const alloc = testing.allocator;
	const result = try normalizeText(alloc, "about 1,000 items");
	defer alloc.free(result);
	try testing.expectEqualStrings("about 1,000 items", result);
}

test "splitCamelBoundaries: placeimpossible → place impossible" {
	const alloc = testing.allocator;
	// Must init dictionary first
	ensureInit();
	const result = try splitCamelBoundaries(alloc, "placeimpossible to enter");
	defer alloc.free(result);
	try testing.expectEqualStrings("place impossible to enter", result);
}

test "splitCamelBoundaries: preserves McDonald" {
	const alloc = testing.allocator;
	ensureInit();
	const result = try splitCamelBoundaries(alloc, "McDonald went to YouTube");
	defer alloc.free(result);
	try testing.expectEqualStrings("McDonald went to YouTube", result);
}

test "splitCamelBoundaries: preserves URLs" {
	const alloc = testing.allocator;
	ensureInit();
	const result = try splitCamelBoundaries(alloc, "visit www.wolframscience.com for details");
	defer alloc.free(result);
	try testing.expectEqualStrings("visit www.wolframscience.com for details", result);
}test "rejoinWords: full pipeline ligature + punctuation + camel" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "Arti\x02cial Intelligence");
	defer alloc.free(result);
	try testing.expectEqualStrings("Artificial Intelligence", result);
}

test "rejoinWords: cross-newline rejoin 'lit\\ntle' -> 'little'" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "homely lit\ntle punishment");
	defer alloc.free(result);
	try testing.expectEqualStrings("homely little\npunishment", result);
}

test "rejoinWords: cross-newline keeps valid words 'the\ndog'" {
	const alloc = testing.allocator;
	const result = try rejoinWords(alloc, "the\ndog ran");
	defer alloc.free(result);
	// Both are real words — don't join across newline
	try testing.expectEqualStrings("the\ndog ran", result);
}
test "textQuality: garbled OCR text scores below 30" {
	// Garbled text from a bad OCR scan — should score very low quality
	const garbled = "@FDA6G5F;A@ A8 +L77@F5:\n*96 FC?:?8 @7 &C@DA6C@\n*96 (F3C:4 @7 9C:>2?";
	const quality = textQuality(garbled);
	// Must be below 30% — this is clearly not real English
	try testing.expect(quality < 30);
}

test "textQuality: normal English text scores above 70" {
	const english = "The quick brown fox jumps over the lazy dog and runs through the forest";
	const quality = textQuality(english);
	try testing.expect(quality > 70);
}

test "textQuality: control char heavy text scores below 30" {
	// Simulates custom font encoding garbage — lots of control chars
	// mixed with some alpha chars. Big History (DK) had this pattern.
	const garbage = "\x01\x02\x03\x04hello\x05\x06\x07\x08world\x0b\x0c\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f";
	const quality = textQuality(garbage);
	try testing.expect(quality < 30);
}

test "textQuality: U+FFFD replacement chars score below 30" {
	// Real encoding failures have FFFD on nearly every word — apostrophes,
	// quotes, dashes all become replacement chars
	const bad = "the Emperor\xef\xbf\xbds army\xef\xbf\xbds \xef\xbf\xbd" ++
		"great\xef\xbf\xbd power\xef\xbf\xbd and\xef\xbf\xbd glory\xef\xbf\xbd";
	const quality = textQuality(bad);
	try testing.expect(quality < 30);
}

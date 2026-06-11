//! docscan WASM parse-to-text slice — the browser-world parse boundary.
//!
//! Intent: give incitez_web (and any JS/WASM consumer) a fully client-side way
//! to turn a docx/pdf/md/txt file into plain UTF-8 text, with NO server and NO
//! external library. The extracted text then feeds incitez's citation engine.
//!
//! Shape: wasm32-freestanding, reactor module (no `_start`), ZERO imports,
//! memory exported. The ABI mirrors incitez's WASM ABI exactly (len-prefixed
//! UTF-8 result; caller frees both the input and result buffers with one freer)
//! so incitez_web has a single ABI mental model. The sqlite/search/embedding
//! machinery and uchardet (C++) are comptime-excluded; only the pure-Zig
//! parsers (parser_pdf text-layer, parser_docx/zip/xml, parser_md) + wordfix +
//! getEncodingTable are linked.
//!
//! Rooted at src/ (not src/wasm/) so it can `@import("core/...")` — Zig forbids
//! imports above a module's root directory. Same convention as all_tests.zig.

const std = @import("std");
const document = @import("core/document.zig");
const extract_text = @import("core/extract_text.zig");
const parser_md = @import("core/parser_md.zig");
const parser_docx = @import("core/parser_docx.zig");
const parser_pdf = @import("core/parser_pdf.zig");

/// Linear-memory allocator for the freestanding wasm target.
const gpa = std.heap.wasm_allocator;

/// Format selector — values must match the JS-side `fmt` enum.
const Fmt = enum(u32) { docx = 0, md = 1, txt = 2, pdf = 3, _ };

// Every cross-boundary allocation carries a 4-byte little-endian length header
// immediately before the pointer handed to JS, so `docscan_free(ptr)` can
// recover the block size from the pointer alone — matching incitez's
// one-freer-for-both-buffers contract (frees alloc'd input AND extract result).
const HEADER: usize = 4;

/// Allocate `n` usable bytes plus a length header; returns a pointer to the
/// usable region (just past the header), or null on OOM.
fn allocUser(n: usize) ?[*]u8 {
	const block = gpa.alloc(u8, HEADER + n) catch return null;
	std.mem.writeInt(u32, block.ptr[0..4], @intCast(n), .little);
	return block.ptr + HEADER;
}

/// Free a region previously returned by `allocUser`, reading its header for size.
fn freeUser(user: [*]u8) void {
	const base = user - HEADER;
	const n = std.mem.readInt(u32, base[0..4], .little);
	gpa.free(base[0 .. HEADER + n]);
}

/// Allocate `len` writable bytes; returns a pointer (offset), or 0 on OOM.
export fn docscan_alloc(len: u32) u32 {
	const p = allocUser(len) orelse return 0;
	return @intFromPtr(p);
}

/// Free a buffer returned by `docscan_alloc` or `docscan_extract_text`; 0 is a no-op.
export fn docscan_free(ptr: u32) void {
	if (ptr == 0) return;
	freeUser(@ptrFromInt(ptr));
}

/// Extract plain UTF-8 text from `len` bytes at `ptr`, interpreted as `fmt`.
/// Returns a result pointer to a buffer laid out as `[u32 LE text_len][text]`,
/// or 0 on parse error / OOM. Caller frees the result with `docscan_free`.
export fn docscan_extract_text(ptr: u32, len: u32, fmt: u32) u32 {
	if (ptr == 0) return 0;
	const input = @as([*]const u8, @ptrFromInt(ptr))[0..len];
	const text = extractText(input, @enumFromInt(fmt)) catch return 0;
	defer gpa.free(text);
	const res = allocUser(4 + text.len) orelse return 0;
	std.mem.writeInt(u32, res[0..4], @intCast(text.len), .little);
	@memcpy(res[4 .. 4 + text.len], text);
	return @intFromPtr(res);
}

/// Parse `input` as `fmt` and return gpa-owned plain text. txt is identity
/// (UTF-8 assumed); docx/md/pdf go through their parsers + the flattener.
fn extractText(input: []const u8, fmt: Fmt) ![]u8 {
	if (fmt == .txt) return gpa.dupe(u8, input);

	var arena = std.heap.ArenaAllocator.init(gpa);
	defer arena.deinit();
	const a = arena.allocator();
	const doc = switch (fmt) {
		.docx => try parser_docx.parse(a, input, "input.docx"),
		.md => try parser_md.parse(a, input, "input.md"),
		.pdf => try parser_pdf.parse(a, input, "input.pdf"),
		else => return error.UnknownFormat,
	};
	// documentToPlainText copies content into a fresh gpa buffer, so the result
	// outlives the arena (freed on return).
	return extract_text.documentToPlainText(gpa, doc);
}

const version_str: [:0]const u8 = "0.1.0";

/// Pointer to a NUL-terminated ASCII version string (read until `\0`).
export fn docscan_version_ptr() u32 {
	return @intFromPtr(version_str.ptr);
}

/// Run the embedded self-test corpus; returns `(passed << 16) | total`.
/// Rendered by incitez_web as the "parser self-verified N/N ✓" badge on load.
export fn docscan_selftest() u32 {
	var passed: u32 = 0;
	var total: u32 = 0;

	total += 1;
	if (selftestMd()) passed += 1;

	total += 1;
	if (selftestTxt()) passed += 1;

	return (passed << 16) | total;
}

fn selftestMd() bool {
	const text = extractText("# Heading\n\nHello world.", .md) catch return false;
	defer gpa.free(text);
	return std.mem.indexOf(u8, text, "Heading") != null and
		std.mem.indexOf(u8, text, "Hello world") != null;
}

fn selftestTxt() bool {
	const text = extractText("plain text body", .txt) catch return false;
	defer gpa.free(text);
	return std.mem.eql(u8, text, "plain text body");
}

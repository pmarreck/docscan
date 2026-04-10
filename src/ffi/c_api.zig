//! C FFI boundary for docscan.
//! All exported functions use C calling convention and flat C types.
//! This is the public API that the C CLI and any external consumers call.
//!
//! Design: opaque handles, null-terminated C strings, caller-provided error buffers.
//! All returned `char*` must be freed with `docscan_free()`.
//! Errors never panic across the FFI boundary — they are written to err_buf.

const std = @import("std");
const core = @import("core");
const document = core.document;
const storage = core.storage;
const search_mod = core.search;
const chunker = core.chunker;
const parser_md = core.parser_md;
const parser_docx = core.parser_docx;
const parser_pdf = core.parser_pdf;
const parser_doc = core.parser_doc;
const parser_rtf = core.parser_rtf;
const parser_epub = core.parser_epub;

// ── Allocator ─────────────────────────────────────────────────────────

var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
const gpa = gpa_impl.allocator();

// ── Opaque handle ─────────────────────────────────────────────────────

/// Opaque database handle exposed to C consumers.
const DocscanDb = struct {
	db: storage.Db,
};

// ── Error helpers ─────────────────────────────────────────────────────

/// Write a null-terminated error message into the caller's error buffer.
fn writeError(err_buf: ?[*]u8, err_buf_len: usize, msg: []const u8) void {
	if (err_buf) |buf| {
		if (err_buf_len == 0) return;
		const len = @min(msg.len, err_buf_len - 1);
		@memcpy(buf[0..len], msg[0..len]);
		buf[len] = 0;
	}
}

/// Write an error from a Zig error value.
fn writeZigError(err_buf: ?[*]u8, err_buf_len: usize, err: anyerror) void {
	writeError(err_buf, err_buf_len, @errorName(err));
}

/// Duplicate a Zig string as a null-terminated C string allocated via GPA.
/// Caller must free with docscan_free().
fn dupeToC(s: []const u8) ?[*:0]u8 {
	const buf = gpa.alloc(u8, s.len + 1) catch return null;
	@memcpy(buf[0..s.len], s);
	buf[s.len] = 0;
	return @ptrCast(buf.ptr);
}

// ── JSON serialization helpers ────────────────────────────────────────
// Zig 0.15: ArrayList methods take allocator as first arg.

/// Escape a string for JSON output, writing to an ArrayList.
fn jsonEscapeString(out: *std.ArrayList(u8), s: []const u8) !void {
	try out.append(gpa, '"');
	for (s) |ch| {
		switch (ch) {
			'"' => try out.appendSlice(gpa, "\\\""),
			'\\' => try out.appendSlice(gpa, "\\\\"),
			'\n' => try out.appendSlice(gpa, "\\n"),
			'\r' => try out.appendSlice(gpa, "\\r"),
			'\t' => try out.appendSlice(gpa, "\\t"),
			else => {
				if (ch < 0x20) {
					try out.appendSlice(gpa, "\\u00");
					const hex = "0123456789abcdef";
					try out.append(gpa, hex[ch >> 4]);
					try out.append(gpa, hex[ch & 0x0f]);
				} else {
					try out.append(gpa, ch);
				}
			},
		}
	}
	try out.append(gpa, '"');
}

/// Append an optional JSON string field (or "null").
fn jsonOptionalString(out: *std.ArrayList(u8), val: ?[]const u8) !void {
	if (val) |v| {
		try jsonEscapeString(out, v);
	} else {
		try out.appendSlice(gpa, "null");
	}
}

/// Append an optional JSON u32 field (or "null").
fn jsonOptionalU32(out: *std.ArrayList(u8), val: ?u32) !void {
	if (val) |v| {
		var buf: [16]u8 = undefined;
		const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
		try out.appendSlice(gpa, s);
	} else {
		try out.appendSlice(gpa, "null");
	}
}

/// Serialize a Section recursively to JSON.
fn jsonSection(out: *std.ArrayList(u8), section: document.Section) !void {
	try out.appendSlice(gpa, "{\"heading\":");
	try jsonOptionalString(out, section.heading);
	try out.appendSlice(gpa, ",\"level\":");
	var level_buf: [8]u8 = undefined;
	const level_str = std.fmt.bufPrint(&level_buf, "{d}", .{section.level}) catch "0";
	try out.appendSlice(gpa, level_str);
	try out.appendSlice(gpa, ",\"content\":");
	try jsonEscapeString(out, section.content);
	try out.appendSlice(gpa, ",\"page\":");
	try jsonOptionalU32(out, section.page);
	try out.appendSlice(gpa, ",\"source_line\":");
	try jsonOptionalU32(out, section.source_line);
	try out.appendSlice(gpa, ",\"children\":[");
	for (section.children, 0..) |child, i| {
		if (i > 0) try out.append(gpa, ',');
		try jsonSection(out, child);
	}
	try out.appendSlice(gpa, "]}");
}

/// Serialize a Document to JSON.
fn jsonDocument(doc: document.Document) ![]const u8 {
	var out = std.ArrayList(u8){};
	errdefer out.deinit(gpa);

	try out.appendSlice(gpa, "{\"path\":");
	try jsonEscapeString(&out, doc.path);
	try out.appendSlice(gpa, ",\"format\":");
	try jsonEscapeString(&out, doc.format.extension());
	try out.appendSlice(gpa, ",\"title\":");
	try jsonOptionalString(&out, doc.title);
	try out.appendSlice(gpa, ",\"metadata\":{");
	for (doc.metadata, 0..) |entry, i| {
		if (i > 0) try out.append(gpa, ',');
		try jsonEscapeString(&out, entry.key);
		try out.append(gpa, ':');
		try jsonEscapeString(&out, entry.value);
	}
	try out.appendSlice(gpa, "},\"sections\":[");
	for (doc.sections, 0..) |section, i| {
		if (i > 0) try out.append(gpa, ',');
		try jsonSection(&out, section);
	}
	try out.appendSlice(gpa, "]}");

	return out.toOwnedSlice(gpa);
}

/// Serialize a slice of Chunks to a JSON array.
fn jsonChunks(chunks: []const document.Chunk) ![]const u8 {
	var out = std.ArrayList(u8){};
	errdefer out.deinit(gpa);

	try out.append(gpa, '[');
	for (chunks, 0..) |c, i| {
		if (i > 0) try out.append(gpa, ',');
		try out.appendSlice(gpa, "{\"document_path\":");
		try jsonEscapeString(&out, c.document_path);
		try out.appendSlice(gpa, ",\"section_path\":");
		try jsonEscapeString(&out, c.section_path);
		try out.appendSlice(gpa, ",\"heading\":");
		try jsonOptionalString(&out, c.heading);
		try out.appendSlice(gpa, ",\"text\":");
		try jsonEscapeString(&out, c.text);

		var num_buf: [32]u8 = undefined;
		try out.appendSlice(gpa, ",\"start_byte\":");
		const sb = std.fmt.bufPrint(&num_buf, "{d}", .{c.start_byte}) catch "0";
		try out.appendSlice(gpa, sb);
		try out.appendSlice(gpa, ",\"end_byte\":");
		const eb = std.fmt.bufPrint(&num_buf, "{d}", .{c.end_byte}) catch "0";
		try out.appendSlice(gpa, eb);
		try out.appendSlice(gpa, ",\"chunk_index\":");
		const ci = std.fmt.bufPrint(&num_buf, "{d}", .{c.chunk_index}) catch "0";
		try out.appendSlice(gpa, ci);
		try out.appendSlice(gpa, ",\"page\":");
		try jsonOptionalU32(&out, c.page);
		try out.appendSlice(gpa, ",\"source_line\":");
		try jsonOptionalU32(&out, c.source_line);
		try out.append(gpa, '}');
	}
	try out.append(gpa, ']');

	return out.toOwnedSlice(gpa);
}

/// Serialize search results to a JSON array.
fn jsonSearchResults(results: []const document.SearchResult) ![]const u8 {
	var out = std.ArrayList(u8){};
	errdefer out.deinit(gpa);

	try out.append(gpa, '[');
	for (results, 0..) |r, i| {
		if (i > 0) try out.append(gpa, ',');
		try out.appendSlice(gpa, "{\"document_path\":");
		try jsonEscapeString(&out, r.document_path);
		try out.appendSlice(gpa, ",\"document_title\":");
		try jsonOptionalString(&out, r.document_title);
		try out.appendSlice(gpa, ",\"section_path\":");
		try jsonEscapeString(&out, r.section_path);
		try out.appendSlice(gpa, ",\"heading\":");
		try jsonOptionalString(&out, r.heading);
		try out.appendSlice(gpa, ",\"text\":");
		try jsonEscapeString(&out, r.text);

		var num_buf: [64]u8 = undefined;
		try out.appendSlice(gpa, ",\"score\":");
		const sc = std.fmt.bufPrint(&num_buf, "{d:.6}", .{r.score}) catch "0";
		try out.appendSlice(gpa, sc);
		try out.appendSlice(gpa, ",\"vector_score\":");
		const vs = std.fmt.bufPrint(&num_buf, "{d:.6}", .{r.vector_score}) catch "0";
		try out.appendSlice(gpa, vs);
		try out.appendSlice(gpa, ",\"lexical_score\":");
		const ls = std.fmt.bufPrint(&num_buf, "{d:.6}", .{r.lexical_score}) catch "0";
		try out.appendSlice(gpa, ls);
		try out.appendSlice(gpa, ",\"page\":");
		try jsonOptionalU32(&out, r.page);
		try out.appendSlice(gpa, ",\"source_line\":");
		try jsonOptionalU32(&out, r.source_line);
		try out.append(gpa, '}');
	}
	try out.append(gpa, ']');

	return out.toOwnedSlice(gpa);
}

/// Serialize a ChunkRecord to JSON.
fn jsonChunkRecord(rec: storage.ChunkRecord) ![]const u8 {
	var out = std.ArrayList(u8){};
	errdefer out.deinit(gpa);

	var num_buf: [32]u8 = undefined;

	try out.appendSlice(gpa, "{\"id\":");
	const id_s = std.fmt.bufPrint(&num_buf, "{d}", .{rec.id}) catch "0";
	try out.appendSlice(gpa, id_s);
	try out.appendSlice(gpa, ",\"document_id\":");
	const did_s = std.fmt.bufPrint(&num_buf, "{d}", .{rec.document_id}) catch "0";
	try out.appendSlice(gpa, did_s);
	try out.appendSlice(gpa, ",\"chunk_index\":");
	const ci_s = std.fmt.bufPrint(&num_buf, "{d}", .{rec.chunk_index}) catch "0";
	try out.appendSlice(gpa, ci_s);
	try out.appendSlice(gpa, ",\"section_path\":");
	try jsonOptionalString(&out, rec.section_path);
	try out.appendSlice(gpa, ",\"heading\":");
	try jsonOptionalString(&out, rec.heading);
	try out.appendSlice(gpa, ",\"text\":");
	try jsonEscapeString(&out, rec.text);
	try out.appendSlice(gpa, ",\"start_byte\":");
	const sb_s = std.fmt.bufPrint(&num_buf, "{d}", .{rec.start_byte}) catch "0";
	try out.appendSlice(gpa, sb_s);
	try out.appendSlice(gpa, ",\"end_byte\":");
	const eb_s = std.fmt.bufPrint(&num_buf, "{d}", .{rec.end_byte}) catch "0";
	try out.appendSlice(gpa, eb_s);
	try out.appendSlice(gpa, ",\"page\":");
	try jsonOptionalU32(&out, rec.page);
	try out.appendSlice(gpa, ",\"source_line\":");
	try jsonOptionalU32(&out, rec.source_line);
	try out.append(gpa, '}');

	return out.toOwnedSlice(gpa);
}

/// Serialize Stats to JSON.
fn jsonStats(stats: storage.Stats) ![]const u8 {
	var out = std.ArrayList(u8){};
	errdefer out.deinit(gpa);

	var num_buf: [32]u8 = undefined;

	try out.appendSlice(gpa, "{\"doc_count\":");
	const dc = std.fmt.bufPrint(&num_buf, "{d}", .{stats.doc_count}) catch "0";
	try out.appendSlice(gpa, dc);
	try out.appendSlice(gpa, ",\"chunk_count\":");
	const cc_str = std.fmt.bufPrint(&num_buf, "{d}", .{stats.chunk_count}) catch "0";
	try out.appendSlice(gpa, cc_str);
	try out.appendSlice(gpa, ",\"last_indexed\":");
	const li = std.fmt.bufPrint(&num_buf, "{d}", .{stats.last_indexed}) catch "0";
	try out.appendSlice(gpa, li);
	try out.append(gpa, '}');

	return out.toOwnedSlice(gpa);
}

// ── Helper: pick parser by format string ──────────────────────────────

const ParseFn = *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!document.Document;
const FreeFn = *const fn (std.mem.Allocator, document.Document) void;

fn getParser(format: []const u8) ?struct { parse: ParseFn, free: FreeFn } {
	if (std.mem.eql(u8, format, "md") or std.mem.eql(u8, format, "markdown")) {
		return .{ .parse = &parser_md.parse, .free = &parser_md.freeDocument };
	}
	if (std.mem.eql(u8, format, "txt") or std.mem.eql(u8, format, "text")) {
		// Plain text uses the markdown parser (same logic, just no headings expected)
		return .{ .parse = &parser_md.parse, .free = &parser_md.freeDocument };
	}
	if (std.mem.eql(u8, format, "docx")) {
		return .{ .parse = &parser_docx.parse, .free = &parser_docx.freeDocument };
	}
	if (std.mem.eql(u8, format, "pdf")) {
		return .{ .parse = &parser_pdf.parse, .free = &parser_pdf.freeDocument };
	}
	if (std.mem.eql(u8, format, "doc")) {
		return .{ .parse = &parser_doc.parse, .free = &parser_doc.freeDocument };
	}
	if (std.mem.eql(u8, format, "rtf")) {
		return .{ .parse = &parser_rtf.parse, .free = &parser_rtf.freeDocument };
	}
	if (std.mem.eql(u8, format, "epub")) {
		return .{ .parse = &parser_epub.parse, .free = &parser_epub.freeDocument };
	}
	return null;
}

// ── Exported C API ────────────────────────────────────────────────────

/// Return the docscan version string as a null-terminated C string.
export fn docscan_version() [*:0]const u8 {
	return "0.1.0";
}

/// Open (or create) a database at the given path.
/// Returns an opaque handle, or null on error (with message in err_buf).
export fn docscan_open(
	db_path: [*:0]const u8,
	embedding_dim: u32,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) ?*DocscanDb {
	const handle = gpa.create(DocscanDb) catch {
		writeError(err_buf, err_buf_len, "out of memory");
		return null;
	};
	handle.db = storage.openDb(gpa, db_path, embedding_dim) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		gpa.destroy(handle);
		return null;
	};
	return handle;
}

/// Close a database handle and free its memory.
export fn docscan_close(db: ?*DocscanDb) void {
	if (db) |d| {
		storage.closeDb(&d.db);
		gpa.destroy(d);
	}
}

/// Parse a document from raw bytes.
/// format: "md", "docx", "pdf", "doc", "rtf"
/// Returns a JSON string (caller must free with docscan_free), or null on error.
export fn docscan_parse(
	data: ?[*]const u8,
	len: usize,
	path: ?[*:0]const u8,
	format: ?[*:0]const u8,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) ?[*:0]u8 {
	const content = if (data) |d| d[0..len] else {
		writeError(err_buf, err_buf_len, "null data pointer");
		return null;
	};
	const path_slice = if (path) |p| std.mem.span(p) else {
		writeError(err_buf, err_buf_len, "null path");
		return null;
	};
	const format_slice = if (format) |f| std.mem.span(f) else {
		writeError(err_buf, err_buf_len, "null format");
		return null;
	};

	const parser = getParser(format_slice) orelse {
		writeError(err_buf, err_buf_len, "unsupported format");
		return null;
	};

	const doc = parser.parse(gpa, content, path_slice) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer parser.free(gpa, doc);

	const json = jsonDocument(doc) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer gpa.free(json);

	return dupeToC(json) orelse {
		writeError(err_buf, err_buf_len, "out of memory");
		return null;
	};
}

/// Parse raw document bytes and chunk the result.
/// Returns JSON array of chunks. Caller must free with docscan_free().
export fn docscan_chunk(
	text: ?[*]const u8,
	text_len: usize,
	path: ?[*:0]const u8,
	format: ?[*:0]const u8,
	max_chunk_tokens: u32,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) ?[*:0]u8 {
	const content = if (text) |t| t[0..text_len] else {
		writeError(err_buf, err_buf_len, "null text pointer");
		return null;
	};
	const path_slice = if (path) |p| std.mem.span(p) else {
		writeError(err_buf, err_buf_len, "null path");
		return null;
	};
	const format_slice = if (format) |f| std.mem.span(f) else {
		writeError(err_buf, err_buf_len, "null format");
		return null;
	};

	const parser = getParser(format_slice) orelse {
		writeError(err_buf, err_buf_len, "unsupported format");
		return null;
	};

	// Parse the document first
	const doc = parser.parse(gpa, content, path_slice) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer parser.free(gpa, doc);

	// Chunk it
	const opts = chunker.ChunkOptions{
		.max_chunk_tokens = if (max_chunk_tokens > 0) max_chunk_tokens else 1500,
	};
	const chunks = chunker.chunk(gpa, doc, opts) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer chunker.freeChunks(gpa, chunks);

	// Serialize to JSON
	const json = jsonChunks(chunks) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer gpa.free(json);

	return dupeToC(json) orelse {
		writeError(err_buf, err_buf_len, "out of memory");
		return null;
	};
}

/// Index a document: parse raw bytes, chunk, store document + chunks + embeddings.
/// This is the high-level "fast path" for the CLI.
/// embeddings: flat float array of size (num_chunks * embedding_dim), or null.
/// Returns 0 on success, -1 on error.
export fn docscan_index_file(
	db: ?*DocscanDb,
	data: ?[*]const u8,
	len: usize,
	path: ?[*:0]const u8,
	format: ?[*:0]const u8,
	content_hash: ?[*:0]const u8,
	embeddings: ?[*]const f32,
	num_chunks: u32,
	max_chunk_tokens: u32,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) c_int {
	const d = db orelse {
		writeError(err_buf, err_buf_len, "null db handle");
		return -1;
	};
	const content = if (data) |ptr| ptr[0..len] else {
		writeError(err_buf, err_buf_len, "null data pointer");
		return -1;
	};
	const path_slice = if (path) |p| std.mem.span(p) else {
		writeError(err_buf, err_buf_len, "null path");
		return -1;
	};
	const format_slice = if (format) |f| std.mem.span(f) else {
		writeError(err_buf, err_buf_len, "null format");
		return -1;
	};
	const hash_slice = if (content_hash) |h| std.mem.span(h) else {
		writeError(err_buf, err_buf_len, "null content_hash");
		return -1;
	};

	const parser = getParser(format_slice) orelse {
		writeError(err_buf, err_buf_len, "unsupported format");
		return -1;
	};

	// Parse
	const doc = parser.parse(gpa, content, path_slice) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return -1;
	};
	defer parser.free(gpa, doc);

	// Chunk
	const opts = chunker.ChunkOptions{
		.max_chunk_tokens = if (max_chunk_tokens > 0) max_chunk_tokens else 1500,
	};
	const chunks = chunker.chunk(gpa, doc, opts) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return -1;
	};
	defer chunker.freeChunks(gpa, chunks);

	// Insert document
	const doc_id = storage.insertDocument(
		&d.db,
		path_slice,
		format_slice,
		if (doc.title) |t| t else null,
		hash_slice,
		null,
	) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return -1;
	};

	// Insert chunks + embeddings
	for (chunks, 0..) |chunk, idx| {
		const chunk_id = storage.insertChunk(&d.db, doc_id, chunk) catch |e| {
			writeZigError(err_buf, err_buf_len, e);
			return -1;
		};

		// Insert embedding if provided
		if (embeddings) |emb_ptr| {
			if (idx < num_chunks) {
				const dim = d.db.embedding_dim;
				const offset = idx * dim;
				const emb_slice = emb_ptr[offset .. offset + dim];
				storage.insertEmbedding(&d.db, chunk_id, emb_slice) catch |e| {
					writeZigError(err_buf, err_buf_len, e);
					return -1;
				};
			}
		}
	}

	return 0;
}

/// Search the database. mode: "hybrid", "exact", "similar".
/// Returns JSON array of results (caller must free with docscan_free), or null on error.
export fn docscan_search(
	db: ?*DocscanDb,
	query_text: ?[*:0]const u8,
	query_embedding: ?[*]const f32,
	embedding_len: u32,
	mode: ?[*:0]const u8,
	limit: u32,
	format_filter: ?[*:0]const u8,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) ?[*:0]u8 {
	const d = db orelse {
		writeError(err_buf, err_buf_len, "null db handle");
		return null;
	};
	const qt = if (query_text) |q| std.mem.span(q) else "";
	const mode_str = if (mode) |m| std.mem.span(m) else "hybrid";

	const search_mode: search_mod.SearchMode = blk: {
		if (std.mem.eql(u8, mode_str, "exact")) break :blk .exact;
		if (std.mem.eql(u8, mode_str, "similar")) break :blk .similar;
		break :blk .hybrid;
	};

	const qe: ?[]const f32 = if (query_embedding) |e| e[0..embedding_len] else null;
	const ff: ?[]const u8 = if (format_filter) |f| blk: {
		const s = std.mem.span(f);
		break :blk if (s.len > 0) s else null;
	} else null;

	const options = search_mod.SearchOptions{
		.mode = search_mode,
		.limit = if (limit > 0) limit else 10,
		.format_filter = ff,
	};

	const results = search_mod.search(gpa, &d.db, qt, qe, options) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer search_mod.freeResults(gpa, results);

	const json = jsonSearchResults(results) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer gpa.free(json);

	return dupeToC(json) orelse {
		writeError(err_buf, err_buf_len, "out of memory");
		return null;
	};
}

/// Check if a document needs re-indexing.
/// Returns 1=yes, 0=no, -1=error.
export fn docscan_needs_reindex(
	db: ?*DocscanDb,
	path: ?[*:0]const u8,
	content_hash: ?[*:0]const u8,
) c_int {
	const d = db orelse return -1;
	const p = if (path) |pp| std.mem.span(pp) else return -1;
	const h = if (content_hash) |hh| std.mem.span(hh) else return -1;

	const needs = storage.needsReindex(&d.db, p, h) catch return -1;
	return if (needs) 1 else 0;
}

/// Remove a document and all its chunks/embeddings.
/// Returns 0 on success, -1 on error.
export fn docscan_remove_document(
	db: ?*DocscanDb,
	path: ?[*:0]const u8,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) c_int {
	const d = db orelse {
		writeError(err_buf, err_buf_len, "null db handle");
		return -1;
	};
	const p = if (path) |pp| std.mem.span(pp) else {
		writeError(err_buf, err_buf_len, "null path");
		return -1;
	};

	// Look up document by path
	const maybe_doc = storage.getDocumentByPath(&d.db, gpa, p) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return -1;
	};
	const doc_rec = maybe_doc orelse {
		writeError(err_buf, err_buf_len, "document not found");
		return -1;
	};
	defer doc_rec.deinit(gpa);

	// Remove chunks (including FTS and embeddings), then document
	storage.removeChunksForDocument(&d.db, doc_rec.id) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return -1;
	};
	storage.removeDocument(&d.db, doc_rec.id) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return -1;
	};

	return 0;
}

/// Get database status as JSON. Caller must free with docscan_free.
export fn docscan_status(
	db: ?*DocscanDb,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) ?[*:0]u8 {
	const d = db orelse {
		writeError(err_buf, err_buf_len, "null db handle");
		return null;
	};

	const stats = storage.getStats(&d.db) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};

	const json = jsonStats(stats) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer gpa.free(json);

	return dupeToC(json) orelse {
		writeError(err_buf, err_buf_len, "out of memory");
		return null;
	};
}

/// Get a chunk by ID. Returns JSON or null on error.
/// Caller must free with docscan_free.
export fn docscan_read_chunk(
	db: ?*DocscanDb,
	chunk_id: i64,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) ?[*:0]u8 {
	const d = db orelse {
		writeError(err_buf, err_buf_len, "null db handle");
		return null;
	};

	const maybe_rec = storage.getChunk(&d.db, gpa, chunk_id) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	const rec = maybe_rec orelse {
		writeError(err_buf, err_buf_len, "chunk not found");
		return null;
	};
	defer rec.deinit(gpa);

	const json = jsonChunkRecord(rec) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	defer gpa.free(json);

	return dupeToC(json) orelse {
		writeError(err_buf, err_buf_len, "out of memory");
		return null;
	};
}

/// Get a config value by key. Returns the value string or null.
/// Caller must free with docscan_free.
export fn docscan_config_get(
	db: ?*DocscanDb,
	key: ?[*:0]const u8,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) ?[*:0]u8 {
	const d = db orelse {
		writeError(err_buf, err_buf_len, "null db handle");
		return null;
	};
	const k = if (key) |kk| std.mem.span(kk) else {
		writeError(err_buf, err_buf_len, "null key");
		return null;
	};

	const maybe_val = storage.getConfig(&d.db, gpa, k) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return null;
	};
	const val = maybe_val orelse {
		// Not an error — key simply doesn't exist. Return null.
		return null;
	};
	defer gpa.free(val);

	return dupeToC(val) orelse {
		writeError(err_buf, err_buf_len, "out of memory");
		return null;
	};
}

/// Set a config key-value pair. Returns 0 on success, -1 on error.
export fn docscan_config_set(
	db: ?*DocscanDb,
	key: ?[*:0]const u8,
	value: ?[*:0]const u8,
	err_buf: ?[*]u8,
	err_buf_len: usize,
) c_int {
	const d = db orelse {
		writeError(err_buf, err_buf_len, "null db handle");
		return -1;
	};
	const k = if (key) |kk| std.mem.span(kk) else {
		writeError(err_buf, err_buf_len, "null key");
		return -1;
	};
	const v = if (value) |vv| std.mem.span(vv) else {
		writeError(err_buf, err_buf_len, "null value");
		return -1;
	};

	storage.setConfig(&d.db, k, v) catch |e| {
		writeZigError(err_buf, err_buf_len, e);
		return -1;
	};

	return 0;
}

/// Free a string returned by any docscan_* function.
export fn docscan_free(ptr: ?[*:0]u8) void {
	if (ptr) |p| {
		// Find the length of the null-terminated string to reconstruct the slice.
		const s = std.mem.span(p);
		// Free the allocation (len + 1 for the null terminator).
		gpa.free(s.ptr[0 .. s.len + 1]);
	}
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "docscan_version returns expected string" {
	const v = docscan_version();
	try testing.expectEqualStrings("0.1.0", std.mem.span(v));
}

test "docscan_open and docscan_close — in-memory DB" {
	var err_buf: [256]u8 = undefined;
	const db = docscan_open(":memory:", 4, &err_buf, err_buf.len);
	try testing.expect(db != null);
	docscan_close(db);
}

test "docscan_open — error on bad path writes to err_buf" {
	var err_buf: [256]u8 = undefined;
	// A path that should fail (directory that doesn't exist)
	const db = docscan_open("/nonexistent/path/that/surely/does/not/exist/db.sqlite", 4, &err_buf, err_buf.len);
	// If it fails, err_buf should have a message
	if (db == null) {
		const err = std.mem.span(@as([*:0]const u8, @ptrCast(&err_buf)));
		try testing.expect(err.len > 0);
	} else {
		// Some systems might create in-memory fallback; just close it
		docscan_close(db);
	}
}

test "docscan_parse — markdown returns JSON" {
	const md_input = "# Hello\n\nWorld content here.\n";
	var err_buf: [256]u8 = undefined;
	const result = docscan_parse(md_input.ptr, md_input.len, "/test/hello.md", "md", &err_buf, err_buf.len);
	try testing.expect(result != null);
	defer docscan_free(result);

	const json = std.mem.span(result.?);
	// Should contain basic structure
	try testing.expect(std.mem.indexOf(u8, json, "\"path\"") != null);
	try testing.expect(std.mem.indexOf(u8, json, "\"format\"") != null);
	try testing.expect(std.mem.indexOf(u8, json, "\"sections\"") != null);
	try testing.expect(std.mem.indexOf(u8, json, "Hello") != null);
	try testing.expect(std.mem.indexOf(u8, json, "World content here.") != null);
}

test "docscan_parse — unsupported format returns null with error" {
	var err_buf: [256]u8 = undefined;
	const result = docscan_parse("data", 4, "/test/file.xyz", "xyz", &err_buf, err_buf.len);
	try testing.expect(result == null);
	const err = std.mem.span(@as([*:0]const u8, @ptrCast(&err_buf)));
	try testing.expectEqualStrings("unsupported format", err);
}

test "docscan_chunk — markdown produces chunk JSON" {
	const md_input = "# Intro\n\nSome content.\n\n# Details\n\nMore content.\n";
	var err_buf: [256]u8 = undefined;
	const result = docscan_chunk(md_input.ptr, md_input.len, "/test/doc.md", "md", 1500, &err_buf, err_buf.len);
	try testing.expect(result != null);
	defer docscan_free(result);

	const json = std.mem.span(result.?);
	// Should be a JSON array
	try testing.expect(json.len > 2);
	try testing.expect(json[0] == '[');
	try testing.expect(json[json.len - 1] == ']');
	// Should contain chunk fields
	try testing.expect(std.mem.indexOf(u8, json, "\"text\"") != null);
	try testing.expect(std.mem.indexOf(u8, json, "\"section_path\"") != null);
}

test "docscan_status — returns JSON for empty DB" {
	var err_buf: [256]u8 = undefined;
	const db = docscan_open(":memory:", 4, &err_buf, err_buf.len);
	try testing.expect(db != null);
	defer docscan_close(db);

	const status = docscan_status(db, &err_buf, err_buf.len);
	try testing.expect(status != null);
	defer docscan_free(status);

	const json = std.mem.span(status.?);
	try testing.expect(std.mem.indexOf(u8, json, "\"doc_count\"") != null);
	try testing.expect(std.mem.indexOf(u8, json, "\"chunk_count\"") != null);
}

test "docscan_config_get and docscan_config_set" {
	var err_buf: [256]u8 = undefined;
	const db = docscan_open(":memory:", 4, &err_buf, err_buf.len);
	try testing.expect(db != null);
	defer docscan_close(db);

	// Set a config value
	const rc = docscan_config_set(db, "test_key", "test_value", &err_buf, err_buf.len);
	try testing.expectEqual(@as(c_int, 0), rc);

	// Get it back
	const val = docscan_config_get(db, "test_key", &err_buf, err_buf.len);
	try testing.expect(val != null);
	defer docscan_free(val);
	try testing.expectEqualStrings("test_value", std.mem.span(val.?));

	// Non-existent key returns null (not an error)
	const missing = docscan_config_get(db, "nonexistent", &err_buf, err_buf.len);
	try testing.expect(missing == null);
}

test "docscan_needs_reindex — new document returns 1" {
	var err_buf: [256]u8 = undefined;
	const db = docscan_open(":memory:", 4, &err_buf, err_buf.len);
	try testing.expect(db != null);
	defer docscan_close(db);

	const result = docscan_needs_reindex(db, "/docs/new.md", "hash123");
	try testing.expectEqual(@as(c_int, 1), result);
}

test "docscan_index_file and docscan_search — round trip" {
	var err_buf: [256]u8 = undefined;
	const db = docscan_open(":memory:", 4, &err_buf, err_buf.len);
	try testing.expect(db != null);
	defer docscan_close(db);

	// Index a markdown document
	const md_content = "# Quantum Physics\n\nThe quantum mechanics of particles.\n";
	const rc = docscan_index_file(
		db,
		md_content.ptr,
		md_content.len,
		"/docs/physics.md",
		"md",
		"hash_physics",
		null, // no embeddings
		0,
		1500,
		&err_buf,
		err_buf.len,
	);
	try testing.expectEqual(@as(c_int, 0), rc);

	// After indexing, needs_reindex should return 0 for same hash
	const reindex = docscan_needs_reindex(db, "/docs/physics.md", "hash_physics");
	try testing.expectEqual(@as(c_int, 0), reindex);

	// Search for it
	const results = docscan_search(
		db,
		"quantum",
		null,
		0,
		"exact",
		10,
		null,
		&err_buf,
		err_buf.len,
	);
	try testing.expect(results != null);
	defer docscan_free(results);

	const json = std.mem.span(results.?);
	try testing.expect(json[0] == '[');
	try testing.expect(std.mem.indexOf(u8, json, "quantum") != null);
	try testing.expect(std.mem.indexOf(u8, json, "/docs/physics.md") != null);
}

test "docscan_read_chunk — retrieves indexed chunk" {
	var err_buf: [256]u8 = undefined;
	const db = docscan_open(":memory:", 4, &err_buf, err_buf.len);
	try testing.expect(db != null);
	defer docscan_close(db);

	// Index a document
	const md_content = "# Test\n\nTest content.\n";
	const rc = docscan_index_file(
		db,
		md_content.ptr,
		md_content.len,
		"/test/doc.md",
		"md",
		"hash_test",
		null,
		0,
		1500,
		&err_buf,
		err_buf.len,
	);
	try testing.expectEqual(@as(c_int, 0), rc);

	// Read chunk ID 1 (first inserted)
	const chunk_json = docscan_read_chunk(db, 1, &err_buf, err_buf.len);
	try testing.expect(chunk_json != null);
	defer docscan_free(chunk_json);

	const json = std.mem.span(chunk_json.?);
	try testing.expect(std.mem.indexOf(u8, json, "\"text\"") != null);
	try testing.expect(std.mem.indexOf(u8, json, "Test content.") != null);
}

test "docscan_remove_document — removes indexed data" {
	var err_buf: [256]u8 = undefined;
	const db = docscan_open(":memory:", 4, &err_buf, err_buf.len);
	try testing.expect(db != null);
	defer docscan_close(db);

	// Index
	const md_content = "# Remove Me\n\nContent to remove.\n";
	const rc = docscan_index_file(
		db,
		md_content.ptr,
		md_content.len,
		"/docs/removable.md",
		"md",
		"hash_rm",
		null,
		0,
		1500,
		&err_buf,
		err_buf.len,
	);
	try testing.expectEqual(@as(c_int, 0), rc);

	// Remove it
	const rm_rc = docscan_remove_document(db, "/docs/removable.md", &err_buf, err_buf.len);
	try testing.expectEqual(@as(c_int, 0), rm_rc);

	// After removal, search should return empty
	const results = docscan_search(db, "remove", null, 0, "exact", 10, null, &err_buf, err_buf.len);
	try testing.expect(results != null);
	defer docscan_free(results);
	try testing.expectEqualStrings("[]", std.mem.span(results.?));
}

test "docscan_free — null is safe" {
	docscan_free(null); // should not crash
}

test "docscan_close — null is safe" {
	docscan_close(null); // should not crash
}

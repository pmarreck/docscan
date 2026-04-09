//! SQLite + sqlite-vec + FTS5 storage layer for documents, chunks, and embeddings.
//! Manages the persistence of parsed document data, vector embeddings for semantic
//! search, and full-text search indices via FTS5.

const std = @import("std");
const document = @import("document.zig");

const c = @cImport({
	@cDefine("SQLITE_VEC_STATIC", "1");
	@cInclude("sqlite3.h");
	@cInclude("sqlite-vec.h");
});

/// SQLite error type returned when a C API call fails.
pub const SqliteError = error{
	SqliteError,
	SqliteBusy,
	SqliteNotFound,
};

/// Storage database handle wrapping SQLite with vec and FTS5 extensions.
pub const Db = struct {
	handle: *c.sqlite3,
	embedding_dim: u32,
	allocator: std.mem.Allocator,
};

/// A persisted document record.
pub const DocumentRecord = struct {
	id: i64,
	path: []const u8,
	format: []const u8,
	title: ?[]const u8,
	content_hash: []const u8,
	metadata: ?[]const u8,
	indexed_at: i64,

	pub fn deinit(self: *const DocumentRecord, allocator: std.mem.Allocator) void {
		allocator.free(self.path);
		allocator.free(self.format);
		if (self.title) |t| allocator.free(t);
		allocator.free(self.content_hash);
		if (self.metadata) |m| allocator.free(m);
	}
};

/// A persisted chunk record.
pub const ChunkRecord = struct {
	id: i64,
	document_id: i64,
	chunk_index: i32,
	section_path: ?[]const u8,
	heading: ?[]const u8,
	text: []const u8,
	start_byte: i64,
	end_byte: i64,

	pub fn deinit(self: *const ChunkRecord, allocator: std.mem.Allocator) void {
		if (self.section_path) |sp| allocator.free(sp);
		if (self.heading) |h| allocator.free(h);
		allocator.free(self.text);
	}
};

/// A vector search result: chunk ID with distance score.
pub const VectorResult = struct {
	chunk_id: i64,
	distance: f32,
};

/// An FTS5 search result: chunk ID with BM25 rank score.
pub const FtsResult = struct {
	chunk_id: i64,
	rank: f32,
};

/// Database statistics.
pub const Stats = struct {
	doc_count: i64,
	chunk_count: i64,
	last_indexed: i64,
};

// ── Helpers ─────────────────────────────────────────────────────────────

/// Execute a simple SQL statement that returns no rows.
fn execSql(db_handle: *c.sqlite3, sql: [*:0]const u8) SqliteError!void {
	const rc = c.sqlite3_exec(db_handle, sql, null, null, null);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
}

/// Prepare a statement. Caller must finalize.
fn prepareSql(db_handle: *c.sqlite3, sql: [*:0]const u8) SqliteError!*c.sqlite3_stmt {
	var stmt: ?*c.sqlite3_stmt = null;
	const rc = c.sqlite3_prepare_v2(db_handle, sql, -1, &stmt, null);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
	return stmt orelse return SqliteError.SqliteError;
}

/// Bind a text parameter (1-indexed). Uses SQLITE_STATIC since all callers
/// keep the source data alive through statement execution and finalization.
fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) SqliteError!void {
	const rc = c.sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
}

/// Bind a nullable text parameter.
fn bindOptionalText(stmt: *c.sqlite3_stmt, idx: c_int, text: ?[]const u8) SqliteError!void {
	if (text) |t| {
		return bindText(stmt, idx, t);
	} else {
		const rc = c.sqlite3_bind_null(stmt, idx);
		if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
	}
}

/// Bind an i64 parameter.
fn bindInt64(stmt: *c.sqlite3_stmt, idx: c_int, val: i64) SqliteError!void {
	const rc = c.sqlite3_bind_int64(stmt, idx, val);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
}

/// Bind an i32 parameter.
fn bindInt32(stmt: *c.sqlite3_stmt, idx: c_int, val: i32) SqliteError!void {
	const rc = c.sqlite3_bind_int(stmt, idx, val);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
}

/// Bind a blob parameter.
fn bindBlob(stmt: *c.sqlite3_stmt, idx: c_int, data: []const u8) SqliteError!void {
	const rc = c.sqlite3_bind_blob(stmt, idx, data.ptr, @intCast(data.len), c.SQLITE_STATIC);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
}

/// Read a text column as an owned Zig slice.
fn columnText(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) !?[]const u8 {
	const ptr = c.sqlite3_column_text(stmt, col);
	if (ptr == null) return null;
	const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
	return try allocator.dupe(u8, ptr[0..len]);
}

/// Read a text column, returning error if NULL.
fn columnTextRequired(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) ![]const u8 {
	return (try columnText(allocator, stmt, col)) orelse return SqliteError.SqliteNotFound;
}

/// Step a statement expecting SQLITE_DONE (for INSERT/UPDATE/DELETE).
fn stepExpectDone(stmt: *c.sqlite3_stmt) SqliteError!void {
	const rc = c.sqlite3_step(stmt);
	if (rc != c.SQLITE_DONE) return SqliteError.SqliteError;
}

/// Finalize a statement (ignoring errors, since finalize errors are about the
/// *previous* step result, which we've already handled).
fn finalize(stmt: *c.sqlite3_stmt) void {
	_ = c.sqlite3_finalize(stmt);
}

// ── Public API ──────────────────────────────────────────────────────────

/// Open (or create) a database at the given path, initialise schema and extensions.
pub fn openDb(allocator: std.mem.Allocator, path: [*:0]const u8, embedding_dim: u32) !Db {
	var db_handle: ?*c.sqlite3 = null;
	var rc = c.sqlite3_open(path, &db_handle);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
	const handle = db_handle orelse return SqliteError.SqliteError;

	// Register sqlite-vec extension
	rc = c.sqlite3_vec_init(handle, null, null);
	if (rc != c.SQLITE_OK) {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	}

	// WAL mode for concurrency
	execSql(handle, "PRAGMA journal_mode=WAL;") catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	// Foreign keys
	execSql(handle, "PRAGMA foreign_keys=ON;") catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	// Create schema
	execSql(handle, "CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL);") catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	execSql(handle,
		\\CREATE TABLE IF NOT EXISTS documents (
		\\    id INTEGER PRIMARY KEY,
		\\    path TEXT UNIQUE NOT NULL,
		\\    format TEXT NOT NULL,
		\\    title TEXT,
		\\    content_hash TEXT NOT NULL,
		\\    metadata TEXT,
		\\    indexed_at INTEGER NOT NULL
		\\);
	) catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	execSql(handle,
		\\CREATE TABLE IF NOT EXISTS chunks (
		\\    id INTEGER PRIMARY KEY,
		\\    document_id INTEGER NOT NULL REFERENCES documents(id),
		\\    chunk_index INTEGER NOT NULL,
		\\    section_path TEXT,
		\\    heading TEXT,
		\\    text TEXT NOT NULL,
		\\    start_byte INTEGER NOT NULL,
		\\    end_byte INTEGER NOT NULL
		\\);
	) catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	// vec0 virtual table for embeddings — dimension is dynamic
	var dim_buf: [64]u8 = undefined;
	const dim_sql = std.fmt.bufPrint(&dim_buf, "{d}", .{embedding_dim}) catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	// Build the CREATE VIRTUAL TABLE statement with the dynamic dimension
	var create_vec_buf: [256]u8 = undefined;
	const create_vec_sql = std.fmt.bufPrint(&create_vec_buf,
		"CREATE VIRTUAL TABLE IF NOT EXISTS chunk_embeddings USING vec0(chunk_id INTEGER PRIMARY KEY, embedding float[{s}]);",
		.{dim_sql},
	) catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	// Null-terminate for sqlite3_exec
	if (create_vec_buf.len <= create_vec_sql.len) {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	}
	create_vec_buf[create_vec_sql.len] = 0;
	const create_vec_z: [*:0]const u8 = create_vec_buf[0..create_vec_sql.len :0];

	execSql(handle, create_vec_z) catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	// FTS5 virtual table for full-text search
	execSql(handle,
		\\CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
		\\    text, heading, section_path, content='chunks', content_rowid='id'
		\\);
	) catch {
		_ = c.sqlite3_close(handle);
		return SqliteError.SqliteError;
	};

	var db = Db{
		.handle = handle,
		.embedding_dim = embedding_dim,
		.allocator = allocator,
	};

	// Set default config values (only if not already set)
	const dim_str = std.fmt.bufPrint(&dim_buf, "{d}", .{embedding_dim}) catch {
		closeDb(&db);
		return SqliteError.SqliteError;
	};
	if (dim_buf.len <= dim_str.len) {
		closeDb(&db);
		return SqliteError.SqliteError;
	}
	dim_buf[dim_str.len] = 0;

	setConfigIfAbsent(&db, "schema_version", "1") catch {
		closeDb(&db);
		return SqliteError.SqliteError;
	};
	setConfigIfAbsent(&db, "embedding_dim", dim_str) catch {
		closeDb(&db);
		return SqliteError.SqliteError;
	};
	setConfigIfAbsent(&db, "model_name", "nomic-embed-text") catch {
		closeDb(&db);
		return SqliteError.SqliteError;
	};

	return db;
}

/// Close the database handle.
pub fn closeDb(db: *Db) void {
	_ = c.sqlite3_close(db.handle);
}

// ── Config ──────────────────────────────────────────────────────────────

/// Set a config key only if it doesn't already exist.
fn setConfigIfAbsent(db: *Db, key: []const u8, value: []const u8) !void {
	const existing = try getConfig(db, db.allocator, key);
	if (existing) |v| {
		db.allocator.free(v);
		return; // already set
	}
	try setConfig(db, key, value);
}

/// Get a config value by key. Caller owns the returned slice.
pub fn getConfig(db: *Db, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
	const stmt = try prepareSql(db.handle, "SELECT value FROM config WHERE key = ?1;");
	defer finalize(stmt);
	try bindText(stmt, 1, key);
	const rc = c.sqlite3_step(stmt);
	if (rc == c.SQLITE_ROW) {
		return try columnTextRequired(allocator, stmt, 0);
	}
	if (rc == c.SQLITE_DONE) return null;
	return SqliteError.SqliteError;
}

/// Set a config key-value pair (upsert).
pub fn setConfig(db: *Db, key: []const u8, value: []const u8) !void {
	const stmt = try prepareSql(db.handle,
		"INSERT INTO config (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
	);
	defer finalize(stmt);
	try bindText(stmt, 1, key);
	try bindText(stmt, 2, value);
	try stepExpectDone(stmt);
}

// ── Documents ───────────────────────────────────────────────────────────

/// Insert a document and return its rowid.
pub fn insertDocument(db: *Db, path: []const u8, format: []const u8, title: ?[]const u8, content_hash: []const u8, metadata: ?[]const u8) !i64 {
	const now = std.time.timestamp();
	const stmt = try prepareSql(db.handle,
		"INSERT INTO documents (path, format, title, content_hash, metadata, indexed_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
	);
	defer finalize(stmt);
	try bindText(stmt, 1, path);
	try bindText(stmt, 2, format);
	try bindOptionalText(stmt, 3, title);
	try bindText(stmt, 4, content_hash);
	try bindOptionalText(stmt, 5, metadata);
	try bindInt64(stmt, 6, now);
	try stepExpectDone(stmt);
	return c.sqlite3_last_insert_rowid(db.handle);
}

/// Retrieve a document by its file path. Caller owns the record's strings.
pub fn getDocumentByPath(db: *Db, allocator: std.mem.Allocator, path: []const u8) !?DocumentRecord {
	const stmt = try prepareSql(db.handle,
		"SELECT id, path, format, title, content_hash, metadata, indexed_at FROM documents WHERE path = ?1;",
	);
	defer finalize(stmt);
	try bindText(stmt, 1, path);
	const rc = c.sqlite3_step(stmt);
	if (rc == c.SQLITE_ROW) {
		const rec_path = try columnTextRequired(allocator, stmt, 1);
		errdefer allocator.free(rec_path);
		const rec_format = try columnTextRequired(allocator, stmt, 2);
		errdefer allocator.free(rec_format);
		const rec_title = try columnText(allocator, stmt, 3);
		errdefer if (rec_title) |t| allocator.free(t);
		const rec_hash = try columnTextRequired(allocator, stmt, 4);
		errdefer allocator.free(rec_hash);
		const rec_meta = try columnText(allocator, stmt, 5);

		return DocumentRecord{
			.id = c.sqlite3_column_int64(stmt, 0),
			.path = rec_path,
			.format = rec_format,
			.title = rec_title,
			.content_hash = rec_hash,
			.metadata = rec_meta,
			.indexed_at = c.sqlite3_column_int64(stmt, 6),
		};
	}
	if (rc == c.SQLITE_DONE) return null;
	return SqliteError.SqliteError;
}

/// Remove a document by ID (chunks must be removed separately first).
pub fn removeDocument(db: *Db, doc_id: i64) !void {
	const stmt = try prepareSql(db.handle, "DELETE FROM documents WHERE id = ?1;");
	defer finalize(stmt);
	try bindInt64(stmt, 1, doc_id);
	try stepExpectDone(stmt);
}

/// Check whether a document needs re-indexing.
/// Returns true if the document is new or its content hash has changed.
pub fn needsReindex(db: *Db, path: []const u8, content_hash: []const u8) !bool {
	const stmt = try prepareSql(db.handle, "SELECT content_hash FROM documents WHERE path = ?1;");
	defer finalize(stmt);
	try bindText(stmt, 1, path);
	const rc = c.sqlite3_step(stmt);
	if (rc == c.SQLITE_ROW) {
		const existing_ptr = c.sqlite3_column_text(stmt, 0);
		if (existing_ptr == null) return true;
		const existing_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
		const existing = existing_ptr[0..existing_len];
		return !std.mem.eql(u8, existing, content_hash);
	}
	if (rc == c.SQLITE_DONE) return true; // not in DB = needs indexing
	return SqliteError.SqliteError;
}

// ── Chunks ──────────────────────────────────────────────────────────────

/// Insert a chunk and return its rowid. Also inserts into FTS5 index.
pub fn insertChunk(db: *Db, doc_id: i64, chunk: document.Chunk) !i64 {
	const stmt = try prepareSql(db.handle,
		"INSERT INTO chunks (document_id, chunk_index, section_path, heading, text, start_byte, end_byte) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
	);
	defer finalize(stmt);
	try bindInt64(stmt, 1, doc_id);
	try bindInt32(stmt, 2, @intCast(chunk.chunk_index));
	try bindOptionalText(stmt, 3, if (chunk.section_path.len > 0) chunk.section_path else null);
	try bindOptionalText(stmt, 4, chunk.heading);
	try bindText(stmt, 5, chunk.text);
	try bindInt64(stmt, 6, @intCast(chunk.start_byte));
	try bindInt64(stmt, 7, @intCast(chunk.end_byte));
	try stepExpectDone(stmt);
	const chunk_id = c.sqlite3_last_insert_rowid(db.handle);

	// Insert into FTS5 index
	const fts_stmt = try prepareSql(db.handle,
		"INSERT INTO chunks_fts (rowid, text, heading, section_path) VALUES (?1, ?2, ?3, ?4);",
	);
	defer finalize(fts_stmt);
	try bindInt64(fts_stmt, 1, chunk_id);
	try bindText(fts_stmt, 2, chunk.text);
	try bindOptionalText(fts_stmt, 3, chunk.heading);
	try bindOptionalText(fts_stmt, 4, if (chunk.section_path.len > 0) chunk.section_path else null);
	try stepExpectDone(fts_stmt);

	return chunk_id;
}

/// Retrieve a chunk by its ID. Caller owns the record's strings.
pub fn getChunk(db: *Db, allocator: std.mem.Allocator, chunk_id: i64) !?ChunkRecord {
	const stmt = try prepareSql(db.handle,
		"SELECT id, document_id, chunk_index, section_path, heading, text, start_byte, end_byte FROM chunks WHERE id = ?1;",
	);
	defer finalize(stmt);
	try bindInt64(stmt, 1, chunk_id);
	const rc = c.sqlite3_step(stmt);
	if (rc == c.SQLITE_ROW) {
		const sec_path = try columnText(allocator, stmt, 3);
		errdefer if (sec_path) |sp| allocator.free(sp);
		const heading = try columnText(allocator, stmt, 4);
		errdefer if (heading) |h| allocator.free(h);
		const text = try columnTextRequired(allocator, stmt, 5);

		return ChunkRecord{
			.id = c.sqlite3_column_int64(stmt, 0),
			.document_id = c.sqlite3_column_int64(stmt, 1),
			.chunk_index = @intCast(c.sqlite3_column_int(stmt, 2)),
			.section_path = sec_path,
			.heading = heading,
			.text = text,
			.start_byte = c.sqlite3_column_int64(stmt, 6),
			.end_byte = c.sqlite3_column_int64(stmt, 7),
		};
	}
	if (rc == c.SQLITE_DONE) return null;
	return SqliteError.SqliteError;
}

/// Remove all chunks for a document, including FTS5 and embedding entries.
pub fn removeChunksForDocument(db: *Db, doc_id: i64) !void {
	// First, delete FTS5 entries for each chunk (content-sync requires manual delete)
	{
		const sel = try prepareSql(db.handle,
			"SELECT id, text, heading, section_path FROM chunks WHERE document_id = ?1;",
		);
		defer finalize(sel);
		try bindInt64(sel, 1, doc_id);

		while (true) {
			const rc = c.sqlite3_step(sel);
			if (rc == c.SQLITE_DONE) break;
			if (rc != c.SQLITE_ROW) return SqliteError.SqliteError;

			const row_id = c.sqlite3_column_int64(sel, 0);
			const text_ptr = c.sqlite3_column_text(sel, 1);
			const text_len: usize = @intCast(c.sqlite3_column_bytes(sel, 1));
			const heading_ptr = c.sqlite3_column_text(sel, 2);
			const heading_len: usize = @intCast(c.sqlite3_column_bytes(sel, 2));
			const sp_ptr = c.sqlite3_column_text(sel, 3);
			const sp_len: usize = @intCast(c.sqlite3_column_bytes(sel, 3));

			const fts_del = try prepareSql(db.handle,
				"INSERT INTO chunks_fts(chunks_fts, rowid, text, heading, section_path) VALUES('delete', ?1, ?2, ?3, ?4);",
			);
			defer finalize(fts_del);
			try bindInt64(fts_del, 1, row_id);
			if (text_ptr != null) {
				try bindText(fts_del, 2, text_ptr[0..text_len]);
			} else {
				const bind_rc = c.sqlite3_bind_null(fts_del, 2);
				if (bind_rc != c.SQLITE_OK) return SqliteError.SqliteError;
			}
			if (heading_ptr != null) {
				try bindText(fts_del, 3, heading_ptr[0..heading_len]);
			} else {
				const bind_rc = c.sqlite3_bind_null(fts_del, 3);
				if (bind_rc != c.SQLITE_OK) return SqliteError.SqliteError;
			}
			if (sp_ptr != null) {
				try bindText(fts_del, 4, sp_ptr[0..sp_len]);
			} else {
				const bind_rc = c.sqlite3_bind_null(fts_del, 4);
				if (bind_rc != c.SQLITE_OK) return SqliteError.SqliteError;
			}
			try stepExpectDone(fts_del);
		}
	}

	// Delete embeddings for chunks belonging to this document
	{
		const del_emb = try prepareSql(db.handle,
			"DELETE FROM chunk_embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id = ?1);",
		);
		defer finalize(del_emb);
		try bindInt64(del_emb, 1, doc_id);
		try stepExpectDone(del_emb);
	}

	// Delete chunks
	{
		const del_chunks = try prepareSql(db.handle, "DELETE FROM chunks WHERE document_id = ?1;");
		defer finalize(del_chunks);
		try bindInt64(del_chunks, 1, doc_id);
		try stepExpectDone(del_chunks);
	}
}

// ── Embeddings ──────────────────────────────────────────────────────────

/// Insert a vector embedding for a chunk.
pub fn insertEmbedding(db: *Db, chunk_id: i64, embedding: []const f32) !void {
	const stmt = try prepareSql(db.handle, "INSERT INTO chunk_embeddings (chunk_id, embedding) VALUES (?1, ?2);");
	defer finalize(stmt);
	try bindInt64(stmt, 1, chunk_id);
	// Bind embedding as a blob (float array)
	const byte_len: c_int = @intCast(embedding.len * @sizeOf(f32));
	const rc = c.sqlite3_bind_blob(stmt, 2, @ptrCast(embedding.ptr), byte_len, c.SQLITE_STATIC);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;
	try stepExpectDone(stmt);
}

/// Perform a KNN vector search. Returns up to `limit` results sorted by distance (ascending).
/// Caller owns the returned slice.
pub fn searchVector(db: *Db, allocator: std.mem.Allocator, query_embedding: []const f32, limit: u32) ![]VectorResult {
	const stmt = try prepareSql(db.handle,
		"SELECT chunk_id, distance FROM chunk_embeddings WHERE embedding MATCH ?1 AND k = ?2;",
	);
	defer finalize(stmt);

	// Bind query as blob
	const byte_len: c_int = @intCast(query_embedding.len * @sizeOf(f32));
	var rc = c.sqlite3_bind_blob(stmt, 1, @ptrCast(query_embedding.ptr), byte_len, c.SQLITE_STATIC);
	if (rc != c.SQLITE_OK) return SqliteError.SqliteError;

	try bindInt32(stmt, 2, @intCast(limit));

	var results: std.ArrayListUnmanaged(VectorResult) = .{};
	errdefer results.deinit(allocator);

	while (true) {
		rc = c.sqlite3_step(stmt);
		if (rc == c.SQLITE_DONE) break;
		if (rc != c.SQLITE_ROW) return SqliteError.SqliteError;
		try results.append(allocator, .{
			.chunk_id = c.sqlite3_column_int64(stmt, 0),
			.distance = @floatCast(c.sqlite3_column_double(stmt, 1)),
		});
	}

	return results.toOwnedSlice(allocator);
}

// ── FTS5 ────────────────────────────────────────────────────────────────

/// Perform an FTS5 full-text search. Returns up to `limit` results sorted by rank.
/// Caller owns the returned slice.
pub fn searchFts(db: *Db, allocator: std.mem.Allocator, query: []const u8, limit: u32) ![]FtsResult {
	const stmt = try prepareSql(db.handle,
		"SELECT rowid, -rank FROM chunks_fts WHERE chunks_fts MATCH ?1 ORDER BY rank LIMIT ?2;",
	);
	defer finalize(stmt);
	try bindText(stmt, 1, query);
	try bindInt32(stmt, 2, @intCast(limit));

	var results: std.ArrayListUnmanaged(FtsResult) = .{};
	errdefer results.deinit(allocator);

	while (true) {
		const rc = c.sqlite3_step(stmt);
		if (rc == c.SQLITE_DONE) break;
		if (rc != c.SQLITE_ROW) return SqliteError.SqliteError;
		try results.append(allocator, .{
			.chunk_id = c.sqlite3_column_int64(stmt, 0),
			.rank = @floatCast(c.sqlite3_column_double(stmt, 1)),
		});
	}

	return results.toOwnedSlice(allocator);
}

// ── Stats ───────────────────────────────────────────────────────────────

/// Get database statistics: document count, chunk count, and latest indexed_at timestamp.
pub fn getStats(db: *Db) !Stats {
	var stats = Stats{ .doc_count = 0, .chunk_count = 0, .last_indexed = 0 };

	{
		const stmt = try prepareSql(db.handle, "SELECT COUNT(*) FROM documents;");
		defer finalize(stmt);
		if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
			stats.doc_count = c.sqlite3_column_int64(stmt, 0);
		}
	}
	{
		const stmt = try prepareSql(db.handle, "SELECT COUNT(*) FROM chunks;");
		defer finalize(stmt);
		if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
			stats.chunk_count = c.sqlite3_column_int64(stmt, 0);
		}
	}
	{
		const stmt = try prepareSql(db.handle, "SELECT MAX(indexed_at) FROM documents;");
		defer finalize(stmt);
		if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
			stats.last_indexed = c.sqlite3_column_int64(stmt, 0);
		}
	}

	return stats;
}

// ── Tests ───────────────────────────────────────────────────────────────

fn openTestDb() !Db {
	return openDb(std.testing.allocator, ":memory:", 4);
}

test "open and close DB — schema is created" {
	var db = try openTestDb();
	defer closeDb(&db);

	// Verify tables exist by querying sqlite_master
	const stmt = try prepareSql(db.handle,
		"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;",
	);
	defer finalize(stmt);

	var tables: std.ArrayListUnmanaged([]const u8) = .{};
	defer {
		for (tables.items) |t| std.testing.allocator.free(t);
		tables.deinit(std.testing.allocator);
	}

	while (true) {
		const rc = c.sqlite3_step(stmt);
		if (rc == c.SQLITE_DONE) break;
		if (rc != c.SQLITE_ROW) return SqliteError.SqliteError;
		const name = try columnTextRequired(std.testing.allocator, stmt, 0);
		try tables.append(std.testing.allocator, name);
	}

	// Should have at minimum: chunks, config, documents
	// (FTS and vec tables have internal names too)
	var found_chunks = false;
	var found_config = false;
	var found_documents = false;
	for (tables.items) |name| {
		if (std.mem.eql(u8, name, "chunks")) found_chunks = true;
		if (std.mem.eql(u8, name, "config")) found_config = true;
		if (std.mem.eql(u8, name, "documents")) found_documents = true;
	}
	try std.testing.expect(found_chunks);
	try std.testing.expect(found_config);
	try std.testing.expect(found_documents);
}

test "insert and retrieve document — round-trip" {
	var db = try openTestDb();
	defer closeDb(&db);

	const doc_id = try insertDocument(&db, "/test/hello.md", "md", "Hello World", "abc123", "{\"author\":\"Peter\"}");
	try std.testing.expect(doc_id > 0);

	const maybe_doc = try getDocumentByPath(&db, std.testing.allocator, "/test/hello.md");
	try std.testing.expect(maybe_doc != null);
	const doc = maybe_doc.?;
	defer doc.deinit(std.testing.allocator);

	try std.testing.expectEqual(doc_id, doc.id);
	try std.testing.expectEqualStrings("/test/hello.md", doc.path);
	try std.testing.expectEqualStrings("md", doc.format);
	try std.testing.expectEqualStrings("Hello World", doc.title.?);
	try std.testing.expectEqualStrings("abc123", doc.content_hash);
	try std.testing.expectEqualStrings("{\"author\":\"Peter\"}", doc.metadata.?);
	try std.testing.expect(doc.indexed_at > 0);
}

test "insert and retrieve chunk — round-trip" {
	var db = try openTestDb();
	defer closeDb(&db);

	const doc_id = try insertDocument(&db, "/test/file.pdf", "pdf", null, "hash1", null);

	const chunk = document.Chunk{
		.document_path = "/test/file.pdf",
		.section_path = "Section 1 > 1.1",
		.heading = "Introduction",
		.text = "Lorem ipsum dolor sit amet.",
		.start_byte = 0,
		.end_byte = 27,
		.chunk_index = 0,
	};
	const chunk_id = try insertChunk(&db, doc_id, chunk);
	try std.testing.expect(chunk_id > 0);

	const maybe_rec = try getChunk(&db, std.testing.allocator, chunk_id);
	try std.testing.expect(maybe_rec != null);
	const rec = maybe_rec.?;
	defer rec.deinit(std.testing.allocator);

	try std.testing.expectEqual(doc_id, rec.document_id);
	try std.testing.expectEqual(@as(i32, 0), rec.chunk_index);
	try std.testing.expectEqualStrings("Section 1 > 1.1", rec.section_path.?);
	try std.testing.expectEqualStrings("Introduction", rec.heading.?);
	try std.testing.expectEqualStrings("Lorem ipsum dolor sit amet.", rec.text);
	try std.testing.expectEqual(@as(i64, 0), rec.start_byte);
	try std.testing.expectEqual(@as(i64, 27), rec.end_byte);
}

test "needsReindex — unchanged file returns false" {
	var db = try openTestDb();
	defer closeDb(&db);

	_ = try insertDocument(&db, "/test/stable.md", "md", null, "samehash", null);

	const needs = try needsReindex(&db, "/test/stable.md", "samehash");
	try std.testing.expect(!needs);
}

test "needsReindex — changed file returns true" {
	var db = try openTestDb();
	defer closeDb(&db);

	_ = try insertDocument(&db, "/test/changed.md", "md", null, "oldhash", null);

	const needs = try needsReindex(&db, "/test/changed.md", "newhash");
	try std.testing.expect(needs);
}

test "needsReindex — new file returns true" {
	var db = try openTestDb();
	defer closeDb(&db);

	const needs = try needsReindex(&db, "/test/brand_new.md", "anyhash");
	try std.testing.expect(needs);
}

test "remove document cascades to chunks" {
	var db = try openTestDb();
	defer closeDb(&db);

	const doc_id = try insertDocument(&db, "/test/remove_me.md", "md", null, "hash", null);

	const c1 = document.Chunk{
		.document_path = "/test/remove_me.md",
		.section_path = "A",
		.heading = "H1",
		.text = "chunk one",
		.start_byte = 0,
		.end_byte = 9,
		.chunk_index = 0,
	};
	const c2 = document.Chunk{
		.document_path = "/test/remove_me.md",
		.section_path = "B",
		.heading = "H2",
		.text = "chunk two",
		.start_byte = 10,
		.end_byte = 19,
		.chunk_index = 1,
	};
	const chunk_id1 = try insertChunk(&db, doc_id, c1);
	const chunk_id2 = try insertChunk(&db, doc_id, c2);

	// Verify chunks exist (and properly free the returned records)
	{
		const rec = (try getChunk(&db, std.testing.allocator, chunk_id1)).?;
		rec.deinit(std.testing.allocator);
	}
	{
		const rec = (try getChunk(&db, std.testing.allocator, chunk_id2)).?;
		rec.deinit(std.testing.allocator);
	}

	// Remove chunks for document
	try removeChunksForDocument(&db, doc_id);

	// Verify chunks are gone
	try std.testing.expect((try getChunk(&db, std.testing.allocator, chunk_id1)) == null);
	try std.testing.expect((try getChunk(&db, std.testing.allocator, chunk_id2)) == null);

	// Remove the document itself
	try removeDocument(&db, doc_id);

	// Verify document is gone
	try std.testing.expect((try getDocumentByPath(&db, std.testing.allocator, "/test/remove_me.md")) == null);
}

test "insert and query embedding — vector KNN search" {
	var db = try openTestDb();
	defer closeDb(&db);

	const doc_id = try insertDocument(&db, "/test/vectors.md", "md", null, "vhash", null);

	const chunk1 = document.Chunk{
		.document_path = "/test/vectors.md",
		.section_path = "S1",
		.heading = null,
		.text = "first chunk",
		.start_byte = 0,
		.end_byte = 11,
		.chunk_index = 0,
	};
	const chunk2 = document.Chunk{
		.document_path = "/test/vectors.md",
		.section_path = "S2",
		.heading = null,
		.text = "second chunk",
		.start_byte = 12,
		.end_byte = 24,
		.chunk_index = 1,
	};
	const cid1 = try insertChunk(&db, doc_id, chunk1);
	const cid2 = try insertChunk(&db, doc_id, chunk2);

	// Insert embeddings (dim=4)
	try insertEmbedding(&db, cid1, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
	try insertEmbedding(&db, cid2, &[_]f32{ 0.0, 1.0, 0.0, 0.0 });

	// Query — closer to embedding 1
	const query = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
	const results = try searchVector(&db, std.testing.allocator, &query, 2);
	defer std.testing.allocator.free(results);

	try std.testing.expect(results.len == 2);
	// First result should be chunk 1 (closer)
	try std.testing.expectEqual(cid1, results[0].chunk_id);
	try std.testing.expectEqual(cid2, results[1].chunk_id);
	// Distance to first should be smaller
	try std.testing.expect(results[0].distance < results[1].distance);
}

test "FTS5 search — insert chunks with text, query with MATCH" {
	var db = try openTestDb();
	defer closeDb(&db);

	const doc_id = try insertDocument(&db, "/test/fts.md", "md", null, "ftshash", null);

	const chunk1 = document.Chunk{
		.document_path = "/test/fts.md",
		.section_path = "Intro",
		.heading = "Welcome",
		.text = "The quick brown fox jumps over the lazy dog",
		.start_byte = 0,
		.end_byte = 44,
		.chunk_index = 0,
	};
	const chunk2 = document.Chunk{
		.document_path = "/test/fts.md",
		.section_path = "Body",
		.heading = "Details",
		.text = "A slow blue cat sleeps on the warm rug",
		.start_byte = 45,
		.end_byte = 83,
		.chunk_index = 1,
	};
	_ = try insertChunk(&db, doc_id, chunk1);
	_ = try insertChunk(&db, doc_id, chunk2);

	// Search for "fox"
	const results = try searchFts(&db, std.testing.allocator, "fox", 10);
	defer std.testing.allocator.free(results);

	try std.testing.expect(results.len >= 1);
	// The rank should be positive (we negate the BM25 score)
	try std.testing.expect(results[0].rank > 0);
}

test "config get/set — round-trip" {
	var db = try openTestDb();
	defer closeDb(&db);

	// Default config set by openDb
	{
		const val = try getConfig(&db, std.testing.allocator, "schema_version");
		try std.testing.expect(val != null);
		defer std.testing.allocator.free(val.?);
		try std.testing.expectEqualStrings("1", val.?);
	}

	// Set custom value
	try setConfig(&db, "my_key", "my_value");
	{
		const val = try getConfig(&db, std.testing.allocator, "my_key");
		try std.testing.expect(val != null);
		defer std.testing.allocator.free(val.?);
		try std.testing.expectEqualStrings("my_value", val.?);
	}

	// Update
	try setConfig(&db, "my_key", "updated");
	{
		const val = try getConfig(&db, std.testing.allocator, "my_key");
		try std.testing.expect(val != null);
		defer std.testing.allocator.free(val.?);
		try std.testing.expectEqualStrings("updated", val.?);
	}

	// Non-existent key
	{
		const val = try getConfig(&db, std.testing.allocator, "nonexistent");
		try std.testing.expect(val == null);
	}
}

test "getStats — verify counts" {
	var db = try openTestDb();
	defer closeDb(&db);

	// Initially empty
	{
		const stats = try getStats(&db);
		try std.testing.expectEqual(@as(i64, 0), stats.doc_count);
		try std.testing.expectEqual(@as(i64, 0), stats.chunk_count);
		try std.testing.expectEqual(@as(i64, 0), stats.last_indexed);
	}

	// Add a document and chunk
	const doc_id = try insertDocument(&db, "/test/stats.md", "md", null, "shash", null);
	const chunk = document.Chunk{
		.document_path = "/test/stats.md",
		.section_path = "",
		.heading = null,
		.text = "some content",
		.start_byte = 0,
		.end_byte = 12,
		.chunk_index = 0,
	};
	_ = try insertChunk(&db, doc_id, chunk);

	{
		const stats = try getStats(&db);
		try std.testing.expectEqual(@as(i64, 1), stats.doc_count);
		try std.testing.expectEqual(@as(i64, 1), stats.chunk_count);
		try std.testing.expect(stats.last_indexed > 0);
	}
}

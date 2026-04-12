//! Hybrid vector + BM25 search engine with Reciprocal Rank Fusion (RRF).
//! Composes storage layer functions (vector KNN, FTS5) into a unified search
//! interface that fuses semantic similarity and lexical relevance scores.
//! Pure computation — no direct I/O; all database access goes through storage.zig.

const std = @import("std");
const storage = @import("storage.zig");
const document = @import("document.zig");

/// Search strategy selector.
pub const SearchMode = enum {
	/// Both vector similarity and FTS5 lexical search, fused with RRF.
	hybrid,
	/// FTS5 full-text search only. No embeddings required.
	exact,
	/// Vector similarity search only. Requires query embedding.
	similar,
};

/// Configuration for a search query.
pub const SearchOptions = struct {
	mode: SearchMode = .hybrid,
	limit: usize = 10,
	/// Weight for vector similarity contribution in RRF fusion.
	weight_vector: f32 = 0.7,
	/// Weight for lexical (BM25) contribution in RRF fusion.
	weight_lexical: f32 = 0.3,
	/// RRF smoothing constant (higher = less sensitivity to rank position).
	rrf_k: f32 = 60.0,
	/// Heading boost per level: higher-level headings get a score multiplier.
	/// Level 1 (h1) gets boost = 1.0 + (6 - 1) * this value.
	/// Level 0 (body text) and level 6+ get no boost (multiplier = 1.0).
	heading_boost_per_level: f32 = 0.05,
	/// If set, only include results from documents with this format (e.g., "pdf").
	format_filter: ?[]const u8 = null,
};

/// Perform a search combining vector similarity and/or lexical BM25, returning
/// results sorted by fused RRF score descending.
///
/// - `exact` mode: FTS5 only, query_embedding may be null.
/// - `hybrid` mode: both vector and FTS5, fused with RRF. query_embedding required.
/// - `similar` mode: vector only. query_embedding required.
pub fn search(
	allocator: std.mem.Allocator,
	db: *storage.Db,
	query_text: []const u8,
	query_embedding: ?[]const f32,
	options: SearchOptions,
) ![]document.SearchResult {
	// How many raw results to fetch from each backend — fetch more than the
	// final limit so that RRF fusion has enough candidates after filtering.
	const fetch_limit: u32 = @intCast(@min(options.limit * 3, 1000));

	// Collect raw results from the relevant backends.
	var vector_results: ?[]storage.VectorResult = null;
	var fts_results: ?[]storage.FtsResult = null;

	defer if (vector_results) |vr| allocator.free(vr);
	defer if (fts_results) |fr| allocator.free(fr);

	switch (options.mode) {
		.hybrid => {
			const emb = query_embedding orelse return error.EmbeddingRequired;
			vector_results = try storage.searchVector(db, allocator, emb, fetch_limit);
			fts_results = try storage.searchFts(db, allocator, query_text, fetch_limit);
		},
		.exact => {
			fts_results = try storage.searchFts(db, allocator, query_text, fetch_limit);
		},
		.similar => {
			const emb = query_embedding orelse return error.EmbeddingRequired;
			vector_results = try storage.searchVector(db, allocator, emb, fetch_limit);
		},
	}

	// Build a map from chunk_id -> (vector_rank, lexical_rank, raw scores).
	// Ranks are 1-based position in the sorted result list.
	var chunk_map = std.AutoHashMap(i64, ChunkScores).init(allocator);
	defer chunk_map.deinit();

	if (vector_results) |vr| {
		for (vr, 1..) |result, rank| {
			const entry = try chunk_map.getOrPut(result.chunk_id);
			if (!entry.found_existing) {
				entry.value_ptr.* = ChunkScores{};
			}
			entry.value_ptr.vector_rank = @intCast(rank);
			entry.value_ptr.vector_distance = result.distance;
		}
	}

	if (fts_results) |fr| {
		for (fr, 1..) |result, rank| {
			const entry = try chunk_map.getOrPut(result.chunk_id);
			if (!entry.found_existing) {
				entry.value_ptr.* = ChunkScores{};
			}
			entry.value_ptr.lexical_rank = @intCast(rank);
			entry.value_ptr.lexical_score = result.rank;
		}
	}

	// Compute fused RRF score for each candidate, applying heading boost.
	var candidates: std.ArrayListUnmanaged(ScoredCandidate) = .{};
	defer candidates.deinit(allocator);

	var it = chunk_map.iterator();
	while (it.next()) |entry| {
		const scores = entry.value_ptr;
		var fused: f32 = 0.0;

		if (scores.vector_rank > 0) {
			fused += options.weight_vector / (options.rrf_k + @as(f32, @floatFromInt(scores.vector_rank)));
		}
		if (scores.lexical_rank > 0) {
			fused += options.weight_lexical / (options.rrf_k + @as(f32, @floatFromInt(scores.lexical_rank)));
		}

		// Apply heading-level boost: higher-level headings get a mild score multiplier.
		if (options.heading_boost_per_level > 0.0) {
			const heading_level = try storage.getChunkHeadingLevel(db, entry.key_ptr.*);
			const boost = computeHeadingBoost(heading_level, options.heading_boost_per_level);
			fused *= boost;
		}

		try candidates.append(allocator, .{
			.chunk_id = entry.key_ptr.*,
			.fused_score = fused,
			.vector_distance = scores.vector_distance,
			.lexical_score = scores.lexical_score,
		});
	}

	// Sort by fused score descending.
	std.mem.sort(ScoredCandidate, candidates.items, {}, struct {
		fn lessThan(_: void, a: ScoredCandidate, b: ScoredCandidate) bool {
			return a.fused_score > b.fused_score; // descending
		}
	}.lessThan);

	// Resolve candidates to full SearchResult structs, applying format filter.
	var results: std.ArrayListUnmanaged(document.SearchResult) = .{};
	errdefer {
		for (results.items) |*r| freeResult(allocator, r);
		results.deinit(allocator);
	}

	// Cache document lookups to avoid repeated queries for chunks from the same doc.
	var doc_cache = std.AutoHashMap(i64, CachedDoc).init(allocator);
	defer {
		var doc_it = doc_cache.iterator();
		while (doc_it.next()) |de| {
			de.value_ptr.record.deinit(allocator);
		}
		doc_cache.deinit();
	}

	for (candidates.items) |cand| {
		if (results.items.len >= options.limit) break;

		// Fetch chunk record.
		const maybe_chunk = try storage.getChunk(db, allocator, cand.chunk_id);
		if (maybe_chunk == null) continue;
		var chunk = maybe_chunk.?;
		errdefer chunk.deinit(allocator);

		// Look up the parent document (with caching).
		const doc_entry = try doc_cache.getOrPut(chunk.document_id);
		if (!doc_entry.found_existing) {
			const maybe_doc = try storage.getDocumentById(db, allocator, chunk.document_id);
			if (maybe_doc == null) {
				chunk.deinit(allocator);
				// Remove the just-inserted entry since we have no doc.
				_ = doc_cache.remove(chunk.document_id);
				continue;
			}
			doc_entry.value_ptr.* = .{ .record = maybe_doc.? };
		}
		const doc = &doc_entry.value_ptr.record;

		// Apply format filter.
		if (options.format_filter) |ff| {
			if (!std.mem.eql(u8, doc.format, ff)) {
				chunk.deinit(allocator);
				continue;
			}
		}

		// Build the result. We need to dupe strings that come from the chunk
		// since we transfer ownership: the chunk record will be freed after
		// copying, and document strings are in the cache (freed at end).
		const res_path = try allocator.dupe(u8, doc.path);
		errdefer allocator.free(res_path);
		const res_title = if (doc.title) |t| try allocator.dupe(u8, t) else null;
		errdefer if (res_title) |t| allocator.free(t);
		const res_section = try allocator.dupe(u8, chunk.section_path orelse "");
		errdefer allocator.free(res_section);
		const res_heading = if (chunk.heading) |h| try allocator.dupe(u8, h) else null;
		errdefer if (res_heading) |h| allocator.free(h);
		const res_text = try allocator.dupe(u8, chunk.text);
		errdefer allocator.free(res_text);

		// We've duped what we need; free the chunk's owned strings.
		chunk.deinit(allocator);

		try results.append(allocator, .{
			.document_path = res_path,
			.document_title = res_title,
			.section_path = res_section,
			.heading = res_heading,
			.text = res_text,
			.score = cand.fused_score,
			.vector_score = cand.vector_distance,
			.lexical_score = cand.lexical_score,
			.page_physical = chunk.page_physical,
			.page_logical = chunk.page_logical,
			.page_section = chunk.page_section,
			.page_roman = chunk.page_roman,
			.source_line = chunk.source_line,
		});
	}

	return results.toOwnedSlice(allocator);
}

/// Free a slice of SearchResults returned by `search()`.
pub fn freeResults(allocator: std.mem.Allocator, results: []document.SearchResult) void {
	for (results) |*r| {
		freeResult(allocator, r);
	}
	allocator.free(results);
}

// ── Internal types ─────────────────────────────────────────────────────

const ChunkScores = struct {
	vector_rank: u32 = 0,
	lexical_rank: u32 = 0,
	vector_distance: f32 = 0,
	lexical_score: f32 = 0,
};

const ScoredCandidate = struct {
	chunk_id: i64,
	fused_score: f32,
	vector_distance: f32,
	lexical_score: f32,
};

const CachedDoc = struct {
	record: storage.DocumentRecord,
};

/// Compute a heading-level boost multiplier.
/// Level 1 (h1) gets the highest boost; level 0 (body) and level >= max_level get 1.0 (no boost).
fn computeHeadingBoost(heading_level: i32, boost_per_level: f32) f32 {
	const max_level: i32 = 6;
	if (heading_level <= 0 or heading_level >= max_level) return 1.0;
	const levels_above: f32 = @floatFromInt(max_level - heading_level);
	return 1.0 + levels_above * boost_per_level;
}

fn freeResult(allocator: std.mem.Allocator, r: *document.SearchResult) void {
	allocator.free(r.document_path);
	if (r.document_title) |t| allocator.free(t);
	allocator.free(r.section_path);
	if (r.heading) |h| allocator.free(h);
	allocator.free(r.text);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Helper: open an in-memory test database with a small embedding dimension.
fn openTestDb() !storage.Db {
	return storage.openDb(testing.allocator, ":memory:", 4);
}

/// Helper: insert a document + chunk pair and optionally an embedding. Returns (doc_id, chunk_id).
fn insertTestData(
	db: *storage.Db,
	path: []const u8,
	format: []const u8,
	title: ?[]const u8,
	section_path: []const u8,
	heading: ?[]const u8,
	text: []const u8,
	embedding: ?[]const f32,
) !struct { doc_id: i64, chunk_id: i64 } {
	const doc_id = try storage.insertDocument(db, path, format, title, "hash123", null);
	const chunk = document.Chunk{
		.document_path = path,
		.section_path = section_path,
		.heading = heading,
		.text = text,
		.start_byte = 0,
		.end_byte = @intCast(text.len),
		.chunk_index = 0,
	};
	const chunk_id = try storage.insertChunk(db, doc_id, chunk);
	if (embedding) |emb| {
		try storage.insertEmbedding(db, chunk_id, emb);
	}
	return .{ .doc_id = doc_id, .chunk_id = chunk_id };
}

/// Helper: insert a chunk for an existing document (for multi-chunk tests).
fn insertTestChunk(
	db: *storage.Db,
	doc_id: i64,
	doc_path: []const u8,
	chunk_index: u32,
	section_path: []const u8,
	heading: ?[]const u8,
	text: []const u8,
	embedding: ?[]const f32,
) !i64 {
	const chunk = document.Chunk{
		.document_path = doc_path,
		.section_path = section_path,
		.heading = heading,
		.text = text,
		.start_byte = 0,
		.end_byte = @intCast(text.len),
		.chunk_index = chunk_index,
	};
	const chunk_id = try storage.insertChunk(db, doc_id, chunk);
	if (embedding) |emb| {
		try storage.insertEmbedding(db, chunk_id, emb);
	}
	return chunk_id;
}

test "exact search returns FTS matches" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Insert a chunk containing the word "quantum"
	_ = try insertTestData(&db, "/docs/physics.md", "md", "Physics Notes", "Chapter 1", "Quantum Mechanics", "The quantum mechanics of particles involves wave functions and probability.", null);

	// Insert another chunk WITHOUT the word "quantum"
	_ = try insertTestData(&db, "/docs/cooking.md", "md", "Cooking Guide", "Recipe 1", "Pasta", "Boil water and add pasta for ten minutes.", null);

	const results = try search(testing.allocator, &db, "quantum", null, .{ .mode = .exact });
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len >= 1);
	try testing.expectEqualStrings("/docs/physics.md", results[0].document_path);
	// The matching chunk's text should contain "quantum"
	try testing.expect(std.mem.indexOf(u8, results[0].text, "quantum") != null);
}

test "exact search ranks by relevance" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Chunk with "algorithm" appearing many times
	_ = try insertTestData(&db, "/docs/cs.md", "md", "CS Notes", "Algorithms", "Sorting", "algorithm sorting algorithm complexity algorithm analysis algorithm design", null);

	// Chunk with "algorithm" once
	_ = try insertTestData(&db, "/docs/intro.md", "md", "Intro", "Basics", "Overview", "This is a brief introduction to one algorithm.", null);

	const results = try search(testing.allocator, &db, "algorithm", null, .{ .mode = .exact });
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len == 2);
	// Higher-scoring result (more occurrences) should come first
	try testing.expectEqualStrings("/docs/cs.md", results[0].document_path);
	try testing.expect(results[0].lexical_score >= results[1].lexical_score);
}

test "vector search returns nearest neighbors" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Insert chunk with embedding [1, 0, 0, 0] — "north"
	_ = try insertTestData(&db, "/docs/north.md", "md", "North", "Section 1", "North", "Northern content here.", &[_]f32{ 1.0, 0.0, 0.0, 0.0 });

	// Insert chunk with embedding [0, 1, 0, 0] — "east"
	_ = try insertTestData(&db, "/docs/east.md", "md", "East", "Section 1", "East", "Eastern content here.", &[_]f32{ 0.0, 1.0, 0.0, 0.0 });

	// Query with embedding close to "north": [0.9, 0.1, 0, 0]
	const query_emb = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
	const results = try search(testing.allocator, &db, "", &query_emb, .{ .mode = .similar });
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len >= 1);
	// The "north" document should be the closest match
	try testing.expectEqualStrings("/docs/north.md", results[0].document_path);
}

test "hybrid mode fuses results — chunks in both sets score higher" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Chunk A: has the query word AND a similar embedding
	_ = try insertTestData(&db, "/docs/both.md", "md", "Both Match", "Sec", "Both", "The quantum physics of entanglement.", &[_]f32{ 1.0, 0.0, 0.0, 0.0 });

	// Chunk B: has the query word but DIFFERENT embedding
	_ = try insertTestData(&db, "/docs/text_only.md", "md", "Text Only", "Sec", "Text", "The quantum computing revolution.", &[_]f32{ 0.0, 0.0, 1.0, 0.0 });

	// Chunk C: no query word but similar embedding
	_ = try insertTestData(&db, "/docs/vec_only.md", "md", "Vec Only", "Sec", "Vec", "Completely unrelated content here.", &[_]f32{ 0.95, 0.05, 0.0, 0.0 });

	const query_emb = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
	const results = try search(testing.allocator, &db, "quantum", &query_emb, .{
		.mode = .hybrid,
		.weight_vector = 0.7,
		.weight_lexical = 0.3,
	});
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len >= 1);
	// Chunk A appears in BOTH result sets, so it should have the highest fused score.
	try testing.expectEqualStrings("/docs/both.md", results[0].document_path);
	// Its fused score should be > any single-set result
	if (results.len > 1) {
		try testing.expect(results[0].score > results[1].score);
	}
}

test "RRF score computation — exact values" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Single chunk that would be rank 1 in both vector and FTS
	_ = try insertTestData(&db, "/docs/test.md", "md", "Test", "Sec", "Heading", "alpha beta gamma", &[_]f32{ 1.0, 0.0, 0.0, 0.0 });

	const query_emb = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
	const k: f32 = 60.0;
	const wv: f32 = 0.7;
	const wl: f32 = 0.3;
	const expected_score = wv / (k + 1.0) + wl / (k + 1.0);

	const results = try search(testing.allocator, &db, "alpha", &query_emb, .{
		.mode = .hybrid,
		.weight_vector = wv,
		.weight_lexical = wl,
		.rrf_k = k,
	});
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len == 1);
	// Score should match: wv/(k+1) + wl/(k+1) = 1.0/61.0 ≈ 0.01639
	try testing.expectApproxEqAbs(expected_score, results[0].score, 1e-6);
}

test "similar mode — vector only, no FTS" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	_ = try insertTestData(&db, "/docs/a.md", "md", "Doc A", "S", null, "Hello world", &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
	_ = try insertTestData(&db, "/docs/b.md", "md", "Doc B", "S", null, "Goodbye world", &[_]f32{ 0.0, 1.0, 0.0, 0.0 });

	const query_emb = [_]f32{ 0.0, 0.95, 0.0, 0.05 };
	const results = try search(testing.allocator, &db, "", &query_emb, .{ .mode = .similar });
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len >= 1);
	try testing.expectEqualStrings("/docs/b.md", results[0].document_path);
	// In similar mode, lexical_score should be 0
	try testing.expectApproxEqAbs(@as(f32, 0.0), results[0].lexical_score, 1e-6);
}

test "limit parameter — only N results returned" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Insert 5 chunks all matching the query
	const doc_id = try storage.insertDocument(&db, "/docs/big.md", "md", "Big Doc", "hash_big", null);
	for (0..5) |i| {
		var buf: [64]u8 = undefined;
		const text = std.fmt.bufPrint(&buf, "keyword content number {d}", .{i}) catch unreachable;
		_ = try insertTestChunk(&db, doc_id, "/docs/big.md", @intCast(i), "Section", null, text, null);
	}

	const results = try search(testing.allocator, &db, "keyword", null, .{ .mode = .exact, .limit = 3 });
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len == 3);
}

test "format filter — only matching format returned" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	_ = try insertTestData(&db, "/docs/report.pdf", "pdf", "PDF Report", "Sec", null, "Important findings about climate change.", null);
	_ = try insertTestData(&db, "/docs/notes.md", "md", "Markdown Notes", "Sec", null, "Important notes about climate change.", null);

	const results = try search(testing.allocator, &db, "climate", null, .{
		.mode = .exact,
		.format_filter = "pdf",
	});
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len == 1);
	try testing.expectEqualStrings("/docs/report.pdf", results[0].document_path);
}

test "empty results — no matches" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	_ = try insertTestData(&db, "/docs/stuff.md", "md", "Stuff", "Sec", null, "Some content about dogs and cats.", null);

	const results = try search(testing.allocator, &db, "xyznonexistent", null, .{ .mode = .exact });
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len == 0);
}

test "result fields populated correctly" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	_ = try insertTestData(
		&db,
		"/docs/contract.docx",
		"docx",
		"Service Agreement",
		"Section 4 > 4.2",
		"Indemnification",
		"The party shall indemnify and hold harmless the other party.",
		&[_]f32{ 0.5, 0.5, 0.0, 0.0 },
	);

	const query_emb = [_]f32{ 0.5, 0.5, 0.0, 0.0 };
	const results = try search(testing.allocator, &db, "indemnify", &query_emb, .{ .mode = .hybrid });
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len == 1);
	const r = results[0];
	try testing.expectEqualStrings("/docs/contract.docx", r.document_path);
	try testing.expectEqualStrings("Service Agreement", r.document_title.?);
	try testing.expectEqualStrings("Section 4 > 4.2", r.section_path);
	try testing.expectEqualStrings("Indemnification", r.heading.?);
	try testing.expect(std.mem.indexOf(u8, r.text, "indemnify") != null);
	try testing.expect(r.score > 0.0);
	try testing.expect(r.vector_score >= 0.0); // distance (lower = closer)
	try testing.expect(r.lexical_score > 0.0); // BM25 rank (positive)
}

test "heading boost — h1 chunk scores higher than body chunk with equal base relevance" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Two chunks with identical text and embeddings, differing only in heading_level.
	const doc_id = try storage.insertDocument(&db, "/docs/boost.md", "md", "Boost Test", "hash_boost", null);

	// Chunk A: body text (heading_level = 0)
	const chunk_body = document.Chunk{
		.document_path = "/docs/boost.md",
		.section_path = "Section",
		.heading = null,
		.text = "quantum entanglement explanation",
		.start_byte = 0,
		.end_byte = 31,
		.chunk_index = 0,
		.heading_level = 0,
	};
	const body_id = try storage.insertChunk(&db, doc_id, chunk_body);
	try storage.insertEmbedding(&db, body_id, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });

	// Chunk B: h1 heading (heading_level = 1)
	const chunk_h1 = document.Chunk{
		.document_path = "/docs/boost.md",
		.section_path = "Title",
		.heading = "Quantum",
		.text = "quantum entanglement explanation",
		.start_byte = 31,
		.end_byte = 62,
		.chunk_index = 1,
		.heading_level = 1,
	};
	const h1_id = try storage.insertChunk(&db, doc_id, chunk_h1);
	try storage.insertEmbedding(&db, h1_id, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });

	const query_emb = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
	const results = try search(testing.allocator, &db, "quantum", &query_emb, .{
		.mode = .hybrid,
		.heading_boost_per_level = 0.05,
	});
	defer freeResults(testing.allocator, results);

	try testing.expect(results.len == 2);
	// The h1 chunk should rank first due to heading boost
	try testing.expectEqualStrings("Quantum", results[0].heading.?);
	try testing.expect(results[0].score > results[1].score);
}

test "heading boost — boost_per_level=0 does not modify scores" {
	var db = try openTestDb();
	defer storage.closeDb(&db);

	// Single chunk — verify score is unmodified when boost is disabled.
	_ = try insertTestData(&db, "/docs/noboost.md", "md", "No Boost", "Sec", "Alpha", "alpha beta content", &[_]f32{ 1.0, 0.0, 0.0, 0.0 });

	const query_emb = [_]f32{ 1.0, 0.0, 0.0, 0.0 };

	// Compute RRF score with boost disabled
	const results_off = try search(testing.allocator, &db, "alpha", &query_emb, .{
		.mode = .hybrid,
		.heading_boost_per_level = 0.0,
	});
	defer freeResults(testing.allocator, results_off);

	// Compute RRF score with boost enabled (but heading_level=0 means boost=1.0)
	const results_on = try search(testing.allocator, &db, "alpha", &query_emb, .{
		.mode = .hybrid,
		.heading_boost_per_level = 0.05,
	});
	defer freeResults(testing.allocator, results_on);

	try testing.expect(results_off.len == 1);
	try testing.expect(results_on.len == 1);
	// heading_level=0 (body text) gets boost=1.0 regardless of boost_per_level,
	// so both scores should be identical.
	try testing.expectApproxEqAbs(results_off[0].score, results_on[0].score, 1e-6);
}

test "computeHeadingBoost — values" {
	// Level 0 (body) gets no boost
	try testing.expectApproxEqAbs(@as(f32, 1.0), computeHeadingBoost(0, 0.05), 1e-6);
	// Level 1 (h1) gets max boost: 1.0 + (6-1)*0.05 = 1.25
	try testing.expectApproxEqAbs(@as(f32, 1.25), computeHeadingBoost(1, 0.05), 1e-6);
	// Level 2 (h2): 1.0 + (6-2)*0.05 = 1.20
	try testing.expectApproxEqAbs(@as(f32, 1.20), computeHeadingBoost(2, 0.05), 1e-6);
	// Level 5 (h5): 1.0 + (6-5)*0.05 = 1.05
	try testing.expectApproxEqAbs(@as(f32, 1.05), computeHeadingBoost(5, 0.05), 1e-6);
	// Level 6 (h6) gets no boost
	try testing.expectApproxEqAbs(@as(f32, 1.0), computeHeadingBoost(6, 0.05), 1e-6);
	// Negative level gets no boost
	try testing.expectApproxEqAbs(@as(f32, 1.0), computeHeadingBoost(-1, 0.05), 1e-6);
}

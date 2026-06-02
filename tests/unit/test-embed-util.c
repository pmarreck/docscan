/* Unit tests for cli/embed_util.{h,c} — the pure (no-I/O) logic that governs
 * how docscan reacts to embedding-server failures: HTTP status parsing, retry
 * classification, backoff schedule, and mapping a failed chunk range back to
 * the files that own those chunks (so they can be marked for re-indexing
 * instead of silently polluting the vector index with zero/garbage vectors).
 *
 * Compiled and run standalone by tests/unit/run-embed-util (pure C, no deps).
 */
#include "../../cli/embed_util.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { \
	checks++; \
	if (!(cond)) { failures++; printf("  FAIL: %s\n", msg); } \
} while (0)

#define CHECK_EQ(got, want, msg) do { \
	checks++; \
	long _g = (long)(got), _w = (long)(want); \
	if (_g != _w) { failures++; printf("  FAIL: %s (got %ld, want %ld)\n", msg, _g, _w); } \
} while (0)

static void test_http_status_parsing(void) {
	CHECK_EQ(http_status_from_response("HTTP/1.1 200 OK\r\n\r\n{}"), 200, "200 OK");
	CHECK_EQ(http_status_from_response("HTTP/1.0 200 OK\r\n"), 200, "HTTP/1.0 200");
	CHECK_EQ(http_status_from_response("HTTP/1.1 500 Internal Server Error\r\n"), 500, "500");
	CHECK_EQ(http_status_from_response("HTTP/1.1 429 Too Many Requests\r\n"), 429, "429");
	CHECK_EQ(http_status_from_response("HTTP/1.1 401 Unauthorized\r\n"), 401, "401");
	CHECK_EQ(http_status_from_response(""), 0, "empty -> 0");
	CHECK_EQ(http_status_from_response("garbage not http"), 0, "garbage -> 0");
	CHECK_EQ(http_status_from_response(NULL), 0, "NULL -> 0");
}

static void test_retry_classification(void) {
	/* Transient failures: should retry */
	CHECK(embed_is_retryable(0),   "transport error (status 0) retryable");
	CHECK(embed_is_retryable(408), "408 retryable");
	CHECK(embed_is_retryable(425), "425 retryable");
	CHECK(embed_is_retryable(429), "429 retryable");
	CHECK(embed_is_retryable(500), "500 retryable");
	CHECK(embed_is_retryable(502), "502 retryable");
	CHECK(embed_is_retryable(503), "503 retryable");
	CHECK(embed_is_retryable(504), "504 retryable");

	/* Permanent failures: never retry (bad request / auth / payload) */
	CHECK(!embed_is_retryable(400), "400 not retryable");
	CHECK(!embed_is_retryable(401), "401 not retryable");
	CHECK(!embed_is_retryable(403), "403 not retryable");
	CHECK(!embed_is_retryable(404), "404 not retryable");
	CHECK(!embed_is_retryable(413), "413 not retryable");
	CHECK(!embed_is_retryable(422), "422 not retryable");
	CHECK(!embed_is_retryable(200), "200 not retryable (success)");
}

static void test_backoff_schedule(void) {
	/* Deterministic, monotonic, capped. Pure function — no sleeping in tests. */
	CHECK_EQ(embed_backoff_ms(0), 250,  "attempt 0 -> 250ms");
	CHECK_EQ(embed_backoff_ms(1), 500,  "attempt 1 -> 500ms");
	CHECK_EQ(embed_backoff_ms(2), 1000, "attempt 2 -> 1000ms");
	CHECK_EQ(embed_backoff_ms(3), 2000, "attempt 3 -> 2000ms");
	CHECK_EQ(embed_backoff_ms(4), 4000, "attempt 4 -> 4000ms (cap)");
	CHECK_EQ(embed_backoff_ms(10), 4000, "attempt 10 -> 4000ms (capped)");
}

static void test_affected_files_mapping(void) {
	/* Layout: 4 files. Offsets are the chunk index where each file's chunks
	 * begin. total_chunks = 10.
	 *   file 0: chunks [0,3)   -> 0,1,2
	 *   file 1: chunks [3,3)   -> none (e.g. skipped / errored file, 0 chunks)
	 *   file 2: chunks [3,8)   -> 3,4,5,6,7
	 *   file 3: chunks [8,10)  -> 8,9
	 */
	int offsets[4] = {0, 3, 3, 8};
	int total = 10;
	unsigned char flags[4];

	/* Failed batch covers chunks [3,5) — entirely inside file 2. */
	memset(flags, 0, sizeof(flags));
	int n = file_indices_for_chunk_range(offsets, 4, total, 3, 2, flags);
	CHECK_EQ(n, 1, "range [3,5) flags 1 file");
	CHECK(!flags[0] && !flags[1] && flags[2] && !flags[3], "only file 2 flagged");

	/* Failed batch covers chunks [2,4) — spans file 0 and file 2 (file 1 empty). */
	memset(flags, 0, sizeof(flags));
	n = file_indices_for_chunk_range(offsets, 4, total, 2, 2, flags);
	CHECK_EQ(n, 2, "range [2,4) flags 2 files");
	CHECK(flags[0] && !flags[1] && flags[2] && !flags[3], "files 0 and 2 flagged");

	/* Failed batch covers the last chunk [9,10) — only file 3. */
	memset(flags, 0, sizeof(flags));
	n = file_indices_for_chunk_range(offsets, 4, total, 9, 1, flags);
	CHECK_EQ(n, 1, "range [9,10) flags 1 file");
	CHECK(flags[3] && !flags[0] && !flags[1] && !flags[2], "only file 3 flagged");

	/* Zero-length range flags nothing. */
	memset(flags, 0, sizeof(flags));
	n = file_indices_for_chunk_range(offsets, 4, total, 5, 0, flags);
	CHECK_EQ(n, 0, "empty range flags 0 files");

	/* An empty file (file 1, [3,3)) is never flagged even by an adjacent range. */
	memset(flags, 0, sizeof(flags));
	n = file_indices_for_chunk_range(offsets, 4, total, 3, 1, flags);
	CHECK(!flags[1], "empty file never flagged");
}

int main(void) {
	test_http_status_parsing();
	test_retry_classification();
	test_backoff_schedule();
	test_affected_files_mapping();

	if (failures == 0) {
		printf("embed-util: all %d checks passed\n", checks);
		return 0;
	}
	printf("embed-util: %d/%d checks FAILED\n", failures, checks);
	return 1;
}

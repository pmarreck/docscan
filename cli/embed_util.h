/* embed_util.h — pure (no-I/O) helpers governing docscan's response to
 * embedding-server failures. Separated from main.c so the failure-handling
 * logic can be unit-tested deterministically (see tests/unit/test-embed-util.c).
 */
#ifndef DOCSCAN_EMBED_UTIL_H
#define DOCSCAN_EMBED_UTIL_H

/* Parse the numeric HTTP status code from the start of a raw response buffer
 * (e.g. "HTTP/1.1 503 ...\r\n" -> 503). Returns 0 if the buffer is NULL, empty,
 * or does not begin with a recognizable HTTP status line. */
int http_status_from_response(const char* resp);

/* Classify an embedding request outcome as retryable (transient) or not.
 * status 0 means "no usable response" (connection reset, premature close,
 * transport error) and is treated as transient. 5xx and rate-limit/timeout
 * codes are transient; 4xx (bad request, auth, payload) are permanent. */
int embed_is_retryable(int http_status);

/* Backoff delay (milliseconds) before retry attempt `attempt` (0-based):
 * 250ms, 500ms, 1000ms, 2000ms, then capped at 4000ms. Pure so tests assert
 * the schedule without sleeping. */
int embed_backoff_ms(int attempt);

/* Given per-file chunk start offsets (file i owns chunks
 * [file_chunk_offsets[i], file_chunk_offsets[i+1]); the last file runs to
 * total_chunks), set out_flags[i]=1 for every file whose chunks intersect the
 * failed range [range_start, range_start+range_len). Files with zero chunks are
 * never flagged. Returns the number of files flagged. out_flags must have
 * num_files elements; callers typically OR results across multiple failed
 * ranges, so this function only ever sets (never clears) flags. */
int file_indices_for_chunk_range(const int* file_chunk_offsets, int num_files,
                                 int total_chunks, int range_start, int range_len,
                                 unsigned char* out_flags);

#endif /* DOCSCAN_EMBED_UTIL_H */

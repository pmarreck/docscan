/* embed_util.c — pure helpers for embedding-failure handling. No I/O, no
 * globals; every function is a deterministic mapping of its inputs so the
 * failure-recovery policy can be unit-tested (tests/unit/test-embed-util.c). */
#include "embed_util.h"

/* Parse "HTTP/1.x NNN ..." -> NNN. Tolerant of HTTP/1.0 and HTTP/1.1; returns
 * 0 on anything that doesn't start with a recognizable status line. */
int http_status_from_response(const char* resp) {
	if (!resp) return 0;
	if (resp[0] != 'H' || resp[1] != 'T' || resp[2] != 'T' || resp[3] != 'P'
	    || resp[4] != '/') return 0;
	/* Skip "HTTP/" then the version token up to the first space. */
	const char* p = resp + 5;
	while (*p && *p != ' ') p++;
	if (*p != ' ') return 0;
	p++; /* at first digit of status code */
	int code = 0;
	int digits = 0;
	while (*p >= '0' && *p <= '9') {
		code = code * 10 + (*p - '0');
		p++;
		digits++;
	}
	if (digits == 0) return 0;
	return code;
}

/* Transient (retry) vs permanent (give up). A status of 0 means no usable
 * HTTP response was obtained (connection reset / premature close / transport
 * error) — the dominant failure mode under sustained Connection: close load —
 * and is treated as transient. */
int embed_is_retryable(int http_status) {
	switch (http_status) {
		case 0:    /* transport error / no response */
		case 408:  /* request timeout */
		case 425:  /* too early */
		case 429:  /* too many requests */
		case 500:  /* internal server error */
		case 502:  /* bad gateway */
		case 503:  /* service unavailable */
		case 504:  /* gateway timeout */
			return 1;
		default:
			return 0;
	}
}

/* Exponential backoff: 250ms * 2^attempt, capped at 4000ms. */
int embed_backoff_ms(int attempt) {
	if (attempt < 0) attempt = 0;
	int ms = 250;
	for (int i = 0; i < attempt && ms < 4000; i++) ms *= 2;
	if (ms > 4000) ms = 4000;
	return ms;
}

/* Flag every file whose chunk interval intersects the failed range. File i
 * owns [file_chunk_offsets[i], end_i) where end_i is the next file's offset
 * (or total_chunks for the last file). Empty intervals (start==end) never
 * intersect anything. Only sets flags (caller may accumulate across ranges). */
int file_indices_for_chunk_range(const int* file_chunk_offsets, int num_files,
                                 int total_chunks, int range_start, int range_len,
                                 unsigned char* out_flags) {
	if (range_len <= 0 || !file_chunk_offsets || !out_flags) return 0;
	int range_end = range_start + range_len;
	int newly = 0;
	for (int i = 0; i < num_files; i++) {
		int file_start = file_chunk_offsets[i];
		int file_end = (i + 1 < num_files) ? file_chunk_offsets[i + 1] : total_chunks;
		if (file_end <= file_start) continue; /* file owns no chunks */
		/* half-open intervals [file_start,file_end) and [range_start,range_end) */
		if (file_start < range_end && range_start < file_end) {
			if (!out_flags[i]) { out_flags[i] = 1; newly++; }
		}
	}
	return newly;
}

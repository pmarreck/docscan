/*
 * docscan_core.h — C FFI header for docscan
 *
 * This is the public API boundary. The C CLI and any external consumers
 * include this header and link against libdocscan_core.a.
 *
 * Conventions:
 *   - All returned char* must be freed with docscan_free().
 *   - Error buffers (err_buf) are caller-provided; on error the function
 *     writes a null-terminated message into err_buf.
 *   - Functions returning pointers return NULL on error.
 *   - Functions returning int return 0 on success, -1 on error.
 *   - docscan_needs_reindex returns 1=yes, 0=no, -1=error.
 */

#ifndef DOCSCAN_CORE_H
#define DOCSCAN_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Opaque handle ───────────────────────────────────────────────── */

typedef struct DocscanDb docscan_db;

/* ── Version ─────────────────────────────────────────────────────── */

/* Return the docscan version string (statically allocated, do not free). */
const char* docscan_version(void);

/* ── Database lifecycle ──────────────────────────────────────────── */

/* Open (or create) a database. Returns NULL on error. */
docscan_db* docscan_open(const char* db_path, uint32_t embedding_dim,
                          char* err_buf, size_t err_buf_len);

/* Close a database handle (NULL-safe). */
void docscan_close(docscan_db* db);

/* ── Parsing ─────────────────────────────────────────────────────── */

/*
 * Parse a document from raw bytes.
 * format: "md", "docx", "pdf", "doc"
 * Returns JSON string with document structure. Caller must free with docscan_free().
 */
char* docscan_parse(const uint8_t* data, size_t len,
                     const char* path, const char* format,
                     char* err_buf, size_t err_buf_len);

/* ── Chunking ────────────────────────────────────────────────────── */

/*
 * Parse raw document bytes and chunk the result.
 * Returns JSON array of chunks. Caller must free with docscan_free().
 * max_chunk_tokens: 0 = default (1500).
 */
char* docscan_chunk(const uint8_t* data, size_t len,
                     const char* path, const char* format,
                     uint32_t max_chunk_tokens,
                     char* err_buf, size_t err_buf_len);

/* ── Indexing ────────────────────────────────────────────────────── */

/*
 * High-level: parse raw bytes, chunk, store document + chunks + embeddings.
 * embeddings: flat float array of size (num_chunks * embedding_dim), or NULL.
 * Returns 0 on success, -1 on error.
 */
int docscan_index_file(docscan_db* db,
                        const uint8_t* data, size_t len,
                        const char* path, const char* format,
                        const char* content_hash,
                        const float* embeddings, uint32_t num_chunks,
                        uint32_t max_chunk_tokens,
                        char* err_buf, size_t err_buf_len);

/* ── Search ──────────────────────────────────────────────────────── */

/*
 * Search the database.
 * mode: "hybrid", "exact", "similar"
 * Returns JSON array of results. Caller must free with docscan_free().
 */
char* docscan_search(docscan_db* db,
                      const char* query_text,
                      const float* query_embedding, uint32_t embedding_len,
                      const char* mode, uint32_t limit,
                      const char* format_filter,
                      char* err_buf, size_t err_buf_len);

/* ── Re-index check ──────────────────────────────────────────────── */

/* Returns 1=needs reindex, 0=up to date, -1=error. */
int docscan_needs_reindex(docscan_db* db, const char* path,
                           const char* content_hash);

/* ── Document management ─────────────────────────────────────────── */

/* Remove a document and its chunks/embeddings. Returns 0 ok, -1 error. */
int docscan_remove_document(docscan_db* db, const char* path,
                             char* err_buf, size_t err_buf_len);

/* ── Status / inspection ─────────────────────────────────────────── */

/* Database stats as JSON. Caller must free with docscan_free(). */
char* docscan_status(docscan_db* db, char* err_buf, size_t err_buf_len);

/* Retrieve a chunk by ID as JSON. Caller must free with docscan_free(). */
char* docscan_read_chunk(docscan_db* db, int64_t chunk_id,
                          char* err_buf, size_t err_buf_len);

/* ── Config ──────────────────────────────────────────────────────── */

/* Get a config value. Returns NULL if key not found. Free with docscan_free(). */
char* docscan_config_get(docscan_db* db, const char* key,
                          char* err_buf, size_t err_buf_len);

/* Set a config key-value pair. Returns 0 ok, -1 error. */
int docscan_config_set(docscan_db* db, const char* key, const char* value,
                        char* err_buf, size_t err_buf_len);

/* ── Memory ──────────────────────────────────────────────────────── */

/* Free any string returned by docscan_* functions (NULL-safe). */
void docscan_free(char* ptr);

#ifdef __cplusplus
}
#endif

#endif /* DOCSCAN_CORE_H */

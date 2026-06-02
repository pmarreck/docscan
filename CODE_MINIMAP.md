# Code Minimap

~12,700 lines across 18 source files.

## Build System

- **`build.zig`** — Zig build configuration. Declares sqlite-vec dependency, core module (rooted at `root.zig`), static library (`docscan_core`), C CLI executable (`docscan`), unit tests + FFI tests. Defaults to ReleaseFast.
- **`build.zig.zon`** — Package manifest with sqlite-vec dependency (provides sqlite3 + sqlite_vec0).
- **`flake.nix`** — Nix flake. Pre-fetches sqlite-vec via `fetchgit`, creates `zigPkgCache` linkFarm for `--system` flag. Defines `packages.default`, `checks.{build,test}`, and `devShells.default` (zig_0_15, jq, hyperfine).

## Source — Zig Core (`src/core/`)

All pure computation — no I/O.

- **`root.zig`** (25 lines) — Module root. Re-exports all sub-modules: document, parser_md, parser_docx, parser_pdf, parser_doc, chunker, storage, search, ignore, xml, zip, ole2, pdf_objects, wordfix.
- **`document.zig`** (~250 lines) — Core data model types + roman numeral conversion:
  - `Format` enum (md/docx/pdf/doc) with `extension()`/`fromExtension()`
  - `MetadataEntry`, `Section` (recursive with `page_physical`/`page_logical`/`page_section`/`page_roman`), `Document`, `Chunk`, `SearchResult`
  - `arabicToRoman()`/`romanToArabic()` — bidirectional roman numeral conversion (case-insensitive, lenient)
- **`parser_md.zig`** (417 lines) — Markdown parser. Splits on ATX headings (`# ` through `###### `), builds nested section tree. 8 tests.
- **`xml.zig`** (552 lines) — Minimal XML parser for DOCX. Elements, attributes, namespaced tags, entity decoding. 14 tests.
- **`zip.zig`** (360 lines) — In-memory ZIP reader. Stored + deflated extraction. `buildTestZip()` helper. 7 tests.
- **`parser_docx.zig`** (613 lines) — DOCX parser. ZIP extraction → XML parse → heading style detection (Heading1-6, Title) → text run extraction → metadata from core.xml. 8 tests.
- **`pdf_objects.zig`** (~1700 lines) — Low-level PDF infrastructure. Xref table and xref stream (PDF 1.5+) parsing, /Prev incremental update chain following, object lookup including compressed objects in object streams (/Type /ObjStm), stream decompression (FlateDecode/zlib with PNG predictor support) with per-context decompression cache (`stream_cache`) to avoid redundant decompression of shared object streams, indirect /Length resolution, PdfValue deep cloning, full PDF value parser (dicts, arrays, strings, references, names). 23 tests.
- **`wordfix.zig`** (~310 lines) — Dictionary-based word rejoining for PDF text extraction. Embeds a zlib-compressed 89K-word dictionary via `@embedFile`, lazy-initializes into a hashmap on first use (thread-safe via mutex). Two-pass algorithm fixes false word splits (e.g., "kn own" -> "known", "un know n" -> "unknown"). Handles case-insensitive lookup, preserves original case, protects standalone single-char words ("a", "I") from merging. 11 tests.
- **`dictionary.zlib`** (250KB) — Zlib-compressed English dictionary, one word per line, 89,217 words. Embedded into the binary at compile time.
- **`parser_pdf.zig`** (~1600 lines) — PDF text extraction. Page tree traversal, content stream operator parsing (BT/ET, Tf, Tj, TJ, Td, Tm), hex string glyph decoding via ToUnicode CMap, font resource resolution, TJ kerning-to-space insertion for word boundaries, same-line vs different-line span joining (space vs newline), font-size heading heuristic, post-processing word rejoining via wordfix. 14 tests.
- **`ole2.zig`** (685 lines) — OLE2 (Compound Binary File) reader. Header parsing, FAT chain following, directory walking, mini stream support, UTF-16LE→UTF-8 conversion. 9 tests.
- **`parser_doc.zig`** (1138 lines) — Legacy Word (.doc) parser. FIB parsing, Piece Table extraction, Windows-1252 decoding, heuristic heading detection (ALL CAPS, numbered sections, Chapter/Section patterns). 24 tests.
- **`chunker.zig`** (601 lines) — Structure-aware chunker. Recursive section walking, breadcrumb paths, paragraph-boundary splitting, small-section merging. 10 tests.
- **`storage.zig`** (~1040 lines) — SQLite + sqlite-vec + FTS5. Document/chunk/embedding CRUD, vector KNN search, BM25 full-text search, WAL mode (+ `synchronous=NORMAL`, `busy_timeout`), config table, incremental reindex via hash. `beginTransaction`/`commitTransaction`/`rollbackTransaction` wrap per-file inserts in `docscan_index_file` (one fsync per file instead of per row — ~20x faster bulk insert, and atomic per file). 13 tests.
- **`search.zig`** (518 lines) — Hybrid search engine. Exact (FTS5), hybrid (vector+lexical with RRF fusion), similar (vector-only) modes. Format filtering, document caching. 10 tests.
- **`ignore.zig`** (607 lines) — Gitignore-compatible pattern matcher. Globs (`*`, `**`, `?`), negation, dir-only, anchored patterns, last-match-wins. Built-in defaults. 14 tests.

## Source — C FFI (`src/ffi/`)

- **`c_api.zig`** (1134 lines) — C FFI boundary. 16 exported functions: open/close DB, parse, chunk, index_file, search, needs_reindex, remove_document, status, read_chunk, config get/set, free, normalize, text_quality, preprocess_page, free_bytes. Hand-rolled JSON serialization. 14 tests.

## FFI Header (`ffi/`)

- **`docscan_core.h`** — Complete C header declaring all 14 FFI functions with opaque `docscan_db` handle.

## C CLI (`cli/`)

- **`main.c`** (2329 lines) — C CLI entry point, dogfoods the C FFI. Includes:
  - SHA-256 (FIPS 180-4) for content hashing
  - POSIX socket HTTP client (Ollama `/api/embed` + OpenAI `/v1/embeddings`) with per-request retry/backoff on transient failures (5xx, resets) and reported HTTP status. On permanent embedding failure, affected files are deferred (skipped, not stored with zero vectors) and re-indexed on a later run
  - Recursive directory walker with format filtering
  - Terminal-aware progress bar
  - MCP server (JSON-RPC 2.0 over stdio, 7 tools)
  - Commands: index, update, search, status, config, config debug, extract, normalize, preprocess, mcp-serve
  - Flags: --help, --about, --json, --limit, --exact, --similar, --model, --db, --no-color, --no-progress, --simple, --lang, --markdown, --format

- **`embed_util.{c,h}`** — Pure (no-I/O) helpers for embedding-failure policy, separated from `main.c` for deterministic unit testing: `http_status_from_response` (parse HTTP code), `embed_is_retryable` (transient vs permanent classifier), `embed_backoff_ms` (exponential backoff schedule), `file_indices_for_chunk_range` (map a failed chunk range back to the files that own those chunks). 37 checks.

## Tests

- **`src/all_tests.zig`** — Aggregated Zig unit tests (~153 tests across all modules)
- **`tests/cli/test-cli`** — 68 Bash black-box CLI tests
- **`tests/mcp/test-mcp`** (316 lines) — 14 Bash MCP protocol tests
- **`tests/integration/test-integration`** — Ollama-dependent integration tests (skips if unavailable)
- **`tests/integration/test-embed-failures`** + **`mock-embed-server.c`** — 5 tests driving the real binary against a scriptable mock embedding server: transient-retry, single-threaded defer, and batch-path defer + re-index
- **`tests/unit/test-embed-util.c`** + **`run-embed-util`** — Pure-C unit tests for `embed_util` (37 checks)

## Scripts

- **`build`** — `nix build` wrapper (--test, --debug flags)
- **`test`** — Master runner: embed-util + unit + cli + mcp + integration + embed-failures suites
- **`bm`** — Benchmark runner stub (rejects debug builds)
- **`build_all`** — Cross-compile for 5 targets

## Config

- **`.docscanignore.default`** — Default ignore patterns (VCS, deps, build artifacts, binaries, IDE, OS files)
- **`.gitignore`** — Git ignores for build artifacts

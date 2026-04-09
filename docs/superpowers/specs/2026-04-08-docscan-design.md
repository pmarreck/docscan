# docscan — Document Indexing & Semantic Search Tool

**Date:** 2026-04-08
**Status:** Approved design, pre-implementation

## Overview

docscan is a CLI tool for indexing and semantically searching document collections (.md, .docx, .pdf, .doc). It follows a general-purpose document search architecture with legal document awareness provided by the embedding model choice, not by domain-specific code. The tool is read-only — it indexes and searches documents but never modifies them.

### Done Criteria (v1)

- Index a directory tree of .md, .docx, .pdf, and .doc files (recursive, with ignore patterns)
- Structure-aware text extraction and chunking for all four formats
- Embed chunks via Ollama (nomic-embed-text default, configurable)
- Store in SQLite + sqlite-vec + FTS5
- Hybrid search (vector + BM25) from CLI
- MCP server over stdio
- Commands: `docscan index`, `search`, `update`, `status`, `mcp-serve`, `config`
- Cross-platform (Mac aarch64, Linux aarch64/x86_64, Windows aarch64/x86_64)
- Full test coverage (unit, CLI, MCP, integration, benchmarks)

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    C CLI (I/O)                       │
│  docscan index | search | update | status | mcp     │
└──────────────────────┬──────────────────────────────┘
                       │ C FFI calls
┌──────────────────────▼──────────────────────────────┐
│                 C FFI Boundary                       │
│  docscan_core.h — flat C API, opaque handles         │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│              Zig Core (pure, no I/O)                 │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐  │
│  │ Parsers  │  │ Chunker  │  │ Search Engine     │  │
│  │ .md      │  │ structure│  │ vector (sqlite-vec)│  │
│  │ .docx    │  │ -aware   │  │ lexical (FTS5)    │  │
│  │ .pdf     │  │ splitting│  │ hybrid fusion     │  │
│  │ .doc     │  └────┬─────┘  └────────┬──────────┘  │
│  └────┬─────┘       │                 │              │
│       │        ┌────▼─────┐    ┌──────▼───────┐     │
│       └───────►│ Document │    │   Storage    │     │
│                │ Model    │───►│  SQLite+vec  │     │
│                │ (chunks, │    │  +FTS5       │     │
│                │  metadata)    └──────────────┘     │
│                └──────────┘                          │
└──────────────────────────────────────────────────────┘
                       │
          Ollama (external, via C CLI I/O layer)
```

**Key principles:**
- Zig core is pure computation — takes byte slices in, returns structured results out. No file reads, no HTTP calls.
- The C CLI handles all I/O: reading files from disk, calling Ollama for embeddings, writing to SQLite.
- Ollama interaction lives in the C CLI, not the Zig core. The core accepts pre-computed embedding vectors.
- MCP server is a thin JSON-RPC stdin/stdout loop in the C CLI that dispatches to the same FFI calls.

## Embedding Model Strategy

**Primary choice: `nomic-embed-text`** via Ollama — 768 dimensions, 8192-token context window. The long context is critical for legal clauses that can span pages. Available out of the box (`ollama pull nomic-embed-text`).

**Legal-specific models:** The current landscape (LEGAL-BERT, InLegalBERT, etc.) is thin — old architectures, 512-token limits, not available as GGUF/Ollama. nomic-embed-text's 8K context and strong general quality is more valuable than domain tuning with a short window.

**Fine-tuning path (future):** Base on nomic-embed-text-v1.5 or bge-base. Training data: CaseLaw Access Project (~6.7M cases), CUAD contract dataset, EDGAR SEC filings, EUR-Lex. Only pursue once evaluation data shows gaps in the general model.

**Model is configurable** — stored in the index config, overridable via `--model` flag or `DOCSCAN_MODEL` env var.

## Document Model & Parsing Pipeline

### Document Model

What the Zig core produces from raw bytes:

```
Document
├── path: []const u8
├── format: enum { md, docx, pdf, doc }
├── title: ?[]const u8
├── metadata: key-value pairs (author, date, subject, etc.)
└── sections: []Section
    ├── heading: ?[]const u8
    ├── level: u8 (0 = root, 1 = top heading, 2 = sub, ...)
    ├── content: []const u8 (plaintext of this section)
    └── children: []Section (recursive)
```

### Chunks

Derived from sections for embedding:

```
Chunk
├── document_path: []const u8
├── section_path: []const u8       -- "Section 4 > 4.2 > (a)" breadcrumb
├── heading: ?[]const u8
├── text: []const u8
├── start_byte: u64                -- offset in extracted plaintext
├── end_byte: u64
└── chunk_index: u32               -- sequential within document
```

### Chunking Rules

- Each leaf section becomes a chunk
- If a section exceeds configurable max size (default ~1500 tokens), split at paragraph boundaries, keeping the section_path context
- If adjacent sibling sections are very small (under ~100 tokens), merge them into one chunk
- Every chunk carries its breadcrumb path so search results have structural context

### Parser Responsibilities

All pure Zig, forked from validate's structural parsing infrastructure, extended with text extraction:

- **Markdown:** Split on `#` headings. Straightforward.
- **DOCX:** Unzip, parse `word/document.xml`, walk `<w:p>` and `<w:pStyle>` for heading levels, extract text runs.
- **PDF:** Walk page content streams, extract text operators (Tj, TJ, etc.), infer structure from font size/bold heuristics. This is the fuzziest parser — PDFs lack semantic headings. Heuristic approach (large/bold = heading) works for most professional documents.
- **.doc (legacy):** OLE2 container, Piece Table text extraction, style-based heading detection.

## Storage Schema

SQLite database (single file, WAL mode):

```sql
-- Configuration
config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL
)
-- Stores: schema_version, model_name, embedding_dimensions, created_at

-- Document metadata
documents (
    id          INTEGER PRIMARY KEY,
    path        TEXT UNIQUE NOT NULL,
    format      TEXT NOT NULL,          -- md, docx, pdf, doc
    title       TEXT,
    content_hash TEXT NOT NULL,         -- blake3 hash of raw file bytes
    metadata    TEXT,                   -- JSON blob (author, date, etc.)
    indexed_at  INTEGER NOT NULL        -- unix timestamp
)

-- Chunks with structural context
chunks (
    id              INTEGER PRIMARY KEY,
    document_id     INTEGER NOT NULL REFERENCES documents(id),
    chunk_index     INTEGER NOT NULL,
    section_path    TEXT,               -- "Section 4 > 4.2 > (a)"
    heading         TEXT,
    text            TEXT NOT NULL,
    start_byte      INTEGER NOT NULL,
    end_byte        INTEGER NOT NULL
)

-- Vector embeddings (sqlite-vec virtual table)
chunk_embeddings (
    chunk_id    INTEGER PRIMARY KEY,
    embedding   FLOAT[N]               -- dimension from config
)

-- Full-text search (FTS5 virtual table)
chunks_fts (
    chunk_id,
    text,
    heading,
    section_path
)
```

**Incremental updates:** `content_hash` on documents — skip unchanged files on re-index. Changed files get their chunks and embeddings fully replaced.

**Embedding dimension:** Configured at index creation time, stored in `config` table. Enables model swaps (requires re-index).

**FTS5** indexes chunk text, heading, and section_path — enables structural search ("indemnification" in headings vs body).

## Search Engine

### Hybrid Search

- **Vector:** Query text → embed via Ollama → cosine similarity against chunk_embeddings → top K
- **Lexical:** Query text → FTS5 BM25 ranking against chunks_fts → top K
- **Fusion:** Reciprocal Rank Fusion (RRF), configurable weight (default 70% vector / 30% lexical)

### Search Result

```
SearchResult
├── document_path: []const u8
├── document_title: ?[]const u8
├── section_path: []const u8       -- breadcrumb
├── heading: ?[]const u8
├── text: []const u8               -- matching chunk
├── score: f32                     -- fused score
├── vector_score: f32
├── lexical_score: f32
```

### Search Modes

- **Hybrid** (default) — full vector + lexical fusion. Best for conceptual queries ("limitation of liability clauses").
- **Exact** — FTS5 only. For known phrases ("governing law", "Section 12.4").
- **Similar** — given text, find similar chunks across all documents. Useful for "find all clauses like this one."

## CLI Interface

### Commands

```
docscan index <path>          Index a directory (recursive) or single file
docscan update [path]         Re-index changed files (hash diff)
docscan search <query>        Hybrid search (default)
docscan search --exact <q>    FTS5-only exact phrase search
docscan search --similar <q>  Find similar chunks
docscan status                Show index stats
docscan mcp-serve             MCP server over stdio (JSON-RPC 2.0)
docscan config                Show/set config
```

### Common Flags

- `--json` — structured JSON output on all commands
- `--limit N` — cap search results (default 10)
- `--model <name>` — override Ollama model
- `--db <path>` — explicit database path (default: `.docscan/index.db` relative to indexed root)
- `--lang <code>` — language override (i18n groundwork, English default)
- `--no-color` / `--no-ansi` — suppress ANSI formatting
- `--simple` — plain output (no emoji, ANSI, color)
- `--no-progress` — suppress progress bars
- `-h` / `--help` — usage
- `--about` — one-line version/platform/arch

### Ignore Patterns

- `.docscanignore` file (gitignore syntax) in the indexed root
- Sensible defaults: `.git`, `.jj`, `node_modules`, `__pycache__`, binary/image files, etc.

### Progress Indication

- `index` and `update` show progress bar to stderr (file count, rate, ETA) when on interactive terminal
- Embedding batches show sub-progress (Ollama is the bottleneck)

### Environment Variables

- `DOCSCAN_LANG` — language override (overridden by `--lang`)
- `DOCSCAN_MODEL` — default Ollama model
- `DOCSCAN_DB` — default database path

## MCP Interface

JSON-RPC 2.0 over stdio. Read-only — no editing tools, no hashlines.

### Tools

```
docscan.search        query, mode (hybrid|exact|similar), limit, format_filter
docscan.index         path
docscan.update        path (optional)
docscan.status        (no args)
docscan.read_chunk    chunk_id — full chunk text with context
docscan.list_docs     filter (optional glob) — list indexed documents
docscan.config        key, value (optional — get or set)
```

`read_chunk` lets an LLM fetch full chunk text by ID after seeing a truncated search snippet, without reading the original file.

## Testing Strategy

### Structure

```
tests/
├── unit/          Zig unit tests (parsers, chunker, search, storage)
├── cli/           Bash black-box tests against the C CLI binary
├── mcp/           JSON-RPC stdin/stdout tests against mcp-serve
└── integration/   Full pipeline with Ollama (run separately)
```

Master runner: `./test` runs unit + cli + mcp. Integration tests require Ollama.

### Unit Tests — Parsers

- Each format (.md, .docx, .pdf, .doc) gets its own test suite
- Fixture documents: nested headings, tables, footnotes, empty sections, multi-page content, unicode text, malformed input
- Assert on: extracted text content, section hierarchy, heading levels, metadata
- PDF heuristic heading detection tested against documents with known structure
- .docx: real fixture files checked into repo

### Unit Tests — Chunker

- Structure-aware splitting respects section boundaries
- Max-size splitting at paragraph boundaries
- Small-section merging
- Breadcrumb path correctness at every nesting level
- Edge cases: single giant section, deeply nested structure, empty sections

### Unit Tests — Storage

- Round-trip insert/query for each table
- Hash-based skip: re-index unchanged file, assert no re-embedding
- Hash-based update: modify file, re-index, assert chunks replaced
- FTS5 queries return expected results
- Schema migration

### Unit Tests — Search

- Fixture corpus in-memory with pre-computed embeddings (no Ollama dependency)
- Exact mode: known phrases rank first
- Hybrid mode: semantically related but lexically different queries find correct chunks
- Similar mode: given a chunk, most-similar results share topic
- Fusion: verify RRF ranking order with known scores
- Filter by document format

### CLI Tests (Bash)

- Each command with valid and invalid args
- `--json` output parsed with jq
- Paths with spaces
- `--help` and `--about` output
- Error messages (missing path, unsupported format, Ollama unreachable)
- Stdin input via `-`/`@stdin`
- Progress suppression flags

### MCP Tests

- Pipe JSON-RPC requests, assert on response structure
- Tool discovery (list tools)
- Search round-trip
- Error responses for bad requests

### Integration Tests (requires Ollama)

- Index small corpus of real .md/.docx/.pdf files
- Run known queries, assert correct documents in top results
- Verify `update` detects changed files and re-indexes only those

**All tests run clean** — no visible stderr noise; expected output captured and asserted.

## Benchmark Suite

Run via `./bm`. ReleaseFast builds only — errors out if DEBUG BUILD detected.

### What Gets Benchmarked

- **Parsing throughput** — bytes/sec per format. Fixtures: 1-page contract, 50-page agreement, 500-page filing.
- **Chunking throughput** — sections/sec, chunks/sec on pre-parsed documents of varying complexity.
- **Storage write** — chunks+embeddings insert rate (documents/sec, chunks/sec) with pre-computed embeddings.
- **Search latency** — query-to-results time per mode (hybrid, exact, similar) against 100, 1K, 10K chunk corpora. Vector and FTS5 measured separately plus fused.
- **Index pipeline end-to-end** — wall-clock time excluding Ollama (Ollama latency reported as separate metric).

### How It Runs

- `hyperfine` for CLI-level benchmarks
- Zig `std.time.Timer` for hot-path microbenchmarks (CPU time)
- Results logged to `benchmarks/results.log` (source-controlled) with timestamp, commit hash, CPU time, wall-clock time
- **Regression detection:** >10% change (improvement or regression) from prior run loudly flagged as requiring attention
- Rerunning the benchmark is implicit acceptance of the new baseline

### Fixtures

- Small set of real-ish documents in `benchmarks/fixtures/`
- Synthetic large corpus generator for 10K-chunk search latency tests

## Build & Deployment

### Scripts

- `./build` — `nix build`, copies binary to `zig-out/bin/docscan`
- `./build --test` / `./build --debug` — corresponding build modes
- `./test` — unit + cli + mcp tests via Nix
- `./bm` — benchmark suite
- `./build_all` — cross-compile for 5 targets

### Nix (flake.nix)

- Zig 0.15+ via Nix
- SQLite amalgamation + sqlite-vec (static)
- `hyperfine` in dev dependencies
- `zigDeps` fixed-output derivation for Zig dependencies
- `packages.default` + `checks.${system}.{build, test}` for Garnix CI

### Project Structure

```
docscan/
├── src/
│   ├── core/                     -- Zig core (pure, no I/O)
│   │   ├── parser_md.zig
│   │   ├── parser_docx.zig
│   │   ├── parser_pdf.zig
│   │   ├── parser_doc.zig
│   │   ├── document.zig          -- Document/Section/Chunk models
│   │   ├── chunker.zig
│   │   ├── search.zig
│   │   └── storage.zig
│   └── all_tests.zig             -- aggregated unit tests
├── ffi/
│   ├── docscan_core.h            -- C FFI header
│   └── docscan_ffi.zig           -- FFI implementation
├── cli/
│   └── main.c                    -- C CLI (all I/O, Ollama, MCP)
├── tests/
│   ├── unit/
│   ├── cli/
│   ├── mcp/
│   └── integration/
├── benchmarks/
│   ├── fixtures/
│   └── results.log
├── build.zig
├── build.zig.zon
├── flake.nix
├── flake.lock
├── .docscanignore.default
├── build
├── build_all
├── test
├── bm
├── PLAN.md
├── PROJECT_OVERVIEW.md
├── CODE_MINIMAP.md
└── CLAUDE.md / AGENTS.md
```

### Debug Build Warning

Early in `main()`, emit yellow `DEBUG BUILD` to stderr. Benchmark suite asserts it's absent.

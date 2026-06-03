# docscan Implementation Plan

See `docs/superpowers/plans/2026-04-08-docscan-implementation.md` for full task details.

## Completed

- [x] Task 1: Project Scaffolding (2026-04-09)
- [x] Task 2: Markdown Parser — 8 tests (2026-04-09)
- [x] Task 3: XML Parser for DOCX — 14 tests (2026-04-09)
- [x] Task 4: DOCX Parser — 15 tests (2026-04-09)
- [x] Task 5: PDF Parser — 30 tests (2026-04-09)
- [x] Task 6: DOC Parser — 33 tests (2026-04-09)
- [x] Task 7: Chunker — 10 tests (2026-04-09)
- [x] Task 8: Storage Layer — 11 tests (2026-04-09)
- [x] Task 9: Search Engine — 10 tests (2026-04-09)
- [x] Task 10: C FFI Boundary — 14 tests (2026-04-09)
- [x] Task 11: C CLI (2026-04-09)
- [x] Task 12: MCP Server (2026-04-09)
- [x] Task 13: CLI Tests — 18 tests (2026-04-09)
- [x] Task 14: MCP Tests — 14 tests (2026-04-09)
- [x] Task 17: Ignore Patterns — 14 tests (2026-04-09)
- [x] Task 18: Final Integration + Documentation (2026-04-09)
- [x] `docscan preprocess` CLI command — PDF page rasterization + text isolation via FFI + reassembly (2026-04-13 EST)
- [x] Embedding-failure robustness: per-request retry/backoff + HTTP-status diagnostics, and mark-for-reindex on permanent failure (no more silent zero-vector inserts) in both batch and single-threaded paths. New `cli/embed_util.{c,h}` (37 unit checks) + `tests/integration/test-embed-failures` (5 tests, mock server). Fixes intermittent batch failures observed on the 1200-file index run (2026-06-01 EST)
- [x] flake.nix: default dev shell repaired — overlay disables broken unpaper/ocrmypdf upstream check phases in nixos-unstable so `nix develop` evaluates again (2026-06-01 EST)
- [x] Phase-3 insertion hang fixed: wrap per-file chunk/embedding inserts in a single transaction + `synchronous=NORMAL`/`busy_timeout` pragmas. ~112s -> a few seconds for 1715 chunks; makes indexing usable when the DB is on a network filesystem. Also: ignore SIGPIPE so a dropped embedding-server connection defers instead of killing the process. 2 new storage tests (2026-06-02 EST)
- [x] `docscan index` with no path now defaults to the current directory (mirrors `update`) (2026-06-02 EST)
- [x] Phase-2 embedding hang fixed: http_post had a connect timeout but no read timeout, so a server that accepts then stalls blocked read() forever. Added SO_RCVTIMEO/SO_SNDTIMEO (read bounded by DOCSCAN_HTTP_READ_TIMEOUT_SECS, default 120s) — a stalled connection now times out -> retry -> defer. Reproduced via a stalling mock (TDD: hang->recover), locked in as integration Test D (2026-06-02 EST)
## Deferred

- [ ] Task 15: Integration Tests — requires running Ollama
- [ ] Task 16: Benchmark Suite — `./bm` stub exists
- [ ] Wire ignore patterns into CLI directory walker
- [ ] `docscan_list_documents` FFI function
- [ ] DIFAT chain support in OLE2 (>7MB .doc files)

## Known Limitations

- **Word rejoining ambiguity**: When a PDF/OCR split produces two fragments that are BOTH valid dictionary words but the combined form is also a word (e.g., "met hod" → "method", "car go" → "cargo", "for age" → "forage"), the pipeline conservatively keeps them separate. Resolving this requires sentence-level semantic context — a statistical language model or LLM, not a dictionary lookup. Same applies to 3+ way splits like "pr operl y" → "properly" where no pairwise combination is a word. Out of scope for the current dictionary-based approach.
- [x] Xref stream support in PDF parser (2026-04-08 EST)
- [x] CIDFont/ToUnicode mapping in PDF (2026-04-08 EST)
- [x] Object stream decompression cache + re-enable CMap/ToUnicode parsing (2026-04-10 EST)
- [x] Object stream support in PDF parser (2026-04-08 EST)
- [x] PNG predictor decompression for xref streams (2026-04-08 EST)
- [x] Incremental update /Prev chain following in PDF xref (2026-04-08 EST)
- [x] Word spacing in PDF text extraction (same-line vs newline) (2026-04-08 EST)
- [x] TJ kerning-to-space insertion for word boundaries (2026-04-08 EST)
- [x] Indirect /Length reference resolution in PDF streams (2026-04-08 EST)
- [ ] Windows directory walking (currently POSIX-only)
- [ ] i18n translations (groundwork laid: --lang, DOCSCAN_LANG)
- [ ] Legal embedding model research/fine-tuning
- [x] `docscan config debug` subcommand — shows effective config with sources (2026-04-08 EST)
- [x] `docscan extract` command — parse-and-output with plaintext/markdown/JSON modes, stdin support (2026-04-10 EST)

## Future: `docscan translate`

Local document translation using open-source models. Potential architecture:

- **Bulk translation**: NLLB-200 (Meta, MIT, 200 languages, 600M-3.3B params) or Madlad-400 (Google, Apache 2.0, 400 languages). MLX versions exist for Apple Silicon.
- **Cross-lingual indexing**: index both original text AND English translation per chunk, enabling FTS5 exact search across languages (not just vector search)
- **Cross-lingual search**: `docscan search "financial crisis" --translate es` — translates results
- **Full document translation**: `docscan translate --from auto --to es document.pdf > documento_es.md`

### Translation metadata / translator's notes

Local translation models (NLLB, OpusMT, Madlad) produce raw translations without cultural context. Frontier LLMs produce *annotated* translations with notes on idioms, cultural references, and ambiguities. A hybrid approach:

1. Local model does bulk translation (fast, cheap)
2. Reasoning model (cloud API or local 7B+ instruct) does a second pass flagging:
   - Idioms that don't translate literally
   - Cultural references that need context
   - Ambiguous terms with multiple valid translations
   - Register/formality mismatches

Inline format for translation notes (inspired by published translator's notes):
```markdown
He kicked the bucket [TN: "cassé sa pipe" — lit. "broke his pipe," French idiom for dying]
```

Structured format for downstream processing:
```json
{
  "original": "Il a cassé sa pipe",
  "translation": "He kicked the bucket",
  "notes": [{"type": "idiom", "span": "cassé sa pipe", "literal": "broke his pipe", "note": "French idiom for dying, informal register"}]
}
```

This is a separate project-scale feature — the translation model is a heavy dependency (600M-3B params), quality bar is high, and the annotation pass requires LLM reasoning.

## Stats

- ~16,000+ lines across 20+ source files
- ~240+ automated tests (227 Zig unit + CLI + MCP)
- 7 format parsers (md, txt, docx, pdf, doc, rtf, epub)

## Known text extraction artifacts (remaining)

- OCR-like corruption: "wo1,1ld" — commas/digits substituted for letters, can't fix without OCR correction
- Email/URL boundaries: "Nakamotosatoshin@gmx.comwww.bitcoin.org" — need URL/email pattern detection to insert spaces
- Encoding replacement chars: "�" in some PDFs (Berkshire letter) — need better fallback encoding handling
- Stray isolated ligature expansions: lone "ff" on a line from a PDF ligature with no surrounding context

## In Progress: Logical page numbers

### Completed steps
- [x] Roman numeral conversion: `arabicToRoman()`/`romanToArabic()` with 5 tests (2026-04-10 EST)
- [x] Rename `page` -> `page_physical` across all source files (2026-04-10 EST)
- [x] Add `page_logical`, `page_section`, `page_roman` fields to Section, Chunk, SearchResult, ChunkRecord (2026-04-10 EST)
- [x] Add DB columns and indexes for new page fields (2026-04-10 EST)
- [x] Update JSON serialization in c_api.zig for all new fields (2026-04-10 EST)
- [x] Update CLI main.c to parse `page_physical` from JSON (2026-04-10 EST)

### Remaining steps
- [ ] PDF `/PageLabels` parsing in parser_pdf.zig
- [ ] CLI `--logical`/`--physical` flags and display changes
- [ ] DOCX `pgNumType` support
- [ ] DOC `pgn_start` support
- [ ] RTF `\pgnstart` support

### Background

Physical page numbers (what we track now) differ from logical page numbers
(what the reader sees) due to front matter, section breaks, and page number
restarts. All major formats support this:

- **PDF**: `/PageLabels` number tree in catalog — maps physical pages to labels (roman numerals, decimal with offset)
- **DOCX**: `<w:pgNumType w:start="N"/>` in section properties — restarts numbering per section
- **DOC**: `pgn_start` in SEPX (Section Properties) via plcfSed in Table stream
- **RTF**: `\pgnstart N` control word — sets starting page number
- **EPUB**: `<pageList>` in navigation document (maps reading positions to printed pages, optional)

### Data model

Rename existing `page` to `page_physical` (u32, 1-indexed, always present for PDFs).

New fields per section/chunk:
- `page_logical: ?u32` — logical page number (null if no page labels metadata)
- `page_section: u32` — numbering section (1-based, increments on each restart)
- `page_roman: bool` — true = display as roman numeral, false = arabic

Unique constraint: `(page_logical, page_section, page_roman)` per document.

Roman numeral conversion: implement and test `romanToArabic()`/`arabicToRoman()` functions.

DB: add indexes on `page_physical` and `(page_logical, page_section)` in chunks table.

### CLI behavior

- `--from N` / `--to N` default to `--physical` (whole document, no section filtering)
- If `--physical` is defaulted to, stderr hint: "Using physical page numbers. Use --logical if document metadata supports it."
- `--logical` flag switches to logical page matching
- Cross-section ambiguity (same logical page in multiple sections): not handled for v1 — use physical pages. Document this limitation.

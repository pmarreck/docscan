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

## Deferred

- [ ] Task 15: Integration Tests — requires running Ollama
- [ ] Task 16: Benchmark Suite — `./bm` stub exists
- [ ] Wire ignore patterns into CLI directory walker
- [ ] `docscan_list_documents` FFI function
- [ ] DIFAT chain support in OLE2 (>7MB .doc files)
- [x] Xref stream support in PDF parser (2026-04-08 EST)
- [x] CIDFont/ToUnicode mapping in PDF (2026-04-08 EST)
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

## Stats

- ~12,800 lines across 18 source files
- ~201 automated tests (159 Zig unit + 28 CLI + 14 MCP)
- 4 format parsers (md, docx, pdf, doc)

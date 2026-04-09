# docscan Implementation Plan

See `docs/superpowers/plans/2026-04-08-docscan-implementation.md` for full task details.

## Tasks

- [x] Task 1: Project Scaffolding — build.zig, flake.nix, stub sources, scripts, docs (2026-04-09 ~09:00 EST)
- [ ] Task 2: Markdown Parser — structure-aware .md text extraction
- [ ] Task 3: XML Parser for DOCX — minimal XML parser (pure Zig)
- [ ] Task 4: DOCX Parser — ZIP + XML walk for text extraction
- [ ] Task 5: PDF Parser — content stream text operators + font heuristics
- [ ] Task 6: DOC Parser — OLE2 container + Piece Table
- [ ] Task 7: Chunker — structure-aware splitting with breadcrumb paths
- [ ] Task 8: Storage Layer — SQLite + sqlite-vec + FTS5
- [ ] Task 9: Search Engine — hybrid vector + BM25 with RRF fusion
- [ ] Task 10: C FFI Boundary — full C API with opaque handles
- [x] Task 11: C CLI — all commands, flags, progress, i18n groundwork (2026-04-09 ~11:10 EST)
- [ ] Task 12: MCP Server — JSON-RPC 2.0 over stdio
- [ ] Task 13: CLI Tests — Bash black-box tests
- [ ] Task 14: MCP Tests — JSON-RPC stdin/stdout tests
- [ ] Task 15: Integration Tests — full pipeline with Ollama
- [ ] Task 16: Benchmark Suite — parsing, chunking, search latency
- [ ] Task 17: Ignore Patterns — .docscanignore with sensible defaults
- [ ] Task 18: Final Integration + Documentation

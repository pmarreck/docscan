# PLAN

Open work in priority order. Completed items: `docs/PLAN_LOG.md`. Background: `docs/plan_context/`.
Original task breakdown: `docs/superpowers/plans/2026-04-08-docscan-implementation.md`.

## Next (authorized, unblocked)

- [ ] `./test` should build the binary (or fail on a stale `zig-out/bin/docscan`) before CLI/MCP suites run
- [ ] Remaining tests/cli/test-cli index calls that do not target the mock (13 call sites) may contact the host embedding server; route them to the mock
- [ ] Make tests/integration/test-embed-failures use tests/lib/mock-embed.bash instead of its own copy of the start/stop logic
- [ ] Logical pages: DOCX `<w:pgNumType w:start>` support (context: docs/plan_context/logical_page_numbers.md)
- [ ] Logical pages: DOC `pgn_start` (SEPX via plcfSed) support (context: docs/plan_context/logical_page_numbers.md)
- [ ] Logical pages: RTF `\pgnstart` support (context: docs/plan_context/logical_page_numbers.md)
- [ ] `docscan_list_documents` FFI function
- [ ] Benchmark suite behind `./bm` (Task 16; use the performance-profiling skill)
- [ ] Integration tests that need a running Ollama (Task 15)

- [ ] Bump the chardetz pin from c7d1779 to ffefc74: `detect()` now returns `error{OutOfMemory}![:0]const u8`, so `detectEncoding` in src/core/encoding.zig needs `catch return null`; refresh the package hash with `zig fetch --save`
## Deferred

- [ ] Citation pipeline Phase 2: offset map + `docscan_extract_structured`, md/txt first; waits for a consumer to ask (context: docs/plan_context/citation_pipeline.md)
- [ ] Grammar/POS averaged-perceptron tagger for residual ambiguous joins and party attribution (context: docs/plan_context/pdf_quality.md)
- [ ] Figure/diagram region detection for dense 2-column STEM layouts (context: docs/plan_context/pdf_quality.md)
- [ ] Integrate ocrz (the separate Zig OCR project) as the fallback for image-only PDF pages once it is usable (context: docs/plan_context/ocr.md)
- [ ] Windows directory walking (currently POSIX-only)
- [ ] i18n translations (groundwork laid: --lang, DOCSCAN_LANG)
- [ ] Legal embedding model research/fine-tuning
- [ ] `docscan translate` local translation feature (context: docs/plan_context/translate.md)

## Tabled by owner (do not resume without direction)

- [ ] Fileserver index recovery: confirm local DB home, resume-from-pull vs fresh-local (context: docs/plan_context/fileserver_index_recovery.md)
- [ ] Auto-default the index DB to local app-data when the corpus is on a network mount (context: docs/plan_context/fileserver_index_recovery.md)

## Recently completed

- [x] Owner decisions 2026-10-20: docscan stays a document-to-plaintext parser independent of incitez (citation integration declined); OCR moves to a new Zig project, ocrz (done 2026-10-20 15:55 EDT)
- [x] `.docscanignore` wired into the CLI/MCP directory walker via new length-delimited FFI (`docscan_ignore_new`/`_matches`/`_free`); CLI and MCP suites made hermetic with a shared mock embedding server (done 2026-10-14 18:10 EDT)
- [x] PLAN.md migrated to one-line items; prose moved to docs/plan_context/ and docs/PLAN_LOG.md (done 2026-10-14 14:45 EDT)
- [x] Verified already done in code and retired: PDF `/PageLabels` + CLI `--logical`/`--physical` (519e7ff), ligature normalization for doc/rtf/epub via `wordfix.applySections` (done 2026-10-14 14:45 EDT)
- [x] Borderline line-break hyphen + LuraDocument empty-extract fix (done 2026-06-16 EST)

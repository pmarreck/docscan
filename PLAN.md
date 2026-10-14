# PLAN

Open work in priority order. Completed items: `docs/PLAN_LOG.md`. Background: `docs/plan_context/`.
Original task breakdown: `docs/superpowers/plans/2026-04-08-docscan-implementation.md`.

## Next (authorized, unblocked)

- [ ] Wire `.docscanignore` patterns (src/core/ignore.zig) into the CLI directory walker through the C FFI
- [ ] Logical pages: DOCX `<w:pgNumType w:start>` support (context: docs/plan_context/logical_page_numbers.md)
- [ ] Logical pages: DOC `pgn_start` (SEPX via plcfSed) support (context: docs/plan_context/logical_page_numbers.md)
- [ ] Logical pages: RTF `\pgnstart` support (context: docs/plan_context/logical_page_numbers.md)
- [ ] `docscan_list_documents` FFI function
- [ ] Benchmark suite behind `./bm` (Task 16; use the performance-profiling skill)
- [ ] Integration tests that need a running Ollama (Task 15)

## Awaiting owner decision

- [ ] OCR for image-only scans: Tesseract-FFI native fallback vs ocrs-WASM evaluation (walking decision docscan-ocr-direction) (context: docs/plan_context/ocr.md)
- [ ] incitez citation-extraction integration into the chunker/index (walking decision docscan-incitez-integration) (context: docs/plan_context/citation_pipeline.md)

## Deferred

- [ ] Citation pipeline Phase 2: offset map + `docscan_extract_structured`, md/txt first; waits for a consumer to ask (context: docs/plan_context/citation_pipeline.md)
- [ ] Grammar/POS averaged-perceptron tagger for residual ambiguous joins and party attribution (context: docs/plan_context/pdf_quality.md)
- [ ] Figure/diagram region detection for dense 2-column STEM layouts (context: docs/plan_context/pdf_quality.md)
- [ ] OCR quality ideas: consensus OCR and lexicon-constrained OCR (context: docs/plan_context/ocr.md)
- [ ] Windows directory walking (currently POSIX-only)
- [ ] i18n translations (groundwork laid: --lang, DOCSCAN_LANG)
- [ ] Legal embedding model research/fine-tuning
- [ ] `docscan translate` local translation feature (context: docs/plan_context/translate.md)

## Tabled by owner (do not resume without direction)

- [ ] Fileserver index recovery: confirm local DB home, resume-from-pull vs fresh-local (context: docs/plan_context/fileserver_index_recovery.md)
- [ ] Auto-default the index DB to local app-data when the corpus is on a network mount (context: docs/plan_context/fileserver_index_recovery.md)

## Recently completed

- [x] PLAN.md migrated to one-line items; prose moved to docs/plan_context/ and docs/PLAN_LOG.md (done 2026-10-14 14:45 EDT)
- [x] Verified already done in code and retired: PDF `/PageLabels` + CLI `--logical`/`--physical` (519e7ff), ligature normalization for doc/rtf/epub via `wordfix.applySections` (done 2026-10-14 14:45 EDT)
- [x] CTM (q/Q/cm) applied to PDF text positions (done 2026-06-16 EST)
- [x] Borderline line-break hyphen + LuraDocument empty-extract fix (done 2026-06-16 EST)

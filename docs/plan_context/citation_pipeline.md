# Citation pipeline and WASM slice context

Moved verbatim from PLAN.md on 2026-10-14 when the plan was reduced to one-line items.

## Citation-extraction integration (gated)

- [ ] **incitez citation-extraction integration** (GATED - awaiting Peter's prioritization; inbox brief 2026-06-12 from Einstein). Add incitez as a Zig package dependency (`build.zig.zon`) and call its Zig API directly -- allowed per Peter's 2026-06-12 FFI refinement: incitez's own CLI already dogfoods its C FFI (`include/incitez.h`), so the FFI is proven exercised and re-vendoring through it is unnecessary (C FFI stays the boundary only for any non-Zig consumer). chunker enrichment pass -> per-chunk `citations[]` (incitez byte-offset spans translated to chunk-relative, UTF-8-multibyte-safe; type, reporter, courts-db id, resolution cluster id); store in SQLite (FTS5 col or sidecar table keyed by chunk id); citation-aware search (`docscan search --citing "531 U.S. 98"`) + MCP exposure. TDD + byte-offset round-trip proof; bench under existing bm gates. Plan of record: `docs/citation_extraction.md`. Unlocks legal_ai stage-1 extraction.

## In Progress: docscan-WASM parse-to-text slice (for incitez_web private demo)

Work order: Einstein 2026-06-12 (Peter opted in; approach delegated to docscan agent).
LLMsend Einstein at each milestone boundary; coordinate output contract with the
incitez_web session. STOP at each milestone boundary — do NOT roll PDF build in on momentum.


## Citation pipeline (docscan slice) — per CITATION_PIPELINE_RESPONSIBILITIES.md

docscan owns STRUCTURE-AWARE extraction + the offset map; incitez consumes the lone-\n
hard-stop signal; incitez_web composes the map for source-highlighting. Marker contract
agreed with incitez (2026-06-14): wraps→space, lone \n = boundary, no \n runs/trailing.

- [ ] **Phase 2 — offset map + `docscan_extract_structured`** (emitted↔original): sorted `{emitted_off, original_off}` breakpoint array (piecewise-1:1, binary-search to map back); new export returns `[u32 text_len][text][u32 n][n×{emitted,original}]` in one buffer. md/txt exact byte-to-byte first; pdf/docx pending an incitez_web highlight-needs convo ("original bytes" into a binary PDF isn't directly a highlight position).

## Decision 2026-10-20 (owner, walking brief docscan-incitez-integration rev 2)

Declined. Verbatim: "docscan project should remain independent from the incitez legal work. docscan is document-to-plaintext parsing. incitez is citation extraction." The incitez integration item above is retired; docscan does not depend on incitez or store citations.

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
- [x] OLE2 DIFAT chain followed (ole2.zig): files >109 FAT sectors (>~7MB legacy Office/.doc) no longer silently misparse. Loop-guarded against malformed/cyclic chains (CorruptFAT). 2 new tests (2026-06-03 EST)
- [x] Factored duplicated readU16/readU32 (ole2/zip/parser_doc) into shared src/core/endian.zig (2026-06-03 EST)
- [x] Chunker oversized-chunk fix (root cause of HTTP 400 "input exceeds 8192 tokens"): oversized boundary-less content and single oversized paragraphs are now force-split to an embed-safe byte budget (max_chunk_tokens / tokens_per_byte, default 6000B) instead of being emitted whole up to the 256KB SQLite ceiling. 2 new tests; verified 100KB blob -> 17 chunks max 6000B (2026-06-03 EST)
## Deferred

- [ ] Task 15: Integration Tests — requires running Ollama
- [ ] Task 16: Benchmark Suite — `./bm` stub exists
- [ ] Wire ignore patterns into CLI directory walker
- [ ] `docscan_list_documents` FFI function
- [x] DIFAT chain support in OLE2 (>7MB .doc files) (2026-06-03 EST)
- [ ] **incitez citation-extraction integration** (GATED - awaiting Peter's prioritization; inbox brief 2026-06-12 from Einstein). Add incitez as a Zig package dependency (`build.zig.zon`) and call its Zig API directly -- allowed per Peter's 2026-06-12 FFI refinement: incitez's own CLI already dogfoods its C FFI (`include/incitez.h`), so the FFI is proven exercised and re-vendoring through it is unnecessary (C FFI stays the boundary only for any non-Zig consumer). chunker enrichment pass -> per-chunk `citations[]` (incitez byte-offset spans translated to chunk-relative, UTF-8-multibyte-safe; type, reporter, courts-db id, resolution cluster id); store in SQLite (FTS5 col or sidecar table keyed by chunk id); citation-aware search (`docscan search --citing "531 U.S. 98"`) + MCP exposure. TDD + byte-offset round-trip proof; bench under existing bm gates. Plan of record: `docs/citation_extraction.md`. Unlocks legal_ai stage-1 extraction.

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

## Ops: fileserver index recovery (Textfiles & PDF & eBook corpus) — TABLED 2026-06-13 (Peter: WASM slice is higher priority)

Index run died ~Jun 5 09:57 when /Volumes/Fileserver went unresponsive (external
mount failure, NOT a docscan bug — process wedged in uninterruptible "U" state).
DB left ~70% done: 834/1200 docs, ~143k embeddings, hot journal present (unclean
shutdown). Clean 732MB `index.db.killed-20260603-212303` backup beside it.

DECISION (Peter, 2026-06-12): the index DB is a *derived* artifact → it belongs on
LOCAL disk; the corpus is read remotely. NO copy-back. Only one-time copy is a 932MB
pull-DOWN of the existing partial to recover the 70% GPU work (optional vs fresh-local).
- [ ] Confirm local DB home + resume-from-pull vs fresh-local, then execute
- [ ] Proposed improvement: docscan auto-defaults DB to a local app-data dir when the
      corpus is detected on a network mount (one-line stderr note) — kills the footgun
      by construction instead of by remembering `--db`.

## In Progress: docscan-WASM parse-to-text slice (for incitez_web private demo)

Work order: Einstein 2026-06-12 (Peter opted in; approach delegated to docscan agent).
LLMsend Einstein at each milestone boundary; coordinate output contract with the
incitez_web session. STOP at each milestone boundary — do NOT roll PDF build in on momentum.

- [x] **Milestone 1 (done 2026-06-13: 964KB artifact, checks.wasm green) — `packages.wasm` parse-to-text slice (BUILD NOW)**: export
      `docscan_extract_text(ptr,len,fmt)->resPtr` returning `[u32 LE len][UTF-8 text]` +
      `alloc`/`free`/`selftest`/`version`. `fmt`: docx|md|txt (pdf reserved). wasm32-
      freestanding, ZERO imports; comptime-EXCLUDE search/sqlite-vec/FTS5/embedding/Ollama
      (parse-to-text ONLY, mirror how incitez comptime-excluded PCRE2). Reuse incitez's
      exact memory ABI — read `~/Documents-CloudManaged/incitez/docs/wasm_abi.md`, mirror
      it (len-prefixed UTF-8, who-frees-what, grow-detaches-ArrayBuffer gotcha), write
      `docscan/docs/wasm_abi.md`. selftest() embeds tiny .docx + .md → assert expected text.
      CI `checks.wasm` node-smoke instantiation; report artifact SIZE (incitez ~536KB; aim small).
      Purity gate: docx/md/txt paths do NO I/O at the parse boundary.
- [x] **Milestone 2 (resolved 2026-06-13: PDF pure-Zig w/ToUnicode CMaps, BUILT into the slice) — PDF feasibility READ (BEFORE any PDF build)**: report to Einstein —
      docscan PDF parse pure-Zig or C-dep? rough wasm size delta? extraction quality (simple
      Tj/TJ content-stream only, or subset/CID font handling)? Decides PDF-via-WASM vs
      self-hosted pdf.js (incitez_web CSP `default-src 'none'; connect-src 'self'` → no CDN).

## Citation pipeline (docscan slice) — per CITATION_PIPELINE_RESPONSIBILITIES.md

docscan owns STRUCTURE-AWARE extraction + the offset map; incitez consumes the lone-\n
hard-stop signal; incitez_web composes the map for source-highlighting. Marker contract
agreed with incitez (2026-06-14): wraps→space, lone \n = boundary, no \n runs/trailing.

- [x] **Phase 1 — structure-aware extraction (md/docx/pdf)** (2026-06-14): intra-paragraph
      wraps → space (the ~47% recall fix), lone `\n` ONLY at structural boundaries. md =
      paragraph reflow; docx = `<w:p>` boundary + `<w:br/>`→space + no `\n` runs; pdf = y-gap
      threshold (font×2.2) wrap-vs-paragraph (headings already split by font-size sections).
      Reporter-spacing class still byte-for-byte. TDD red→green per format. Pushed @ fdd78334.
- [ ] **Phase 2 — offset map + `docscan_extract_structured`** (emitted↔original): sorted
      `{emitted_off, original_off}` breakpoint array (piecewise-1:1, binary-search to map back);
      new export returns `[u32 text_len][text][u32 n][n×{emitted,original}]` in one buffer.
      md/txt exact byte-to-byte first; pdf/docx pending an incitez_web highlight-needs convo
      ("original bytes" into a binary PDF isn't directly a highlight position).

## ⏸ Paused 2026-06-14 (Peter guiding chardetz) — resumption notes

**Pushed & deployed (yolo @ c83fe7c8):** WASM parse-to-text slice; reporter-spacing
fix; citation Phase 1 (md/docx/pdf structure-aware); Tm/groff wrap-join fix. The
citation "surpass" is live across formats; incitez_web consumes it.

**Local-only (NOT pushed):**
- `zonxmnro` adaptive modal line-gap (robustness; did NOT crack the Brann brief).
- `tmtxprto` ligature normalization (wanted — keep) + WinAnsi-default CP1252 stopgap
  (Peter objected to blanket "assume Windows"; INTERIM only, to be superseded by
  chardetz detection — do NOT push the assumption as-is; consider splitting the commit
  to push ligatures alone, or narrow encoding to C1-range-only as the defensible interim).

**Open threads:**
- [x] **Encoding (chardetz integration, 2026-06-14 EST):** chardetz (pure-Zig uchardet,
      published & green) now drives `encoding.detectEncoding` — C++ uchardet fully retired
      (uchardetz zon dep + all build.zig links + the `enable_uchardet` option removed; flake
      zigDepsHash recomputed). Detection works in the wasm slice now too. `encoding.toUtf8`
      transcodes EVERY single-byte charset chardetz can detect (Cyrillic/Greek/Hebrew/Arabic/
      Thai/Turkish/Vietnamese/Central-European: 19 generated `codepages.zig` tables + the
      existing WINDOWS-1252/ISO-8859-1/MAC-ROMAN) plus UTF-16/UTF-32 (BOM- and name-directed,
      surrogate pairs). CJK multibyte is detected but NOT yet transcoded (deferred per Peter).
      MFIC: tables written mechanically from Unicode MAPPINGS (VISCII via perl Encode),
      differential-tested vs `iconv` over all 256 bytes × 22 charsets (5632 cells; hermetic
      `@embedFile` oracle in codepages_test.zig). At generation iconv and MAPPINGS agreed on
      all cells (0 divergences). Regenerate via `tools/gen_codepages.sh`.
- [x] **Encoding HEURISTIC (decode-both, 2026-06-14 EST):** simple PDF fonts with no
      ToUnicode and no recognized /Encoding are marked `stopgap` (CMap.stopgap); their
      Tj/' text is kept as RAW bytes (TextSpan.raw) instead of being committed to the
      WinAnsi guess. `resolveStopgapEncoding` (parser_pdf.zig) then concatenates ALL such
      bytes in the doc (detection confidence), runs `chardetz` detection, and keeps the
      higher-scoring of {WinAnsi decode, detected decode} per `wordfix.textQuality` — with
      a fast path that trusts valid multibyte UTF-8 outright. Neither the PDF's implicit
      claim nor the detector is trusted alone; the dictionary is the independent judge.
      Fixes the classic UTF-8-as-CP1252 mojibake ("café"→"cafÃ©") while preserving genuine
      CP1252 docs (the WinAnsi default still wins when nothing beats it). chardetz detection
      now actually runs in the wasm slice too (+148KB → ~1.17MB). Test: parser_pdf.zig
      "stopgap font whose bytes are UTF-8…" (Tj) and "…in a TJ array…" (TJ). Covers the
      Tj/' and TJ-array operators (the common simple-font text paths). Remaining gap: hex
      `<...>` strings inside a stopgap font are still WinAnsi-CMap-decoded (rare — hex is a
      CID/composite-font form, which carries ToUnicode; would need a raw-bytes mode in
      extractHexStringText that keeps high bytes).
- [ ] **Brann real-brief reconstruction** (citations split across lines). DIAGNOSED 2026-06-15
      (empirical, with pdftotext as an independent oracle): NOT a wrap problem — the PDF emits
      per-styling-run fragments (italic party names split from roman prose) and docscan emits a
      newline per run. pdftotext reflows it into correct LINES, and ground-truth bboxes show
      runs share a baseline y per line (Following/five-day/jury/trial/Matrix all yMin≈125.5),
      so clustering-by-y IS achievable; docscan also tracks real positions (x=211.68). Exact
      intra-run SPACING is genuinely positional (even pdftotext emits "trial , the") — secondary,
      doesn't split citations. Agreed roadmap (Peter 2026-06-15):
      - [x] **(1) Crash bug** (2026-06-15 EST): headingLevelForSize did `@intCast(i+1)→u8`;
            a PDF with >255 distinct heading sizes (Brann's erratic sizing) overflowed it
            (Debug panic / ReleaseFast UB). Now saturates at u8 max. Regression test added.
      - [x] **(1b) parse() memory leak** (2026-06-15 EST): extractFormXObjectText resolved an
            INDIRECT /Resources via getObject (fresh alloc) but never freed it on early-return
            paths — a per-page leak on real PDFs (~976 allocs on Brann; masked by the CLI arena,
            caught by testing.allocator). Now tracks ownership + frees. Added a comprehensive
            "parse() leak sweep" test over allocation-heavy shapes (inline/indirect resources,
            form XObjects, encrypted, TJ, multi-page) as the standing leak gate — extend it
            whenever a new leak is found.
      - [x] **(2) Separate extraction vs index concerns** (2026-06-15 EST): AUDIT result —
            boundary already clean. Extraction (applySections) is faithful-restoration only
            (ligatures, de-hyphenation, word-rejoin, punctuation-spacing *restoration*); FTS5's
            unicode61 tokenizer does punctuation-stripping/case-folding at INDEX time; the index
            path adds no extra normalization. The space-BEFORE-comma is a run-join artifact (not
            an index concern). Ruling (Peter): keep punctuation-spacing restoration as faithful.
      - [~] **(3) Line-aware re-section** (IN PROGRESS, local WIP — NOT on yolo). Done: pure
            helpers clusterRunsIntoLines + joinLineRuns (committed 64743c91, unpushed) and the
            inferStructure rewire (collapse runs→per-line synthetic spans; dominant from RAW
            runs; heading detection per line median). All unit tests + the erratic-per-run-size
            regression pass. BUT validating revealed a deeper, COMPOSITION-DEPENDENT fragility:
            on long docs whose front-matter is mostly tiny text (Brann's 90pg Table of
            Authorities = 5pt dot-leaders; the 144pg arXiv survey's refs), the global font mode
            collapses to 5 → threshold ~5.75 → ~every line flagged a heading. A 5-page version
            would "work" — classic OVERFITTING risk if tuned to one doc (Peter 2026-06-15: test
            as classifiers over a SET, vary doc SIZE to float statistical-dependency bugs; do
            NOT hard-code a font floor to make Brann pass).
            NEXT: make dominant-size detection robust across the corpus (candidates: median-by-
            char / trimmed mode / bimodal-aware), validated by tools/fetch-corpus.sh +
            tests/corpus/run-corpus (the differential gate: word-recall vs pdftotext + heading-
            fraction over a stratified PUBLIC set incl. encrypted + local Brann). Accept a fix
            ONLY if the whole corpus passes — never because Brann does. Detokenizer spacing
            (the original space-before-comma concern) is already handled by joinLineRuns.
      - [x] **Corpus harness** (2026-06-15): tools/fetch-corpus.sh (pinned public arXiv 12–144pg
            + qpdf blank-pw encrypted variants + local Brann, gitignored) + tests/corpus/run-corpus
            (dev-time differential vs pdftotext; word-recall + heading-fraction; skips w/o corpus).
      - [ ] **(4) Grammar/POS** for the residual ambiguous joins (the deferred tagger).
      Fixture: `tests/corpus/legal-brann-appellate-brief.pdf` (3.5MB, gitignored).
      incitez_web holds pdf on `incitez_clean` (recall-safe) until fixed.
- [x] **POS/grammar research** (2026-06-14): docs/research/2026-06-14-pos-tagging-for-zig-wasm.md — RECOMMENDATION: averaged-perceptron tagger (pure-Zig, wasm-able via @embedFile+flate like wordfix dicts); PROPN tag = party-attribution signal for the heading-bleed problem. Implementation deferred.
      party-name signal (helps the heading-bleed problem). Synthesis still owed.
- [ ] **Ligature normalization for doc/rtf/epub** — currently only via wordfix (md/docx/pdf);
      extend to the other parsers if they don't route through wordfix.
- [ ] **Citation pipeline Phase 2** — offset map + `docscan_extract_structured` (deferred;
      md/txt exact first, pdf/docx pending incitez_web highlight-needs convo).
- [ ] Stray uncommitted `docs/superpowers/plans/2026-04-15-libvips-ocr-preprocessing.md`.

# OCR for image-only scans

Moved verbatim from PLAN.md on 2026-10-14 when the plan was reduced to one-line items.

      - [ ] **(5f) OCR for image-only scans (no text layer) — researched, not started** (Peter 2026-06-16): high-quality OCR is ML-based → clashes with the wasm32-freestanding zero-import slice, so OCR must be a SEPARATE heavy capability, not in the parse-to-text slice. Options: Tesseract (C++/C-API, Apache-2.0, best maturity, native via FFI + @embedFile traineddata) for the CLI; ocrs (Rust, MIT, compact, WASM-clean) or lazy-loaded tesseract.js for the browser. preprocess.zig (rasterize + text-region isolate) + docs/superpowers/plans/2026-04-15-libvips-ocr-preprocessing.md are the scaffolding; validate's JBIG2 decoder = image front-end. extract tries the text layer first; OCR only when absent. Awaiting Peter's direction (spike Tesseract-FFI native fallback vs ocrs-WASM eval).
      - [ ] **(5h) OCR quality ideas (Peter 2026-06-16, future)**: (a) **consensus OCR** — when both an embedded text layer AND a re-OCR exist, spatially align words by position (now correct via 5g) and keep the dictionary-valid variant per word (wordfix.isWord); the common garbles (E8cobedo/c6unsel/kn6wing) are non-words so the dict cleanly picks the good one. Same MFIC "two independent sources, keep the externally-validated one" pattern. Caveats: proper nouns (neither in dict → confidence tiebreak), both-valid-but-different. (b) **whole-word / lexicon-constrained OCR** — recognize word-images → word-probability distributions (TrOCR/ocrs lean this way; Tesseract LSTM already biases to dict). Pragmatic path: lexicon-constrained OCR mode + (a) gives most of the benefit without training a model.

## Decision 2026-10-20 (owner, walking brief docscan-ocr-direction rev 2)

Verbatim: "start a new OCR project to beat Tesseract, in Zig… call it… ocrz, and kick it off, Opus 5.5". OCR (including the consensus and lexicon-constrained ideas above) is developed in the separate ocrz project. docscan's remaining OCR work is to call ocrz for image-only pages once it is usable; the Tesseract-FFI and ocrs-WASM options are not pursued here.

## 2026-10-21: ocrz page-level C API exists

ocrz now exports `ocrz_read_page` in `include/ocrz.h`: grayscale pixels (width, height, stride) in, UTF-8 text with one line per detected text line out, caller frees. Models load separately via `ocrz_model_load`. The API is pre-1.0 and may change. Reported accuracy is not yet competitive (newspaper lines 17.9% CER against 7.3% for Tesseract's best model; a clean book page about 14% CER), so the docscan integration item stays deferred until ocrz reports usable accuracy.

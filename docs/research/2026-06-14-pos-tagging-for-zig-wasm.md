# POS / grammar tagging that can live inside Zig and compile to WASM

**Date:** 2026-06-14 · **Context:** Peter asked whether part-of-speech / grammar
signal could be a docscan output mode — and specifically whether it can be embedded
in the Zig core and compiled to `wasm32-freestanding` (like the existing
parse-to-text slice).

## TL;DR

**Yes — use an averaged-perceptron POS tagger.** Its inference is pure
arithmetic over a sparse feature→weight map + a greedy argmax (no I/O, no C deps,
no ML runtime), and its model is *just data* — so it embeds via `@embedFile` +
`std.compress.flate` **exactly like docscan already embeds `dictionary.zlib` /
`proper_nouns.zlib` in `wordfix`**, and compiles to `wasm32-freestanding`
trivially. It's the same tagger spaCy/NLTK/TextBlob ship; ~96.8% accuracy; a
working Rust port with a C ABI already exists, proving the algorithm + model port
cleanly to a systems language.

## Why this constraint rules most tools out

- **Neural / transformer taggers** (spaCy v3, Stanza, Flair, BERTweet) hit 95–97%
  but need a tensor/ML runtime, large weights, and aren't `wasm-freestanding`
  friendly. Out for the embedded-in-Zig goal.
- POS accuracy has **plateaued at ~92–97% for a decade**; past ~97% is diminishing
  returns. So a *classical* tagger gives essentially state-of-the-art signal at a
  fraction of the footprint — perfect when the constraint is "must compile to WASM
  with no runtime."

## Candidates, ranked for "embed in Zig → WASM"

### 1. Averaged perceptron (RECOMMENDED)
- **Algorithm:** greedy left-to-right; for each token, sum the weights of its
  active features per candidate tag, take the argmax (alphabetic tiebreak). No
  search, no CRF. ~200 lines of core logic.
- **Features (13, all sparse/binary):** bias; current-word suffix (last 3 chars);
  first char; previous tag; tag-two-back; tag-history (prev+2back); current word;
  previous word + its suffix; word-two-back; next word + its suffix; word-two-ahead;
  (prev-tag × current-word). Words lowercased; numbers → `!YEAR`/`!DIGITS`.
- **Model:** a dict-of-dicts `{feature → {tag → weight}}`, a tag list, and a
  known-word→tag table. Pure data → compress + `@embedFile`.
- **Accuracy:** 96.8% WSJ in-domain (94.8% broadcast, 91.8% web).
- **Portability proof:** `postagger.rs` (Apache-2.0) is a Rust port of NLTK's
  averaged-perceptron model with a **C ABI** (cbindgen); 100% Rust, cross-target.
  No WASM yet, but pure-Rust ⇒ wasm-trivial. Zig is in the same class — a direct
  reimplementation is very tractable. *"Sparse features and dictionary-based
  weights suit embedded systems better than dense matrices."*

### 2. RDRPOSTagger (rule-based, Ripple-Down-Rules)
- Error-driven SCRDR **rule tree** + initial lexicon; 45 languages; ~90K words/s
  (Java). Per-language model is small (the 41 MB release is *all 330* models).
  Inference = walk a rule tree — trivial to port; tiny embed. **GPL** (license
  friction). Slightly below perceptron accuracy. Good fallback / multilingual path.

### 3. Brill / FastTag (`pos-js` lineage)
- Brill transformation rules + an English lexicon (word→most-common-tag). Simplest
  to port; the lexicon is the bulk (~hundreds of KB). Lowest accuracy (~Brill-era).
  Smallest code; a fine "v0" if model size must be minimal.

### 4. HMM / Viterbi (`viterbi_pos_tagger` lineage)
- Emission + transition tables, DP decode. Embeddable; ~95–96%. More than greedy
  perceptron's complexity for similar/again-lower accuracy. Not preferred.

## Model sourcing & tagset (licensing matters)

- **Fast path:** reuse NLTK's `averaged_perceptron_tagger` weights (what
  postagger.rs does) — Penn Treebank tagset (45 tags: `NNP`, `NN`, `VB`, …).
  Check the model-distribution license (the *weights* are generally redistributable;
  Penn Treebank *training text* is restricted, but we ship only the model).
- **Clean path (recommended):** train a compact model on **Universal Dependencies**
  (mostly CC-BY-SA) with the **Universal POS tagset (17 tags)**. Benefits: permissive
  license, a tidy 17-tag output, and crucially a dedicated **`PROPN`** (proper noun)
  tag — exactly the signal we want (see below). Prune low-magnitude features to
  shrink the embed.
- **Size:** raw NLTK weights are a few MB; compressed + pruned ≈ low-MB embed — same
  order as docscan's current embedded dicts, same `@embedFile`+flate mechanism.

## Why this is directly useful to docscan (the "signal")

The citation pipeline's hardest open problem is **party attribution / heading-bleed**
(distinguishing a case-name proper noun from a surrounding heading or prose). POS
gives that signal cheaply:
- **`PROPN`/`NNP` runs** = candidate party names ("Brown", "Board of Education").
  Combined with the structural `\n` boundaries docscan already emits, a tagger lets
  the consumer say "this token span is a proper-noun phrase, and it does/doesn't
  cross a boundary" — a stronger antecedent/walk-back stop than geometry alone.
- Cheap **noun-phrase chunking** and **sentence-boundary** signal build on POS.
- It's a *feature*, not an oracle (96.8%): use to bias decisions, not to gate them —
  which matches the "provides signal for downstream decisions" framing.

Beyond POS, **dependency parsing** (subject/object/apposition structure) is the
next rung — transition-based parsers are also classical and portable, but bigger;
POS + shallow NP chunking is the tractable first deliverable, parsing deferred.

## Concrete docscan integration sketch

- New pure-Zig module `src/core/pos.zig`: feature extractor + sparse weight lookup +
  greedy argmax. No I/O, no C deps → compiles into both the native CLI and the wasm
  slice.
- Model embedded as `pos_model.<fmt>.zlib` via `@embedFile` + `std.compress.flate`
  (the established `wordfix` pattern), decoded once at first use.
- Surfaces: a `docscan tag` CLI mode (JSON per-token tags) and a wasm export
  `docscan_pos_tag(ptr,len) -> [u32 LE len][tags]` alongside `docscan_extract_text`,
  same memory ABI.
- MFIC: differential-test the Zig tagger against the reference (NLTK/postagger.rs)
  over a corpus — same maker≠checker discipline used elsewhere.

## Sources

- [A Good Part-of-Speech Tagger in about 200 Lines (Explosion / spaCy author)](https://explosion.ai/blog/part-of-speech-pos-tagger-in-python)
- [NLTK averaged-perceptron tagger source](https://www.nltk.org/_modules/nltk/tag/perceptron.html)
- [postagger.rs — Rust averaged-perceptron tagger w/ C ABI](https://github.com/shubham0204/postagger.rs)
- [viterbi_pos_tagger (Rust, no-deps HMM)](https://crates.io/crates/viterbi_pos_tagger)
- [RDRPOSTagger (rule-based, 45 languages)](https://github.com/datquocnguyen/RDRPOSTagger)
- [pos-js — Brill/FastTag in JS](https://github.com/dariusk/pos-js)
- [Optimal Size-Performance Tradeoffs: Weighing PoS Tagger Models (arXiv)](https://arxiv.org/pdf/2104.07951)
- [Universal Dependencies (training data, UPOS tagset)](https://universaldependencies.org/)

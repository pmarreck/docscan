# Known limitations and extraction artifacts

Moved verbatim from PLAN.md on 2026-10-14 when the plan was reduced to one-line items.

## Known Limitations

- **Word rejoining ambiguity**: When a PDF/OCR split produces two fragments that are BOTH valid dictionary words but the combined form is also a word (e.g., "met hod" → "method", "car go" → "cargo", "for age" → "forage"), the pipeline conservatively keeps them separate. Resolving this requires sentence-level semantic context — a statistical language model or LLM, not a dictionary lookup. Same applies to 3+ way splits like "pr operl y" → "properly" where no pairwise combination is a word. Out of scope for the current dictionary-based approach.

## Known text extraction artifacts (remaining)

- OCR-like corruption: "wo1,1ld" — commas/digits substituted for letters, can't fix without OCR correction
- Email/URL boundaries: "Nakamotosatoshin@gmx.comwww.bitcoin.org" — need URL/email pattern detection to insert spaces
- Encoding replacement chars: "�" in some PDFs (Berkshire letter) — need better fallback encoding handling
- Stray isolated ligature expansions: lone "ff" on a line from a PDF ligature with no surrounding context

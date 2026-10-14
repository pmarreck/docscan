# Logical page numbers

Moved verbatim from PLAN.md on 2026-10-14 when the plan was reduced to one-line items.

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

# Legal citation extraction — reference & integration plan

## The tool: eyecite (Free Law Project)

**eyecite** is the standard open-source library for finding legal citations in arbitrary text. Repo: <https://github.com/freelawproject/eyecite>.

- Extracts **full** citations (`Bush v. Gore, 531 U.S. 98`), **short form** (`531 U.S., at 99`), **supra** (`Bush, supra, at 100`), **id.** and **ibid.** references.
- Battle-tested at scale: run against **50M+ citations**; powers CourtListener and the Caselaw Access Project; developed with the Harvard Library Innovation Lab.
- Its coverage comes mostly from two open **data** packages, not from clever code:
  - **reporters-db** — every reporter abbreviation, edition, and variation (<https://github.com/freelawproject/reporters-db>)
  - **courts-db** — court metadata / jurisdiction mapping (<https://github.com/freelawproject/courts-db>)

## Maturity (as of June 2026)

Mature — yes. Version **2.7.6** (Jun 2025), Trove classifier **"5 — Production/Stable"**; well past 1.0 with no major-version churn. Powers CourtListener, the Caselaw Access Project, and Harvard LIL at production scale; reporters-db is trained on **55M+ citations**.

Releases are *frequent but incremental* (2.7.0 → 2.7.6 in ~2 months: edge-case fixes, a two-step reference/`supra` resolution refinement, data syncs) — i.e. polishing the long tail, **not** rewriting the grammar. No 3.0, no breaking grammar changes.

The split that matters for a port: the **grammar/rules** (full / short / supra / id. / ibid.) are settled and stable — that's what you port, and it barely moves; the **coverage data** (reporters-db) is a living JSON dataset that grows *additively* — that's what you re-vendor periodically. The churn lives in the data, not the rules: the best possible shape for a port-the-code / vendor-the-data plan.

Scope honesty: best-in-class for **US case-law** citations (its design center) plus statutes/regs via reporters-db; weaker on foreign, historical, or exotic formats. Fine if docscan's corpus is US legal documents; a gap to note otherwise.

## The catch for docscan

eyecite is **Python**. docscan is pure Zig (no-Python house rule, single static binary). So we do **not** take a Python runtime dependency. The value to extract is the *data* and the *grammar*, both language-agnostic.

## Recommended integration (MFIC-shaped, no Python at runtime)

1. **Vendor the data** — `reporters-db` and `courts-db` are open JSON. Pull them in as a data asset (regenerate-able), the way we'd vendor any lookup table.
2. **Port the matcher to Zig** — implement the citation grammar (full / short / supra / id. / ibid.) in the Zig core as a structure-aware pass over already-extracted text. Modest next to the parsers already here (H.264/LZMA-class work this is not).
3. **Use eyecite as the differential-test oracle** — run eyecite and the Zig extractor over the same citation corpus in CI; they must agree. eyecite is the *reference implementation*, invoked only at test time (Python stays out of the shipped binary). This is the MFIC **static / differential** check: the verifier's correctness is anchored to an independent, 50M-citation-tested oracle, not to our own say-so.
4. **Emit citations as structured chunk metadata** — each indexed chunk gets its extracted citations as fields. This enables citation-aware search in docscan **and** feeds the extraction stage of the `legal_ai` verification harness (existence / treatment / quote-fidelity lookups downstream). See `../legal_ai/verification_harness_spec.md`.

## Status

Noted, not yet built. Sequence when picked up: vendor data → Zig matcher (TDD) → differential CI gate vs. eyecite → chunk-metadata wiring.

## Sources

- eyecite — <https://github.com/freelawproject/eyecite> · <https://free.law/projects/eyecite/>
- reporters-db — <https://github.com/freelawproject/reporters-db>
- courts-db — <https://github.com/freelawproject/courts-db>

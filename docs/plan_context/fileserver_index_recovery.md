# Fileserver index recovery (tabled)

Moved verbatim from PLAN.md on 2026-10-14 when the plan was reduced to one-line items.

## Ops: fileserver index recovery (Textfiles & PDF & eBook corpus) — TABLED 2026-06-13 (Peter: WASM slice is higher priority)

Index run died ~Jun 5 09:57 when /Volumes/Fileserver went unresponsive (external
mount failure, NOT a docscan bug — process wedged in uninterruptible "U" state).
DB left ~70% done: 834/1200 docs, ~143k embeddings, hot journal present (unclean
shutdown). Clean 732MB `index.db.killed-20260603-212303` backup beside it.

DECISION (Peter, 2026-06-12): the index DB is a *derived* artifact → it belongs on
LOCAL disk; the corpus is read remotely. NO copy-back. Only one-time copy is a 932MB
pull-DOWN of the existing partial to recover the 70% GPU work (optional vs fresh-local).
- [ ] Confirm local DB home + resume-from-pull vs fresh-local, then execute
- [ ] Proposed improvement: docscan auto-defaults DB to a local app-data dir when the corpus is detected on a network mount (one-line stderr note) — kills the footgun by construction instead of by remembering `--db`.

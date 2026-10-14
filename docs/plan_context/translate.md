# docscan translate (future idea)

Moved verbatim from PLAN.md on 2026-10-14 when the plan was reduced to one-line items.

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

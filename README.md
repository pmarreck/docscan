# docscan

[![CI](https://github.com/pmarreck/docscan/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/docscan/actions/workflows/ci.yml)
[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fdocscan%3Fbranch%3Dyolo)](https://garnix.io/repo/pmarreck/docscan)

Document indexing and semantic search for `.md`, `.docx`, `.pdf`, `.doc`, and `.rtf` files.

## What it does

docscan indexes a collection of documents, extracts structured text with heading detection, chunks by document structure, embeds via a local model (Ollama or oMLX), and provides hybrid vector + lexical search from the CLI or via MCP for LLM integration.

## Architecture

```
C CLI (I/O, Ollama/oMLX, files) → C FFI → Zig Core (pure computation)
                                             ├── Parsers (md, docx, pdf, doc, rtf)
                                             ├── Chunker (structure-aware)
                                             ├── Storage (SQLite + sqlite-vec + FTS5)
                                             └── Search (hybrid vector + BM25 with RRF)
```

- **Zig core** is pure computation — no I/O, receives byte slices, returns structured results
- **C FFI** is the public API boundary — flat C functions with opaque handles
- **C CLI** handles all I/O: file reading, embedding server calls, progress bars, output formatting
- **MCP server** over stdio for LLM integration (JSON-RPC 2.0)

## Quick start

```bash
# Build
nix build
# or
./build

# Index a directory
docscan index ~/Documents/contracts/

# Search (exact text match, no embedding server needed)
docscan search --exact "indemnification clause"

# Search (hybrid semantic + lexical, needs Ollama or oMLX)
docscan search "liability protection provisions"

# Check index status
docscan status

# Extract text from a document (no database needed)
docscan extract document.pdf
docscan extract --markdown report.docx
docscan extract --json contract.md
docscan extract --from 5 --to 10 book.pdf
cat file.md | docscan extract --format md -

# Normalize text (fix word splits, ligatures, hyphenation)
echo "kn own" | docscan normalize```

## Embedding backends

docscan supports both Ollama and OpenAI-compatible embedding servers (oMLX, LM Studio, vLLM, etc.).

```bash
# Ollama (default)
docscan index ~/docs/ --model nomic-embed-text

# oMLX / OpenAI-compatible
docscan index ~/docs/ \
  --embedding-api openai \
  --embedding-url http://localhost:8000 \
  --embedding-api-key YOUR_KEY \
  --model bge-m3-mlx-fp16
```

Settings are saved to `.docscan/config.ini` on first index, so subsequent commands pick them up automatically.

Environment variables: `DOCSCAN_MODEL`, `DOCSCAN_EMBEDDING_API`, `DOCSCAN_EMBEDDING_URL`, `DOCSCAN_EMBEDDING_API_KEY`, `DOCSCAN_DB`

Override precedence: CLI flags > env vars > `.docscan/config.ini` > global `~/.config/docscan/config.ini` > defaults

To see the effective configuration with the source of each value:

```bash
docscan config debug
docscan config debug --json  # machine-readable
```

## MCP server

```bash
# Start MCP server for LLM integration
docscan mcp-serve --db path/to/index.db
```

Exposes 7 tools: `docscan_search`, `docscan_status`, `docscan_read_chunk`, `docscan_list_docs`, `docscan_config`, `docscan_index`, `docscan_update`

## Search modes

| Mode | Flag | Description |
|------|------|-------------|
| Hybrid | *(default)* | Vector similarity + BM25 lexical, fused with Reciprocal Rank Fusion |
| Exact | `--exact` | FTS5 full-text search only (no embedding server needed) |
| Similar | `--similar` | Vector similarity only |

## Document format support

| Format | Extraction | Structure detection | Location info |
|--------|-----------|-------------------|---------------|
| `.md` | Full text | ATX headings (`#` through `######`) | Line number |
| `.txt` | Full text | (same as markdown) | Line number |
| `.docx` | Full text + metadata | Word heading styles (Heading1-6, Title) | Page (from `lastRenderedPageBreak`) |
| `.pdf` | Full text via content stream operators | Font-size heuristics + ToUnicode CMap | Page number |
| `.doc` | Full text via OLE2/Piece Table | Heuristic (ALL CAPS, numbered sections) | — |
| `.rtf` | Full text with Unicode/Windows-1252 decoding | Font-size heuristics, `\page` breaks | Page (hard breaks) |
| `.epub` | Full text from XHTML chapters | HTML headings (h1-h6) | — |
## Building from source

Requires [Nix](https://nixos.org/download) with flakes enabled.

```bash
./build              # Release build via nix build
./build --debug      # Debug build
./build --test       # Build + run tests
./test               # Run all test suites (unit + CLI + MCP)
./build_all          # Cross-compile for 5 targets
```

## Cross-platform targets

- macOS aarch64 (Apple Silicon)
- Linux aarch64
- Linux x86_64
- Windows aarch64
- Windows x86_64

## License

MIT

# docscan

**docscan** is a CLI tool for indexing and semantically searching document collections (`.md`, `.docx`, `.pdf`, `.doc`). It provides hybrid search combining vector similarity (via Ollama embeddings stored in sqlite-vec) with lexical BM25 ranking (via SQLite FTS5), fused through Reciprocal Rank Fusion (RRF).

## Architecture

```
C CLI (all I/O) --> C FFI boundary --> Zig core (pure computation, no I/O)
```

- **Zig core**: Parsers, chunker, search engine, storage layer. Takes byte slices in, returns structured results. No file reads, no HTTP calls.
- **C FFI**: Flat C API with opaque handles. This is the public API.
- **C CLI**: Dogfoods the FFI. Handles file I/O, Ollama embedding requests, progress display, MCP server.

## Key Terminology

- **Document**: A parsed file with structural metadata (sections, headings, metadata entries).
- **Section**: A hierarchical unit within a document (heading + content + children).
- **Chunk**: A text fragment derived from sections, carrying a breadcrumb path, sized for embedding.
- **Embedding**: A vector representation of a chunk's text, computed by Ollama (nomic-embed-text default, 768 dimensions).
- **Hybrid search**: Vector cosine similarity + FTS5 BM25, combined via RRF with configurable weight (default 70% vector / 30% lexical).
- **MCP**: Model Context Protocol server over stdio (JSON-RPC 2.0), providing read-only search tools for LLM integration.

## Supported Formats

| Format | Extension | Parser Strategy |
|--------|-----------|-----------------|
| Markdown | `.md` | Split on `#` headings |
| DOCX | `.docx` | Unzip + XML walk (`w:p`, `w:pStyle`) |
| PDF | `.pdf` | Content stream text operators + font heuristics |
| DOC | `.doc` | OLE2 container + Piece Table extraction |

## Commands

```
docscan index <path>       Index a directory or file
docscan update [path]      Re-index changed files
docscan search <query>     Hybrid search (default)
docscan status             Show index stats
docscan mcp-serve          MCP server over stdio
docscan config             Show/set config
```

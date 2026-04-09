# Code Minimap

## Build System

- **`build.zig`** — Zig build configuration. Declares sqlite-vec dependency, core module, static library (`docscan_core`), C CLI executable (`docscan`), and unit test step. Defaults to ReleaseFast.
- **`build.zig.zon`** — Package manifest. Declares sqlite-vec dependency (provides sqlite3 + sqlite_vec0 artifacts).
- **`flake.nix`** — Nix flake. Pre-fetches sqlite-vec via `fetchgit`, creates `zigPkgCache` linkFarm for `--system` flag. Defines `packages.default`, `checks.${system}.{build,test}`, and `devShells.default` (with zig, jq, hyperfine).

## Source — `src/`

- **`src/all_tests.zig`** — Aggregated test entry point. Imports all test-containing modules so `zig build test` discovers everything.
- **`src/core/document.zig`** — Core data model types:
  - `Format` enum (md, docx, pdf, doc) with `extension()` and `fromExtension()` methods
  - `MetadataEntry` struct (key, value)
  - `Section` struct (heading, level, content, children) — recursive hierarchy
  - `Document` struct (path, format, title, metadata, sections)
  - `Chunk` struct (document_path, section_path, heading, text, start_byte, end_byte, chunk_index)
  - `SearchResult` struct (document_path, document_title, section_path, heading, text, score, vector_score, lexical_score)
- **`src/ffi/c_api.zig`** — C FFI implementation. Currently exports `docscan_version()`.

## FFI Header — `ffi/`

- **`ffi/docscan_core.h`** — C header declaring the public FFI API. Currently declares `docscan_version()`.

## CLI — `cli/`

- **`cli/main.c`** — Full C CLI entry point (~1050 lines). Dogfoods the C FFI for all operations. Includes:
  - **SHA-256** — Minimal FIPS 180-4 implementation for file change detection hashing.
  - **HTTP client** — POSIX socket-based HTTP POST for Ollama embedding API (`/api/embed`). Non-blocking connect with timeout.
  - **JSON extraction** — Minimal parsers for Ollama embedding responses and chunk text extraction.
  - **Directory walker** — Recursive `opendir`/`readdir` with format filtering (.md, .docx, .pdf, .doc) and noise directory skipping.
  - **Progress bar** — Terminal-aware progress with rate/ETA display on stderr.
  - **Commands**: `index <path>`, `update [path]`, `search <query>`, `status`, `config [key] [value]`, `mcp-serve`.
  - **MCP server** (`cmd_mcp_serve`) — JSON-RPC 2.0 over newline-delimited stdin/stdout. Implements:
    - Protocol: `initialize`, `tools/list`, `tools/call`, `ping`, `notifications/initialized`
    - Tools: `docscan_search`, `docscan_status`, `docscan_read_chunk`, `docscan_list_docs`, `docscan_config`, `docscan_index`, `docscan_update`
    - JSON helpers: `mcp_json_get_string`, `mcp_json_get_int`, `mcp_json_has_key`, `mcp_json_get_params`, `mcp_json_get_arguments`
    - Response helpers: `mcp_write_result_text`, `mcp_write_raw_result`, `mcp_write_error`
    - Supports integer and string request ids; graceful error handling for malformed input and unknown methods/tools
  - **Flags**: `--help`, `--about`, `--json`, `--limit`, `--exact`, `--similar`, `--model`, `--db`, `--no-color`, `--no-progress`, `--simple`, `--lang`.
  - **Environment**: `DOCSCAN_MODEL`, `DOCSCAN_DB`, `DOCSCAN_LANG`.

## Scripts

- **`build`** — Nix build wrapper. Supports `--test`, `--debug` flags.
- **`test`** — Master test runner. Runs unit + cli + mcp suites, accumulates failures.
- **`bm`** — Benchmark runner stub. Rejects debug builds, uses hyperfine.
- **`build_all`** — Cross-compile for 5 targets (native + 4 cross).

## Documentation

- **`PROJECT_OVERVIEW.md`** — Architecture, terminology, supported formats, commands.
- **`PLAN.md`** — Task checklist with completion timestamps.
- **`CODE_MINIMAP.md`** — This file.

## Tests — `tests/`

- **`tests/unit/`** — Zig unit test fixtures (empty, tests live in source files)
- **`tests/cli/`** — Bash CLI black-box tests (not yet created)
- **`tests/mcp/`** — MCP JSON-RPC tests (not yet created)
- **`tests/integration/`** — Full pipeline tests requiring Ollama (not yet created)

## Benchmarks — `benchmarks/`

- **`benchmarks/fixtures/`** — Benchmark fixture documents (not yet populated)

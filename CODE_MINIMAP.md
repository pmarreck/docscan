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

- **`cli/main.c`** — C CLI entry point. Prints version via FFI. Emits DEBUG BUILD warning when compiled without NDEBUG.

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

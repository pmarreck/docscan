# docscan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CLI tool for indexing and semantically searching document collections (.md, .docx, .pdf, .doc) with hybrid vector+lexical search, exposed via CLI and MCP.

**Architecture:** Zig core (pure, no I/O) → C FFI → C CLI. Parsers extract structured text from documents, chunker splits by structure, embeddings via Ollama, storage in SQLite+sqlite-vec+FTS5, hybrid search with RRF fusion. MCP server over stdio for LLM integration.

**Tech Stack:** Zig 0.15+, SQLite amalgamation + sqlite-vec (static), FTS5, Ollama (nomic-embed-text), Nix (flake.nix), Garnix CI.

**Reference projects:**
- `/Users/pmarreck/Documents-CloudManaged/codescan` — sibling project, same architecture pattern for storage/search/MCP
- `/Users/pmarreck/Documents-CloudManaged/validate` — fork PDF/DOCX/DOC parser infrastructure from here

**Spec:** `docs/superpowers/specs/2026-04-08-docscan-design.md`

---

## File Structure

```
docscan/
├── src/
│   ├── core/
│   │   ├── document.zig          -- Document/Section/Chunk model structs
│   │   ├── parser_md.zig         -- Markdown text extraction + structure
│   │   ├── parser_docx.zig       -- DOCX (ZIP + XML) text extraction
│   │   ├── parser_pdf.zig        -- PDF content stream text extraction
│   │   ├── parser_doc.zig        -- Legacy Word OLE2 text extraction
│   │   ├── chunker.zig           -- Structure-aware chunk splitting
│   │   ├── storage.zig           -- SQLite + sqlite-vec + FTS5 layer
│   │   ├── search.zig            -- Hybrid vector + BM25 search engine
│   │   └── xml.zig               -- Minimal XML parser for DOCX
│   ├── ffi/
│   │   └── c_api.zig             -- C FFI implementation
│   └── all_tests.zig             -- Aggregated test entry point
├── ffi/
│   └── docscan_core.h            -- C FFI header
├── cli/
│   └── main.c                    -- C CLI (all I/O, Ollama, MCP)
├── tests/
│   ├── unit/                     -- Zig unit test fixtures
│   ├── cli/
│   │   └── test-cli              -- Bash CLI tests
│   ├── mcp/
│   │   └── test-mcp              -- Bash MCP tests
│   └── integration/
│       └── test-integration      -- Requires Ollama
├── benchmarks/
│   ├── fixtures/                 -- Benchmark fixture documents
│   └── results.log
├── build.zig
├── build.zig.zon
├── flake.nix
├── flake.lock
├── .docscanignore.default
├── build                         -- Nix build script
├── build_all                     -- Cross-compile all targets
├── test                          -- Master test runner
├── bm                            -- Benchmark runner
├── PLAN.md
├── PROJECT_OVERVIEW.md
└── CODE_MINIMAP.md
```

---

## Task 1: Project Scaffolding

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `flake.nix`
- Create: `src/all_tests.zig`
- Create: `src/core/document.zig`
- Create: `build` (script)
- Create: `test` (script)
- Create: `bm` (script)
- Create: `build_all` (script)
- Create: `PROJECT_OVERVIEW.md`
- Create: `PLAN.md`
- Create: `CODE_MINIMAP.md`

- [ ] **Step 1: Create `build.zig.zon`**

```zig
.{
    .name = .docscan,
    .version = "0.1.0",
    .fingerprint = 0x0,  // Zig will compute on first build
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "ffi",
        "cli",
    },
    .dependencies = .{
        // sqlite-vec provides both sqlite3 and vec extension
        .sqlite_vec = .{
            .url = "git+https://github.com/pmarreck/sqlite-vec.git#<commit>",
            .hash = "<hash>",  // Get from codescan's build.zig.zon
        },
    },
}
```

Note: Copy the exact sqlite-vec dependency URL and hash from codescan's `build.zig.zon` at `/Users/pmarreck/Documents-CloudManaged/codescan/build.zig.zon`.

- [ ] **Step 2: Create `build.zig`**

Modeled on codescan's build.zig but much simpler (no tree-sitter, no PCRE2):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // SQLite + sqlite-vec from dependency
    const sqlite_vec_dep = b.dependency("sqlite_vec", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite3_lib = sqlite_vec_dep.artifact("sqlite3");
    const vec_static_lib = sqlite_vec_dep.artifact("sqlite-vec-static");

    // Core library (Zig, pure computation)
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/document.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library for C FFI
    const lib = b.addStaticLibrary(.{
        .name = "docscan_core",
        .root_source_file = b.path("src/ffi/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("core", core_mod);
    lib.linkLibrary(sqlite3_lib);
    lib.linkLibrary(vec_static_lib);
    lib.root_module.addCMacro("SQLITE_VEC_STATIC", "1");
    lib.installHeader(b.path("ffi/docscan_core.h"), "docscan_core.h");
    b.installArtifact(lib);

    // C CLI executable
    const exe = b.addExecutable(.{
        .name = "docscan",
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{"-std=c11"},
    });
    exe.linkLibrary(lib);
    exe.linkLibrary(sqlite3_lib);
    exe.linkLibrary(vec_static_lib);
    b.installArtifact(exe);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/all_tests.zig"),
        .target = target,
        .optimize = .Debug,
    });
    unit_tests.root_module.addImport("core", core_mod);
    unit_tests.linkLibrary(sqlite3_lib);
    unit_tests.linkLibrary(vec_static_lib);
    unit_tests.root_module.addCMacro("SQLITE_VEC_STATIC", "1");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 3: Create `flake.nix`**

Follow the zigDeps fixed-output derivation pattern from CLAUDE.md:

```nix
{
  description = "docscan - document indexing and semantic search";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pname = "docscan";
        version = "0.1.0";

        zigDepsHash = "";  # Set to "" first, build to get real hash

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = ./.;
          nativeBuildInputs = with pkgs; [ zig git cacert ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$out
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';
          dontInstall = true;
          dontFixup = true;
        };
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            zig build -Doptimize=ReleaseFast --prefix $out
          '';
          dontInstall = true;
        };

        checks.${system} = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ pkgs.zig ];
            buildPhase = ''
              export HOME=$TMPDIR
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              mkdir -p $ZIG_GLOBAL_CACHE_DIR
              cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
              chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
              timeout 600 zig build test || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
            jq
            ollama
          ];
        };
      });
}
```

- [ ] **Step 4: Create stub source files**

`src/core/document.zig` — the Document model (empty stubs to make build compile):

```zig
const std = @import("std");

pub const Format = enum {
    md,
    docx,
    pdf,
    doc,
};

pub const Section = struct {
    heading: ?[]const u8,
    level: u8,
    content: []const u8,
    children: []const Section,
};

pub const Document = struct {
    path: []const u8,
    format: Format,
    title: ?[]const u8,
    metadata: []const MetadataEntry,
    sections: []const Section,
};

pub const MetadataEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const Chunk = struct {
    document_path: []const u8,
    section_path: []const u8,
    heading: ?[]const u8,
    text: []const u8,
    start_byte: u64,
    end_byte: u64,
    chunk_index: u32,
};

pub const SearchResult = struct {
    document_path: []const u8,
    document_title: ?[]const u8,
    section_path: []const u8,
    heading: ?[]const u8,
    text: []const u8,
    score: f32,
    vector_score: f32,
    lexical_score: f32,
};
```

`src/all_tests.zig`:

```zig
test {
    _ = @import("core/document.zig");
}
```

`src/ffi/c_api.zig` (minimal stub):

```zig
const std = @import("std");

export fn docscan_version() [*:0]const u8 {
    return "0.1.0";
}
```

`ffi/docscan_core.h`:

```c
#ifndef DOCSCAN_CORE_H
#define DOCSCAN_CORE_H

const char* docscan_version(void);

#endif
```

`cli/main.c` (minimal stub):

```c
#include <stdio.h>
#include "docscan_core.h"

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    printf("docscan %s\n", docscan_version());
    return 0;
}
```

- [ ] **Step 5: Create build scripts**

`build` (chmod +x):

```bash
#!/usr/bin/env bash
set -u
mode="release"
for arg in "$@"; do
    case "$arg" in
        --test)  mode="test" ;;
        --debug) mode="debug" ;;
    esac
done

case "$mode" in
    release)
        nix build 2>&1
        mkdir -p zig-out/bin
        cp -f result/bin/docscan zig-out/bin/docscan
        echo "Built: zig-out/bin/docscan"
        ;;
    test)
        nix build .#checks.$(nix eval --impure --expr 'builtins.currentSystem').test 2>&1
        ;;
    debug)
        nix develop -c zig build -Doptimize=Debug
        ;;
esac
```

`test` (chmod +x):

```bash
#!/usr/bin/env bash
set -u
errors=0

echo "=== Unit Tests ==="
nix develop -c zig build test 2>&1 || ((errors++))

if [ -x tests/cli/test-cli ]; then
    echo "=== CLI Tests ==="
    tests/cli/test-cli || ((errors++))
fi

if [ -x tests/mcp/test-mcp ]; then
    echo "=== MCP Tests ==="
    tests/mcp/test-mcp || ((errors++))
fi

echo ""
if [ "$errors" -gt 0 ]; then
    echo "FAILED: $errors test suite(s) failed"
    exit "$errors"
else
    echo "ALL TESTS PASSED"
fi
```

`bm` (chmod +x):

```bash
#!/usr/bin/env bash
set -u

# Ensure we're running a release build
binary="zig-out/bin/docscan"
if [ ! -f "$binary" ]; then
    echo "No release binary found. Run ./build first."
    exit 1
fi

debug_check=$("$binary" --about 2>&1)
if echo "$debug_check" | grep -q "DEBUG BUILD"; then
    echo "ERROR: Cannot benchmark a debug build. Run ./build (release) first."
    exit 1
fi

echo "=== Benchmarks ==="
echo "TODO: benchmarks not yet implemented"
```

`build_all` (chmod +x):

```bash
#!/usr/bin/env bash
set -u
echo "=== Building all targets ==="
targets=(
    "aarch64-macos"
    "aarch64-linux-musl"
    "x86_64-linux-musl"
    "aarch64-windows"
    "x86_64-windows"
)

errors=0
for t in "${targets[@]}"; do
    echo "Building: $t"
    nix develop -c zig build -Dtarget="$t" -Doptimize=ReleaseFast 2>&1 || ((errors++))
done

if [ "$errors" -gt 0 ]; then
    echo "FAILED: $errors target(s) failed"
    exit "$errors"
else
    echo "ALL TARGETS BUILT"
fi
```

- [ ] **Step 6: Create project docs**

`PROJECT_OVERVIEW.md`:

```markdown
# docscan

A CLI tool for indexing and semantically searching document collections
(.md, .docx, .pdf, .doc).

## Architecture

Zig core (pure, no I/O) → C FFI → C CLI (hexagonal design).

- **Parsers** extract structured text from documents
- **Chunker** splits by document structure (sections, headings)
- **Embeddings** via Ollama (nomic-embed-text default)
- **Storage** in SQLite + sqlite-vec + FTS5
- **Search** hybrid vector + BM25 with RRF fusion
- **MCP** server over stdio for LLM integration

## Terminology

- **Chunk**: A semantic unit of text from a document, typically one section or clause
- **Section path**: Breadcrumb string like "Section 4 > 4.2 > (a)" showing hierarchy
- **Hybrid search**: Combines vector similarity and BM25 lexical ranking
- **RRF**: Reciprocal Rank Fusion — method for merging two ranked lists
```

- [ ] **Step 7: Run initial build to verify scaffolding compiles**

```bash
nix develop -c zig build
```

Expected: compiles successfully, produces `zig-out/bin/docscan` that prints version.

- [ ] **Step 8: Commit**

```bash
git init && git checkout -b yolo
git add build.zig build.zig.zon flake.nix src/ ffi/ cli/ build test bm build_all PROJECT_OVERVIEW.md PLAN.md CODE_MINIMAP.md .docscanignore.default
git commit -m "$(cat <<'EOF'
scaffold docscan project

Zig core + C FFI + C CLI hexagonal architecture.
SQLite + sqlite-vec dependency. Build scripts, flake.nix, Garnix CI checks.
EOF
)"
```

---

## Task 2: Markdown Parser

The simplest parser. Proves the Document model works end-to-end.

**Files:**
- Create: `src/core/parser_md.zig`
- Modify: `src/all_tests.zig`

**Reference:** No validate code to fork — markdown is plaintext with `#` headings.

- [ ] **Step 1: Write failing test — basic heading extraction**

In `src/core/parser_md.zig`:

```zig
const std = @import("std");
const document = @import("document.zig");

pub fn parse(allocator: std.mem.Allocator, content: []const u8, path: []const u8) !document.Document {
    _ = allocator;
    _ = content;
    _ = path;
    unreachable; // Not yet implemented
}

test "md: basic heading structure" {
    const alloc = std.testing.allocator;
    const md =
        \\# Title
        \\
        \\Intro paragraph.
        \\
        \\## Section A
        \\
        \\Content A.
        \\
        \\## Section B
        \\
        \\Content B.
    ;
    const doc = try parse(alloc, md, "test.md");
    defer freeDocument(alloc, doc);

    try std.testing.expectEqual(@as(usize, 3), doc.sections.len);
    try std.testing.expectEqualStrings("Title", doc.sections[0].heading.?);
    try std.testing.expectEqual(@as(u8, 1), doc.sections[0].level);
    try std.testing.expectEqualStrings("Section A", doc.sections[1].heading.?);
    try std.testing.expectEqual(@as(u8, 2), doc.sections[1].level);
}
```

Add `freeDocument` stub and register in `all_tests.zig`:

```zig
// all_tests.zig
test {
    _ = @import("core/document.zig");
    _ = @import("core/parser_md.zig");
}
```

- [ ] **Step 2: Run test, confirm it fails**

```bash
nix develop -c zig build test
```

Expected: FAIL — hits `unreachable`.

- [ ] **Step 3: Implement markdown parser**

Replace the `parse` function body. The parser:
1. Splits input on newlines
2. Detects heading lines (`#` prefix), counts level
3. Groups content under headings into sections
4. Handles nested headings (## under # becomes child)

```zig
pub fn parse(allocator: std.mem.Allocator, content: []const u8, path: []const u8) !document.Document {
    var sections = std.ArrayList(document.Section).init(allocator);
    // ... line-by-line parsing, heading detection, section building
    // See implementation for full code
    return .{
        .path = path,
        .format = .md,
        .title = title,
        .metadata = &.{},
        .sections = sections.toOwnedSlice(),
    };
}

pub fn freeDocument(allocator: std.mem.Allocator, doc: document.Document) void {
    // Free all allocated sections recursively
    freeSections(allocator, doc.sections);
    allocator.free(doc.sections);
}
```

Full implementation: parse line by line, track heading stack for nesting, accumulate content between headings into section content.

- [ ] **Step 4: Run test, confirm it passes**

```bash
nix develop -c zig build test
```

Expected: PASS.

- [ ] **Step 5: Write additional edge-case tests**

```zig
test "md: nested headings become children" {
    const alloc = std.testing.allocator;
    const md =
        \\# Top
        \\
        \\## Sub
        \\
        \\### SubSub
        \\
        \\Deep content.
    ;
    const doc = try parse(alloc, md, "test.md");
    defer freeDocument(alloc, doc);

    try std.testing.expectEqual(@as(usize, 1), doc.sections.len);
    try std.testing.expectEqual(@as(usize, 1), doc.sections[0].children.len);
    try std.testing.expectEqual(@as(usize, 1), doc.sections[0].children[0].children.len);
    try std.testing.expectEqualStrings("Deep content.", doc.sections[0].children[0].children[0].content);
}

test "md: no headings — single root section" {
    const alloc = std.testing.allocator;
    const doc = try parse(alloc, "Just plain text.\nNo headings.", "test.md");
    defer freeDocument(alloc, doc);

    try std.testing.expectEqual(@as(usize, 1), doc.sections.len);
    try std.testing.expectEqual(@as(?[]const u8, null), doc.sections[0].heading);
}

test "md: empty document" {
    const alloc = std.testing.allocator;
    const doc = try parse(alloc, "", "test.md");
    defer freeDocument(alloc, doc);
    try std.testing.expectEqual(@as(usize, 0), doc.sections.len);
}

test "md: heading with no content" {
    const alloc = std.testing.allocator;
    const md =
        \\# Empty Section
        \\
        \\# Next Section
        \\
        \\Has content.
    ;
    const doc = try parse(alloc, md, "test.md");
    defer freeDocument(alloc, doc);
    try std.testing.expectEqual(@as(usize, 2), doc.sections.len);
    try std.testing.expectEqualStrings("", doc.sections[0].content);
}
```

- [ ] **Step 6: Run all tests, confirm they pass**

```bash
nix develop -c zig build test
```

- [ ] **Step 7: Commit**

```bash
git add src/core/parser_md.zig src/all_tests.zig
git commit -m "feat: markdown parser with heading-based section extraction"
```

---

## Task 3: XML Parser for DOCX

DOCX files contain `word/document.xml`. We need a minimal XML parser to extract text runs and paragraph styles. This is a prerequisite for the DOCX parser.

**Files:**
- Create: `src/core/xml.zig`
- Modify: `src/all_tests.zig`

- [ ] **Step 1: Write failing test — parse XML elements and text**

```zig
test "xml: basic element with text" {
    const alloc = std.testing.allocator;
    const input = "<root><child>hello</child></root>";
    const doc = try parse(alloc, input);
    defer freeXmlDoc(alloc, doc);

    try std.testing.expectEqualStrings("root", doc.root.?.tag);
    try std.testing.expectEqual(@as(usize, 1), doc.root.?.children.len);
    try std.testing.expectEqualStrings("hello", doc.root.?.children[0].text.?);
}
```

- [ ] **Step 2: Run test, confirm it fails**

- [ ] **Step 3: Implement minimal XML parser**

We need just enough to handle DOCX XML: elements, attributes, text content, namespaced tags (w:p, w:r, w:t, w:pStyle). No DTD, no CDATA, no processing instructions — DOCX doesn't use them in document.xml.

Key types:
```zig
pub const XmlNode = struct {
    tag: []const u8,
    attributes: []const Attribute,
    children: []const XmlNode,
    text: ?[]const u8,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const XmlDoc = struct {
    root: ?XmlNode,
};
```

- [ ] **Step 4: Run test, confirm it passes**

- [ ] **Step 5: Add tests for attributes and namespaced tags**

```zig
test "xml: attributes" {
    const alloc = std.testing.allocator;
    const input = "<w:pStyle w:val=\"Heading1\"/>";
    const doc = try parse(alloc, input);
    defer freeXmlDoc(alloc, doc);

    const root = doc.root.?;
    try std.testing.expectEqualStrings("w:pStyle", root.tag);
    try std.testing.expectEqualStrings("Heading1", root.getAttr("w:val").?);
}

test "xml: nested elements with mixed content" {
    const alloc = std.testing.allocator;
    const input =
        \\<w:p>
        \\  <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
        \\  <w:r><w:t>Hello</w:t></w:r>
        \\  <w:r><w:t xml:space="preserve"> World</w:t></w:r>
        \\</w:p>
    ;
    const doc = try parse(alloc, input);
    defer freeXmlDoc(alloc, doc);

    const p = doc.root.?;
    try std.testing.expectEqualStrings("w:p", p.tag);
    try std.testing.expectEqual(@as(usize, 3), p.children.len);
}
```

- [ ] **Step 6: Run all tests, confirm they pass**

- [ ] **Step 7: Commit**

```bash
git add src/core/xml.zig src/all_tests.zig
git commit -m "feat: minimal XML parser for DOCX document.xml extraction"
```

---

## Task 4: DOCX Parser

Fork validate's ZIP handling, add XML-based text extraction.

**Files:**
- Create: `src/core/parser_docx.zig`
- Create: `src/core/zip.zig` (forked from validate's archive handling)
- Create: `tests/unit/fixtures/` (test .docx files)
- Modify: `src/all_tests.zig`

**Reference:** validate's `src/core/archive_validators.zig` for ZIP parsing. The XML parser from Task 3 handles `word/document.xml`.

- [ ] **Step 1: Create a minimal test .docx fixture**

A .docx is a ZIP containing XML. Create a minimal fixture programmatically in the test:

```zig
test "docx: extract text from simple document" {
    const alloc = std.testing.allocator;
    // Read fixture from tests/unit/fixtures/simple.docx
    // (Created manually: a .docx with "Hello World" as Heading 1 and "Body text." as Normal)
    const content = @embedFile("../../tests/unit/fixtures/simple.docx");
    const doc = try parse(alloc, content, "simple.docx");
    defer freeDocument(alloc, doc);

    try std.testing.expect(doc.sections.len >= 1);
    // The heading "Hello World" should be extracted
    try std.testing.expectEqualStrings("Hello World", doc.sections[0].heading.?);
    try std.testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Body text.") != null);
}
```

Create the fixture .docx by hand (or with a script) — it's a ZIP with:
- `[Content_Types].xml`
- `word/document.xml` containing `<w:p>` with `Heading1` style and text runs

- [ ] **Step 2: Run test, confirm it fails**

- [ ] **Step 3: Implement ZIP extractor**

Fork validate's ZIP central directory parsing from `archive_validators.zig`. We only need:
- Find end-of-central-directory record
- Parse central directory entries
- Extract file entries by name (decompress with stored/deflate)

```zig
// src/core/zip.zig
pub const ZipEntry = struct {
    name: []const u8,
    data: []const u8,    // decompressed content
};

pub fn extractEntry(allocator: std.mem.Allocator, archive: []const u8, name: []const u8) !?ZipEntry {
    // Parse EOCD, find central directory, locate entry by name, decompress
}
```

- [ ] **Step 4: Implement DOCX parser**

```zig
// src/core/parser_docx.zig
pub fn parse(allocator: std.mem.Allocator, content: []const u8, path: []const u8) !document.Document {
    // 1. Extract word/document.xml from ZIP
    const doc_xml = try zip.extractEntry(allocator, content, "word/document.xml") orelse
        return error.InvalidDocx;

    // 2. Parse XML
    const xml_doc = try xml.parse(allocator, doc_xml.data);

    // 3. Walk <w:body> children
    //    For each <w:p>:
    //      - Check <w:pPr>/<w:pStyle> for heading level
    //      - Extract text from <w:r>/<w:t> runs
    //      - Build Section tree based on heading hierarchy
}
```

Heading detection: map DOCX styles to levels:
- `Heading1` → level 1, `Heading2` → level 2, etc.
- `Title` → level 0
- Everything else → body content of current section

- [ ] **Step 5: Run test, confirm it passes**

- [ ] **Step 6: Add edge-case tests**

```zig
test "docx: multiple headings with nesting" { ... }
test "docx: document with no headings — single section" { ... }
test "docx: empty document" { ... }
test "docx: document with tables — text extracted from cells" { ... }
test "docx: unicode content" { ... }
test "docx: metadata extraction (title, author from core.xml)" { ... }
```

For metadata, also extract `docProps/core.xml` from the ZIP (dc:title, dc:creator, dcterms:created).

- [ ] **Step 7: Run all tests, confirm they pass**

- [ ] **Step 8: Commit**

```bash
git add src/core/parser_docx.zig src/core/zip.zig tests/unit/fixtures/ src/all_tests.zig
git commit -m "feat: DOCX parser with heading-aware text extraction"
```

---

## Task 5: PDF Parser

Fork validate's PDF infrastructure, add content stream text extraction.

**Files:**
- Create: `src/core/parser_pdf.zig`
- Create: `src/core/pdf_objects.zig` (PDF object graph, xref, streams)
- Create: `tests/unit/fixtures/simple.pdf` (hand-crafted minimal PDF)
- Modify: `src/all_tests.zig`

**Reference:**
- validate's `src/core/pdf_validator.zig` for xref/object parsing
- validate's `src/core/pdf_xref_parser.zig` for `XrefTable`, `XrefEntry`, `TrailerInfo`

This is the most complex parser. PDF has no semantic structure — we infer headings from font size/bold heuristics.

- [ ] **Step 1: Write failing test — extract text from simple PDF**

```zig
test "pdf: extract text from single-page PDF" {
    const alloc = std.testing.allocator;
    const content = @embedFile("../../tests/unit/fixtures/simple.pdf");
    const doc = try parse(alloc, content, "simple.pdf");
    defer freeDocument(alloc, doc);

    try std.testing.expect(doc.sections.len >= 1);
    // simple.pdf contains "Hello World" in large font and "Body text here." in normal font
    try std.testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Hello World") != null);
}
```

Create `tests/unit/fixtures/simple.pdf` — a hand-crafted minimal valid PDF with known text content.

- [ ] **Step 2: Run test, confirm it fails**

- [ ] **Step 3: Implement PDF object graph parser**

Fork from validate. We need:
- `findStartxref()` → find xref offset
- `parseXref()` → build xref table (maps object numbers to file offsets)
- `parseTrailer()` → find /Root (catalog) object
- Object dereferencing: given an object number, seek to offset, parse the object
- Stream decompression: handle FlateDecode (deflate) for content streams

```zig
// src/core/pdf_objects.zig
pub const XrefEntry = struct {
    offset: u64,
    gen: u16,
    in_use: bool,
};

pub const PdfContext = struct {
    data: []const u8,
    xref: std.AutoHashMap(u32, XrefEntry),
    allocator: std.mem.Allocator,

    pub fn derefObject(self: *PdfContext, obj_num: u32) !PdfObject { ... }
    pub fn decompressStream(self: *PdfContext, stream_obj: PdfObject) ![]const u8 { ... }
};
```

- [ ] **Step 4: Implement content stream text extraction**

PDF text operators:
- `Tj` — show string: `(Hello World) Tj`
- `TJ` — show array: `[(Hel) -10 (lo)] TJ` (with kerning adjustments)
- `Tf` — set font and size: `/F1 24 Tf`
- `Td`, `TD` — move text position
- `Tm` — set text matrix (includes position + scale)
- `BT`/`ET` — begin/end text object

```zig
// src/core/parser_pdf.zig
const TextSpan = struct {
    text: []const u8,
    font_size: f32,
    is_bold: bool,
    page: u32,
    y_position: f32,  // for ordering
};

fn extractTextFromContentStream(allocator: std.mem.Allocator, stream: []const u8) ![]TextSpan {
    // Parse PDF operators, track font state, extract text with metadata
}
```

- [ ] **Step 5: Implement heading heuristic**

```zig
fn inferStructure(allocator: std.mem.Allocator, spans: []const TextSpan) ![]document.Section {
    // 1. Find the dominant (most common) font size — this is "body" text
    // 2. Spans significantly larger than body size → heading candidates
    // 3. Bold spans at body size or larger → also heading candidates
    // 4. Group: heading span starts new section, body spans are content
    // 5. Heading level derived from relative font size (largest = 1, etc.)
}
```

- [ ] **Step 6: Run tests, confirm they pass**

- [ ] **Step 7: Add edge-case tests**

```zig
test "pdf: multi-page document" { ... }
test "pdf: no discernible headings — single section" { ... }
test "pdf: encrypted PDF returns error" { ... }  // we don't decrypt
test "pdf: PDF with only images (no text) — empty sections" { ... }
test "pdf: text extraction preserves reading order (top-to-bottom, left-to-right)" { ... }
test "pdf: FlateDecode compressed content stream" { ... }
```

- [ ] **Step 8: Run all tests**

- [ ] **Step 9: Commit**

```bash
git add src/core/parser_pdf.zig src/core/pdf_objects.zig tests/unit/fixtures/ src/all_tests.zig
git commit -m "feat: PDF parser with content stream text extraction and heading heuristics"
```

---

## Task 6: DOC (Legacy Word) Parser

Fork validate's OLE2 and Word document parsing, add Piece Table text extraction.

**Files:**
- Create: `src/core/parser_doc.zig`
- Create: `src/core/ole2.zig` (OLE2 container, forked from validate)
- Create: `tests/unit/fixtures/simple.doc`
- Modify: `src/all_tests.zig`

**Reference:**
- validate's `src/core/ole2_validator.zig` — `Ole2Header`, FAT chains, `readNamedStream()`
- validate's `src/core/word_doc_validator.zig` — `FibBase`, `FibRgLw97`, Piece Table

- [ ] **Step 1: Write failing test**

```zig
test "doc: extract text from Word 97 document" {
    const alloc = std.testing.allocator;
    const content = @embedFile("../../tests/unit/fixtures/simple.doc");
    const doc = try parse(alloc, content, "simple.doc");
    defer freeDocument(alloc, doc);

    try std.testing.expect(doc.sections.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Hello World") != null);
}
```

- [ ] **Step 2: Run test, confirm it fails**

- [ ] **Step 3: Implement OLE2 container reader**

Fork from validate's `ole2_validator.zig`:

```zig
// src/core/ole2.zig
pub const Ole2Header = struct {
    sector_size: u32,
    mini_sector_size: u32,
    fat_sectors: []const u32,
    mini_fat_start: u32,
    dir_start: u32,
    mini_stream_cutoff: u32,
};

pub fn parseHeader(data: []const u8) !Ole2Header { ... }

pub fn readStream(allocator: std.mem.Allocator, data: []const u8, header: Ole2Header, stream_name: []const u8) ![]const u8 {
    // Walk directory entries, find named stream, follow FAT chain, concatenate sectors
}
```

- [ ] **Step 4: Implement DOC text extraction**

```zig
// src/core/parser_doc.zig
pub fn parse(allocator: std.mem.Allocator, content: []const u8, path: []const u8) !document.Document {
    // 1. Parse OLE2 header
    const header = try ole2.parseHeader(content);

    // 2. Read "WordDocument" stream
    const word_stream = try ole2.readStream(allocator, content, header, "WordDocument");

    // 3. Parse FIB (File Information Block) — first 68+ bytes
    const fib = parseFib(word_stream);

    // 4. Determine Table stream name (0Table or 1Table based on fib.flags)
    const table_name = if (fib.fWhichTblStm) "1Table" else "0Table";
    const table_stream = try ole2.readStream(allocator, content, header, table_name);

    // 5. Parse CLX (Complex List) from Table stream at fib.fcClx
    //    Extract Piece Table → array of (fc, encoding) pairs
    //    For each piece: read text from WordDocument at fc offset
    //    Handle FcCompressed flag (1 byte per char vs 2 bytes UTF-16)

    // 6. Parse character properties to detect heading styles
    //    Use STSH (Stylesheet Hierarchy) from Table stream

    // 7. Build Document with heading-based sections
}
```

- [ ] **Step 5: Run test, confirm it passes**

- [ ] **Step 6: Add edge-case tests**

```zig
test "doc: Word 6/95 format — fallback to structural only" { ... }
test "doc: document with styles — heading detection" { ... }
test "doc: empty document" { ... }
test "doc: compressed text pieces (FcCompressed)" { ... }
test "doc: unicode text in uncompressed pieces" { ... }
```

- [ ] **Step 7: Run all tests**

- [ ] **Step 8: Commit**

```bash
git add src/core/parser_doc.zig src/core/ole2.zig tests/unit/fixtures/ src/all_tests.zig
git commit -m "feat: DOC (Word 97) parser with OLE2/Piece Table text extraction"
```

---

## Task 7: Structure-Aware Chunker

**Files:**
- Create: `src/core/chunker.zig`
- Modify: `src/all_tests.zig`

- [ ] **Step 1: Write failing tests**

```zig
test "chunker: leaf sections become chunks" {
    const alloc = std.testing.allocator;
    const doc = document.Document{
        .path = "test.md",
        .format = .md,
        .title = "Test",
        .metadata = &.{},
        .sections = &.{
            .{ .heading = "Section A", .level = 1, .content = "Content A.", .children = &.{} },
            .{ .heading = "Section B", .level = 1, .content = "Content B.", .children = &.{} },
        },
    };
    const chunks = try chunk(alloc, doc, .{});
    defer freeChunks(alloc, chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqualStrings("Content A.", chunks[0].text);
    try std.testing.expectEqualStrings("Section A", chunks[0].section_path);
    try std.testing.expectEqualStrings("Content B.", chunks[1].text);
}

test "chunker: large section splits at paragraph boundaries" {
    // Create section with content > max_chunk_tokens
    // Assert it splits into multiple chunks, each preserving section_path
}

test "chunker: small adjacent sections merge" {
    // Create 3 sibling sections each under 100 tokens
    // Assert they merge into fewer chunks
}

test "chunker: nested sections produce breadcrumb paths" {
    // Section 1 > Sub A > Sub Sub X
    // Assert chunk.section_path = "Section 1 > Sub A > Sub Sub X"
}
```

- [ ] **Step 2: Run tests, confirm they fail**

- [ ] **Step 3: Implement chunker**

```zig
// src/core/chunker.zig
pub const ChunkOptions = struct {
    max_chunk_tokens: usize = 1500,
    min_chunk_tokens: usize = 100,
    /// Approximate tokens-per-byte ratio for estimation (avoid tokenizer dependency)
    tokens_per_byte: f32 = 0.25,
};

pub fn chunk(allocator: std.mem.Allocator, doc: document.Document, options: ChunkOptions) ![]document.Chunk {
    var chunks = std.ArrayList(document.Chunk).init(allocator);
    var byte_offset: u64 = 0;

    for (doc.sections) |section| {
        try chunkSection(allocator, &chunks, section, "", &byte_offset, options);
    }

    return chunks.toOwnedSlice();
}

fn chunkSection(
    allocator: std.mem.Allocator,
    chunks: *std.ArrayList(document.Chunk),
    section: document.Section,
    parent_path: []const u8,
    byte_offset: *u64,
    options: ChunkOptions,
) !void {
    const path = buildBreadcrumb(allocator, parent_path, section.heading);

    if (section.children.len > 0) {
        // Recurse into children — this section's content is preamble
        if (section.content.len > 0) {
            try emitChunk(chunks, section, path, byte_offset);
        }
        for (section.children) |child| {
            try chunkSection(allocator, chunks, child, path, byte_offset, options);
        }
    } else {
        // Leaf section — emit as chunk(s)
        const est_tokens = estimateTokens(section.content, options.tokens_per_byte);
        if (est_tokens > options.max_chunk_tokens) {
            try splitAtParagraphs(allocator, chunks, section, path, byte_offset, options);
        } else {
            try emitChunk(chunks, section, path, byte_offset);
        }
    }
}
```

- [ ] **Step 4: Run tests, confirm they pass**

- [ ] **Step 5: Add merge logic for small sections**

```zig
/// Post-pass: merge adjacent chunks from sibling sections if both are under min_chunk_tokens
pub fn mergeSmallChunks(allocator: std.mem.Allocator, chunks: []document.Chunk, options: ChunkOptions) ![]document.Chunk {
    // Walk chunks, merge consecutive small ones that share the same parent path
}
```

Add test, run, confirm pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/chunker.zig src/all_tests.zig
git commit -m "feat: structure-aware chunker with paragraph splitting and small-section merging"
```

---

## Task 8: Storage Layer

SQLite + sqlite-vec + FTS5 integration.

**Files:**
- Create: `src/core/storage.zig`
- Modify: `src/all_tests.zig`

**Reference:** codescan's `src/storage.zig` — same pattern: `@cImport` sqlite3, sqlite-vec static, WAL mode.

- [ ] **Step 1: Write failing test — init and round-trip**

```zig
test "storage: init schema and insert document" {
    const alloc = std.testing.allocator;

    // In-memory SQLite for testing
    var db = try openDb(alloc, ":memory:", 768);  // 768 = nomic-embed-text dims
    defer closeDb(db);

    const doc_id = try insertDocument(db, .{
        .path = "test.md",
        .format = "md",
        .title = "Test Doc",
        .content_hash = "abc123",
        .metadata = null,
    });

    try std.testing.expect(doc_id > 0);

    const retrieved = try getDocument(db, "test.md");
    try std.testing.expectEqualStrings("Test Doc", retrieved.?.title.?);
}
```

- [ ] **Step 2: Run test, confirm it fails**

- [ ] **Step 3: Implement storage init + document CRUD**

```zig
// src/core/storage.zig
const c = @cImport({
    @cDefine("SQLITE_VEC_STATIC", "1");
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

pub const Db = struct {
    handle: *c.sqlite3,
    embedding_dim: u32,
};

pub fn openDb(allocator: std.mem.Allocator, path: [*:0]const u8, embedding_dim: u32) !Db {
    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path, &handle) != c.SQLITE_OK) return error.SqliteOpen;

    // Register sqlite-vec extension
    var err_msg: [*c]u8 = null;
    if (c.sqlite3_vec_init(handle, &err_msg) != c.SQLITE_OK) return error.SqliteVecInit;

    // WAL mode
    _ = try exec(handle, "PRAGMA journal_mode=WAL;");

    // Create tables
    try createSchema(handle, embedding_dim);

    return .{ .handle = handle.?, .embedding_dim = embedding_dim };
}

fn createSchema(handle: *c.sqlite3, dim: u32) !void {
    try exec(handle,
        \\CREATE TABLE IF NOT EXISTS config (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS documents (
        \\    id INTEGER PRIMARY KEY,
        \\    path TEXT UNIQUE NOT NULL,
        \\    format TEXT NOT NULL,
        \\    title TEXT,
        \\    content_hash TEXT NOT NULL,
        \\    metadata TEXT,
        \\    indexed_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS chunks (
        \\    id INTEGER PRIMARY KEY,
        \\    document_id INTEGER NOT NULL REFERENCES documents(id),
        \\    chunk_index INTEGER NOT NULL,
        \\    section_path TEXT,
        \\    heading TEXT,
        \\    text TEXT NOT NULL,
        \\    start_byte INTEGER NOT NULL,
        \\    end_byte INTEGER NOT NULL
        \\);
    );

    // sqlite-vec virtual table (dimension is runtime param)
    const vec_sql = try std.fmt.allocPrintZ(allocator,
        "CREATE VIRTUAL TABLE IF NOT EXISTS chunk_embeddings USING vec0(chunk_id INTEGER PRIMARY KEY, embedding float[{d}]);",
        .{dim},
    );
    try exec(handle, vec_sql);

    // FTS5 virtual table
    try exec(handle,
        \\CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        \\    chunk_id,
        \\    text,
        \\    heading,
        \\    section_path
        \\);
    );
}
```

- [ ] **Step 4: Run test, confirm it passes**

- [ ] **Step 5: Add chunk + embedding insert/query tests**

```zig
test "storage: insert and query chunks" {
    // Insert document, insert chunks, query by document_id
}

test "storage: insert and query embeddings" {
    // Insert chunk, insert embedding vector, query via KNN
}

test "storage: FTS5 text search" {
    // Insert chunks with known text, query via FTS5 MATCH, verify BM25 ranking
}

test "storage: hash-based skip on re-index" {
    // Insert document with hash "abc", call insertDocument again with same hash
    // Assert it returns existing doc_id without re-inserting
}

test "storage: hash-based update replaces chunks" {
    // Insert document + chunks, then re-insert with different hash
    // Assert old chunks are deleted and new ones inserted
}
```

- [ ] **Step 6: Run all tests**

- [ ] **Step 7: Commit**

```bash
git add src/core/storage.zig src/all_tests.zig
git commit -m "feat: SQLite + sqlite-vec + FTS5 storage layer"
```

---

## Task 9: Search Engine

Hybrid vector + BM25 with RRF fusion.

**Files:**
- Create: `src/core/search.zig`
- Modify: `src/all_tests.zig`

**Reference:** codescan's `src/search.zig` — RRF fusion at lines 278-288, vector candidates via `vec0 KNN MATCH`.

- [ ] **Step 1: Write failing tests**

```zig
test "search: exact mode returns FTS5 matches" {
    const alloc = std.testing.allocator;
    var db = try storage.openDb(alloc, ":memory:", 768);
    defer storage.closeDb(db);

    // Insert test corpus: 3 documents, multiple chunks
    try insertTestCorpus(db);

    const results = try search(alloc, db, "indemnification", .{ .mode = .exact });
    defer freeResults(alloc, results);

    try std.testing.expect(results.len > 0);
    // The chunk containing "indemnification" should rank first
    try std.testing.expect(std.mem.indexOf(u8, results[0].text, "indemnification") != null);
}

test "search: vector mode returns semantic matches" {
    // Pre-computed embeddings for test corpus
    // Query embedding for "liability protection"
    // Assert chunks about indemnification rank high (semantically related)
}

test "search: hybrid mode fuses vector and lexical" {
    // Assert hybrid results contain entries from both vector and lexical
}

test "search: RRF fusion ranking" {
    // Known vector ranks and lexical ranks → verify fused order
    const fused = computeRRF(&vector_ranks, &lexical_ranks, 60, 0.7, 0.3);
    // Assert expected ordering
}

test "search: similar mode" {
    // Given a chunk's embedding, find similar chunks
}

test "search: limit parameter" {
    // Insert many chunks, search with limit=3, assert exactly 3 results
}
```

- [ ] **Step 2: Run tests, confirm they fail**

- [ ] **Step 3: Implement search modes**

```zig
// src/core/search.zig
pub const SearchMode = enum { hybrid, exact, similar };

pub const SearchOptions = struct {
    mode: SearchMode = .hybrid,
    limit: usize = 10,
    weight_vector: f32 = 0.7,
    weight_lexical: f32 = 0.3,
    rrf_k: f32 = 60,
    format_filter: ?[]const u8 = null,  // e.g., "pdf" to search only PDFs
};

pub fn search(
    allocator: std.mem.Allocator,
    db: storage.Db,
    query_embedding: ?[]const f32,  // null for exact mode
    query_text: []const u8,
    options: SearchOptions,
) ![]document.SearchResult {
    switch (options.mode) {
        .exact => return ftsSearch(allocator, db, query_text, options),
        .hybrid => {
            const vec_results = try vectorSearch(allocator, db, query_embedding.?, options);
            const lex_results = try ftsSearch(allocator, db, query_text, options);
            return rrfFusion(allocator, vec_results, lex_results, options);
        },
        .similar => return vectorSearch(allocator, db, query_embedding.?, options),
    }
}

fn vectorSearch(allocator: std.mem.Allocator, db: storage.Db, embedding: []const f32, options: SearchOptions) ![]document.SearchResult {
    // SELECT chunk_id, distance FROM chunk_embeddings WHERE embedding MATCH ?1 AND k = ?2
    // Join with chunks and documents tables for full result
}

fn ftsSearch(allocator: std.mem.Allocator, db: storage.Db, query: []const u8, options: SearchOptions) ![]document.SearchResult {
    // SELECT chunk_id, bm25(chunks_fts) as score FROM chunks_fts WHERE chunks_fts MATCH ?1
    // Join with chunks and documents
}

fn rrfFusion(
    allocator: std.mem.Allocator,
    vec_results: []document.SearchResult,
    lex_results: []document.SearchResult,
    options: SearchOptions,
) ![]document.SearchResult {
    // For each result, compute:
    //   score = (weight_vector / (k + vec_rank)) + (weight_lexical / (k + lex_rank))
    // Sort by fused score descending
    // Return top options.limit
}
```

- [ ] **Step 4: Run tests, confirm they pass**

- [ ] **Step 5: Commit**

```bash
git add src/core/search.zig src/all_tests.zig
git commit -m "feat: hybrid search engine with vector, FTS5, and RRF fusion"
```

---

## Task 10: C FFI Boundary

Expose the Zig core to C with a flat API using opaque handles.

**Files:**
- Modify: `src/ffi/c_api.zig`
- Modify: `ffi/docscan_core.h`

- [ ] **Step 1: Define the C API header**

```c
// ffi/docscan_core.h
#ifndef DOCSCAN_CORE_H
#define DOCSCAN_CORE_H

#include <stddef.h>
#include <stdint.h>

// Opaque handle to the docscan index database
typedef struct docscan_db docscan_db;

// Version
const char* docscan_version(void);

// Database lifecycle
// Returns NULL on error; error message written to err_buf if non-NULL
docscan_db* docscan_open(const char* db_path, uint32_t embedding_dim, char* err_buf, size_t err_buf_len);
void docscan_close(docscan_db* db);

// Parse a document from raw bytes, returns JSON string with extracted structure
// Caller must free returned string with docscan_free()
char* docscan_parse(const uint8_t* data, size_t len, const char* path, const char* format, char* err_buf, size_t err_buf_len);

// Chunk a parsed document, returns JSON array of chunks
// Caller must free with docscan_free()
char* docscan_chunk(const char* parsed_json, uint32_t max_chunk_tokens, char* err_buf, size_t err_buf_len);

// Index: store document + chunks + embeddings
// embeddings is a flat float array: num_chunks * embedding_dim floats
int docscan_index_document(
    docscan_db* db,
    const char* path,
    const char* format,
    const char* title,
    const char* content_hash,
    const char* metadata_json,
    const char* chunks_json,
    const float* embeddings,
    uint32_t num_chunks,
    char* err_buf, size_t err_buf_len
);

// Search
// Returns JSON array of SearchResults. Caller must free with docscan_free()
char* docscan_search(
    docscan_db* db,
    const char* query_text,
    const float* query_embedding,  // NULL for exact mode
    uint32_t embedding_len,
    const char* mode,  // "hybrid", "exact", "similar"
    uint32_t limit,
    const char* format_filter,  // NULL for no filter
    char* err_buf, size_t err_buf_len
);

// Status: returns JSON with doc_count, chunk_count, model, last_indexed
char* docscan_status(docscan_db* db, char* err_buf, size_t err_buf_len);

// Get a single chunk by ID, returns JSON. Caller must free with docscan_free()
char* docscan_read_chunk(docscan_db* db, int64_t chunk_id, char* err_buf, size_t err_buf_len);

// List indexed documents, returns JSON array. Caller must free with docscan_free()
char* docscan_list_documents(docscan_db* db, const char* glob_filter, char* err_buf, size_t err_buf_len);

// Check if document needs re-indexing (hash changed)
// Returns 1 if changed/new, 0 if unchanged, -1 on error
int docscan_needs_reindex(docscan_db* db, const char* path, const char* content_hash);

// Remove a document and its chunks/embeddings
int docscan_remove_document(docscan_db* db, const char* path, char* err_buf, size_t err_buf_len);

// Config get/set
char* docscan_config_get(docscan_db* db, const char* key, char* err_buf, size_t err_buf_len);
int docscan_config_set(docscan_db* db, const char* key, const char* value, char* err_buf, size_t err_buf_len);

// Free strings returned by docscan_* functions
void docscan_free(char* ptr);

#endif
```

- [ ] **Step 2: Implement the FFI in Zig**

```zig
// src/ffi/c_api.zig
const std = @import("std");
const core = @import("core");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

export fn docscan_version() [*:0]const u8 {
    return "0.1.0";
}

export fn docscan_open(
    db_path: [*:0]const u8,
    embedding_dim: u32,
    err_buf: ?[*]u8,
    err_buf_len: usize,
) ?*DocscanDb {
    const db = core.storage.openDb(allocator, db_path, embedding_dim) catch |e| {
        writeError(err_buf, err_buf_len, @errorName(e));
        return null;
    };
    const wrapper = allocator.create(DocscanDb) catch return null;
    wrapper.* = .{ .inner = db };
    return wrapper;
}

// ... implement each exported function, converting between C types and Zig types
// JSON serialization for structured results using std.json
```

- [ ] **Step 3: Write FFI round-trip tests in Zig**

```zig
test "ffi: open, index, search round-trip" {
    // Call through the C API functions, verify results
}
```

- [ ] **Step 4: Run tests, confirm they pass**

- [ ] **Step 5: Commit**

```bash
git add src/ffi/c_api.zig ffi/docscan_core.h src/all_tests.zig
git commit -m "feat: C FFI boundary with flat API and opaque handles"
```

---

## Task 11: C CLI

The I/O layer. Reads files, calls Ollama, dispatches to FFI.

**Files:**
- Modify: `cli/main.c`

- [ ] **Step 1: Implement argument parsing**

```c
// cli/main.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "docscan_core.h"

typedef enum {
    CMD_INDEX,
    CMD_UPDATE,
    CMD_SEARCH,
    CMD_STATUS,
    CMD_MCP_SERVE,
    CMD_CONFIG,
    CMD_HELP,
    CMD_ABOUT,
    CMD_UNKNOWN,
} Command;

typedef struct {
    Command cmd;
    const char* path;
    const char* query;
    const char* mode;        // "hybrid", "exact", "similar"
    const char* model;       // Ollama model name
    const char* db_path;
    const char* format_filter;
    const char* config_key;
    const char* config_value;
    const char* lang;
    int limit;
    int json_output;
    int no_color;
    int no_progress;
    int simple;
} Options;

static Options parse_args(int argc, char** argv) {
    Options opts = {
        .cmd = CMD_UNKNOWN,
        .limit = 10,
        .model = NULL,  // will fall back to env or default
        // ...
    };

    // Parse: docscan <command> [args...] [flags...]
    // Handle -h/--help, --about, --json, --limit, --model, --db,
    //        --no-color, --no-ansi, --no-progress, --simple, --lang,
    //        --exact, --similar
    // Environment variable fallbacks: DOCSCAN_MODEL, DOCSCAN_DB, DOCSCAN_LANG
}
```

- [ ] **Step 2: Implement `index` command**

```c
static int cmd_index(Options* opts) {
    // 1. Walk directory recursively (or single file)
    //    - Respect .docscanignore patterns
    //    - Filter by supported extensions (.md, .docx, .pdf, .doc)
    // 2. For each file:
    //    a. Read file bytes
    //    b. Compute blake3 hash (or use a C hash lib)
    //    c. Check docscan_needs_reindex()
    //    d. If needed:
    //       - Call docscan_parse() to extract structure
    //       - Call docscan_chunk() to split into chunks
    //       - Call Ollama API to embed each chunk
    //       - Call docscan_index_document() to store
    //    e. Show progress bar to stderr if interactive TTY
    // 3. Report summary: N documents indexed, M chunks, elapsed time
}
```

Ollama embedding call (HTTP POST to `http://localhost:11434/api/embed`):

```c
static float* embed_text(const char* text, const char* model, uint32_t* dim_out) {
    // Build JSON: {"model": "nomic-embed-text", "input": "text here"}
    // POST to http://localhost:11434/api/embed
    // Parse JSON response, extract "embeddings" array
    // Return flat float array
    // Use simple HTTP client (raw sockets or libcurl if available)
}
```

Note: For minimal dependencies, implement a simple HTTP client using POSIX sockets. Or use libcurl if Peter prefers — ask at implementation time.

- [ ] **Step 3: Implement `search` command**

```c
static int cmd_search(Options* opts) {
    // 1. Open database
    // 2. If mode != "exact":
    //    - Embed query text via Ollama
    // 3. Call docscan_search()
    // 4. Format output:
    //    - Default: colored, with file path, section breadcrumb, snippet
    //    - --json: raw JSON array
    //    - --simple: plain text, no ANSI
}
```

- [ ] **Step 4: Implement `update`, `status`, `config` commands**

```c
static int cmd_update(Options* opts) {
    // Same as index but only processes changed files (hash diff)
}

static int cmd_status(Options* opts) {
    // Call docscan_status(), format output
}

static int cmd_config(Options* opts) {
    // Get or set config values
}
```

- [ ] **Step 5: Implement `--about` and `--help`**

```c
static void print_about(void) {
    fprintf(stdout, "docscan %s %s/%s - document indexing and semantic search\n",
            docscan_version(), PLATFORM, ARCH);
}

static void print_help(void) {
    // Full usage text
}
```

Debug build detection early in main():

```c
int main(int argc, char** argv) {
    #ifdef DEBUG
    fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
    #endif
    // ...
}
```

- [ ] **Step 6: Implement progress indication**

```c
static void show_progress(int current, int total, double elapsed_sec) {
    if (!isatty(STDERR_FILENO)) return;
    // Draw progress bar to stderr:
    // [████████░░░░░░░░] 42/100 files | 3.2 files/sec | ETA 18s
}
```

- [ ] **Step 7: Verify the CLI builds and runs basic commands**

```bash
nix develop -c zig build
./zig-out/bin/docscan --help
./zig-out/bin/docscan --about
```

- [ ] **Step 8: Commit**

```bash
git add cli/main.c
git commit -m "feat: C CLI with index, search, update, status, config commands"
```

---

## Task 12: MCP Server

JSON-RPC 2.0 over stdio, thin layer dispatching to FFI.

**Files:**
- Modify: `cli/main.c` (add `mcp-serve` command implementation)
- Or create: `cli/mcp.c` if main.c is getting large

**Reference:** codescan's `src/mcp.zig` for the JSON-RPC protocol pattern.

- [ ] **Step 1: Implement JSON-RPC message loop**

```c
static int cmd_mcp_serve(Options* opts) {
    docscan_db* db = docscan_open(opts->db_path, embedding_dim, err_buf, sizeof(err_buf));
    if (!db) { fprintf(stderr, "Failed to open db: %s\n", err_buf); return 1; }

    char line[1024 * 1024];  // 1MB line buffer
    while (fgets(line, sizeof(line), stdin)) {
        // Parse JSON-RPC request: {"jsonrpc":"2.0","method":"...","id":...,"params":{...}}
        // Dispatch based on method:
        //   "initialize" → return capabilities
        //   "tools/list" → return tool definitions
        //   "tools/call" → dispatch to tool handler
        // Write JSON-RPC response to stdout, one line, flush
    }

    docscan_close(db);
    return 0;
}
```

- [ ] **Step 2: Implement tool definitions**

```c
static const char* tools_list_json =
    "[{\"name\":\"docscan_search\",\"description\":\"Search indexed documents\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"query\":{\"type\":\"string\",\"description\":\"Search query\"},"
    "\"mode\":{\"type\":\"string\",\"enum\":[\"hybrid\",\"exact\",\"similar\"],\"default\":\"hybrid\"},"
    "\"limit\":{\"type\":\"integer\",\"default\":10},"
    "\"format_filter\":{\"type\":\"string\",\"description\":\"Filter by format (md, docx, pdf, doc)\"}"
    "},\"required\":[\"query\"]}},"
    // ... docscan_index, docscan_update, docscan_status, docscan_read_chunk,
    //     docscan_list_docs, docscan_config
    "]";
```

- [ ] **Step 3: Implement tool dispatch**

```c
static char* handle_tool_call(docscan_db* db, const char* tool_name, /* parsed params */) {
    if (strcmp(tool_name, "docscan_search") == 0) {
        // Extract query, mode, limit, format_filter from params
        // If mode != "exact": embed query via Ollama
        // Call docscan_search()
        // Return result as JSON content block
    } else if (strcmp(tool_name, "docscan_index") == 0) {
        // ... same pattern as CLI index but returns JSON result
    }
    // ...
}
```

- [ ] **Step 4: Commit**

```bash
git add cli/main.c  # or cli/mcp.c
git commit -m "feat: MCP server over stdio with JSON-RPC 2.0"
```

---

## Task 13: CLI Tests (Bash)

Black-box tests against the compiled binary.

**Files:**
- Create: `tests/cli/test-cli`
- Create: `tests/cli/fixtures/` (test documents)

- [ ] **Step 1: Set up test harness**

```bash
#!/usr/bin/env bash
# tests/cli/test-cli
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BINARY="$ROOT_DIR/zig-out/bin/docscan"
FIXTURES="$SCRIPT_DIR/fixtures"
TMPDIR="${TMPDIR:-/tmp}"
TEST_DIR="$TMPDIR/docscan-cli-test-$$"

source "$HOME/dotfiles/bin/src/capture.bash"

errors=0
tests=0
pass() { ((tests++)); echo "  PASS: $1"; }
fail() { ((tests++)); ((errors++)); echo "  FAIL: $1"; }

mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Create test fixtures
mkdir -p "$FIXTURES"
cat > "$TEST_DIR/test.md" << 'MDEOF'
# Contract Overview

This is a test contract.

## Indemnification

The party shall indemnify...

## Governing Law

This agreement shall be governed by the laws of New York.
MDEOF
```

- [ ] **Step 2: Write tests for each command**

```bash
echo "=== CLI Tests ==="

# --help
capture "$BINARY" --help
[ "$CAPTURE_EXIT" -eq 0 ] && pass "--help exits 0" || fail "--help exits 0"
echo "$CAPTURE_STDOUT" | grep -q "Usage:" && pass "--help shows usage" || fail "--help shows usage"

# --about
capture "$BINARY" --about
[ "$CAPTURE_EXIT" -eq 0 ] && pass "--about exits 0" || fail "--about exits 0"
echo "$CAPTURE_STDOUT" | grep -q "docscan" && pass "--about shows name" || fail "--about shows name"

# index
capture "$BINARY" index "$TEST_DIR" --db "$TEST_DIR/test.db"
[ "$CAPTURE_EXIT" -eq 0 ] && pass "index exits 0" || fail "index exits 0"

# status
capture "$BINARY" status --db "$TEST_DIR/test.db"
[ "$CAPTURE_EXIT" -eq 0 ] && pass "status exits 0" || fail "status exits 0"

# status --json
capture "$BINARY" status --db "$TEST_DIR/test.db" --json
echo "$CAPTURE_STDOUT" | jq . > /dev/null 2>&1 && pass "status --json is valid JSON" || fail "status --json is valid JSON"

# search
capture "$BINARY" search "indemnification" --db "$TEST_DIR/test.db"
[ "$CAPTURE_EXIT" -eq 0 ] && pass "search exits 0" || fail "search exits 0"
echo "$CAPTURE_STDOUT" | grep -qi "indemnif" && pass "search finds expected term" || fail "search finds expected term"

# search --exact
capture "$BINARY" search --exact "Governing Law" --db "$TEST_DIR/test.db"
echo "$CAPTURE_STDOUT" | grep -qi "governing" && pass "exact search works" || fail "exact search works"

# search --json
capture "$BINARY" search "indemnification" --db "$TEST_DIR/test.db" --json
echo "$CAPTURE_STDOUT" | jq . > /dev/null 2>&1 && pass "search --json valid" || fail "search --json valid"

# search --limit
capture "$BINARY" search "contract" --db "$TEST_DIR/test.db" --json --limit 1
count=$(echo "$CAPTURE_STDOUT" | jq 'length')
[ "$count" -le 1 ] && pass "search --limit caps results" || fail "search --limit caps results"

# path with spaces
mkdir -p "$TEST_DIR/path with spaces"
cp "$TEST_DIR/test.md" "$TEST_DIR/path with spaces/test.md"
capture "$BINARY" index "$TEST_DIR/path with spaces" --db "$TEST_DIR/spaces.db"
[ "$CAPTURE_EXIT" -eq 0 ] && pass "path with spaces works" || fail "path with spaces works"

# error: missing path
capture "$BINARY" index
[ "$CAPTURE_EXIT" -ne 0 ] && pass "missing path errors" || fail "missing path errors"

# error: unsupported format
echo "not a doc" > "$TEST_DIR/test.xyz"
capture "$BINARY" index "$TEST_DIR/test.xyz" --db "$TEST_DIR/xyz.db"
# Should either skip or error gracefully

# --no-color, --simple flags don't crash
capture "$BINARY" search "test" --db "$TEST_DIR/test.db" --no-color
[ "$CAPTURE_EXIT" -eq 0 ] && pass "--no-color works" || fail "--no-color works"

capture "$BINARY" search "test" --db "$TEST_DIR/test.db" --simple
[ "$CAPTURE_EXIT" -eq 0 ] && pass "--simple works" || fail "--simple works"
```

- [ ] **Step 3: Write stdin test**

```bash
# stdin via - or @stdin
cat "$TEST_DIR/test.md" | capture "$BINARY" index - --db "$TEST_DIR/stdin.db" --format md
[ "$CAPTURE_EXIT" -eq 0 ] && pass "stdin input works" || fail "stdin input works"
```

- [ ] **Step 4: Report results**

```bash
echo ""
echo "$tests tests, $((tests - errors)) passed, $errors failed"
exit "$errors"
```

- [ ] **Step 5: Make executable and run**

```bash
chmod +x tests/cli/test-cli
./test
```

- [ ] **Step 6: Commit**

```bash
git add tests/cli/
git commit -m "feat: CLI black-box test suite"
```

---

## Task 14: MCP Tests (Bash)

**Files:**
- Create: `tests/mcp/test-mcp`

- [ ] **Step 1: Write MCP test harness**

```bash
#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BINARY="$ROOT_DIR/zig-out/bin/docscan"
TMPDIR="${TMPDIR:-/tmp}"
TEST_DIR="$TMPDIR/docscan-mcp-test-$$"

source "$HOME/dotfiles/bin/src/capture.bash"

errors=0
tests=0
pass() { ((tests++)); echo "  PASS: $1"; }
fail() { ((tests++)); ((errors++)); echo "  FAIL: $1"; }

mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Index a test document first
cat > "$TEST_DIR/test.md" << 'EOF'
# Test Document
Some searchable content about contracts and legal matters.
EOF
"$BINARY" index "$TEST_DIR" --db "$TEST_DIR/test.db" 2>/dev/null

# Helper: send JSON-RPC request and capture response
mcp_call() {
    local request="$1"
    echo "$request" | "$BINARY" mcp-serve --db "$TEST_DIR/test.db" 2>/dev/null | head -1
}

echo "=== MCP Tests ==="

# Initialize
resp=$(mcp_call '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}')
echo "$resp" | jq -e '.result' > /dev/null 2>&1 && pass "initialize" || fail "initialize"

# Tools list
resp=$(mcp_call '{"jsonrpc":"2.0","method":"tools/list","id":2,"params":{}}')
echo "$resp" | jq -e '.result.tools' > /dev/null 2>&1 && pass "tools/list" || fail "tools/list"
tool_count=$(echo "$resp" | jq '.result.tools | length')
[ "$tool_count" -ge 5 ] && pass "has expected tools" || fail "has expected tools (got $tool_count)"

# Search tool
resp=$(mcp_call '{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"docscan_search","arguments":{"query":"contracts","mode":"exact"}}}')
echo "$resp" | jq -e '.result' > /dev/null 2>&1 && pass "search tool" || fail "search tool"

# Status tool
resp=$(mcp_call '{"jsonrpc":"2.0","method":"tools/call","id":4,"params":{"name":"docscan_status","arguments":{}}}')
echo "$resp" | jq -e '.result' > /dev/null 2>&1 && pass "status tool" || fail "status tool"

# List docs tool
resp=$(mcp_call '{"jsonrpc":"2.0","method":"tools/call","id":5,"params":{"name":"docscan_list_docs","arguments":{}}}')
echo "$resp" | jq -e '.result' > /dev/null 2>&1 && pass "list_docs tool" || fail "list_docs tool"

# Error: unknown tool
resp=$(mcp_call '{"jsonrpc":"2.0","method":"tools/call","id":6,"params":{"name":"nonexistent","arguments":{}}}')
echo "$resp" | jq -e '.error' > /dev/null 2>&1 && pass "unknown tool returns error" || fail "unknown tool returns error"

# Error: malformed JSON
resp=$(echo "not json" | "$BINARY" mcp-serve --db "$TEST_DIR/test.db" 2>/dev/null | head -1)
echo "$resp" | jq -e '.error' > /dev/null 2>&1 && pass "malformed JSON returns error" || fail "malformed JSON returns error"

echo ""
echo "$tests tests, $((tests - errors)) passed, $errors failed"
exit "$errors"
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x tests/mcp/test-mcp
./test
```

- [ ] **Step 3: Commit**

```bash
git add tests/mcp/
git commit -m "feat: MCP server test suite"
```

---

## Task 15: Integration Tests

Full pipeline with real Ollama embeddings. Run separately from the main test suite.

**Files:**
- Create: `tests/integration/test-integration`
- Create: `tests/integration/fixtures/` (real documents)

- [ ] **Step 1: Write integration test suite**

```bash
#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BINARY="$ROOT_DIR/zig-out/bin/docscan"
FIXTURES="$SCRIPT_DIR/fixtures"
TMPDIR="${TMPDIR:-/tmp}"
TEST_DIR="$TMPDIR/docscan-integration-test-$$"

source "$HOME/dotfiles/bin/src/capture.bash"

errors=0
tests=0
pass() { ((tests++)); echo "  PASS: $1"; }
fail() { ((tests++)); ((errors++)); echo "  FAIL: $1"; }

# Check Ollama is running
if ! curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "SKIP: Ollama is not running (required for integration tests)"
    exit 0
fi

mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Copy fixture documents
cp -r "$FIXTURES"/* "$TEST_DIR/"

echo "=== Integration Tests ==="

# Index the fixture corpus
capture "$BINARY" index "$TEST_DIR" --db "$TEST_DIR/index.db"
[ "$CAPTURE_EXIT" -eq 0 ] && pass "index corpus" || fail "index corpus"

# Semantic search: "liability protection" should find indemnification content
capture "$BINARY" search "liability protection" --db "$TEST_DIR/index.db" --json
[ "$CAPTURE_EXIT" -eq 0 ] && pass "semantic search runs" || fail "semantic search runs"
echo "$CAPTURE_STDOUT" | jq -e '.[0]' > /dev/null 2>&1 && pass "semantic search has results" || fail "semantic search has results"

# Exact search
capture "$BINARY" search --exact "governing law" --db "$TEST_DIR/index.db" --json
echo "$CAPTURE_STDOUT" | jq -e '.[0]' > /dev/null 2>&1 && pass "exact search has results" || fail "exact search has results"

# Update: modify a file, re-index, verify update
echo -e "\n## New Section\n\nAdded content about jurisdiction." >> "$TEST_DIR/contract.md"
capture "$BINARY" update --db "$TEST_DIR/index.db"
[ "$CAPTURE_EXIT" -eq 0 ] && pass "update runs" || fail "update runs"

# Search for newly added content
capture "$BINARY" search --exact "jurisdiction" --db "$TEST_DIR/index.db" --json
echo "$CAPTURE_STDOUT" | jq -e '.[0]' > /dev/null 2>&1 && pass "update indexed new content" || fail "update indexed new content"

# Status shows correct counts
capture "$BINARY" status --db "$TEST_DIR/index.db" --json
doc_count=$(echo "$CAPTURE_STDOUT" | jq '.doc_count')
[ "$doc_count" -gt 0 ] && pass "status shows documents" || fail "status shows documents"

echo ""
echo "$tests tests, $((tests - errors)) passed, $errors failed"
exit "$errors"
```

- [ ] **Step 2: Create fixture documents**

Place in `tests/integration/fixtures/`:
- `contract.md` — markdown contract with headings (Indemnification, Governing Law, Termination)
- `agreement.docx` — simple DOCX with heading styles (if fixture available)
- `filing.pdf` — simple PDF with text content (if fixture available)

Start with .md only, add .docx and .pdf fixtures as those parsers are validated.

- [ ] **Step 3: Run and verify**

```bash
chmod +x tests/integration/test-integration
tests/integration/test-integration
```

- [ ] **Step 4: Commit**

```bash
git add tests/integration/
git commit -m "feat: integration test suite (requires Ollama)"
```

---

## Task 16: Benchmark Suite

**Files:**
- Create: `benchmarks/run-benchmarks` (Zig or Bash)
- Create: `benchmarks/fixtures/` (benchmark documents)
- Create: `benchmarks/generate-corpus` (synthetic corpus generator)
- Modify: `bm` (point to benchmark runner)

- [ ] **Step 1: Create benchmark fixture documents**

Place in `benchmarks/fixtures/`:
- `small.md` — ~1 page contract
- `medium.docx` — ~20 pages (or .md equivalent)
- `large.pdf` — ~100 pages (or .md equivalent)

For initial benchmarks, use .md files of varying sizes to avoid parser-specific variance.

- [ ] **Step 2: Create synthetic corpus generator**

```bash
#!/usr/bin/env bash
# benchmarks/generate-corpus
# Generates a corpus of N documents for search latency benchmarks
set -u

N="${1:-100}"
OUTPUT_DIR="${2:-$TMPDIR/docscan-bench-corpus}"
mkdir -p "$OUTPUT_DIR"

for i in $(seq 1 "$N"); do
    cat > "$OUTPUT_DIR/doc_$i.md" << EOF
# Document $i: $(shuf -n3 /usr/share/dict/words | tr '\n' ' ')

## Section 1

$(shuf -n50 /usr/share/dict/words | tr '\n' ' ')

## Section 2

$(shuf -n50 /usr/share/dict/words | tr '\n' ' ')

## Section 3

$(shuf -n50 /usr/share/dict/words | tr '\n' ' ')
EOF
done

echo "Generated $N documents in $OUTPUT_DIR"
```

- [ ] **Step 3: Implement benchmark runner**

Update `bm` script:

```bash
#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/zig-out/bin/docscan"
FIXTURES="$SCRIPT_DIR/benchmarks/fixtures"
RESULTS="$SCRIPT_DIR/benchmarks/results.log"
TMPDIR="${TMPDIR:-/tmp}"
BENCH_DIR="$TMPDIR/docscan-bench-$$"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Ensure release build
if [ ! -f "$BINARY" ]; then
    echo "No release binary. Run ./build first."
    exit 1
fi

debug_check=$("$BINARY" --about 2>&1)
if echo "$debug_check" | grep -q "DEBUG BUILD"; then
    echo "ERROR: Cannot benchmark a debug build."
    exit 1
fi

mkdir -p "$BENCH_DIR"
trap 'rm -rf "$BENCH_DIR"' EXIT

echo "=== docscan Benchmarks ==="
echo "Commit: $COMMIT"
echo "Date: $TIMESTAMP"
echo ""

# --- Parsing throughput ---
echo "## Parsing Throughput"
for fixture in "$FIXTURES"/*.md; do
    name=$(basename "$fixture")
    size=$(wc -c < "$fixture")
    result=$(hyperfine --warmup 3 --min-runs 10 --export-json "$BENCH_DIR/$name.json" \
        "$BINARY parse-bench $fixture" 2>&1)
    mean=$(jq '.results[0].mean' "$BENCH_DIR/$name.json")
    throughput=$(echo "scale=2; $size / $mean / 1048576" | bc)
    echo "  $name: ${throughput} MB/s (mean ${mean}s, size ${size}B)"
done

# --- Search latency ---
echo ""
echo "## Search Latency"

# Generate and index test corpora of different sizes
for corpus_size in 100 1000; do
    "$SCRIPT_DIR/benchmarks/generate-corpus" "$corpus_size" "$BENCH_DIR/corpus-$corpus_size"
    "$BINARY" index "$BENCH_DIR/corpus-$corpus_size" --db "$BENCH_DIR/bench-$corpus_size.db" 2>/dev/null

    # Exact search
    result=$(hyperfine --warmup 5 --min-runs 20 \
        "$BINARY search --exact 'test query' --db $BENCH_DIR/bench-$corpus_size.db --json --limit 10" 2>&1)
    echo "  exact/$corpus_size chunks: $(echo "$result" | grep 'Time (mean')"

    # Hybrid search (requires Ollama)
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        result=$(hyperfine --warmup 3 --min-runs 10 \
            "$BINARY search 'liability protection' --db $BENCH_DIR/bench-$corpus_size.db --json --limit 10" 2>&1)
        echo "  hybrid/$corpus_size chunks: $(echo "$result" | grep 'Time (mean')"
    fi
done

# --- Log results ---
echo "" >> "$RESULTS"
echo "## $TIMESTAMP ($COMMIT)" >> "$RESULTS"
# Append all benchmark results to log

# --- Regression detection ---
# Compare against previous entry in results.log
# If any metric changed > 10%, print WARNING
echo ""
echo "Results logged to $RESULTS"
```

- [ ] **Step 4: Run benchmarks**

```bash
chmod +x bm benchmarks/generate-corpus
./bm
```

- [ ] **Step 5: Commit**

```bash
git add bm benchmarks/
git commit -m "feat: benchmark suite with parsing throughput and search latency"
```

---

## Task 17: Ignore Patterns + Directory Walking

**Files:**
- Create: `src/core/ignore.zig` (gitignore-syntax pattern matcher)
- Create: `.docscanignore.default`

- [ ] **Step 1: Write failing test for ignore patterns**

```zig
test "ignore: basic glob patterns" {
    var ig = try IgnoreList.init(alloc);
    try ig.addPattern("*.log");
    try ig.addPattern("node_modules/");
    try ig.addPattern(".git/");

    try std.testing.expect(ig.isIgnored("debug.log"));
    try std.testing.expect(ig.isIgnored("node_modules/foo.js"));
    try std.testing.expect(!ig.isIgnored("contract.pdf"));
}

test "ignore: negation patterns" {
    var ig = try IgnoreList.init(alloc);
    try ig.addPattern("*.pdf");
    try ig.addPattern("!important.pdf");

    try std.testing.expect(ig.isIgnored("random.pdf"));
    try std.testing.expect(!ig.isIgnored("important.pdf"));
}

test "ignore: classifier over sets, not single examples" {
    // Test with full set of file paths, verify classification is correct across all
    const paths = [_][]const u8{
        "contract.pdf", "notes.md", "debug.log", ".git/config",
        "node_modules/pkg/index.js", "build/output.o", "README.md",
    };
    const expected_ignored = [_]bool{
        false, false, true, true, true, true, false,
    };
    var ig = try IgnoreList.init(alloc);
    try ig.addPattern("*.log");
    try ig.addPattern(".git/");
    try ig.addPattern("node_modules/");
    try ig.addPattern("build/");

    for (paths, expected_ignored) |path, expected| {
        try std.testing.expectEqual(expected, ig.isIgnored(path));
    }
}
```

- [ ] **Step 2: Run tests, confirm they fail**

- [ ] **Step 3: Implement ignore pattern matcher**

Gitignore-compatible: globs, directory markers (`/`), negation (`!`), comments (`#`).

- [ ] **Step 4: Create default ignore file**

`.docscanignore.default`:
```
# Version control
.git/
.jj/

# Dependencies
node_modules/
__pycache__/
.venv/

# Build artifacts
zig-out/
zig-cache/
target/
build/
dist/

# Binary/image files
*.exe
*.dll
*.so
*.dylib
*.o
*.a
*.png
*.jpg
*.jpeg
*.gif
*.ico
*.svg
*.mp3
*.mp4
*.wav
*.zip
*.tar
*.gz
*.7z

# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# docscan's own index
.docscan/
```

- [ ] **Step 5: Run tests, commit**

```bash
git add src/core/ignore.zig .docscanignore.default src/all_tests.zig
git commit -m "feat: gitignore-compatible file ignore patterns"
```

---

## Task 18: Final Integration + Documentation

**Files:**
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`
- Modify: `PROJECT_OVERVIEW.md`

- [ ] **Step 1: Run full test suite**

```bash
./build && ./test
```

Expected: all unit, CLI, and MCP tests pass.

- [ ] **Step 2: Run integration tests (if Ollama available)**

```bash
tests/integration/test-integration
```

- [ ] **Step 3: Run benchmarks**

```bash
./bm
```

- [ ] **Step 4: Update CODE_MINIMAP.md**

Document every source file, its purpose, and key functions/types.

- [ ] **Step 5: Update PLAN.md**

Check off all completed items. Add any discovered follow-up work.

- [ ] **Step 6: Cross-compile all targets**

```bash
./build_all
```

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "feat: docscan v0.1.0 — document indexing and semantic search"
```

- [ ] **Step 8: Verify Garnix CI**

Push to GitHub, verify `packages.default` and `checks.*.{build, test}` pass on Garnix.

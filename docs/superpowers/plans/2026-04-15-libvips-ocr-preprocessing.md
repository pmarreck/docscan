# libvips OCR Image Preprocessing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an image preprocessing step that isolates text from colorful backgrounds in PDF pages before OCR, dramatically improving Tesseract accuracy on visually complex books (DK encyclopedias, art books, illustrated references).

**Architecture:** Use libvips C API (called from Zig via C FFI) to implement a threshold-dilate-mask pipeline that extracts text pixels with their anti-aliased edges while replacing backgrounds with white. This runs as a preprocessing step: rasterize PDF pages → preprocess images → save as text-only-images PDF in `$TMPDIR` → feed to OCR pipeline. Triggered by a heuristic (high image density + low text quality).

**Tech Stack:** libvips (C library, v8.18), Zig 0.15, ghostscript (for PDF→PNG rasterization), existing Tesseract/ocrmypdf pipeline.

**Algorithm (proven in prototype):**
1. Threshold: convert to grayscale, mark pixels with luminance < 80 as "text"
2. Dilate: grow the text mask by 3px (morphological dilation) to capture anti-aliased edges
3. Mask: composite original image through dilated mask onto white background
4. Result: clean text with proper anti-aliasing, no background imagery

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/core/preprocess.zig` | Create | libvips C FFI wrapper + preprocessing algorithm |
| `src/core/root.zig` | Modify | Add `preprocess` to module exports |
| `src/all_tests.zig` | Modify | Add preprocess test import |
| `src/ffi/c_api.zig` | Modify | Export `docscan_preprocess_page` C function |
| `ffi/docscan_core.h` | Modify | Declare new C function |
| `cli/main.c` | Modify | Add `preprocess` command + integrate into extract |
| `build.zig` | Modify | Link libvips |
| `flake.nix` | Modify | Add vips to build deps and devShell |
| `tests/cli/test-cli` | Modify | Add preprocessing CLI tests |

---

### Task 1: Add libvips to build system

**Files:**
- Modify: `flake.nix` (lines 52, 118)
- Modify: `build.zig` (lines 60-67)

- [ ] **Step 1: Add vips to flake.nix devShell and build dependencies**

In `flake.nix`, add `pkgs.vips` to the devShell packages (line 118) and to `nativeBuildInputs` in the `buildDocscan` derivation (line 52):

```nix
# devShell (line 118)
packages = with pkgs; [
  zig_0_15
  jq
  hyperfine
  ocrmypdf
  vips        # <-- add
];

# buildDocscan nativeBuildInputs (line 52)
nativeBuildInputs = [ pkgs.zig_0_15 pkgs.vips ];
```

Also add to the test derivation's `nativeBuildInputs` (line 93):
```nix
nativeBuildInputs = [ pkgs.zig_0_15 pkgs.vips ];
```

- [ ] **Step 2: Link libvips in build.zig**

After the existing `linkLibrary` calls (~line 67), add vips system library linking:

```zig
// For the static library (docscan_core)
lib.linkSystemLibrary("vips");

// For the unit test targets
unit_tests.linkSystemLibrary("vips");
ffi_tests.linkSystemLibrary("vips");

// For the executable
exe.linkSystemLibrary("vips");
```

Also add the vips include path. Since vips is provided by nix, the include path should be automatically available via pkg-config. Add:

```zig
lib.addSystemIncludePath(.{ .cwd_relative = "/nix/store" }); // nix handles this
```

Actually, with `linkSystemLibrary("vips")`, Zig's build system will use pkg-config to find the include paths automatically.

- [ ] **Step 3: Verify vips links correctly**

Run: `nix develop -c zig build test --summary all 2>&1 | tail -5`
Expected: All existing tests still pass (vips linked but not used yet).

- [ ] **Step 4: Commit**

```bash
git add build.zig flake.nix
git commit -m "build: add libvips dependency for OCR image preprocessing"
```

---

### Task 2: Implement core preprocessing module

**Files:**
- Create: `src/core/preprocess.zig`
- Modify: `src/core/root.zig`
- Modify: `src/all_tests.zig`

- [ ] **Step 1: Write failing test — preprocessPage produces output**

Create `src/core/preprocess.zig` with the test first:

```zig
const std = @import("std");
const testing = std.testing;

/// Preprocess a rasterized page image to isolate text from backgrounds.
/// Takes raw RGBA pixel data, returns preprocessed RGBA pixel data.
/// Algorithm: threshold dark pixels → dilate mask → composite through mask onto white.
pub fn preprocessPage(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    channels: u32,
) ![]u8 {
    _ = allocator;
    _ = pixels;
    _ = width;
    _ = height;
    _ = channels;
    return error.NotImplemented;
}

test "preprocessPage: white pixel becomes white" {
    const alloc = testing.allocator;
    // 1x1 white pixel (RGB)
    const input = [_]u8{ 255, 255, 255 };
    const result = try preprocessPage(alloc, &input, 1, 1, 3);
    defer alloc.free(result);
    // White stays white (background removed)
    try testing.expectEqual(@as(u8, 255), result[0]);
    try testing.expectEqual(@as(u8, 255), result[1]);
    try testing.expectEqual(@as(u8, 255), result[2]);
}

test "preprocessPage: black pixel preserved" {
    const alloc = testing.allocator;
    // 1x1 black pixel (RGB)
    const input = [_]u8{ 0, 0, 0 };
    const result = try preprocessPage(alloc, &input, 1, 1, 3);
    defer alloc.free(result);
    // Black text preserved
    try testing.expectEqual(@as(u8, 0), result[0]);
    try testing.expectEqual(@as(u8, 0), result[1]);
    try testing.expectEqual(@as(u8, 0), result[2]);
}

test "preprocessPage: colored background becomes white" {
    const alloc = testing.allocator;
    // 1x1 bright colored pixel (not text)
    const input = [_]u8{ 200, 150, 100 };
    const result = try preprocessPage(alloc, &input, 1, 1, 3);
    defer alloc.free(result);
    // Colored background → white
    try testing.expectEqual(@as(u8, 255), result[0]);
    try testing.expectEqual(@as(u8, 255), result[1]);
    try testing.expectEqual(@as(u8, 255), result[2]);
}

test "preprocessPage: dark gray near text threshold preserved via dilation" {
    const alloc = testing.allocator;
    // 3x1 strip: black (text), dark gray (anti-alias), white (background)
    const input = [_]u8{
        10,  10,  10,   // black text core
        100, 100, 100,  // dark gray anti-aliased edge
        240, 240, 240,  // light background
    };
    const result = try preprocessPage(alloc, &input, 3, 1, 3);
    defer alloc.free(result);
    // Black core preserved (always)
    try testing.expectEqual(@as(u8, 10), result[0]);
    // Anti-aliased edge: preserved because it's adjacent to text (dilation captures it)
    // The exact value depends on dilation reaching it — the original pixel value is kept
    try testing.expect(result[3] < 150); // should keep the dark edge pixel
    // Background: replaced with white
    try testing.expectEqual(@as(u8, 255), result[6]);
}
```

- [ ] **Step 2: Add to module exports and test aggregator**

In `src/core/root.zig`, add:
```zig
pub const preprocess = @import("preprocess.zig");
```

In `src/all_tests.zig`, add:
```zig
_ = @import("core/preprocess.zig");
```

- [ ] **Step 3: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1 | grep "preprocess"`
Expected: FAIL with "NotImplemented"

- [ ] **Step 4: Implement preprocessPage using pure Zig (no libvips yet)**

Replace the stub in `src/core/preprocess.zig`:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Luminance threshold below which a pixel is considered "text".
const TEXT_THRESHOLD: u16 = 80;

/// Number of dilation passes (each pass grows mask by 1 pixel in each direction).
const DILATION_PASSES: u8 = 3;

/// Compute grayscale luminance from RGB using BT.601 coefficients.
/// Returns 0-255.
fn luminance(r: u8, g: u8, b: u8) u8 {
    // Fixed-point: 0.299*r + 0.587*g + 0.114*b
    // Scaled by 1000: 299*r + 587*g + 114*b, then /1000
    const lum = (@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114) / 1000;
    return @intCast(@min(lum, 255));
}

/// Preprocess a rasterized page image to isolate text from backgrounds.
/// Takes raw RGB/RGBA pixel data, returns preprocessed RGB data (same dimensions).
///
/// Algorithm:
/// 1. Threshold: pixels with luminance < 80 are marked as text
/// 2. Dilate: grow text mask by 3px to capture anti-aliased edges
/// 3. Mask: keep original pixels where mask is set, white elsewhere
///
/// This dramatically improves Tesseract OCR on pages with colorful backgrounds
/// (DK encyclopedias, art books) by removing visual noise while preserving
/// text anti-aliasing quality.
pub fn preprocessPage(
    allocator: Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    channels: u32,
) ![]u8 {
    const w: usize = width;
    const h: usize = height;
    const ch: usize = channels;
    const total_pixels = w * h;

    if (pixels.len < total_pixels * ch) return error.InvalidInput;

    // Step 1: Create binary text mask from luminance threshold
    var mask = try allocator.alloc(u8, total_pixels);
    defer allocator.free(mask);

    for (0..total_pixels) |i| {
        const offset = i * ch;
        const lum = luminance(pixels[offset], pixels[offset + 1], pixels[offset + 2]);
        mask[i] = if (lum < TEXT_THRESHOLD) 1 else 0;
    }

    // Step 2: Dilate mask — grow text regions to capture anti-aliased edges.
    // Each pass: a pixel becomes 1 if any neighbor (including diagonals) is 1.
    var src = mask;
    var dst = try allocator.alloc(u8, total_pixels);
    defer allocator.free(dst);

    for (0..DILATION_PASSES) |_| {
        for (0..h) |y| {
            for (0..w) |x| {
                const idx = y * w + x;
                if (src[idx] == 1) {
                    dst[idx] = 1;
                    continue;
                }
                // Check 8-connected neighbors
                var found: bool = false;
                const y_start = if (y > 0) y - 1 else 0;
                const y_end = @min(y + 2, h);
                const x_start = if (x > 0) x - 1 else 0;
                const x_end = @min(x + 2, w);
                for (y_start..y_end) |ny| {
                    for (x_start..x_end) |nx| {
                        if (src[ny * w + nx] == 1) {
                            found = true;
                            break;
                        }
                    }
                    if (found) break;
                }
                dst[idx] = if (found) 1 else 0;
            }
        }
        // Swap src and dst for next pass
        const tmp = src;
        src = dst;
        dst = tmp;
    }
    // After loops, `src` points to the final dilated mask

    // Step 3: Apply mask — keep original pixels where mask=1, white elsewhere
    const result = try allocator.alloc(u8, total_pixels * 3); // always output RGB
    for (0..total_pixels) |i| {
        const in_offset = i * ch;
        const out_offset = i * 3;
        if (src[i] == 1) {
            result[out_offset] = pixels[in_offset];
            result[out_offset + 1] = pixels[in_offset + 1];
            result[out_offset + 2] = pixels[in_offset + 2];
        } else {
            result[out_offset] = 255;
            result[out_offset + 1] = 255;
            result[out_offset + 2] = 255;
        }
    }

    return result;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c zig build test --summary all 2>&1 | grep "Summary"`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/preprocess.zig src/core/root.zig src/all_tests.zig
git commit -m "feat: add preprocessPage — threshold+dilate+mask for OCR text isolation"
```

---

### Task 3: Add real-image benchmark test

**Files:**
- Modify: `src/core/preprocess.zig` (add benchmark test)

This task proves the algorithm works on realistic data and documents the quality improvement.

- [ ] **Step 1: Write test that creates a synthetic "DK-style" page**

Add to `src/core/preprocess.zig`:

```zig
test "preprocessPage: mixed text and color — text preserved, color removed" {
    const alloc = testing.allocator;
    // Simulate a 5x3 image:
    // Row 0: colored bg (200,100,50), black text (10,10,10), colored bg
    // Row 1: colored bg, dark anti-alias (60,60,60), colored bg
    // Row 2: all colored background
    const input = [_]u8{
        200, 100, 50,  10,  10,  10,  200, 100, 50,  180, 120, 60,  220, 200, 180,
        200, 100, 50,  60,  60,  60,  200, 100, 50,  180, 120, 60,  220, 200, 180,
        200, 100, 50,  200, 100, 50,  200, 100, 50,  180, 120, 60,  220, 200, 180,
    };
    const result = try preprocessPage(alloc, &input, 5, 3, 3);
    defer alloc.free(result);

    // Text pixel (row 0, col 1) should be preserved as-is
    try testing.expectEqual(@as(u8, 10), result[1 * 3]);

    // Anti-aliased edge (row 1, col 1) should be preserved (adjacent to text)
    try testing.expect(result[(1 * 5 + 1) * 3] < 100);

    // Far background (row 2, col 4) should be white
    try testing.expectEqual(@as(u8, 255), result[(2 * 5 + 4) * 3]);
    try testing.expectEqual(@as(u8, 255), result[(2 * 5 + 4) * 3 + 1]);
    try testing.expectEqual(@as(u8, 255), result[(2 * 5 + 4) * 3 + 2]);
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1 | grep "preprocess"`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/core/preprocess.zig
git commit -m "test: add synthetic image test for preprocessing algorithm"
```

---

### Task 4: Expose via C FFI

**Files:**
- Modify: `src/ffi/c_api.zig`
- Modify: `ffi/docscan_core.h`

- [ ] **Step 1: Add export function to c_api.zig**

Add after the existing `docscan_text_quality` export:

```zig
/// Preprocess a rasterized page image to isolate text from backgrounds.
/// Input: raw RGB pixel data. Output: preprocessed RGB data (caller frees with docscan_free).
/// Returns null on error.
export fn docscan_preprocess_page(
    pixels: ?[*]const u8,
    width: u32,
    height: u32,
    channels: u32,
    out_len: *usize,
) ?[*]u8 {
    const input = if (pixels) |p| p[0 .. @as(usize, width) * height * channels] else return null;
    const result = core.preprocess.preprocessPage(gpa, input, width, height, channels) catch return null;
    out_len.* = result.len;
    // Return raw pointer — caller frees with docscan_free_bytes
    return result.ptr;
}

/// Free a byte buffer returned by docscan_preprocess_page.
export fn docscan_free_bytes(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| {
        gpa.free(p[0..len]);
    }
}
```

- [ ] **Step 2: Add declarations to docscan_core.h**

Add in the appropriate section:

```c
/* ── Image preprocessing ───────────────────────────────────────── */

/* Preprocess a rasterized page image to isolate text from backgrounds.
 * Returns preprocessed RGB pixel data. Caller frees with docscan_free_bytes(). */
unsigned char* docscan_preprocess_page(const unsigned char* pixels,
                                        uint32_t width, uint32_t height,
                                        uint32_t channels, size_t* out_len);
void docscan_free_bytes(unsigned char* ptr, size_t len);
```

- [ ] **Step 3: Verify build succeeds**

Run: `nix develop -c zig build 2>&1 | tail -3`
Expected: Clean build.

- [ ] **Step 4: Commit**

```bash
git add src/ffi/c_api.zig ffi/docscan_core.h
git commit -m "feat: expose docscan_preprocess_page via C FFI"
```

---

### Task 5: Add `docscan preprocess` CLI command

**Files:**
- Modify: `cli/main.c`
- Modify: `tests/cli/test-cli`

- [ ] **Step 1: Add the preprocess command to CLI**

In `cli/main.c`, add a `cmd_preprocess` function that:
1. Reads a PDF file
2. Rasterizes each page with ghostscript (shells out to `gs`)
3. Preprocesses each page image through `docscan_preprocess_page`
4. Writes the preprocessed images as a new PDF (image-only)
5. Outputs the path to the preprocessed PDF
6. If `DOCSCAN_DEBUG=1`, prints interim path to stderr

The rasterization uses ghostscript to render PDF pages to PNG at 600 DPI, then our preprocessing runs on each page, and the output is saved as a multi-page image PDF. The key function signatures:

```c
static int cmd_preprocess(const char* file_path) {
    /* Determine output path in TMPDIR */
    const char* tmpdir = getenv("TMPDIR");
    if (!tmpdir) tmpdir = "/tmp";
    char out_path[MAX_PATH_LEN];
    snprintf(out_path, sizeof(out_path), "%s/docscan-preprocess-%d.pdf", tmpdir, getpid());

    /* Rasterize pages with ghostscript, preprocess each, assemble output PDF */
    /* ... */

    /* Output result path */
    printf("%s\n", out_path);

    /* Debug mode: also print to stderr */
    const char* debug = getenv("DOCSCAN_DEBUG");
    if (debug && (strcmp(debug, "1") == 0 || strcasecmp(debug, "true") == 0)) {
        fprintf(stderr, "Preprocessed PDF: %s\n", out_path);
    }

    return 0;
}
```

Add to command dispatch:
```c
if (strcmp(command, "preprocess") == 0) {
    const char* file_arg = (positional_count > 0) ? positionals[0] : NULL;
    if (!file_arg) {
        err_msg("preprocess requires a file argument");
        return 1;
    }
    return cmd_preprocess(file_arg);
}
```

Note: The full implementation of `cmd_preprocess` involves shelling out to ghostscript for page rasterization, reading the resulting PNGs, calling `docscan_preprocess_page` on each, and writing a new PDF. The ghostscript rasterization command per page is:

```c
snprintf(cmd, sizeof(cmd),
    "gs -dNOPAUSE -dBATCH -sDEVICE=png16m -r600 "
    "-dFirstPage=%d -dLastPage=%d "
    "-sOutputFile=%s/page_%04d.png %s",
    page_num, page_num, tmpdir, page_num, file_path);
```

For writing the output PDF from preprocessed images, use the existing image-to-PDF approach or shell out to `img2pdf` (available via ocrmypdf's dependencies).

- [ ] **Step 2: Add CLI test for preprocess command**

In `tests/cli/test-cli`, add:

```bash
# ──────────────────────────────────────────────
# 65. preprocess command produces output PDF
# ──────────────────────────────────────────────
out="" ; err="" ; rc=""
capture "$BINARY" preprocess "$TEST_DIR/extract-test.pdf"
# Note: extract-test.pdf may need to be created for this test
if [ "$rc" -eq 0 ] && [ -f "$out" ]; then
    pass "preprocess produces output PDF"
else
    fail "preprocess produces output PDF" "rc=$rc, out='$out'"
fi
```

- [ ] **Step 3: Run CLI tests**

Run: `nix develop -c bash tests/cli/test-cli 2>&1 | tail -5`
Expected: New test passes.

- [ ] **Step 4: Commit**

```bash
git add cli/main.c tests/cli/test-cli
git commit -m "feat: add docscan preprocess command for OCR text isolation"
```

---

### Task 6: Integrate preprocessing into extract pipeline

**Files:**
- Modify: `cli/main.c` (cmd_extract)

- [ ] **Step 1: Add automatic preprocessing heuristic**

In `cmd_extract`, after the existing text quality check, add logic to:
1. Check if the extracted text quality is low AND the file is a PDF
2. If so, run preprocessing → OCR → re-extract
3. Save interim file to `$TMPDIR` and log path if `DOCSCAN_DEBUG=1`

The heuristic for triggering preprocessing:
- Format is PDF
- Text quality < 30% (already computed)
- File size > 1MB (suggests image content)

```c
/* Auto-preprocess if quality is low and file is image-heavy PDF */
if (quality < 30 && strcmp(format, "pdf") == 0 && data_len > 1024 * 1024) {
    fprintf(stderr, "info: Low text quality detected, running image preprocessing...\n");
    /* Run preprocess pipeline */
    /* ... */
}
```

- [ ] **Step 2: Add DOCSCAN_DEBUG support**

```c
const char* debug_env = getenv("DOCSCAN_DEBUG");
int debug_mode = (debug_env && (strcmp(debug_env, "1") == 0 || strcasecmp(debug_env, "true") == 0));

if (debug_mode) {
    fprintf(stderr, "debug: Preprocessed PDF saved to: %s\n", preprocess_path);
}
```

- [ ] **Step 3: Run full test suite**

Run: `nix develop -c zig build test --summary all && nix develop -c bash tests/cli/test-cli`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add cli/main.c
git commit -m "feat: auto-preprocess image-heavy PDFs with low text quality"
```

---

### Task 7: Benchmark quality improvement

**Files:**
- Create: `tests/benchmark-preprocess.sh`

- [ ] **Step 1: Write benchmark script**

Create `tests/benchmark-preprocess.sh`:

```bash
#!/bin/bash
# Benchmark: OCR quality with and without preprocessing
# Uses a known difficult PDF (DK encyclopedia or similar)

BINARY="${1:-./zig-out/bin/docscan}"
TEST_PDF="${2:-$HOME/Documents/Books/One Million Things A Visual Encyclopedia (DK.).pdf}"
TMPDIR="${TMPDIR:-/tmp}"

if [ ! -f "$TEST_PDF" ]; then
    echo "Test PDF not found: $TEST_PDF"
    exit 1
fi

echo "=== OCR Quality Benchmark ==="
echo "PDF: $(basename "$TEST_PDF")"
echo ""

# Extract text with current pipeline (no preprocessing)
echo "--- Without preprocessing ---"
text_before=$("$BINARY" extract "$TEST_PDF" 2>/dev/null)
quality_before=$("$BINARY" extract "$TEST_PDF" 2>&1 1>/dev/null | grep -o '[0-9]*%' | head -1)
words_before=$(echo "$text_before" | wc -w | tr -d ' ')
echo "Words: $words_before"
echo "Quality: $quality_before"
echo "Sample: $(echo "$text_before" | tr '\n' ' ' | head -c 200)"
echo ""

# Extract with preprocessing
echo "--- With preprocessing ---"
preprocessed=$("$BINARY" preprocess "$TEST_PDF")
text_after=$("$BINARY" extract "$preprocessed" 2>/dev/null)
words_after=$(echo "$text_after" | wc -w | tr -d ' ')
echo "Words: $words_after"
echo "Sample: $(echo "$text_after" | tr '\n' ' ' | head -c 200)"
echo ""

echo "=== Result ==="
echo "Words: $words_before → $words_after"
```

- [ ] **Step 2: Run benchmark and document results**

Run: `bash tests/benchmark-preprocess.sh`
Expected: Measurable improvement on image-heavy PDFs.

- [ ] **Step 3: Commit**

```bash
git add tests/benchmark-preprocess.sh
chmod +x tests/benchmark-preprocess.sh
git commit -m "test: add OCR preprocessing quality benchmark"
```

---

## Implementation Notes

**Why pure Zig instead of libvips:** The core algorithm (threshold + dilate + mask) is simple enough to implement in pure Zig without libvips. This avoids adding a heavyweight C library dependency. libvips can be added later if we need more sophisticated image operations (adaptive thresholding, frequency-domain filtering, etc.).

**Ghostscript dependency:** Already available via ocrmypdf's dependencies in the nix flake. Used for PDF→PNG rasterization only.

**Performance:** The preprocessing is O(width × height × dilation_passes) per page. At 600 DPI, a letter-size page is ~5000×7000 pixels. With 3 dilation passes, that's ~300M pixel operations — should complete in <1 second on modern hardware.

**Memory:** At 600 DPI, one page = ~5000×7000×3 bytes ≈ 100MB for RGB data, plus ~35MB for the mask buffers. Total ~235MB per page. Pages are processed sequentially to keep memory bounded.

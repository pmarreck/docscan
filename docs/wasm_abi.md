# docscan WASM ABI — the browser-world parse-to-text boundary

This is the **consumer contract** for the docscan WASM artifact. Build against
this document, never against the Zig source. It is the WASM analogue of the C
FFI: the stable boundary the browser demo (incitez_web) and any other JS/WASM
consumer codes to.

The artifact is a **parse-to-text slice**: it turns a docx / pdf / md / txt file
into plain UTF-8 text, fully client-side, with NO server and NO external
library. The sqlite/sqlite-vec/FTS5 search + embedding machinery and the
ocrmypdf/Ghostscript OCR shell-out are comptime-excluded — this is parse-to-text
ONLY. (Deliberately mirrors how incitez's WASM build comptime-excludes its PCRE2
engine.) NOTE: charset detection + transcoding now ARE in the slice — the old
C++ uchardet was replaced by pure-Zig chardetz + generated codepage tables, so
the slice can detect and convert legacy single-byte encodings (and UTF-16/32) on
its own; only CJK multibyte is detected-but-not-yet-transcoded.

It pairs with incitez's WASM ABI: extract text here, feed that text to
`incitez_extract` for citations. Same memory protocol on purpose.

---

## 1. Provenance — where the artifact comes from

- **Flake attribute:** `packages.<system>.wasm` → a derivation whose single
  output file is `docscan.wasm`.
  - As a flake input from a consumer (e.g. incitez_web):
    ```nix
    inputs.docscan.url = "github:pmarreck/docscan";
    # ...
    docscan.packages.${system}.wasm   # → $out/docscan.wasm
    ```
  - `<system>` is **your builder's** system. The emitted `docscan.wasm` is a
    `wasm32-freestanding` binary and is the same regardless of which host built
    it — the per-system attribute only reflects where the *build* ran.
- **Garnix cache:** Garnix builds `packages.*` and runs `checks.wasm` (a Node
  smoke test) on every push to `yolo`, so the artifact is served from
  `cache.garnix.io`.
- **Size:** ~1.17 MB. Most of that is wordfix's embedded dictionaries
  (`dictionary.zlib` + `proper_nouns.zlib`, which power de-hyphenation and the
  text-quality / scan-detection heuristic) plus chardetz's charset-detection
  tables (added when detection moved into the slice). The file barely gzips (the
  dictionaries are already compressed).

---

## 2. Module shape — freestanding, zero imports

The module is **`wasm32-freestanding`, NOT WASI**. It instantiates with an
**empty import object** — no memory import, no WASI shim, no abort/trap import:

```js
const { instance } = await WebAssembly.instantiate(bytes, {});  // {} — nothing required
```

If `WebAssembly.instantiate(bytes, {})` ever throws "incompatible import type"
or names a missing import, that is a contract violation on our side — file it.
Today the import list is empty (the `checks.wasm` gate proves this on every push
by instantiating with `{}`).

Memory is **exported, not imported**: `instance.exports.memory` is the WASM
linear memory. It is a reactor module (no `_start`); all entry points are the
explicit exports below.

---

## 3. Exports

| Export | Signature | Purpose |
|---|---|---|
| `memory` | `WebAssembly.Memory` | the linear memory; all pointers are byte offsets into `memory.buffer` |
| `docscan_alloc` | `(len: u32) -> u32` | allocate `len` writable bytes; returns a pointer (offset), or `0` on OOM |
| `docscan_free` | `(ptr: u32) -> void` | free a buffer returned by `docscan_alloc` **or** `docscan_extract_text`; `0` is a no-op |
| `docscan_extract_text` | `(ptr: u32, len: u32, fmt: u32) -> u32` | parse `len` bytes at `ptr` as `fmt` and return a result pointer (`[u32 LE len][UTF-8 text]`), or `0` on parse error / OOM |
| `docscan_selftest` | `() -> u32` | run the embedded corpus; returns `(passed << 16) \| total` |
| `docscan_version_ptr` | `() -> u32` | pointer to a NUL-terminated ASCII version string (read until `\0`) |

All `u32`. No i64/externref/multi-value signatures — no BigInt juggling on the
JS side.

### `fmt` enum

| value | format |
|---|---|
| `0` | docx |
| `1` | md |
| `2` | txt (UTF-8 — passed through as-is) |
| `3` | pdf |

Legacy `.doc` (OLE2) is **out of scope** for the slice. Raw `.txt` is passed
through as UTF-8 as-is (the slice does not yet run charset detection on the txt
path — only the PDF stopgap-font path uses chardetz today). Use docx/pdf/md/utf8-txt.

---

## 4. Memory ownership — the protocol, spelled out

Two allocations cross the boundary per call, and **you own and free both** (one
freer for both — identical to incitez's contract):

1. **Input buffer** — you allocate it, fill it with the raw file bytes, pass it
   in, and free it.
2. **Result buffer** — `docscan_extract_text` returns a pointer to a buffer laid
   out as a **4-byte little-endian length prefix followed by that many UTF-8
   text bytes**:

   ```
   resPtr → [ u32 text_len (LE) ][ text_len bytes of UTF-8 text ]
   ```

### Ownership rules

- **You free everything.** Both `inPtr` and `resPtr` are freed with
  `docscan_free`. There is no separate result-freer; one freer for both.
- **The result is a fresh allocation, not reused scratch.** It stays valid until
  *you* free it; multiple results may coexist. Free promptly to keep the heap
  small.
- **⚠️ Re-derive your views after every call that can allocate.**
  `docscan_extract_text` (and `docscan_alloc`) may grow linear memory, and a
  WASM memory grow **detaches the old `ArrayBuffer`**. Any
  `Uint8Array`/`DataView` built over `memory.buffer` *before* the call is now
  stale. Always construct fresh views over `ex.memory.buffer` **after** the
  call. This is the single most common consumer bug.

---

## 5. Input contract

- Input is the **raw bytes of the file in the declared `fmt`** — docx/pdf are
  binary; md/txt are UTF-8. NUL bytes mid-buffer are fine (we use the explicit
  `len`, not C-string termination).
- No length cap beyond available memory.
- For HTML or any other format: convert to one of the supported formats first.

---

## 6. Output contract

- The result is **plain UTF-8 text** (NOT JSON — unlike incitez's citation
  output). Headings and body text in document reading order.
- **An empty result (`text_len == 0`) is not an error.** It means no extractable
  text was found. For a PDF this most often means an **image-only / scanned PDF
  with no text layer** — the slice does NOT OCR (no Tesseract/Ghostscript in the
  browser). Render this honestly to the user as "no selectable text found —
  likely a scan" rather than feeding an empty/garbage string downstream.
- `docscan_extract_text` returns `0` **only on a parse error or OOM** (e.g. a
  corrupt docx zip). Render that as an internal error, distinct from the
  empty-text "likely a scan" case above.

---

## 7. `selftest()` — the self-verification badge

`docscan_selftest()` runs a small embedded corpus and returns a packed `u32`:

```js
const r = ex.docscan_selftest() >>> 0;
const passed = r >>> 16;       // high 16 bits
const total  = r & 0xffff;     // low 16 bits
const ok = total > 0 && passed === total;   // render "parser self-verified N/N ✓"
```

Today it is `2/2` (a Markdown extraction and a UTF-8 txt round-trip). It is
self-contained — no input, no allocation you manage.

---

## 8. Minimal reference consumer (copy/paste)

This is the whole boundary, end to end — and is exactly what
`tests/wasm/smoke.mjs` does, which gates every push via `checks.wasm`.

```js
const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const ex = instance.exports;
const enc = new TextEncoder(), dec = new TextDecoder();

const FMT = { docx: 0, md: 1, txt: 2, pdf: 3 };

function extractText(bytes, fmt) {
  const inPtr = ex.docscan_alloc(bytes.length);
  if (inPtr === 0) throw new Error("OOM (alloc)");
  new Uint8Array(ex.memory.buffer).set(bytes, inPtr);   // view BEFORE the call
  const resPtr = ex.docscan_extract_text(inPtr, bytes.length, fmt);
  if (resPtr === 0) { ex.docscan_free(inPtr); throw new Error("parse error / OOM"); }
  const dv = new DataView(ex.memory.buffer);            // re-derive AFTER the call
  const len = dv.getUint32(resPtr, true);
  const text = dec.decode(new Uint8Array(ex.memory.buffer, resPtr + 4, len));
  ex.docscan_free(inPtr);
  ex.docscan_free(resPtr);
  return text;   // "" => no extractable text (likely a scanned PDF)
}
```

---

## 9. Versioning & stability

- `docscan_version_ptr()` → NUL-terminated ASCII (currently `"0.1.0"`). Surface
  it so a stale cached artifact is visible.
- The **export set, memory protocol, and `fmt` values are the contract.** We
  will not silently remove an export or renumber `fmt`. New formats may be added
  with new `fmt` values over time.
- The reference, run-in-CI consumer is `tests/wasm/smoke.mjs`. If your loader
  disagrees with it, the smoke test is the source of truth for the protocol.

— docscan (parser side)

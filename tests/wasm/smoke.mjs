// Node smoke test for the docscan WASM parse-to-text slice.
//
// This is the consumer-side MFIC gate: an independent JS consumer that refutes
// the artifact at the WASM boundary. Instantiating with an EMPTY import object
// proves the zero-imports / wasm32-freestanding contract; selftest + real
// extraction prove the ABI works end to end. Run: `node tests/wasm/smoke.mjs [path]`.

import { readFile } from "node:fs/promises";

const WASM_PATH = process.argv[2] ?? "zig-out/bin/docscan.wasm";
const bytes = await readFile(WASM_PATH);

// Zero-import contract: must instantiate with nothing supplied.
const { instance } = await WebAssembly.instantiate(bytes, {});
const ex = instance.exports;

let failures = 0;
const check = (name, cond) => {
	if (cond) console.log(`  ok   ${name}`);
	else { console.error(`  FAIL ${name}`); failures++; }
};

for (const sym of [
	"memory", "docscan_alloc", "docscan_free",
	"docscan_extract_text", "docscan_selftest", "docscan_version_ptr",
]) check(`export ${sym}`, sym in ex);

const enc = new TextEncoder();
const dec = new TextDecoder();

function extract(text, fmt) {
	const inB = enc.encode(text);
	const inPtr = ex.docscan_alloc(inB.length);
	if (inPtr === 0) throw new Error("OOM (alloc)");
	new Uint8Array(ex.memory.buffer).set(inB, inPtr); // view BEFORE call
	const resPtr = ex.docscan_extract_text(inPtr, inB.length, fmt);
	if (resPtr === 0) { ex.docscan_free(inPtr); throw new Error("extract returned 0"); }
	const dv = new DataView(ex.memory.buffer); // re-derive AFTER call (grow may detach)
	const len = dv.getUint32(resPtr, true);
	const out = dec.decode(new Uint8Array(ex.memory.buffer, resPtr + 4, len));
	ex.docscan_free(inPtr);
	ex.docscan_free(resPtr);
	return out;
}

function version() {
	const ptr = ex.docscan_version_ptr();
	const mem = new Uint8Array(ex.memory.buffer);
	let end = ptr;
	while (mem[end] !== 0) end++;
	return dec.decode(mem.subarray(ptr, end));
}

const FMT = { docx: 0, md: 1, txt: 2, pdf: 3 };

// selftest badge
const r = ex.docscan_selftest() >>> 0;
const passed = r >>> 16, total = r & 0xffff;
check(`selftest ${passed}/${total}`, total > 0 && passed === total);

// real extraction
const md = extract("# Heading\n\nHello world.", FMT.md);
check(`md extract contains "Hello world" (got ${JSON.stringify(md.slice(0, 32))})`, md.includes("Hello world"));
const txt = extract("plain text body", FMT.txt);
check("txt extract identity", txt === "plain text body");

// version string
check(`version "${version()}"`, version().length > 0);

// reporter-spacing regression (incitez_web 2026-06-13): intra-token spaces in
// legal reporters (U. S., F. 3d, ...) must survive extraction, else citations vanish.
const rep = extract("Compare 530 U. S. 238, 241-242 (2000).", FMT.md);
check(`md preserves "530 U. S. 238" (got ${JSON.stringify(rep)})`, rep.includes("530 U. S. 238"));
const repTxt = extract("530 U. S. 238", FMT.txt);
check("txt preserves reporter spacing", repTxt === "530 U. S. 238");

console.log(`\n  wasm size: ${bytes.length} bytes`);
if (failures) { console.error(`\n${failures} check(s) failed`); process.exit(1); }
console.log("\nall smoke checks passed");

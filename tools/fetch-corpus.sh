#!/usr/bin/env bash
# fetch-corpus.sh — assemble a size/composition-stratified PDF corpus for the
# line-aware extraction differential (tests/corpus/run-corpus). PUBLIC + reproducible:
# each entry is a pinned URL + SHA256 (warn-not-fail on drift, since arXiv may
# recompile). Encrypted blank-password variants are generated locally with qpdf so
# the decryptor is exercised on full-size real docs, not just the tiny fixtures.
#
# The corpus is gitignored (large); this script reconstructs it. Stratification
# deliberately spans page counts + front-matter so statistical heuristics
# (dominant font size, modal line gap) are stressed by composition, not one doc.
#
# Usage: ./tools/fetch-corpus.sh   (writes to tests/corpus/fetched/)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/tests/corpus/fetched"
mkdir -p "$DEST"
CURL="/usr/bin/curl"
command -v "$CURL" >/dev/null || CURL="curl"

# name | url | sha256 | tier(pages) | composition
ENTRIES=(
	"arxiv_resnet|https://arxiv.org/pdf/1512.03385|1e0651b6810ecba34a3dbc5b5b0209226f889004607c1f203540a48d64e5a93a|12|2-col prose+refs"
	"arxiv_attention|https://arxiv.org/pdf/1706.03762|bdfaa68d8984f0dc02beaca527b76f207d99b666d31d1da728ee0728182df697|15|2-col prose+tables"
	"arxiv_bert|https://arxiv.org/pdf/1810.04805|5692a5514787a8c6727b4ff3b726a3385798bc68e12138d1d4af83947e2acf6e|16|2-col prose+tables"
	"arxiv_lottery|https://arxiv.org/pdf/1803.03635|e5fe9482538b6573b59382f058c6eaefd933a9941cf7c06baf5c7577c62f68ec|42|1-col prose, many figs"
	"arxiv_llm_survey|https://arxiv.org/pdf/2303.18223|585551fe1a17793d141f6bff3e595e63151e867a53353991c3c9891facc72377|144|LONG: TOC + huge refs (Brann-like font-stat stressor)"
)

fail=0
for e in "${ENTRIES[@]}"; do
	IFS='|' read -r name url want_sha tier comp <<<"$e"
	out="$DEST/$name.pdf"
	code=$("$CURL" -sSL --max-time 90 -o "$out" -w "%{http_code}" "$url" 2>/dev/null)
	if [ "$code" != "200" ]; then echo "FAIL  $name http=$code"; fail=1; continue; fi
	got_sha=$(shasum -a 256 "$out" | cut -d' ' -f1)
	if [ "$got_sha" != "$want_sha" ]; then
		echo "WARN  $name SHA drift (arXiv recompiled?) want=$want_sha got=$got_sha"
	fi
	echo "ok    $name (${tier}pg, $comp)"
done

# Encrypted blank-password variants (RC4-128, AES-128, AES-256) from one source,
# exercising the decryptor on a full-size doc. Blank USER password → opens without
# a password (the case docscan supports). Owner password is arbitrary.
SRC="$DEST/arxiv_resnet.pdf"
if command -v qpdf >/dev/null 2>&1 && [ -f "$SRC" ]; then
	# qpdf >=11 refuses to write RC4 (deprecated) without --allow-weak-crypto, and
	# leaves a 0-byte stub on failure — so pass the flag and verify non-empty output.
	if qpdf --allow-weak-crypto --encrypt "" owner 128 --use-aes=n -- "$SRC" "$DEST/enc_rc4_128.pdf" && [ -s "$DEST/enc_rc4_128.pdf" ]; then echo "ok    enc_rc4_128 (qpdf RC4-128)"; else echo "WARN  enc_rc4_128 generation failed"; fi
	qpdf --encrypt "" owner 128 --use-aes=y -- "$SRC" "$DEST/enc_aes_128.pdf" 2>/dev/null && echo "ok    enc_aes_128 (qpdf AES-128)"
	qpdf --encrypt "" owner 256 -- "$SRC" "$DEST/enc_aes_256.pdf" 2>/dev/null && echo "ok    enc_aes_256 (qpdf AES-256)"
else
	echo "WARN  qpdf or source missing — skipping encrypted variants"
fi

# Fold in the local legal hard cases if present (gitignored, not fetchable).
for local_pdf in "$ROOT/tests/corpus/legal-brann-appellate-brief.pdf"; do
	[ -f "$local_pdf" ] && { ln -sf "$local_pdf" "$DEST/$(basename "$local_pdf")"; echo "ok    $(basename "$local_pdf") (local legal, 90pg)"; }
done

echo ">> corpus at $DEST ($(ls "$DEST"/*.pdf 2>/dev/null | wc -l | tr -d ' ') files)"
[ "$fail" = 0 ] || echo ">> some downloads failed"

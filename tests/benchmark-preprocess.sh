#!/bin/bash
# Benchmark: OCR quality with and without image preprocessing
# Compares Tesseract accuracy on visually complex pages (DK encyclopedias, etc.)
#
# Usage: nix develop -c bash tests/benchmark-preprocess.sh [docscan-binary] [test.pdf]

set -u

BINARY="${1:-./zig-out/bin/docscan}"
TEST_PDF="${2:-}"
TMPDIR="${TMPDIR:-/tmp}"
OCR_TMPDIR="$HOME/.cache/ocrmypdf-tmp"
mkdir -p "$OCR_TMPDIR"

# Ensure tesseract config exists
echo 'tessedit_char_blacklist |' > "$OCR_TMPDIR/tess_config"

if [ -z "$TEST_PDF" ]; then
	# Try to find a DK encyclopedia
	TEST_PDF=$(find ~/Documents/Books -maxdepth 1 -name "*DK*" -name "*.pdf" 2>/dev/null | head -1)
	if [ -z "$TEST_PDF" ]; then
		echo "No test PDF found. Usage: $0 [binary] <test.pdf>"
		exit 1
	fi
fi

if [ ! -f "$TEST_PDF" ]; then
	echo "Test PDF not found: $TEST_PDF"
	exit 1
fi

echo "=== OCR Preprocessing Quality Benchmark ==="
echo "PDF: $(basename "$TEST_PDF")"
echo "Size: $(du -h "$TEST_PDF" | cut -f1)"
echo ""

# Extract 3 interior pages for faster testing
cp "$TEST_PDF" "$OCR_TMPDIR/bench_source.pdf"
gs -dNOPAUSE -dBATCH -dNOSAFER -sDEVICE=pdfwrite \
	-dFirstPage=20 -dLastPage=22 \
	"-sOutputFile=$OCR_TMPDIR/bench_3pages.pdf" \
	"$OCR_TMPDIR/bench_source.pdf" 2>/dev/null
echo "Extracted pages 20-22 for testing"
echo ""

# --- Test 1: OCR without preprocessing ---
echo "--- Without preprocessing (OCR only, 600 DPI) ---"
ocrmypdf --force-ocr --jobs 8 --oversample 600 \
	--output-type pdf --optimize 0 \
	--tesseract-config "$OCR_TMPDIR/tess_config" \
	--tesseract-timeout 120 \
	"$OCR_TMPDIR/bench_3pages.pdf" "$OCR_TMPDIR/bench_ocr_only.pdf" 2>/dev/null

text_without=$("$BINARY" extract "$OCR_TMPDIR/bench_ocr_only.pdf" 2>/dev/null)
words_without=$(echo "$text_without" | wc -w | tr -d ' ')
chars_without=${#text_without}
echo "Chars: $chars_without  Words: $words_without"
echo "Sample: $(echo "$text_without" | tr '\n' ' ' | head -c 200)"
echo ""

# --- Test 2: Preprocess THEN OCR ---
echo "--- With preprocessing (preprocess + OCR, 600 DPI) ---"
prep_path=$("$BINARY" preprocess "$OCR_TMPDIR/bench_3pages.pdf" 2>/dev/null)

ocrmypdf --force-ocr --jobs 8 --oversample 600 \
	--output-type pdf --optimize 0 \
	--tesseract-config "$OCR_TMPDIR/tess_config" \
	--tesseract-timeout 120 \
	"$prep_path" "$OCR_TMPDIR/bench_preprocessed_ocr.pdf" 2>/dev/null

text_with=$("$BINARY" extract "$OCR_TMPDIR/bench_preprocessed_ocr.pdf" 2>/dev/null)
words_with=$(echo "$text_with" | wc -w | tr -d ' ')
chars_with=${#text_with}
echo "Chars: $chars_with  Words: $words_with"
echo "Sample: $(echo "$text_with" | tr '\n' ' ' | head -c 200)"
echo ""

# --- Comparison ---
echo "=== Results ==="
echo "             Without    With Preprocessing"
echo "  Chars:     $chars_without          $chars_with"
echo "  Words:     $words_without          $words_with"

# Check for spaced-out noise (letter-space-letter pattern)
noise_without=$(echo "$text_without" | grep -oP '(\w ){5,}' | wc -l | tr -d ' ')
noise_with=$(echo "$text_with" | grep -oP '(\w ){5,}' | wc -l | tr -d ' ')
echo "  Noise lines (spaced-out letters): $noise_without → $noise_with"

echo ""
if [ "$noise_with" -lt "$noise_without" ]; then
	echo "IMPROVEMENT: Preprocessing reduced OCR noise"
else
	echo "NO CHANGE: Similar noise levels"
fi

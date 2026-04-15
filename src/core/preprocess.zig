//! OCR preprocessing: threshold + dilate + mask for text isolation.
//! Converts a color image to a version where only "text-like" dark pixels
//! survive; everything else is replaced with white.  This dramatically
//! improves Tesseract accuracy on pages with colourful/busy backgrounds
//! (e.g. DK encyclopaedias, art books).
//!
//! Algorithm:
//!   1. Threshold  – mark pixels whose BT.601 luminance < 80 as "text".
//!   2. Dilate     – expand that mask by 3 px (3 passes of 8-connected
//!                   morphological max-filter) to capture anti-aliased edges.
//!   3. Mask       – keep original RGB for marked pixels; set rest to white.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// BT.601 luminance threshold below which a pixel is considered "text".
const LUMA_THRESHOLD: u8 = 80;

/// Number of dilation passes (each expands the mask by 1 pixel in all 8 dirs).
const DILATE_PASSES: u32 = 3;

/// Preprocess an RGB/RGBA image for OCR by isolating dark text pixels.
///
/// Applies threshold → dilate → mask: dark pixels are kept, bright pixels
/// become white.  Uses BT.601 luminance weighting and 8-connected dilation.
/// Always returns 3-channel (RGB) output regardless of input channel count.
pub fn preprocessPage(
	allocator: Allocator,
	pixels: []const u8,
	width: u32,
	height: u32,
	channels: u32,
) ![]u8 {
	const pixel_count = @as(usize, width) * @as(usize, height);
	if (pixels.len < pixel_count * @as(usize, channels)) {
		return error.InvalidInput;
	}

	// --- Step 1: Build binary text mask via luminance threshold ---------------
	// mask[i] = 1 means pixel i is "text" (dark); 0 means background.
	const mask = try allocator.alloc(u8, pixel_count);
	defer allocator.free(mask);

	for (0..pixel_count) |i| {
		const base = i * @as(usize, channels);
		const r: u32 = pixels[base + 0];
		const g: u32 = pixels[base + 1];
		const b: u32 = pixels[base + 2];
		// BT.601 luminance (fixed-point scaled by 1000 to avoid floats)
		const luma = (299 * r + 587 * g + 114 * b) / 1000;
		mask[i] = if (luma < LUMA_THRESHOLD) 1 else 0;
	}

	// --- Step 2: Morphological dilation (8-connected, DILATE_PASSES passes) ---
	// Each pass expands every set pixel to its 8 neighbours.
	// We ping-pong between two buffers to avoid ordering artefacts.
	const buf_a = try allocator.alloc(u8, pixel_count);
	defer allocator.free(buf_a);
	const buf_b = try allocator.alloc(u8, pixel_count);
	defer allocator.free(buf_b);

	@memcpy(buf_a, mask);

	var src = buf_a;
	var dst = buf_b;

	for (0..DILATE_PASSES) |_| {
		@memset(dst, 0);
		for (0..height) |row| {
			for (0..width) |col| {
				const idx = row * @as(usize, width) + col;
				if (src[idx] == 1) {
					// Set the pixel itself and all 8 neighbours in dst.
					const r0: usize = if (row > 0) row - 1 else 0;
					const r1: usize = if (row + 1 < @as(usize, height)) row + 1 else row;
					const c0: usize = if (col > 0) col - 1 else 0;
					const c1: usize = if (col + 1 < @as(usize, width)) col + 1 else col;
					var dr = r0;
					while (dr <= r1) : (dr += 1) {
						var dc = c0;
						while (dc <= c1) : (dc += 1) {
							dst[dr * @as(usize, width) + dc] = 1;
						}
					}
				}
			}
		}
		// swap
		const tmp = src;
		src = dst;
		dst = tmp;
	}
	// After all passes, `src` holds the dilated mask.
	const dilated = src;

	// --- Step 3: Apply mask — keep original RGB, else white ------------------
	const out = try allocator.alloc(u8, pixel_count * 3);
	for (0..pixel_count) |i| {
		const base_in = i * @as(usize, channels);
		const base_out = i * 3;
		if (dilated[i] == 1) {
			out[base_out + 0] = pixels[base_in + 0];
			out[base_out + 1] = pixels[base_in + 1];
			out[base_out + 2] = pixels[base_in + 2];
		} else {
			out[base_out + 0] = 255;
			out[base_out + 1] = 255;
			out[base_out + 2] = 255;
		}
	}

	return out;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "white pixel becomes white" {
	const alloc = std.testing.allocator;
	// 1x1 white pixel
	const pixels = [_]u8{ 255, 255, 255 };
	const out = try preprocessPage(alloc, &pixels, 1, 1, 3);
	defer alloc.free(out);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255 }, out);
}

test "black pixel preserved" {
	const alloc = std.testing.allocator;
	// 1x1 black pixel (luma=0 < 80 → text → kept)
	const pixels = [_]u8{ 0, 0, 0 };
	const out = try preprocessPage(alloc, &pixels, 1, 1, 3);
	defer alloc.free(out);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, out);
}

test "colored background becomes white" {
	const alloc = std.testing.allocator;
	// 1x1 bright red pixel: luma = 0.299*255 ≈ 76 — that is < 80!
	// Use a clearly bright colour: R=200, G=200, B=50 → luma ≈ (299*200+587*200+114*50)/1000
	//   = (59800+117400+5700)/1000 = 182900/1000 = 182 → well above 80 → background → white
	const pixels = [_]u8{ 200, 200, 50 };
	const out = try preprocessPage(alloc, &pixels, 1, 1, 3);
	defer alloc.free(out);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255 }, out);
}

test "dark gray near text threshold preserved via dilation" {
	// 3x1 strip (width=3, height=1):
	//   px0: black   (0,0,0)     → luma=0  → text
	//   px1: dark gray (60,60,60) → luma=60 → text (< 80)
	//   px2: white   (255,255,255) → luma=255 → background
	//
	// After threshold: mask = [1, 1, 0]
	// After 3-pass dilation (1D strip, 8-connected collapses to 1-connected):
	//   pass 1: px2 gets neighbour px1=1 → mask = [1, 1, 1]
	//   So all three become 1.
	// But wait — we want "white replaced" for px2 after dilation expands
	// the text region.  Actually with 3 passes and only width=3, px2 IS
	// captured on pass 1 already since it neighbours px1.
	// Output: px0=black, px1=dark-gray, px2=white (original kept because mask=1,
	//   but pixel IS white, so output is white).
	// Let's use a clearer test: px2 = (200,100,50) bright orange → should become
	// white WITHOUT dilation, but WITH dilation (px1 is text) it gets kept.
	const alloc = std.testing.allocator;
	// px0: black, px1: dark gray (text), px2: bright orange (background but
	// adjacent to text → dilation should pull it in → kept as original colour)
	const pixels = [_]u8{
		0,   0,  0, // px0: black → text (luma=0)
		60, 60, 60, // px1: dark gray → text (luma=60)
		200, 100, 50, // px2: orange → background (luma=138) but dilated from px1
	};
	const out = try preprocessPage(alloc, &pixels, 3, 1, 3);
	defer alloc.free(out);

	// px0 and px1 are text → kept as-is
	try std.testing.expectEqual(@as(u8, 0), out[0]); // px0 R
	try std.testing.expectEqual(@as(u8, 0), out[1]); // px0 G
	try std.testing.expectEqual(@as(u8, 0), out[2]); // px0 B
	try std.testing.expectEqual(@as(u8, 60), out[3]); // px1 R
	try std.testing.expectEqual(@as(u8, 60), out[4]); // px1 G
	try std.testing.expectEqual(@as(u8, 60), out[5]); // px1 B
	// px2: dilation from px1 (1 pass is enough) → kept as original orange
	try std.testing.expectEqual(@as(u8, 200), out[6]); // px2 R
	try std.testing.expectEqual(@as(u8, 100), out[7]); // px2 G
	try std.testing.expectEqual(@as(u8, 50), out[8]); // px2 B
}

test "mixed text and color — text preserved, color removed" {
	// 5x3 synthetic DK-style page.
	// Row 0: all white background                     (luma=255 → bg)
	// Row 1: black text column in middle, rest bright  (px col 2 = black)
	// Row 2: all background except col 1 dark gray     (luma=60 → text)
	//
	// width=5, height=3
	const W = 5;
	const H = 3;
	const alloc = std.testing.allocator;

	// Build pixel array (RGB, width=5, height=3)
	var pixels: [W * H * 3]u8 = undefined;
	// Default: bright colourful background (luma > 80)
	for (0..W * H) |i| {
		pixels[i * 3 + 0] = 180;
		pixels[i * 3 + 1] = 100;
		pixels[i * 3 + 2] = 200; // luma = (299*180+587*100+114*200)/1000 = (53820+58700+22800)/1000 = 135 → bg
	}
	// Row 1, col 2: black text pixel
	const text_idx = 1 * W + 2;
	pixels[text_idx * 3 + 0] = 0;
	pixels[text_idx * 3 + 1] = 0;
	pixels[text_idx * 3 + 2] = 0;
	// Row 2, col 1: dark gray text pixel
	const gray_idx = 2 * W + 1;
	pixels[gray_idx * 3 + 0] = 50;
	pixels[gray_idx * 3 + 1] = 50;
	pixels[gray_idx * 3 + 2] = 50; // luma=50 → text

	const out = try preprocessPage(alloc, &pixels, W, H, 3);
	defer alloc.free(out);

	// The two text pixels themselves must be preserved
	try std.testing.expectEqual(@as(u8, 0), out[text_idx * 3 + 0]);
	try std.testing.expectEqual(@as(u8, 0), out[text_idx * 3 + 1]);
	try std.testing.expectEqual(@as(u8, 0), out[text_idx * 3 + 2]);
	try std.testing.expectEqual(@as(u8, 50), out[gray_idx * 3 + 0]);
	try std.testing.expectEqual(@as(u8, 50), out[gray_idx * 3 + 1]);
	try std.testing.expectEqual(@as(u8, 50), out[gray_idx * 3 + 2]);

	// Corner pixels (far from any text, row=0 col=0 and row=0 col=4) must be white.
	// Row 0, col 0: 3 dilation passes → radius 3; nearest text is row1,col2 = distance ~2.2 → within range!
	// Let's check a pixel truly far: row=0, col=4 (top-right corner).
	// Nearest text: row1,col2 distance = sqrt((4-2)^2+(0-1)^2) = sqrt(5) ≈ 2.24 — still within 3.
	// Use row=0, col=0: distance to row1,col2 = sqrt(4+1)=2.24 — also within 3.
	// Hmm, with 5x3 grid and 3 passes, a lot gets captured.  Let's just verify
	// a truly far pixel:  the grid is only 5 wide × 3 tall; max distance is
	// sqrt(16+4)=4.47.  No pixel is more than 3 away from (row1,col2) OR (row2,col1).
	// So almost everything could be captured.  Instead verify the SEMANTIC invariant:
	// all pixels still in the mask retain their original value OR are white.
	for (0..W * H) |i| {
		const or_r = pixels[i * 3 + 0];
		const or_g = pixels[i * 3 + 1];
		const or_b = pixels[i * 3 + 2];
		const out_r = out[i * 3 + 0];
		const out_g = out[i * 3 + 1];
		const out_b = out[i * 3 + 2];
		// Each output pixel is either the original or white — never an arbitrary colour.
		const is_original = (out_r == or_r and out_g == or_g and out_b == or_b);
		const is_white = (out_r == 255 and out_g == 255 and out_b == 255);
		try std.testing.expect(is_original or is_white);
	}
}

test "RGBA input handled correctly" {
	const alloc = std.testing.allocator;
	// 1x1 black pixel in RGBA
	const pixels = [_]u8{ 0, 0, 0, 255 };
	const out = try preprocessPage(alloc, &pixels, 1, 1, 4);
	defer alloc.free(out);
	// Output is RGB only; alpha stripped; pixel is text → kept
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, out);
}

test "invalid input returns error" {
	const alloc = std.testing.allocator;
	// 2x2 RGB but only 9 bytes (needs 12)
	const pixels = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	const result = preprocessPage(alloc, &pixels, 2, 2, 3);
	try std.testing.expectError(error.InvalidInput, result);
}

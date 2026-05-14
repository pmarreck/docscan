//! Gitignore-compatible pattern matcher for docscan.
//! Pure computation — no I/O. The CLI layer reads `.docscanignore` files
//! and feeds their contents here via `loadFromString`.

const std = @import("std");

/// A single ignore pattern parsed from a gitignore-style file.
/// Tracks negation (`!` prefix), directory-only matching (trailing `/`),
/// and whether the pattern is anchored (contains non-trailing `/`).
pub const Pattern = struct {
	glob: []const u8,
	is_negation: bool,
	is_dir_only: bool,
	is_anchored: bool,

	/// Dupes the glob string so the Pattern owns its memory.
	pub fn parse(allocator: std.mem.Allocator, raw_line: []const u8) !?Pattern {
		var line = raw_line;

		// Strip trailing whitespace
		while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t' or line[line.len - 1] == '\r')) {
			line = line[0 .. line.len - 1];
		}

		// Skip empty lines and comments
		if (line.len == 0) return null;
		if (line[0] == '#') return null;

		var is_negation = false;
		if (line[0] == '!') {
			is_negation = true;
			line = line[1..];
			if (line.len == 0) return null;
		}

		// Trailing / means dir-only
		var is_dir_only = false;
		if (line.len > 0 and line[line.len - 1] == '/') {
			is_dir_only = true;
			line = line[0 .. line.len - 1];
			if (line.len == 0) return null;
		}

		// Leading / means anchored; strip it from the glob
		var is_anchored = false;
		if (line.len > 0 and line[0] == '/') {
			is_anchored = true;
			line = line[1..];
			if (line.len == 0) return null;
		}

		// If the pattern contains a slash (not just trailing), it's anchored
		if (!is_anchored) {
			if (std.mem.indexOfScalar(u8, line, '/') != null) {
				is_anchored = true;
			}
		}

		const glob = try allocator.dupe(u8, line);
		return Pattern{
			.glob = glob,
			.is_negation = is_negation,
			.is_dir_only = is_dir_only,
			.is_anchored = is_anchored,
		};
	}
};

/// A list of gitignore-style patterns that can classify paths as ignored or not.
/// Patterns are processed in order — later patterns override earlier ones,
/// and negation patterns (`!`) un-ignore previously matched paths.
pub const IgnoreList = struct {
	patterns: std.ArrayListUnmanaged(Pattern) = .empty,
	allocator: std.mem.Allocator,

	pub fn init(allocator: std.mem.Allocator) IgnoreList {
		return .{
			.allocator = allocator,
		};
	}

	pub fn deinit(self: *IgnoreList) void {
		for (self.patterns.items) |p| {
			self.allocator.free(p.glob);
		}
		self.patterns.deinit(self.allocator);
	}

	/// Parse and add a single pattern line.
	pub fn addPattern(self: *IgnoreList, line: []const u8) !void {
		if (try Pattern.parse(self.allocator, line)) |p| {
			try self.patterns.append(self.allocator, p);
		}
	}

	/// Parse a multi-line string (e.g., contents of a .docscanignore file).
	pub fn loadFromString(self: *IgnoreList, content: []const u8) !void {
		var iter = std.mem.splitScalar(u8, content, '\n');
		while (iter.next()) |line| {
			try self.addPattern(line);
		}
	}

	/// Returns true if the given path should be ignored.
	pub fn isIgnored(self: *const IgnoreList, path: []const u8) bool {
		return self.isIgnoredEx(path, false);
	}

	/// Returns true if the given path should be ignored.
	/// `is_dir` indicates whether the path refers to a directory.
	pub fn isIgnoredEx(self: *const IgnoreList, path: []const u8, is_dir: bool) bool {
		// Normalize: strip leading ./
		var normalized = path;
		if (normalized.len >= 2 and normalized[0] == '.' and normalized[1] == '/') {
			normalized = normalized[2..];
		}

		var result = false;
		for (self.patterns.items) |p| {
			if (p.is_dir_only and !is_dir) {
				// Dir-only pattern against a file path: match if the file
				// is *inside* a directory that matches the pattern.
				if (matchesDirPrefix(p, normalized)) {
					result = !p.is_negation;
				}
				continue;
			}

			if (matchPattern(p, normalized)) {
				result = !p.is_negation;
			}
		}
		return result;
	}
};

/// Check if `path` starts with `dir_prefix/` or equals `dir_prefix`.
fn pathHasPrefix(path: []const u8, dir_prefix: []const u8) bool {
	if (path.len < dir_prefix.len) return false;
	if (!globMatch(dir_prefix, path[0..dir_prefix.len])) return false;
	if (path.len == dir_prefix.len) return true;
	return path[dir_prefix.len] == '/';
}

/// For dir-only patterns, check if the file path is inside a directory
/// that matches the pattern glob. For unanchored patterns, also try
/// matching against each directory component suffix.
fn matchesDirPrefix(p: Pattern, path: []const u8) bool {
	if (p.is_anchored) {
		return pathHasPrefix(path, p.glob);
	} else {
		// Try matching the prefix at each directory level
		// e.g., for "node_modules" against "src/node_modules/lib.js"
		// we try pathHasPrefix on "src/node_modules/lib.js" then "node_modules/lib.js"
		if (pathHasPrefix(path, p.glob)) return true;
		var i: usize = 0;
		while (i < path.len) : (i += 1) {
			if (path[i] == '/') {
				if (pathHasPrefix(path[i + 1 ..], p.glob)) return true;
			}
		}
		return false;
	}
}

/// Test whether a pattern matches a given path.
fn matchPattern(p: Pattern, path: []const u8) bool {
	if (p.is_anchored) {
		// Anchored: match against the full path
		return globMatch(p.glob, path);
	} else {
		// Unanchored: match against each path component suffix
		// e.g., "*.log" should match "a/b/debug.log" by matching "debug.log"
		// First try the full path
		if (globMatch(p.glob, path)) return true;
		// Then try against the basename
		if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
			return globMatch(p.glob, path[idx + 1 ..]);
		}
		return false;
	}
}

/// Gitignore-compatible glob matcher supporting `*`, `**`, and `?`.
/// `*` matches anything except `/`. `**` matches everything including `/`.
/// `?` matches any single character except `/`.
fn globMatch(pattern: []const u8, str: []const u8) bool {
	return globMatchInner(pattern, str, 0);
}

fn globMatchInner(pattern: []const u8, str: []const u8, depth: usize) bool {
	if (depth > 1000) return false; // guard against pathological patterns

	var pi: usize = 0;
	var si: usize = 0;

	while (pi < pattern.len) {
		if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
			// `**` — matches everything including `/`
			// Consume all consecutive `*`
			while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
			// If `**` is followed by `/`, skip the `/` too
			if (pi < pattern.len and pattern[pi] == '/') {
				pi += 1;
			}

			// If nothing left in pattern, match everything remaining
			if (pi >= pattern.len) return true;

			// Try matching the rest of the pattern at every position in str
			var i = si;
			while (i <= str.len) : (i += 1) {
				if (globMatchInner(pattern[pi..], str[i..], depth + 1)) return true;
			}
			return false;
		} else if (pattern[pi] == '*') {
			// `*` — match anything except `/`
			pi += 1;

			// If nothing left in pattern, succeed if no more `/` in str
			if (pi >= pattern.len) {
				return std.mem.indexOfScalar(u8, str[si..], '/') == null;
			}

			// Try matching rest of pattern at every non-`/` position
			var i = si;
			while (i <= str.len) : (i += 1) {
				if (globMatchInner(pattern[pi..], str[i..], depth + 1)) return true;
				if (i < str.len and str[i] == '/') break;
			}
			return false;
		} else if (pattern[pi] == '?') {
			// `?` — match any single character except `/`
			if (si >= str.len or str[si] == '/') return false;
			pi += 1;
			si += 1;
		} else {
			// Literal character
			if (si >= str.len or pattern[pi] != str[si]) return false;
			pi += 1;
			si += 1;
		}
	}

	return si >= str.len;
}

// ─────────────────────── Tests ───────────────────────

test "basic glob — *.log matches debug.log, not file.txt" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("*.log");

	// Classify a set of paths
	const paths = [_][]const u8{
		"debug.log",
		"error.log",
		"file.txt",
		"src/main.zig",
		"logs/app.log",
	};
	const expected = [_]bool{
		true, // debug.log
		true, // error.log
		false, // file.txt
		false, // src/main.zig
		true, // logs/app.log (basename matches)
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "directory pattern — node_modules/ matches files inside" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("node_modules/");

	const paths = [_][]const u8{
		"node_modules/foo.js",
		"node_modules/bar/baz.js",
		"src/node_modules/lib.js",
		"src/main.js",
	};
	const expected = [_]bool{
		true, // inside node_modules
		true, // nested inside node_modules
		true, // basename match for node_modules prefix
		false, // unrelated
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "negation — !important.pdf un-ignores" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("*.pdf");
	try ig.addPattern("!important.pdf");

	const paths = [_][]const u8{
		"random.pdf",
		"important.pdf",
		"docs/thesis.pdf",
		"readme.md",
	};
	const expected = [_]bool{
		true, // *.pdf matches
		false, // negated by !important.pdf
		true, // *.pdf matches
		false, // not a pdf
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "comments and blank lines are skipped" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.loadFromString(
		\\# This is a comment
		\\
		\\*.log
		\\# Another comment
		\\
	);

	try std.testing.expectEqual(true, ig.isIgnored("debug.log"));
	try std.testing.expectEqual(false, ig.isIgnored("file.txt"));
	try std.testing.expectEqual(@as(usize, 1), ig.patterns.items.len);
}

test "wildcard * matches single path component" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("src/*.zig");

	const paths = [_][]const u8{
		"src/main.zig",
		"src/lib.zig",
		"src/sub/deep.zig",
		"test/main.zig",
	};
	const expected = [_]bool{
		true,
		true,
		false, // * doesn't cross /
		false, // different prefix
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "double star ** matches across directories" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("**/test");

	const paths = [_][]const u8{
		"test",
		"a/test",
		"a/b/test",
		"a/b/c/test",
		"testing",
		"a/testing",
	};
	const expected = [_]bool{
		true,
		true,
		true,
		true,
		false,
		false,
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "classifier — full set classification" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.loadFromString(
		\\*.log
		\\*.tmp
		\\build/
		\\!build/keep.txt
		\\.DS_Store
	);

	const TestCase = struct { path: []const u8, is_dir: bool, expect: bool };
	const cases = [_]TestCase{
		.{ .path = "debug.log", .is_dir = false, .expect = true },
		.{ .path = "app.tmp", .is_dir = false, .expect = true },
		.{ .path = "build/output.bin", .is_dir = false, .expect = true },
		.{ .path = "build/keep.txt", .is_dir = false, .expect = false },
		.{ .path = ".DS_Store", .is_dir = false, .expect = true },
		.{ .path = "src/main.zig", .is_dir = false, .expect = false },
		.{ .path = "README.md", .is_dir = false, .expect = false },
		.{ .path = "src/.DS_Store", .is_dir = false, .expect = true },
		.{ .path = "docs/notes.txt", .is_dir = false, .expect = false },
	};

	for (cases) |tc| {
		try std.testing.expectEqual(tc.expect, ig.isIgnoredEx(tc.path, tc.is_dir));
	}
}

test "no patterns — nothing is ignored" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();

	try std.testing.expectEqual(false, ig.isIgnored("anything.txt"));
	try std.testing.expectEqual(false, ig.isIgnored("src/main.zig"));
	try std.testing.expectEqual(false, ig.isIgnored(".git/config"));
}

test "leading slash — /build matches root only" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("/build");

	const paths = [_][]const u8{
		"build",
		"build/output.o",
		"src/build",
		"src/build/file.o",
	};
	const expected = [_]bool{
		true, // root build
		false, // not exact match (build is a file path, not a dir pattern)
		false, // nested, anchored pattern shouldn't match
		false, // nested
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "extension matching — multiple binary extensions" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("*.exe");
	try ig.addPattern("*.dll");
	try ig.addPattern("*.so");

	const paths = [_][]const u8{
		"app.exe",
		"lib.dll",
		"libfoo.so",
		"app.exe.bak",
		"source.c",
		"deep/nested/lib.dll",
	};
	const expected = [_]bool{
		true,
		true,
		true,
		false,
		false,
		true,
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "question mark matches single non-slash character" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("file?.txt");

	const paths = [_][]const u8{
		"file1.txt",
		"fileA.txt",
		"file.txt",
		"file12.txt",
	};
	const expected = [_]bool{
		true,
		true,
		false, // ? requires exactly one char
		false, // ? matches exactly one char, not two
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "double star with suffix — **/foo/*.txt" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.addPattern("**/foo/*.txt");

	const paths = [_][]const u8{
		"foo/bar.txt",
		"a/foo/bar.txt",
		"a/b/foo/bar.txt",
		"foo/sub/bar.txt",
		"bar/baz.txt",
	};
	const expected = [_]bool{
		true,
		true,
		true,
		false, // * doesn't cross /
		false,
	};

	for (paths, 0..) |p, i| {
		try std.testing.expectEqual(expected[i], ig.isIgnored(p));
	}
}

test "loadFromString with carriage returns" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.loadFromString("*.log\r\n*.tmp\r\n");

	try std.testing.expectEqual(true, ig.isIgnored("test.log"));
	try std.testing.expectEqual(true, ig.isIgnored("test.tmp"));
	try std.testing.expectEqual(false, ig.isIgnored("test.txt"));
}

test "default ignore patterns parse without error" {
	var ig = IgnoreList.init(std.testing.allocator);
	defer ig.deinit();
	try ig.loadFromString(default_patterns);

	// Verify some known patterns work
	try std.testing.expectEqual(true, ig.isIgnored("node_modules/package.json"));
	try std.testing.expectEqual(true, ig.isIgnored("zig-out/bin/docscan"));
	try std.testing.expectEqual(true, ig.isIgnored("photo.png"));
	try std.testing.expectEqual(true, ig.isIgnored(".DS_Store"));
	try std.testing.expectEqual(true, ig.isIgnored("project/.vscode/settings.json"));
	try std.testing.expectEqual(false, ig.isIgnored("src/main.zig"));
	try std.testing.expectEqual(false, ig.isIgnored("README.md"));
}

/// Built-in default ignore patterns, equivalent to `.docscanignore.default`.
/// These are always loaded first; user patterns from `.docscanignore` override.
pub const default_patterns =
	\\# Version control
	\\.git/
	\\.jj/
	\\
	\\# Dependencies
	\\node_modules/
	\\__pycache__/
	\\.venv/
	\\vendor/
	\\
	\\# Build artifacts
	\\zig-out/
	\\zig-cache/
	\\target/
	\\build/
	\\dist/
	\\
	\\# Binary/image files
	\\*.exe
	\\*.dll
	\\*.so
	\\*.dylib
	\\*.o
	\\*.a
	\\*.png
	\\*.jpg
	\\*.jpeg
	\\*.gif
	\\*.ico
	\\*.svg
	\\*.mp3
	\\*.mp4
	\\*.wav
	\\*.zip
	\\*.tar
	\\*.gz
	\\*.7z
	\\*.rar
	\\
	\\# IDE
	\\.idea/
	\\.vscode/
	\\*.swp
	\\*.swo
	\\*~
	\\
	\\# OS files
	\\.DS_Store
	\\Thumbs.db
	\\
	\\# docscan's own index
	\\.docscan/
;

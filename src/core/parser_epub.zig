//! EPUB parser for docscan.
//! Extracts text with heading-aware section structure from .epub files.
//! An EPUB file is a ZIP archive containing XHTML content files organized
//! via an OPF package document. This module extracts the container XML,
//! reads the OPF manifest/spine, then processes each XHTML chapter in
//! reading order to build a hierarchical Document with heading-based sections.
//! Pure computation — no I/O. Receives byte slices, returns a Document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wordfix = @import("wordfix.zig");
const document = @import("document.zig");
const Document = document.Document;
const Section = document.Section;
const MetadataEntry = document.MetadataEntry;
const Format = document.Format;
const xml = @import("xml.zig");
const zip = @import("zip.zig");

/// A flat section before nesting is applied (same pattern as DOCX parser).
const FlatSection = struct {
	heading: ?[]const u8, // owned, must be freed
	level: u8,
	content_buf: std.ArrayList(u8),

	fn deinit(self: *FlatSection, gpa: Allocator) void {
		if (self.heading) |h| gpa.free(h);
		self.content_buf.deinit(gpa);
	}
};

/// Strip `<!DOCTYPE ...>` declarations from XHTML so our XML parser can handle it.
/// DOCTYPE declarations are not comments and would otherwise cause a parse error.
fn stripDoctype(gpa: Allocator, input: []const u8) ![]const u8 {
	// Fast path: no DOCTYPE present
	if (std.mem.indexOf(u8, input, "<!DOCTYPE") == null and
		std.mem.indexOf(u8, input, "<!doctype") == null)
	{
		return try gpa.dupe(u8, input);
	}

	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(gpa);

	var pos: usize = 0;
	while (pos < input.len) {
		// Check for <!DOCTYPE (case-insensitive first char after <!)
		if (pos + 9 <= input.len and input[pos] == '<' and input[pos + 1] == '!') {
			const rest = input[pos + 2 ..];
			if (rest.len >= 7 and (std.mem.startsWith(u8, rest, "DOCTYPE") or
				std.mem.startsWith(u8, rest, "doctype")))
			{
				// Skip to closing '>'
				var end = pos + 2;
				while (end < input.len and input[end] != '>') : (end += 1) {}
				if (end < input.len) end += 1; // skip the '>'
				pos = end;
				continue;
			}
		}
		try buf.append(gpa, input[pos]);
		pos += 1;
	}

	return try buf.toOwnedSlice(gpa);
}

/// Resolve a relative href against an OPF directory base path.
/// E.g., base="OEBPS/" + href="chapter1.xhtml" => "OEBPS/chapter1.xhtml"
/// E.g., base="" + href="chapter1.xhtml" => "chapter1.xhtml"
fn resolveHref(gpa: Allocator, base: []const u8, href: []const u8) ![]const u8 {
	if (base.len == 0) return try gpa.dupe(u8, href);
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(gpa);
	try buf.appendSlice(gpa, base);
	try buf.appendSlice(gpa, href);
	return try buf.toOwnedSlice(gpa);
}

/// Extract the directory portion of a path (everything up to and including the last '/').
/// Returns "" if there is no directory separator.
fn dirName(path: []const u8) []const u8 {
	if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
		return path[0 .. idx + 1];
	}
	return "";
}

/// Find a child element by tag name (first match), with namespace stripping.
/// Matches both "tag" and "ns:tag" against the given name.
fn findChild(node: xml.XmlNode, tag: []const u8) ?xml.XmlNode {
	for (node.children) |child| {
		if (std.mem.eql(u8, child.tag, tag)) return child;
		// Also try stripping namespace prefix
		if (std.mem.indexOfScalar(u8, child.tag, ':')) |colon| {
			if (std.mem.eql(u8, child.tag[colon + 1 ..], tag)) return child;
		}
	}
	return null;
}

/// Find a child element by local tag name, searching recursively.
fn findChildRecursive(node: xml.XmlNode, tag: []const u8) ?xml.XmlNode {
	for (node.children) |child| {
		if (tagMatches(child.tag, tag)) return child;
		if (findChildRecursive(child, tag)) |found| return found;
	}
	return null;
}

/// Check if a tag matches a local name, ignoring namespace prefix.
fn tagMatches(full_tag: []const u8, local: []const u8) bool {
	if (std.mem.eql(u8, full_tag, local)) return true;
	if (std.mem.indexOfScalar(u8, full_tag, ':')) |colon| {
		return std.mem.eql(u8, full_tag[colon + 1 ..], local);
	}
	return false;
}

/// Find all children matching a tag (with namespace stripping).
fn findChildren(gpa: Allocator, node: xml.XmlNode, tag: []const u8) ![]const xml.XmlNode {
	var result = std.ArrayList(xml.XmlNode).empty;
	errdefer result.deinit(gpa);
	for (node.children) |child| {
		if (tagMatches(child.tag, tag)) {
			try result.append(gpa, child);
		}
	}
	return try result.toOwnedSlice(gpa);
}

/// Parse the container.xml and return the full-path of the OPF rootfile.
fn parseContainerXml(gpa: Allocator, container_bytes: []const u8) ![]const u8 {
	const doc = try xml.parse(gpa, container_bytes);
	defer xml.freeXmlDoc(gpa, doc);

	const root = doc.root orelse return error.InvalidEpub;

	// Find <rootfiles> then <rootfile full-path="...">
	const rootfiles = findChildRecursive(root, "rootfiles") orelse return error.InvalidEpub;
	const rootfile = findChild(rootfiles, "rootfile") orelse
		findChildRecursive(rootfiles, "rootfile") orelse return error.InvalidEpub;
	const full_path = rootfile.getAttr("full-path") orelse return error.InvalidEpub;

	return try gpa.dupe(u8, full_path);
}

/// Manifest item: id -> href mapping.
const ManifestItem = struct {
	id: []const u8,
	href: []const u8,
};

/// Parse the OPF package document and extract metadata, manifest, and spine.
fn parseOpf(gpa: Allocator, opf_bytes: []const u8) !struct {
	metadata: []const MetadataEntry,
	title: ?[]const u8,
	manifest: []const ManifestItem,
	spine_order: []const []const u8, // list of idrefs
} {
	const cleaned = try stripDoctype(gpa, opf_bytes);
	defer gpa.free(cleaned);

	const doc = try xml.parse(gpa, cleaned);
	defer xml.freeXmlDoc(gpa, doc);

	const root = doc.root orelse return error.InvalidEpub;

	// --- Metadata ---
	var meta_entries = std.ArrayList(MetadataEntry).empty;
	errdefer {
		for (meta_entries.items) |e| {
			gpa.free(e.key);
			gpa.free(e.value);
		}
		meta_entries.deinit(gpa);
	}
	var title: ?[]const u8 = null;

	if (findChildRecursive(root, "metadata")) |metadata_node| {
		for (metadata_node.children) |child| {
			const key_name = mapEpubMetadata(child.tag) orelse continue;
			const value = child.text orelse continue;
			if (value.len == 0) continue;

			const key_copy = try gpa.dupe(u8, key_name);
			errdefer gpa.free(key_copy);
			const val_copy = try gpa.dupe(u8, value);
			errdefer gpa.free(val_copy);

			try meta_entries.append(gpa, MetadataEntry{
				.key = key_copy,
				.value = val_copy,
			});

			if (std.mem.eql(u8, key_name, "title") and title == null) {
				title = try gpa.dupe(u8, value);
			}
		}
	}

	// --- Manifest ---
	var manifest = std.ArrayList(ManifestItem).empty;
	errdefer {
		for (manifest.items) |m| {
			gpa.free(m.id);
			gpa.free(m.href);
		}
		manifest.deinit(gpa);
	}

	if (findChildRecursive(root, "manifest")) |manifest_node| {
		for (manifest_node.children) |child| {
			if (!tagMatches(child.tag, "item")) continue;
			const id = child.getAttr("id") orelse continue;
			const href = child.getAttr("href") orelse continue;
			try manifest.append(gpa, ManifestItem{
				.id = try gpa.dupe(u8, id),
				.href = try gpa.dupe(u8, href),
			});
		}
	}

	// --- Spine ---
	var spine_order = std.ArrayList([]const u8).empty;
	errdefer {
		for (spine_order.items) |s| gpa.free(s);
		spine_order.deinit(gpa);
	}

	if (findChildRecursive(root, "spine")) |spine_node| {
		for (spine_node.children) |child| {
			if (!tagMatches(child.tag, "itemref")) continue;
			const idref = child.getAttr("idref") orelse continue;
			try spine_order.append(gpa, try gpa.dupe(u8, idref));
		}
	}

	return .{
		.metadata = try meta_entries.toOwnedSlice(gpa),
		.title = title,
		.manifest = try manifest.toOwnedSlice(gpa),
		.spine_order = try spine_order.toOwnedSlice(gpa),
	};
}

/// Map EPUB/Dublin Core metadata tag names to simple keys.
fn mapEpubMetadata(tag: []const u8) ?[]const u8 {
	// Strip namespace prefix for matching
	const local = if (std.mem.indexOfScalar(u8, tag, ':')) |colon|
		tag[colon + 1 ..]
	else
		tag;

	if (std.mem.eql(u8, local, "title")) return "title";
	if (std.mem.eql(u8, local, "creator")) return "author";
	if (std.mem.eql(u8, local, "language")) return "language";
	if (std.mem.eql(u8, local, "date")) return "date";
	if (std.mem.eql(u8, local, "subject")) return "subject";
	if (std.mem.eql(u8, local, "description")) return "description";
	if (std.mem.eql(u8, local, "publisher")) return "publisher";
	if (std.mem.eql(u8, local, "identifier")) return "identifier";
	return null;
}

/// Set of tags whose content should be skipped entirely.
const skip_tags = [_][]const u8{ "script", "style", "head", "nav", "svg", "math" };

fn shouldSkip(tag: []const u8) bool {
	const local = if (std.mem.indexOfScalar(u8, tag, ':')) |colon|
		tag[colon + 1 ..]
	else
		tag;
	for (skip_tags) |s| {
		if (std.mem.eql(u8, local, s)) return true;
	}
	return false;
}

/// Block-level elements that should produce a newline after their content.
const block_tags = [_][]const u8{
	"p", "div", "blockquote", "pre", "li", "ol", "ul", "dl", "dt", "dd",
	"table", "tr", "section", "article", "aside", "header", "footer", "figcaption",
	"figure",
};

fn isBlockTag(tag: []const u8) bool {
	const local = if (std.mem.indexOfScalar(u8, tag, ':')) |colon|
		tag[colon + 1 ..]
	else
		tag;
	for (block_tags) |b| {
		if (std.mem.eql(u8, local, b)) return true;
	}
	// h1-h6 are also block-level
	if (local.len == 2 and local[0] == 'h' and local[1] >= '1' and local[1] <= '6') return true;
	return false;
}

/// Check if a tag is h1-h6 and return the level (1-6).
fn headingLevel(tag: []const u8) ?u8 {
	const local = if (std.mem.indexOfScalar(u8, tag, ':')) |colon|
		tag[colon + 1 ..]
	else
		tag;
	if (local.len == 2 and local[0] == 'h' and local[1] >= '1' and local[1] <= '6') {
		return local[1] - '0';
	}
	return null;
}

/// Extract text from an XHTML XML tree, building flat sections based on heading detection.
/// Appends to the given flat_sections list.
fn extractXhtmlContent(
	gpa: Allocator,
	node: xml.XmlNode,
	flat_sections: *std.ArrayList(FlatSection),
	current_idx: *?usize,
) !void {
	if (shouldSkip(node.tag)) return;

	// Check for heading
	if (headingLevel(node.tag)) |level| {
		// Extract all text from this heading element
		const heading_text = try collectText(gpa, node);
		if (heading_text.len > 0) {
			try flat_sections.append(gpa, FlatSection{
				.heading = heading_text,
				.level = level,
				.content_buf = .empty,
			});
			current_idx.* = flat_sections.items.len - 1;
		} else {
			gpa.free(heading_text);
		}
		return; // Don't recurse into heading children again
	}

	// Check for <br> / <br/> — add a newline
	const local_tag = if (std.mem.indexOfScalar(u8, node.tag, ':')) |colon|
		node.tag[colon + 1 ..]
	else
		node.tag;
	if (std.mem.eql(u8, local_tag, "br")) {
		if (current_idx.*) |idx| {
			try flat_sections.items[idx].content_buf.append(gpa, '\n');
		}
		return;
	}

	// Process text content (skip whitespace-only text nodes)
	if (node.text) |text| {
		const trimmed = std.mem.trim(u8, text, " \t\n\r");
		if (trimmed.len > 0) {
			if (current_idx.* == null) {
				// No section yet — create an untitled root section
				try flat_sections.append(gpa, FlatSection{
					.heading = null,
					.level = 0,
					.content_buf = .empty,
				});
				current_idx.* = flat_sections.items.len - 1;
			}
			const fs = &flat_sections.items[current_idx.*.?];
			try fs.content_buf.appendSlice(gpa, text);
		}
	}

	// Recurse into children
	for (node.children) |child| {
		try extractXhtmlContent(gpa, child, flat_sections, current_idx);
	}

	// Add newline after block elements (if we have content)
	if (isBlockTag(node.tag)) {
		if (current_idx.*) |idx| {
			const fs = &flat_sections.items[idx];
			if (fs.content_buf.items.len > 0) {
				// Don't double up newlines
				if (fs.content_buf.items[fs.content_buf.items.len - 1] != '\n') {
					try fs.content_buf.append(gpa, '\n');
				}
			}
		}
	}
}

/// Recursively collect all text from a node and its children.
fn collectText(gpa: Allocator, node: xml.XmlNode) ![]const u8 {
	var buf = std.ArrayList(u8).empty;
	errdefer buf.deinit(gpa);

	if (node.text) |text| {
		try buf.appendSlice(gpa, text);
	}
	for (node.children) |child| {
		const child_text = try collectText(gpa, child);
		defer gpa.free(child_text);
		try buf.appendSlice(gpa, child_text);
	}

	return try buf.toOwnedSlice(gpa);
}

/// Recursively build nested Section tree from flat sections (same as DOCX parser).
fn buildTree(
	gpa: Allocator,
	flat: []const FlatSection,
	start: usize,
	end: usize,
) ![]const Section {
	var sections: std.ArrayList(Section) = .empty;
	errdefer {
		for (sections.items) |s| freeSectionContents(gpa, s);
		sections.deinit(gpa);
	}

	var i = start;
	while (i < end) {
		const fs = &flat[i];
		const content = try gpa.dupe(u8, fs.content_buf.items);
		errdefer gpa.free(content);

		const heading_dupe: ?[]const u8 = if (fs.heading) |h| try gpa.dupe(u8, h) else null;
		errdefer if (heading_dupe) |h| gpa.free(h);

		// Find range of children: consecutive sections with level > fs.level.
		// Root sections (heading=null, level=0) never absorb children.
		const child_start = i + 1;
		var child_end = child_start;
		if (fs.heading != null) {
			while (child_end < end) {
				if (flat[child_end].level <= fs.level) break;
				child_end += 1;
			}
		}

		const children = try buildTree(gpa, flat, child_start, child_end);
		errdefer {
			for (children) |c| freeSectionContents(gpa, c);
			gpa.free(children);
		}

		try sections.append(gpa, Section{
			.heading = heading_dupe,
			.level = fs.level,
			.content = content,
			.children = children,
		});

		i = child_end;
	}

	return try sections.toOwnedSlice(gpa);
}

/// Free the contents of a single Section recursively.
fn freeSectionContents(gpa: Allocator, section: Section) void {
	for (section.children) |child| {
		freeSectionContents(gpa, child);
	}
	if (section.children.len > 0) {
		gpa.free(section.children);
	}
	if (section.heading) |h| {
		gpa.free(h);
	}
	if (section.content.len > 0) {
		gpa.free(section.content);
	}
}

/// Look up a manifest href by idref.
fn lookupHref(manifest: []const ManifestItem, idref: []const u8) ?[]const u8 {
	for (manifest) |item| {
		if (std.mem.eql(u8, item.id, idref)) return item.href;
	}
	return null;
}

/// Parse an EPUB file (as a byte slice of the ZIP archive) into a Document.
/// Caller owns the returned Document; free with `freeDocument`.
pub fn parse(gpa: Allocator, content: []const u8, path: []const u8) !Document {
	// Step 1: Extract META-INF/container.xml
	const container_xml = (zip.extractEntry(gpa, content, "META-INF/container.xml") catch
		return emptyDocument(gpa, path)) orelse
		return emptyDocument(gpa, path);
	defer gpa.free(container_xml);

	// Step 2: Parse container.xml to find OPF path
	const opf_path = parseContainerXml(gpa, container_xml) catch
		return emptyDocument(gpa, path);
	defer gpa.free(opf_path);

	// Step 3: Extract OPF file
	const opf_xml = (try zip.extractEntry(gpa, content, opf_path)) orelse
		return emptyDocument(gpa, path);
	defer gpa.free(opf_xml);

	// Step 4: Parse OPF
	const opf = parseOpf(gpa, opf_xml) catch
		return emptyDocument(gpa, path);
	defer {
		for (opf.metadata) |m| {
			gpa.free(m.key);
			gpa.free(m.value);
		}
		gpa.free(opf.metadata);
		if (opf.title) |t| gpa.free(t);
		for (opf.manifest) |m| {
			gpa.free(m.id);
			gpa.free(m.href);
		}
		gpa.free(opf.manifest);
		for (opf.spine_order) |s| gpa.free(s);
		gpa.free(opf.spine_order);
	}

	// Base directory of the OPF file
	const opf_base = dirName(opf_path);

	// Step 5: Process each spine item
	var flat_sections = std.ArrayList(FlatSection).empty;
	defer {
		for (flat_sections.items) |*fs| fs.deinit(gpa);
		flat_sections.deinit(gpa);
	}

	var current_idx: ?usize = null;

	for (opf.spine_order) |idref| {
		const href = lookupHref(opf.manifest, idref) orelse continue;
		const full_path = try resolveHref(gpa, opf_base, href);
		defer gpa.free(full_path);

		const xhtml_bytes = (try zip.extractEntry(gpa, content, full_path)) orelse continue;
		defer gpa.free(xhtml_bytes);

		// Strip DOCTYPE before parsing
		const cleaned = try stripDoctype(gpa, xhtml_bytes);
		defer gpa.free(cleaned);

		const xml_doc = xml.parse(gpa, cleaned) catch continue;
		defer xml.freeXmlDoc(gpa, xml_doc);

		if (xml_doc.root) |root| {
			// Find <body> element (possibly nested under <html>)
			const body = findChildRecursive(root, "body") orelse root;
			try extractXhtmlContent(gpa, body, &flat_sections, &current_idx);
		}
	}

	// Step 6: Build hierarchical section tree
	const sections = if (flat_sections.items.len > 0)
		try buildTree(gpa, flat_sections.items, 0, flat_sections.items.len)
	else
		try gpa.alloc(Section, 0);
	errdefer {
		for (sections) |s| freeSectionContents(gpa, s);
		if (sections.len > 0) gpa.free(sections);
	}

	// Re-duplicate metadata for the Document (OPF metadata will be freed by defer above)
	var doc_metadata = std.ArrayList(MetadataEntry).empty;
	errdefer {
		for (doc_metadata.items) |m| {
			gpa.free(m.key);
			gpa.free(m.value);
		}
		doc_metadata.deinit(gpa);
	}
	for (opf.metadata) |m| {
		try doc_metadata.append(gpa, MetadataEntry{
			.key = try gpa.dupe(u8, m.key),
			.value = try gpa.dupe(u8, m.value),
		});
	}

	// Determine title
	var title: ?[]const u8 = if (opf.title) |t| try gpa.dupe(u8, t) else null;
	if (title == null) {
		// Fall back to first heading
		for (flat_sections.items) |fs| {
			if (fs.level >= 1 and fs.heading != null) {
				title = try gpa.dupe(u8, fs.heading.?);
				break;
			}
		}
	}

	// Normalize extracted text
	wordfix.applySections(gpa, sections);

	const path_dupe = try gpa.dupe(u8, path);

	return Document{
		.path = path_dupe,
		.format = .epub,
		.title = title,
		.metadata = try doc_metadata.toOwnedSlice(gpa),
		.sections = sections,
	};
}

/// Return an empty document for graceful degradation.
fn emptyDocument(gpa: Allocator, path: []const u8) !Document {
	return Document{
		.path = try gpa.dupe(u8, path),
		.format = .epub,
		.title = null,
		.metadata = try gpa.alloc(MetadataEntry, 0),
		.sections = try gpa.alloc(Section, 0),
	};
}

/// Recursively free all memory owned by a Document returned from `parse`.
pub fn freeDocument(gpa: Allocator, doc: Document) void {
	for (doc.sections) |section| {
		freeSectionContents(gpa, section);
	}
	if (doc.sections.len > 0) {
		gpa.free(doc.sections);
	}
	if (doc.title) |t| {
		gpa.free(t);
	}
	for (doc.metadata) |m| {
		gpa.free(m.key);
		gpa.free(m.value);
	}
	gpa.free(doc.metadata);
	gpa.free(doc.path);
}

// ── Test helpers ─────────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal EPUB ZIP archive for testing.
fn buildTestEpub(
	gpa: Allocator,
	chapters: []const struct { name: []const u8, content: []const u8 },
	opf_metadata: ?[]const u8,
	opf_dir: ?[]const u8,
) ![]const u8 {
	const base = opf_dir orelse "";

	// Build manifest items and spine itemrefs
	var manifest_buf = std.ArrayList(u8).empty;
	defer manifest_buf.deinit(gpa);
	var spine_buf = std.ArrayList(u8).empty;
	defer spine_buf.deinit(gpa);

	for (chapters, 0..) |ch, idx| {
		// manifest item
		try manifest_buf.appendSlice(gpa, "<item id=\"ch");
		var id_buf: [16]u8 = undefined;
		const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{idx});
		try manifest_buf.appendSlice(gpa, id_str);
		try manifest_buf.appendSlice(gpa, "\" href=\"");
		try manifest_buf.appendSlice(gpa, ch.name);
		try manifest_buf.appendSlice(gpa, "\" media-type=\"application/xhtml+xml\"/>\n");

		// spine itemref
		try spine_buf.appendSlice(gpa, "<itemref idref=\"ch");
		try spine_buf.appendSlice(gpa, id_str);
		try spine_buf.appendSlice(gpa, "\"/>\n");
	}

	// Build OPF content
	var opf_buf = std.ArrayList(u8).empty;
	defer opf_buf.deinit(gpa);
	try opf_buf.appendSlice(gpa,
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
		\\<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
		\\
	);
	if (opf_metadata) |meta| {
		try opf_buf.appendSlice(gpa, meta);
	}
	try opf_buf.appendSlice(gpa, "</metadata>\n<manifest>\n");
	try opf_buf.appendSlice(gpa, manifest_buf.items);
	try opf_buf.appendSlice(gpa, "</manifest>\n<spine>\n");
	try opf_buf.appendSlice(gpa, spine_buf.items);
	try opf_buf.appendSlice(gpa, "</spine>\n</package>\n");

	// Build OPF path
	var opf_path_buf = std.ArrayList(u8).empty;
	defer opf_path_buf.deinit(gpa);
	try opf_path_buf.appendSlice(gpa, base);
	try opf_path_buf.appendSlice(gpa, "content.opf");

	// Build container.xml
	var container_buf = std.ArrayList(u8).empty;
	defer container_buf.deinit(gpa);
	try container_buf.appendSlice(gpa,
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
		\\<rootfiles>
		\\<rootfile full-path="
	);
	try container_buf.appendSlice(gpa, opf_path_buf.items);
	try container_buf.appendSlice(gpa,
		\\" media-type="application/oebps-package+xml"/>
		\\</rootfiles>
		\\</container>
	);

	// Count entries: mimetype + container.xml + opf + chapters
	const num_entries = 3 + chapters.len;
	var entries = std.ArrayList(zip.TestEntry).empty;
	defer entries.deinit(gpa);

	// mimetype must be first
	try entries.append(gpa, .{
		.name = "mimetype",
		.data = "application/epub+zip",
	});

	try entries.append(gpa, .{
		.name = "META-INF/container.xml",
		.data = container_buf.items,
	});

	try entries.append(gpa, .{
		.name = opf_path_buf.items,
		.data = opf_buf.items,
	});

	// Chapters need full paths
	var chapter_paths = std.ArrayList([]const u8).empty;
	defer {
		for (chapter_paths.items) |p| gpa.free(p);
		chapter_paths.deinit(gpa);
	}

	for (chapters) |ch| {
		const full_path = try resolveHref(gpa, base, ch.name);
		try chapter_paths.append(gpa, full_path);
	}

	for (chapters, 0..) |ch, idx| {
		try entries.append(gpa, .{
			.name = chapter_paths.items[idx],
			.data = ch.content,
		});
	}

	_ = num_entries;
	return try zip.buildTestZip(gpa, entries.items);
}

// ── Tests ────────────────────────────────────────────────────────────

test "basic text extraction from EPUB" {
	const chapter =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<head><title>Test</title></head>
		\\<body>
		\\<p>Hello, EPUB world!</p>
		\\</body>
		\\</html>
	;

	const epub = try buildTestEpub(testing.allocator, &.{
		.{ .name = "chapter1.xhtml", .content = chapter },
	}, null, null);
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/basic.epub");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(Format.epub, doc.format);
	try testing.expectEqualStrings("/test/basic.epub", doc.path);
	try testing.expect(doc.sections.len >= 1);

	// Check that text was extracted
	var found_text = false;
	for (doc.sections) |section| {
		if (std.mem.indexOf(u8, section.content, "Hello, EPUB world!") != null) {
			found_text = true;
			break;
		}
	}
	try testing.expect(found_text);
}

test "heading detection in EPUB" {
	const chapter =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body>
		\\<h1>Chapter One</h1>
		\\<p>First chapter content.</p>
		\\<h2>Section 1.1</h2>
		\\<p>Subsection content.</p>
		\\</body>
		\\</html>
	;

	const epub = try buildTestEpub(testing.allocator, &.{
		.{ .name = "chapter1.xhtml", .content = chapter },
	}, null, null);
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/headings.epub");
	defer freeDocument(testing.allocator, doc);

	// Should have a top-level section for h1
	try testing.expect(doc.sections.len >= 1);
	try testing.expectEqualStrings("Chapter One", doc.sections[0].heading.?);
	try testing.expectEqual(@as(u8, 1), doc.sections[0].level);

	// h2 should be nested as a child
	try testing.expectEqual(@as(usize, 1), doc.sections[0].children.len);
	try testing.expectEqualStrings("Section 1.1", doc.sections[0].children[0].heading.?);
	try testing.expectEqual(@as(u8, 2), doc.sections[0].children[0].level);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].children[0].content, "Subsection content.") != null);
}

test "multi-chapter EPUB" {
	const ch1 =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body>
		\\<h1>Chapter 1</h1>
		\\<p>First chapter.</p>
		\\</body>
		\\</html>
	;
	const ch2 =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body>
		\\<h1>Chapter 2</h1>
		\\<p>Second chapter.</p>
		\\</body>
		\\</html>
	;
	const ch3 =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body>
		\\<h1>Chapter 3</h1>
		\\<p>Third chapter.</p>
		\\</body>
		\\</html>
	;

	const epub = try buildTestEpub(testing.allocator, &.{
		.{ .name = "ch1.xhtml", .content = ch1 },
		.{ .name = "ch2.xhtml", .content = ch2 },
		.{ .name = "ch3.xhtml", .content = ch3 },
	}, null, null);
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/multi.epub");
	defer freeDocument(testing.allocator, doc);

	// All three chapters should be extracted in order
	try testing.expectEqual(@as(usize, 3), doc.sections.len);
	try testing.expectEqualStrings("Chapter 1", doc.sections[0].heading.?);
	try testing.expectEqualStrings("Chapter 2", doc.sections[1].heading.?);
	try testing.expectEqualStrings("Chapter 3", doc.sections[2].heading.?);

	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "First chapter.") != null);
	try testing.expect(std.mem.indexOf(u8, doc.sections[1].content, "Second chapter.") != null);
	try testing.expect(std.mem.indexOf(u8, doc.sections[2].content, "Third chapter.") != null);
}

test "metadata extraction from EPUB" {
	const chapter =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body><p>Content.</p></body>
		\\</html>
	;

	const metadata =
		\\<dc:title>My Great Novel</dc:title>
		\\<dc:creator>Jane Author</dc:creator>
		\\<dc:language>en</dc:language>
		\\<dc:date>2026-01-15</dc:date>
	;

	const epub = try buildTestEpub(testing.allocator, &.{
		.{ .name = "chapter1.xhtml", .content = chapter },
	}, metadata, null);
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/meta.epub");
	defer freeDocument(testing.allocator, doc);

	// Title from metadata
	try testing.expectEqualStrings("My Great Novel", doc.title.?);

	// Check metadata entries
	var found_author = false;
	var found_language = false;
	var found_date = false;
	for (doc.metadata) |m| {
		if (std.mem.eql(u8, m.key, "author")) {
			try testing.expectEqualStrings("Jane Author", m.value);
			found_author = true;
		}
		if (std.mem.eql(u8, m.key, "language")) {
			try testing.expectEqualStrings("en", m.value);
			found_language = true;
		}
		if (std.mem.eql(u8, m.key, "date")) {
			try testing.expectEqualStrings("2026-01-15", m.value);
			found_date = true;
		}
	}
	try testing.expect(found_author);
	try testing.expect(found_language);
	try testing.expect(found_date);
}

test "empty EPUB (no chapters)" {
	const epub = try buildTestEpub(testing.allocator, &.{}, null, null);
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/empty.epub");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(@as(?[]const u8, null), doc.title);
}

test "invalid input returns empty document" {
	const doc = try parse(testing.allocator, "not a zip file at all", "/test/bad.epub");
	defer freeDocument(testing.allocator, doc);

	try testing.expectEqual(@as(usize, 0), doc.sections.len);
	try testing.expectEqual(Format.epub, doc.format);
	try testing.expectEqualStrings("/test/bad.epub", doc.path);
}

test "EPUB with OPF in subdirectory" {
	const chapter =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body>
		\\<h1>Intro</h1>
		\\<p>Content from subdirectory EPUB.</p>
		\\</body>
		\\</html>
	;

	const epub = try buildTestEpub(testing.allocator, &.{
		.{ .name = "chapter1.xhtml", .content = chapter },
	}, null, "OEBPS/");
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/subdir.epub");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len >= 1);
	try testing.expectEqualStrings("Intro", doc.sections[0].heading.?);
	try testing.expect(std.mem.indexOf(u8, doc.sections[0].content, "Content from subdirectory EPUB.") != null);
}

test "EPUB skips script and style content" {
	const chapter =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body>
		\\<p>Visible text.</p>
		\\<script>var x = 1;</script>
		\\<style>.foo { color: red; }</style>
		\\<p>More visible text.</p>
		\\</body>
		\\</html>
	;

	const epub = try buildTestEpub(testing.allocator, &.{
		.{ .name = "chapter1.xhtml", .content = chapter },
	}, null, null);
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/scripts.epub");
	defer freeDocument(testing.allocator, doc);

	try testing.expect(doc.sections.len >= 1);

	// Check visible text present, script/style absent
	const content = doc.sections[0].content;
	try testing.expect(std.mem.indexOf(u8, content, "Visible text.") != null);
	try testing.expect(std.mem.indexOf(u8, content, "More visible text.") != null);
	try testing.expect(std.mem.indexOf(u8, content, "var x = 1") == null);
	try testing.expect(std.mem.indexOf(u8, content, "color: red") == null);
}

test "EPUB title falls back to first heading" {
	const chapter =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<html xmlns="http://www.w3.org/1999/xhtml">
		\\<body>
		\\<h1>The First Heading</h1>
		\\<p>Some content.</p>
		\\</body>
		\\</html>
	;

	const epub = try buildTestEpub(testing.allocator, &.{
		.{ .name = "chapter1.xhtml", .content = chapter },
	}, null, null);
	defer testing.allocator.free(epub);

	const doc = try parse(testing.allocator, epub, "/test/fallback.epub");
	defer freeDocument(testing.allocator, doc);

	// No metadata title, should fall back to first heading
	try testing.expectEqualStrings("The First Heading", doc.title.?);
}

test "stripDoctype removes DOCTYPE declarations" {
	const input = "<?xml version=\"1.0\"?><!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\"><html><body>text</body></html>";
	const result = try stripDoctype(testing.allocator, input);
	defer testing.allocator.free(result);

	try testing.expect(std.mem.indexOf(u8, result, "DOCTYPE") == null);
	try testing.expect(std.mem.indexOf(u8, result, "<html>") != null);
	try testing.expect(std.mem.indexOf(u8, result, "text") != null);
}

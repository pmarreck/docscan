//! Minimal XML parser for docscan DOCX support.
//! Parses the subset of XML used in DOCX `word/document.xml` files:
//! namespaced elements/attributes, self-closing tags, basic entities.
//! Pure computation — no I/O. Receives byte slices, returns an XmlDoc tree.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attribute = struct {
	name: []const u8, // e.g. "w:val"
	value: []const u8, // e.g. "Heading1"
};

pub const XmlNode = struct {
	tag: []const u8, // e.g. "w:p"
	attributes: []const Attribute,
	children: []const XmlNode,
	text: ?[]const u8, // text content (null if element-only)

	/// Helper: get attribute value by name.
	pub fn getAttr(self: XmlNode, name: []const u8) ?[]const u8 {
		for (self.attributes) |attr| {
			if (std.mem.eql(u8, attr.name, name)) return attr.value;
		}
		return null;
	}
};

pub const XmlDoc = struct {
	root: ?XmlNode,
};

pub const ParseError = error{
	UnexpectedEof,
	MalformedTag,
	MismatchedClosingTag,
	InvalidEntity,
};

/// Parse XML input into an XmlDoc tree.
/// All strings are allocated via the provided allocator; free with `freeXmlDoc`.
pub fn parse(allocator: Allocator, input: []const u8) !XmlDoc {
	var parser = Parser{
		.input = input,
		.pos = 0,
		.allocator = allocator,
	};
	parser.skipDeclaration();
	parser.skipWhitespace();
	if (parser.pos >= parser.input.len) {
		return XmlDoc{ .root = null };
	}
	const root = try parser.parseElement();
	return XmlDoc{ .root = root };
}

/// Recursively free all memory owned by an XmlDoc returned from `parse`.
pub fn freeXmlDoc(allocator: Allocator, doc: XmlDoc) void {
	if (doc.root) |root| {
		freeNode(allocator, root);
	}
}

fn freeNode(allocator: Allocator, node: XmlNode) void {
	allocator.free(node.tag);
	for (node.attributes) |attr| {
		allocator.free(attr.name);
		allocator.free(attr.value);
	}
	if (node.attributes.len > 0) {
		allocator.free(node.attributes);
	}
	for (node.children) |child| {
		freeNode(allocator, child);
	}
	if (node.children.len > 0) {
		allocator.free(node.children);
	}
	if (node.text) |t| {
		allocator.free(t);
	}
}

const Parser = struct {
	input: []const u8,
	pos: usize,
	allocator: Allocator,

	fn peek(self: *Parser) ?u8 {
		if (self.pos < self.input.len) return self.input[self.pos];
		return null;
	}

	fn advance(self: *Parser) ?u8 {
		if (self.pos < self.input.len) {
			const c = self.input[self.pos];
			self.pos += 1;
			return c;
		}
		return null;
	}

	fn skipWhitespace(self: *Parser) void {
		while (self.pos < self.input.len) {
			const c = self.input[self.pos];
			if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
				self.pos += 1;
			} else break;
		}
	}

	/// Skip `<?xml ... ?>` declaration if present.
	fn skipDeclaration(self: *Parser) void {
		self.skipWhitespace();
		if (self.pos + 1 < self.input.len and
			self.input[self.pos] == '<' and self.input[self.pos + 1] == '?')
		{
			// Skip to ?>
			while (self.pos + 1 < self.input.len) {
				if (self.input[self.pos] == '?' and self.input[self.pos + 1] == '>') {
					self.pos += 2;
					return;
				}
				self.pos += 1;
			}
		}
	}

	/// Skip `<!-- ... -->` comment if present. Returns true if a comment was skipped.
	fn skipComment(self: *Parser) bool {
		if (self.pos + 3 < self.input.len and
			self.input[self.pos] == '<' and
			self.input[self.pos + 1] == '!' and
			self.input[self.pos + 2] == '-' and
			self.input[self.pos + 3] == '-')
		{
			self.pos += 4;
			while (self.pos + 2 < self.input.len) {
				if (self.input[self.pos] == '-' and
					self.input[self.pos + 1] == '-' and
					self.input[self.pos + 2] == '>')
				{
					self.pos += 3;
					return true;
				}
				self.pos += 1;
			}
			// If we get here, we ran off the end without finding -->
			// Consume remaining as part of the comment
			self.pos = self.input.len;
			return true;
		}
		return false;
	}

	/// Parse a tag name: sequence of non-whitespace, non-special chars.
	/// Colons are allowed for namespace prefixes (e.g. "w:p").
	fn parseTagName(self: *Parser) ![]const u8 {
		const start = self.pos;
		while (self.pos < self.input.len) {
			const c = self.input[self.pos];
			if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
				c == '>' or c == '/' or c == '=')
			{
				break;
			}
			self.pos += 1;
		}
		if (self.pos == start) return ParseError.MalformedTag;
		return self.allocator.dupe(u8, self.input[start..self.pos]);
	}

	/// Parse a quoted attribute value, decoding XML entities.
	fn parseAttrValue(self: *Parser) ![]const u8 {
		const quote = self.advance() orelse return ParseError.UnexpectedEof;
		if (quote != '"' and quote != '\'') return ParseError.MalformedTag;
		return self.decodeUntil(quote);
	}

	/// Decode text content until a terminator char, handling XML entities.
	fn decodeUntil(self: *Parser, terminator: u8) ![]const u8 {
		var buf: std.ArrayList(u8) = .{};
		errdefer buf.deinit(self.allocator);

		while (self.pos < self.input.len) {
			const c = self.input[self.pos];
			if (c == terminator) {
				self.pos += 1; // consume terminator
				return buf.toOwnedSlice(self.allocator);
			}
			if (c == '&') {
				const decoded = try self.decodeEntity();
				try buf.append(self.allocator, decoded);
			} else {
				try buf.append(self.allocator, c);
				self.pos += 1;
			}
		}
		return ParseError.UnexpectedEof;
	}

	/// Decode a single XML entity starting at '&'.
	fn decodeEntity(self: *Parser) !u8 {
		std.debug.assert(self.input[self.pos] == '&');
		self.pos += 1; // skip '&'
		const start = self.pos;
		while (self.pos < self.input.len and self.input[self.pos] != ';') {
			self.pos += 1;
		}
		if (self.pos >= self.input.len) return ParseError.UnexpectedEof;
		const entity = self.input[start..self.pos];
		self.pos += 1; // skip ';'

		if (std.mem.eql(u8, entity, "amp")) return '&';
		if (std.mem.eql(u8, entity, "lt")) return '<';
		if (std.mem.eql(u8, entity, "gt")) return '>';
		if (std.mem.eql(u8, entity, "quot")) return '"';
		if (std.mem.eql(u8, entity, "apos")) return '\'';
		return ParseError.InvalidEntity;
	}

	/// Parse attributes within an opening tag until '>' or '/>' is reached.
	/// Returns the attributes and whether the tag is self-closing.
	fn parseAttributes(self: *Parser) !struct { attrs: []const Attribute, self_closing: bool } {
		var attrs: std.ArrayList(Attribute) = .{};
		errdefer {
			for (attrs.items) |attr| {
				self.allocator.free(attr.name);
				self.allocator.free(attr.value);
			}
			attrs.deinit(self.allocator);
		}

		while (true) {
			self.skipWhitespace();
			const c = self.peek() orelse return ParseError.UnexpectedEof;
			if (c == '>') {
				self.pos += 1;
				return .{
					.attrs = try attrs.toOwnedSlice(self.allocator),
					.self_closing = false,
				};
			}
			if (c == '/') {
				self.pos += 1;
				if ((self.advance() orelse return ParseError.UnexpectedEof) != '>') {
					return ParseError.MalformedTag;
				}
				return .{
					.attrs = try attrs.toOwnedSlice(self.allocator),
					.self_closing = true,
				};
			}
			// Parse attribute name
			const attr_name = try self.parseTagName();
			errdefer self.allocator.free(attr_name);
			self.skipWhitespace();
			// Expect '='
			if ((self.advance() orelse return ParseError.UnexpectedEof) != '=') {
				return ParseError.MalformedTag;
			}
			self.skipWhitespace();
			const attr_value = try self.parseAttrValue();
			errdefer self.allocator.free(attr_value);
			try attrs.append(self.allocator, Attribute{
				.name = attr_name,
				.value = attr_value,
			});
		}
	}

	/// Parse a single element, including its children and text content.
	fn parseElement(self: *Parser) !XmlNode {
		self.skipWhitespace();

		// Expect '<'
		if ((self.advance() orelse return ParseError.UnexpectedEof) != '<') {
			return ParseError.MalformedTag;
		}

		// Parse tag name
		const tag = try self.parseTagName();
		errdefer self.allocator.free(tag);

		// Parse attributes
		const attr_result = try self.parseAttributes();
		const attributes = attr_result.attrs;
		errdefer {
			for (attributes) |attr| {
				self.allocator.free(attr.name);
				self.allocator.free(attr.value);
			}
			if (attributes.len > 0) self.allocator.free(attributes);
		}

		if (attr_result.self_closing) {
			return XmlNode{
				.tag = tag,
				.attributes = attributes,
				.children = &.{},
				.text = null,
			};
		}

		// Parse children and/or text content
		var children: std.ArrayList(XmlNode) = .{};
		errdefer {
			for (children.items) |child| freeNode(self.allocator, child);
			children.deinit(self.allocator);
		}

		var text_buf: std.ArrayList(u8) = .{};
		errdefer text_buf.deinit(self.allocator);

		while (self.pos < self.input.len) {
			// Check what's next
			if (self.peek() != '<') {
				// Text content — accumulate until '<'
				while (self.pos < self.input.len and self.input[self.pos] != '<') {
					if (self.input[self.pos] == '&') {
						const decoded = try self.decodeEntity();
						try text_buf.append(self.allocator, decoded);
					} else {
						try text_buf.append(self.allocator, self.input[self.pos]);
						self.pos += 1;
					}
				}
				continue;
			}

			// We have '<' — could be closing tag, comment, or child element
			if (self.pos + 1 >= self.input.len) return ParseError.UnexpectedEof;

			// Skip comments
			if (self.skipComment()) continue;

			// Check for closing tag
			if (self.input[self.pos + 1] == '/') {
				// Closing tag
				self.pos += 2; // skip '</'
				const close_tag = try self.parseTagName();
				defer self.allocator.free(close_tag);
				self.skipWhitespace();
				if ((self.advance() orelse return ParseError.UnexpectedEof) != '>') {
					return ParseError.MalformedTag;
				}
				if (!std.mem.eql(u8, tag, close_tag)) {
					return ParseError.MismatchedClosingTag;
				}

				// Build final text (null if no text was collected)
				const text: ?[]const u8 = if (text_buf.items.len > 0)
					try text_buf.toOwnedSlice(self.allocator)
				else
					null;
				errdefer if (text) |t| self.allocator.free(t);

				if (text == null) text_buf.deinit(self.allocator);

				const owned_children = try children.toOwnedSlice(self.allocator);
				return XmlNode{
					.tag = tag,
					.attributes = attributes,
					.children = owned_children,
					.text = text,
				};
			}

			// Child element
			const child = try self.parseElement();
			try children.append(self.allocator, child);
		}

		return ParseError.UnexpectedEof;
	}
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "basic element with text" {
	const input = "<root><child>hello</child></root>";
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqualStrings("root", root.tag);
	try testing.expectEqual(@as(usize, 1), root.children.len);

	const child = root.children[0];
	try testing.expectEqualStrings("child", child.tag);
	try testing.expectEqualStrings("hello", child.text.?);
}

test "attributes and getAttr" {
	const input =
		\\<w:pStyle w:val="Heading1"/>
	;
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqualStrings("w:pStyle", root.tag);
	try testing.expectEqual(@as(usize, 1), root.attributes.len);
	try testing.expectEqualStrings("Heading1", root.getAttr("w:val").?);
	try testing.expectEqual(@as(?[]const u8, null), root.getAttr("nonexistent"));
}

test "nested DOCX-like structure" {
	const input =
		\\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Hello World</w:t></w:r></w:p>
	;
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const p = doc.root.?;
	try testing.expectEqualStrings("w:p", p.tag);
	try testing.expectEqual(@as(usize, 2), p.children.len);

	// First child: w:pPr with w:pStyle
	const pPr = p.children[0];
	try testing.expectEqualStrings("w:pPr", pPr.tag);
	try testing.expectEqual(@as(usize, 1), pPr.children.len);
	const pStyle = pPr.children[0];
	try testing.expectEqualStrings("w:pStyle", pStyle.tag);
	try testing.expectEqualStrings("Heading1", pStyle.getAttr("w:val").?);

	// Second child: w:r with w:t
	const r = p.children[1];
	try testing.expectEqualStrings("w:r", r.tag);
	try testing.expectEqual(@as(usize, 1), r.children.len);
	const t = r.children[0];
	try testing.expectEqualStrings("w:t", t.tag);
	try testing.expectEqualStrings("Hello World", t.text.?);
}

test "self-closing tags" {
	const input = "<root><br/><w:tab /></root>";
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqual(@as(usize, 2), root.children.len);

	try testing.expectEqualStrings("br", root.children[0].tag);
	try testing.expectEqual(@as(?[]const u8, null), root.children[0].text);

	try testing.expectEqualStrings("w:tab", root.children[1].tag);
	try testing.expectEqual(@as(?[]const u8, null), root.children[1].text);
}

test "XML entities decoded in text" {
	const input = "<root>1 &lt; 2 &amp; 3 &gt; 0 &quot;hi&quot; &apos;lo&apos;</root>";
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqualStrings("1 < 2 & 3 > 0 \"hi\" 'lo'", root.text.?);
}

test "XML declaration skipped" {
	const input =
		\\<?xml version="1.0" encoding="UTF-8"?><root>data</root>
	;
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqualStrings("root", root.tag);
	try testing.expectEqualStrings("data", root.text.?);
}

test "empty element" {
	const input = "<w:p></w:p>";
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqualStrings("w:p", root.tag);
	try testing.expectEqual(@as(usize, 0), root.children.len);
	try testing.expectEqual(@as(?[]const u8, null), root.text);
}

test "multiple children" {
	const input = "<root><a/><b/><c/></root>";
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqual(@as(usize, 3), root.children.len);
	try testing.expectEqualStrings("a", root.children[0].tag);
	try testing.expectEqualStrings("b", root.children[1].tag);
	try testing.expectEqualStrings("c", root.children[2].tag);
}

test "XML entities decoded in attribute values" {
	const input =
		\\<tag attr="a&amp;b"/>
	;
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqualStrings("a&b", root.getAttr("attr").?);
}

test "XML comment skipped" {
	const input = "<root><!-- a comment --><child>text</child></root>";
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqual(@as(usize, 1), root.children.len);
	try testing.expectEqualStrings("child", root.children[0].tag);
	try testing.expectEqualStrings("text", root.children[0].text.?);
}

test "multiple attributes" {
	const input =
		\\<w:rPr w:val="Bold" xml:space="preserve" w:sz="24"/>
	;
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqual(@as(usize, 3), root.attributes.len);
	try testing.expectEqualStrings("Bold", root.getAttr("w:val").?);
	try testing.expectEqualStrings("preserve", root.getAttr("xml:space").?);
	try testing.expectEqualStrings("24", root.getAttr("w:sz").?);
}

test "empty input" {
	const doc = try parse(testing.allocator, "");
	defer freeXmlDoc(testing.allocator, doc);
	try testing.expectEqual(@as(?XmlNode, null), doc.root);
}

test "whitespace-only input" {
	const doc = try parse(testing.allocator, "   \n\t  ");
	defer freeXmlDoc(testing.allocator, doc);
	try testing.expectEqual(@as(?XmlNode, null), doc.root);
}

test "single-quoted attribute values" {
	const input = "<tag attr='value'/>";
	const doc = try parse(testing.allocator, input);
	defer freeXmlDoc(testing.allocator, doc);

	const root = doc.root.?;
	try testing.expectEqualStrings("value", root.getAttr("attr").?);
}

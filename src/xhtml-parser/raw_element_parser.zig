//! A small streaming XML/HTML parser.
//!
//! This parser ingests UTF-8 bytes incrementally and emits a stream of raw
//! element/text events. It is intentionally minimal and is not a validating or
//! normalizing parser.

const std = @import("std");

/// Parsing mode for the raw parser.
///
/// RawElementParser currently implements only `.xml`. `.html` and `.auto` will surface
/// as `Event.Error` with kind `.Unsupported`.
pub const ParserMode = enum { xml, html, auto };

/// Whether an element boundary was explicit in the input or implied by a normalizer.
///
/// RawElementParser always emits `.explicit`.
pub const Origin = enum { explicit, implied };

/// Broad error categories surfaced via `Event.Error`.
pub const ErrorKind = enum {
    InvalidUtf8,
    MalformedMarkup,
    InvalidName,
    UnexpectedEof,
    LimitExceeded,
    Unsupported,
};

/// Streaming event union emitted by the parser.
///
/// All `[]const u8` payloads are arena-backed and remain valid until `reset()`
/// or `deinit()`.
pub const Event = union(enum) {
    /// Start tag `<name ...>`.
    ElementStart: struct { name: []const u8, origin: Origin },
    /// Attribute emitted immediately after its `ElementStart`.
    Attribute: struct { name: []const u8, value: []const u8 },
    /// End tag `</name>`, or the synthetic end emitted for `<name .../>`.
    ElementEnd: struct { name: []const u8, origin: Origin },
    /// Character data outside markup.
    Text: struct { bytes: []const u8 },
    /// Comment `<!-- ... -->` (optional via `Options.emit_comments`).
    Comment: struct { bytes: []const u8 },
    /// Processing instruction `<?target data?>` (optional via `Options.emit_pi`).
    ProcessingInstruction: struct { target: []const u8, data: []const u8 },
    /// CDATA section `<![CDATA[...]]>` (optional via `Options.emit_cdata`).
    Cdata: struct { bytes: []const u8 },
    /// Recoverable parse error. The parser continues after emitting this.
    Error: struct { kind: ErrorKind, message: []const u8, offset: u64 },
    /// The parser needs more input to continue.
    NeedMoreInput,
    /// End-of-stream after `finish()` and draining buffered bytes.
    EndOfStream,
};

/// Parser configuration options.
pub const Options = struct {
    /// Dialect selection.
    mode: ParserMode = .xml,
    /// Maximum bytes in a name (element/attribute/PI target).
    max_name_len: usize = 256,
    /// Maximum bytes in a single attribute value.
    max_attr_len: usize = 4096,
    /// Maximum bytes emitted in a single `Text` event.
    max_text_chunk: usize = 8192,
    /// Maximum attributes on a single element.
    max_attrs_per_element: usize = 64,
    /// Emit `Comment` events.
    emit_comments: bool = false,
    /// Emit `ProcessingInstruction` events.
    emit_pi: bool = false,
    /// Emit `Cdata` events.
    emit_cdata: bool = false,
};

/// Streaming raw element parser.
///
/// Ownership: event payload slices are arena-backed and remain valid until
/// `reset()` or `deinit()`.
pub const RawElementParser = struct {
    /// Allocator used for the input buffer, event queue, and scratch storage.
    allocator: std.mem.Allocator,
    /// Parser configuration.
    options: Options,
    /// Arena used to allocate event payload slices.
    arena: std.heap.ArenaAllocator,
    /// Buffered input.
    buf: std.ArrayListUnmanaged(u8) = .{},
    /// Read cursor into `buf.items`.
    cursor: usize = 0,
    /// Absolute byte offset for consumed input.
    offset: u64 = 0,
    /// Whether `finish()` has been called.
    finished: bool = false,
    /// Internal queue used for multi-event constructs (start + attrs + end).
    queue: std.ArrayListUnmanaged(Event) = .{},
    /// Next index to return from `queue`.
    queue_index: usize = 0,
    /// Temporary spans for attributes while parsing a start tag.
    tmp_attrs: std.ArrayListUnmanaged(AttrSpan) = .{},

    /// Byte spans for one attribute (name/value) in the input buffer.
    const AttrSpan = struct {
        name: Span,
        value: Span,
    };

    /// A byte range in the input buffer.
    const Span = struct {
        start: usize,
        end: usize,

        /// Span length in bytes.
        fn len(self: Span) usize {
            return self.end - self.start;
        }
    };

    /// Initialize a new parser instance.
    pub fn init(allocator: std.mem.Allocator, options: Options) RawElementParser {
        return .{
            .allocator = allocator,
            .options = options,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Free all memory owned by the parser.
    pub fn deinit(self: *RawElementParser) void {
        self.tmp_attrs.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.buf.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Reset the parser state and clear arena allocations (retaining capacity).
    pub fn reset(self: *RawElementParser) void {
        _ = self.arena.reset(.retain_capacity);
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.offset = 0;
        self.finished = false;

        self.queue.clearRetainingCapacity();
        self.queue_index = 0;
        self.tmp_attrs.clearRetainingCapacity();
    }

    /// Append bytes to the input stream.
    pub fn feed(self: *RawElementParser, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// Signal end-of-stream.
    pub fn finish(self: *RawElementParser) void {
        self.finished = true;
    }

    /// Return the next event in the stream.
    ///
    /// If the current buffered bytes do not contain a complete construct,
    /// returns `Event.NeedMoreInput` (unless `finish()` has been called, in which
    /// case the parser emits `Event.Error` with kind `.UnexpectedEof`).
    pub fn nextEvent(self: *RawElementParser) !Event {
        if (self.popQueued()) |ev| return ev;

        while (true) {
            if (self.options.mode != .xml) {
                return self.errorEvent(.Unsupported, "only ParserMode.xml is implemented in RawElementParser");
            }

            if (self.popQueued()) |ev| return ev;
            if (self.cursor >= self.buf.items.len) {
                return if (self.finished) .EndOfStream else .NeedMoreInput;
            }

            if (self.buf.items[self.cursor] != '<') {
                const text_ev = try self.parseText();
                if (text_ev) |ev| return ev;
                continue;
            }

            const markup_ev = try self.parseMarkup();
            if (markup_ev) |ev| return ev;
            if (self.popQueued()) |ev| return ev;
        }
    }

    /// Parse the next `Text` chunk until the next `<` or `max_text_chunk`.
    fn parseText(self: *RawElementParser) !?Event {
        const start = self.cursor;
        const bytes = self.buf.items;
        const lt_rel = std.mem.indexOfScalar(u8, bytes[start..], '<');
        const raw_end = if (lt_rel) |i| start + i else bytes.len;

        if (raw_end == start) return null;

        const max_end = @min(raw_end, start + self.options.max_text_chunk);
        const end = safeUtf8Cut(bytes[start..raw_end], max_end - start) + start;
        if (end == start) {
            // This can happen if max_text_chunk is tiny and we hit a UTF-8 continuation byte.
            const single = start + 1;
            const out = try self.arena.allocator().dupe(u8, bytes[start..single]);
            self.consume(single - start);
            return .{ .Text = .{ .bytes = out } };
        }

        const out = try self.arena.allocator().dupe(u8, bytes[start..end]);
        self.consume(end - start);
        return .{ .Text = .{ .bytes = out } };
    }

    /// Parse a markup construct starting at `<`.
    fn parseMarkup(self: *RawElementParser) !?Event {
        if (self.cursor + 1 >= self.buf.items.len) {
            return self.needMoreOrUnexpectedEof();
        }

        const b1 = self.buf.items[self.cursor + 1];
        if (b1 == '/') return try self.parseEndTag();
        if (b1 == '!') return try self.parseBang();
        if (b1 == '?') return try self.parseProcessingInstruction();
        return try self.parseStartTag();
    }

    /// Parse an end tag `</name>`.
    fn parseEndTag(self: *RawElementParser) !?Event {
        const bytes = self.buf.items;
        var i: usize = self.cursor + 2; // after "</"
        if (i >= bytes.len) return self.needMoreOrUnexpectedEof();

        const name_span = try self.scanName(bytes, &i) orelse return self.errorAndConsume1(.InvalidName, "missing element name in end tag");
        if (name_span.len() > self.options.max_name_len) return self.errorAndConsume1(.LimitExceeded, "element name too long");

        i = skipWs(bytes, i);
        if (i >= bytes.len) return self.needMoreOrUnexpectedEof();
        if (bytes[i] != '>') return self.errorAndConsume1(.MalformedMarkup, "expected '>' to close end tag");
        i += 1;

        const name = try self.arena.allocator().dupe(u8, bytes[name_span.start..name_span.end]);
        self.consume(i - self.cursor);
        return .{ .ElementEnd = .{ .name = name, .origin = .explicit } };
    }

    /// Parse a start tag `<name ...>` or empty element `<name .../>`.
    fn parseStartTag(self: *RawElementParser) !?Event {
        const bytes = self.buf.items;
        var i: usize = self.cursor + 1; // after "<"

        const name_span = try self.scanName(bytes, &i) orelse return self.errorAndConsume1(.InvalidName, "missing element name in start tag");
        if (name_span.len() > self.options.max_name_len) return self.errorAndConsume1(.LimitExceeded, "element name too long");

        self.tmp_attrs.clearRetainingCapacity();
        var empty_element = false;

        while (true) {
            i = skipWs(bytes, i);
            if (i >= bytes.len) return self.needMoreOrUnexpectedEof();

            if (bytes[i] == '>') {
                i += 1;
                break;
            }

            if (bytes[i] == '/' and i + 1 < bytes.len and bytes[i + 1] == '>') {
                empty_element = true;
                i += 2;
                break;
            }

            const attr_name_span = try self.scanName(bytes, &i) orelse return self.errorAndConsume1(.InvalidName, "missing attribute name");
            if (attr_name_span.len() > self.options.max_name_len) return self.errorAndConsume1(.LimitExceeded, "attribute name too long");
            if (self.tmp_attrs.items.len >= self.options.max_attrs_per_element) {
                return self.errorAndConsume1(.LimitExceeded, "too many attributes on element");
            }

            i = skipWs(bytes, i);
            if (i >= bytes.len) return self.needMoreOrUnexpectedEof();
            if (bytes[i] != '=') return self.errorAndConsume1(.MalformedMarkup, "expected '=' after attribute name");
            i += 1;
            i = skipWs(bytes, i);
            if (i >= bytes.len) return self.needMoreOrUnexpectedEof();

            const quote = bytes[i];
            if (quote != '"' and quote != '\'') return self.errorAndConsume1(.MalformedMarkup, "expected quoted attribute value");
            i += 1;
            const value_start = i;
            const end_quote_rel = std.mem.indexOfScalar(u8, bytes[value_start..], quote);
            if (end_quote_rel == null) return self.needMoreOrUnexpectedEof();
            const value_end = value_start + end_quote_rel.?;
            const value_span: Span = .{ .start = value_start, .end = value_end };
            if (value_span.len() > self.options.max_attr_len) {
                return self.errorAndConsume1(.LimitExceeded, "attribute value too long");
            }
            i = value_end + 1;

            try self.tmp_attrs.append(self.allocator, .{ .name = attr_name_span, .value = value_span });
        }

        // Commit: copy into arena + enqueue events.
        const name = try self.arena.allocator().dupe(u8, bytes[name_span.start..name_span.end]);
        try self.enqueue(.{ .ElementStart = .{ .name = name, .origin = .explicit } });
        for (self.tmp_attrs.items) |a| {
            const an = try self.arena.allocator().dupe(u8, bytes[a.name.start..a.name.end]);
            const av = try self.arena.allocator().dupe(u8, bytes[a.value.start..a.value.end]);
            try self.enqueue(.{ .Attribute = .{ .name = an, .value = av } });
        }
        if (empty_element) {
            try self.enqueue(.{ .ElementEnd = .{ .name = name, .origin = .explicit } });
        }

        self.consume(i - self.cursor);
        return null; // nextEvent will return from queue.
    }

    /// Parse `<!...` constructs (comment/CDATA/unsupported).
    fn parseBang(self: *RawElementParser) !?Event {
        const bytes = self.buf.items;
        if (self.cursor + 3 >= bytes.len) return self.needMoreOrUnexpectedEof();

        // Comment: <!-- ... -->
        if (std.mem.startsWith(u8, bytes[self.cursor..], "<!--")) {
            return try self.parseComment();
        }

        // CDATA: <![CDATA[ ... ]]>
        if (std.mem.startsWith(u8, bytes[self.cursor..], "<![CDATA[")) {
            return try self.parseCdata();
        }

        // Not implemented: doctype/DTD/etc.
        return self.errorAndConsume1(.Unsupported, "unsupported '<!' construct");
    }

    /// Parse a comment `<!-- ... -->`.
    fn parseComment(self: *RawElementParser) !?Event {
        const bytes = self.buf.items;
        const body_start = self.cursor + 4;
        const end_rel = std.mem.indexOf(u8, bytes[body_start..], "-->");
        if (end_rel == null) return self.needMoreOrUnexpectedEof();
        const body_end = body_start + end_rel.?;
        const after = body_end + 3;

        if (self.options.emit_comments) {
            const out = try self.arena.allocator().dupe(u8, bytes[body_start..body_end]);
            self.consume(after - self.cursor);
            return .{ .Comment = .{ .bytes = out } };
        }

        self.consume(after - self.cursor);
        return null;
    }

    /// Parse a CDATA section `<![CDATA[...]]>`.
    fn parseCdata(self: *RawElementParser) !?Event {
        const bytes = self.buf.items;
        const body_start = self.cursor + "<![CDATA[".len;
        const end_rel = std.mem.indexOf(u8, bytes[body_start..], "]]>");
        if (end_rel == null) return self.needMoreOrUnexpectedEof();
        const body_end = body_start + end_rel.?;
        const after = body_end + 3;

        if (self.options.emit_cdata) {
            const out = try self.arena.allocator().dupe(u8, bytes[body_start..body_end]);
            self.consume(after - self.cursor);
            return .{ .Cdata = .{ .bytes = out } };
        }

        self.consume(after - self.cursor);
        return null;
    }

    /// Parse a processing instruction `<?target data?>`.
    fn parseProcessingInstruction(self: *RawElementParser) !?Event {
        const bytes = self.buf.items;
        const body_start = self.cursor + 2; // after "<?"
        const end_rel = std.mem.indexOf(u8, bytes[body_start..], "?>");
        if (end_rel == null) return self.needMoreOrUnexpectedEof();
        const body_end = body_start + end_rel.?;
        const after = body_end + 2;

        if (!self.options.emit_pi) {
            self.consume(after - self.cursor);
            return null;
        }

        var i = body_start;
        const target_span = try self.scanName(bytes, &i) orelse return self.errorAndConsume1(.InvalidName, "missing PI target");
        if (target_span.len() > self.options.max_name_len) return self.errorAndConsume1(.LimitExceeded, "PI target too long");
        const data_start = skipWs(bytes, i);
        const target = try self.arena.allocator().dupe(u8, bytes[target_span.start..target_span.end]);
        const data = try self.arena.allocator().dupe(u8, bytes[data_start..body_end]);

        self.consume(after - self.cursor);
        return .{ .ProcessingInstruction = .{ .target = target, .data = data } };
    }

    /// Scan a name and advance the index on success.
    fn scanName(self: *RawElementParser, bytes: []const u8, i: *usize) !?Span {
        _ = self;
        if (i.* >= bytes.len) return null;
        if (!isNameStart(bytes[i.*])) return null;
        const start = i.*;
        i.* += 1;
        while (i.* < bytes.len and isNameChar(bytes[i.*])) : (i.* += 1) {}
        return .{ .start = start, .end = i.* };
    }

    /// Append an event to the internal queue.
    fn enqueue(self: *RawElementParser, ev: Event) !void {
        try self.queue.append(self.allocator, ev);
    }

    /// Consume bytes from the input buffer, advancing the absolute offset.
    fn consume(self: *RawElementParser, n: usize) void {
        self.cursor += n;
        self.offset += @intCast(n);
    }

    /// Handle a "need more input" situation, or convert it to an EOF error after `finish()`.
    fn needMoreOrUnexpectedEof(self: *RawElementParser) ?Event {
        if (!self.finished) return .NeedMoreInput;
        // At EOF, turn incomplete constructs into an error and consume the rest.
        const err_offset = self.offset;
        const remaining = self.buf.items.len - self.cursor;
        self.consume(remaining);
        return .{ .Error = .{ .kind = .UnexpectedEof, .message = "unexpected end of input", .offset = err_offset } };
    }

    /// Emit an error event and consume one byte so parsing continues making progress.
    fn errorAndConsume1(self: *RawElementParser, kind: ErrorKind, message: []const u8) ?Event {
        const err_offset = self.offset;
        self.consume(1);
        return .{ .Error = .{ .kind = kind, .message = message, .offset = err_offset } };
    }

    /// Create an error event at the current offset.
    fn errorEvent(self: *RawElementParser, kind: ErrorKind, message: []const u8) Event {
        return .{ .Error = .{ .kind = kind, .message = message, .offset = self.offset } };
    }

    /// Return a queued event if available.
    fn popQueued(self: *RawElementParser) ?Event {
        if (self.queue_index >= self.queue.items.len) return null;
        const ev = self.queue.items[self.queue_index];
        self.queue_index += 1;
        if (self.queue_index >= self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.queue_index = 0;
            self.compactInputIfNeeded();
        }
        return ev;
    }

    /// Compact the input buffer when a large prefix has been consumed.
    fn compactInputIfNeeded(self: *RawElementParser) void {
        // Compact when we've consumed a bunch and there's remaining data.
        if (self.cursor < 4096) return;
        const remaining = self.buf.items.len - self.cursor;
        if (remaining == 0) {
            self.buf.clearRetainingCapacity();
            self.cursor = 0;
            return;
        }

        if (self.cursor * 2 < self.buf.items.len) return;

        std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.cursor..]);
        self.buf.items.len = remaining;
        self.cursor = 0;
    }
};

/// Minimal XML-ish name start character check.
fn isNameStart(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_' or b == ':';
}

/// Minimal XML-ish name character check.
fn isNameChar(b: u8) bool {
    return isNameStart(b) or (b >= '0' and b <= '9') or b == '.' or b == '-' or b == 0xB7;
}

/// Skip ASCII whitespace.
fn skipWs(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            ' ', '\t', '\n', '\r' => {},
            else => break,
        }
    }
    return i;
}

/// Cut a slice at a boundary that avoids ending on UTF-8 continuation bytes.
fn safeUtf8Cut(bytes: []const u8, max_len: usize) usize {
    const end = @min(bytes.len, max_len);
    if (end == 0) return 0;
    var cut = end;
    var back: usize = 0;
    while (cut > 0 and back < 4) : (back += 1) {
        const b = bytes[cut - 1];
        if (b < 0x80 or b >= 0xC0) break; // ASCII or start byte
        cut -= 1; // continuation byte
    }
    if (cut == 0) return 0;
    return cut;
}

test "raw parser: whole buffer vs 1-byte chunks" {
    const allocator = std.testing.allocator;
    const input = "<a b=\"c\">hi</a><br/>";

    const out_whole = try parseToString(allocator, input, 0);
    defer allocator.free(out_whole);

    const out_chunked = try parseToString(allocator, input, 1);
    defer allocator.free(out_chunked);

    try std.testing.expectEqualStrings(out_whole, out_chunked);
}

test "raw parser: finish with incomplete tag emits UnexpectedEof" {
    const allocator = std.testing.allocator;
    const out = try parseToString(allocator, "<a", 0);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Err(UnexpectedEof)") != null);
}

/// Helper for tests: parse input and return a compact event trace string.
fn parseToString(allocator: std.mem.Allocator, input: []const u8, chunk_size: usize) ![]u8 {
    var p = RawElementParser.init(allocator, .{ .mode = .xml });
    defer p.deinit();

    if (chunk_size == 0) {
        try p.feed(input);
        p.finish();
        return drainToString(allocator, &p);
    }

    var off: usize = 0;
    while (off < input.len) {
        const end = @min(input.len, off + chunk_size);
        try p.feed(input[off..end]);
        off = end;

        while (true) {
            const ev = try p.nextEvent();
            switch (ev) {
                .NeedMoreInput => break,
                .EndOfStream => return error.UnexpectedEos,
                else => {},
            }
        }
    }

    p.finish();
    return drainToString(allocator, &p);
}

/// Drain events into a compact string representation for tests.
fn drainToString(allocator: std.mem.Allocator, p: *RawElementParser) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    while (true) {
        const ev = try p.nextEvent();
        switch (ev) {
            .NeedMoreInput => continue,
            .EndOfStream => {
                try out.appendSlice("EOS|");
                break;
            },
            .ElementStart => |e| try out.writer().print("S({s})|", .{e.name}),
            .ElementEnd => |e| try out.writer().print("E({s})|", .{e.name}),
            .Attribute => |a| try out.writer().print("A({s}={s})|", .{ a.name, a.value }),
            .Text => |t| try out.writer().print("T({s})|", .{t.bytes}),
            .Comment => |c| try out.writer().print("C({s})|", .{c.bytes}),
            .Cdata => |c| try out.writer().print("CD({s})|", .{c.bytes}),
            .ProcessingInstruction => |pi| try out.writer().print("PI({s},{s})|", .{ pi.target, pi.data }),
            .Error => |e| try out.writer().print("Err({s})|", .{@tagName(e.kind)}),
        }
    }

    return try out.toOwnedSlice();
}

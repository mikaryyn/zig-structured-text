//! XML well-formedness sanitizer/normalizer for `RawElementParser` event streams.
//!
//! This enforces a few strong invariants:
//! - Proper element nesting (matched start/end tags)
//! - A single root element
//! - No duplicate attributes on the same element
//! - Text outside the root is limited to XML whitespace
//!
//! The sanitizer is streaming: callers `push()` events in, and then `nextEvent()`
//! yields sanitized events out.
//!
//! Ownership/lifetimes: the sanitizer does not copy payload slices; it forwards the
//! `[]const u8` slices it receives. Payload lifetimes therefore remain governed
//! by the upstream producer (e.g. `RawElementParser` arena contract).

const std = @import("std");

const raw_element_parser = @import("raw_element_parser.zig");
const Event = raw_element_parser.Event;
const ErrorKind = raw_element_parser.ErrorKind;

pub const Options = struct {
    /// If true, the sanitizer stops producing further non-error events after
    /// emitting the first error (including upstream errors).
    fail_fast: bool = true,
    /// Maximum element nesting depth.
    max_depth: usize = 1024,
};

pub const XmlSanitizer = struct {
    allocator: std.mem.Allocator,
    options: Options,

    queue: std.ArrayListUnmanaged(Event) = .{},
    queue_index: usize = 0,

    open_stack: std.ArrayListUnmanaged([]const u8) = .{},

    root_seen: bool = false,
    root_closed: bool = false,

    in_attr_phase: bool = false,
    attr_seen: std.StringHashMapUnmanaged(void) = .{},

    finished: bool = false,
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) XmlSanitizer {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *XmlSanitizer) void {
        self.attr_seen.deinit(self.allocator);
        self.open_stack.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *XmlSanitizer) void {
        self.queue.clearRetainingCapacity();
        self.queue_index = 0;

        self.open_stack.clearRetainingCapacity();

        self.root_seen = false;
        self.root_closed = false;

        self.in_attr_phase = false;
        self.attr_seen.clearRetainingCapacity();

        self.finished = false;
        self.stopped = false;
    }

    pub fn push(self: *XmlSanitizer, ev: Event) !void {
        if (self.stopped) {
            switch (ev) {
                .Error, .EndOfStream => {},
                else => return,
            }
        }

        switch (ev) {
            .NeedMoreInput => return,
            .EndOfStream => {
                self.finished = true;
                try self.onFinish();
                return;
            },
            .Error => |e| {
                try self.enqueue(.{ .Error = e });
                self.stopIfConfigured();
                return;
            },
            .ElementStart => |s| try self.onElementStart(s.name, s.origin),
            .Attribute => |a| try self.onAttribute(a.name, a.value),
            .ElementEnd => |e| try self.onElementEnd(e.name, e.origin),
            .Text => |t| try self.onText(t.bytes),
            .Comment, .ProcessingInstruction, .Cdata => {
                try self.leaveAttrPhase();
                try self.enqueue(ev);
            },
        }
    }

    pub fn finish(self: *XmlSanitizer) !void {
        if (self.finished) return;
        self.finished = true;
        try self.onFinish();
    }

    pub fn nextEvent(self: *XmlSanitizer) !Event {
        if (self.popQueued()) |ev| return ev;
        if (self.finished) return .EndOfStream;
        return .NeedMoreInput;
    }

    fn onElementStart(self: *XmlSanitizer, name: []const u8, origin: raw_element_parser.Origin) !void {
        _ = origin; // currently only `.explicit` flows through this layer.
        try self.leaveAttrPhase();

        if (self.root_closed) {
            try self.emitError(.MalformedMarkup, "multiple root elements are not allowed");
            return;
        }

        if (self.open_stack.items.len == 0) {
            self.root_seen = true;
        }

        if (self.open_stack.items.len >= self.options.max_depth) {
            try self.emitError(.LimitExceeded, "maximum element depth exceeded");
            return;
        }

        try self.open_stack.append(self.allocator, name);
        self.in_attr_phase = true;
        self.attr_seen.clearRetainingCapacity();

        try self.enqueue(.{ .ElementStart = .{ .name = name, .origin = .explicit } });
    }

    fn onAttribute(self: *XmlSanitizer, name: []const u8, value: []const u8) !void {
        if (!self.in_attr_phase) {
            try self.emitError(.MalformedMarkup, "attribute event without a preceding start tag");
            return;
        }

        const gop = try self.attr_seen.getOrPut(self.allocator, name);
        if (gop.found_existing) {
            try self.emitError(.MalformedMarkup, "duplicate attribute on element");
            return;
        }

        try self.enqueue(.{ .Attribute = .{ .name = name, .value = value } });
    }

    fn onElementEnd(self: *XmlSanitizer, name: []const u8, origin: raw_element_parser.Origin) !void {
        _ = origin;
        try self.leaveAttrPhase();

        if (self.open_stack.items.len == 0) {
            try self.emitError(.MalformedMarkup, "end tag without a matching start tag");
            return;
        }

        const top = self.open_stack.items[self.open_stack.items.len - 1];
        if (!std.mem.eql(u8, top, name)) {
            try self.emitError(.MalformedMarkup, "mismatched end tag");
            return;
        }

        _ = self.open_stack.pop();
        try self.enqueue(.{ .ElementEnd = .{ .name = name, .origin = .explicit } });

        if (self.open_stack.items.len == 0 and self.root_seen) {
            self.root_closed = true;
        }
    }

    fn onText(self: *XmlSanitizer, bytes: []const u8) !void {
        try self.leaveAttrPhase();

        if (self.open_stack.items.len == 0) {
            if (!isAllXmlWhitespace(bytes)) {
                try self.emitError(.MalformedMarkup, "non-whitespace text outside root element");
            } else {
                try self.enqueue(.{ .Text = .{ .bytes = bytes } });
            }
            return;
        }

        try self.enqueue(.{ .Text = .{ .bytes = bytes } });
    }

    fn onFinish(self: *XmlSanitizer) !void {
        try self.leaveAttrPhase();

        if (self.open_stack.items.len != 0) {
            try self.emitError(.UnexpectedEof, "unexpected end of input (unclosed element)");
            return;
        }

        if (!self.root_seen) {
            try self.emitError(.MalformedMarkup, "missing root element");
            return;
        }
    }

    fn leaveAttrPhase(self: *XmlSanitizer) !void {
        if (!self.in_attr_phase) return;
        self.in_attr_phase = false;
        self.attr_seen.clearRetainingCapacity();
    }

    fn enqueue(self: *XmlSanitizer, ev: Event) !void {
        try self.queue.append(self.allocator, ev);
    }

    fn popQueued(self: *XmlSanitizer) ?Event {
        if (self.queue_index >= self.queue.items.len) return null;
        const ev = self.queue.items[self.queue_index];
        self.queue_index += 1;
        if (self.queue_index >= self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.queue_index = 0;
        }
        return ev;
    }

    fn emitError(self: *XmlSanitizer, kind: ErrorKind, message: []const u8) !void {
        // Offset is unknown at this stage because upstream events do not carry location.
        try self.enqueue(.{ .Error = .{ .kind = kind, .message = message, .offset = 0 } });
        self.stopIfConfigured();
    }

    fn stopIfConfigured(self: *XmlSanitizer) void {
        if (self.options.fail_fast) self.stopped = true;
    }
};

fn isAllXmlWhitespace(bytes: []const u8) bool {
    for (bytes) |b| {
        switch (b) {
            ' ', '\t', '\n', '\r' => {},
            else => return false,
        }
    }
    return true;
}

test "xml sanitizer: happy path" {
    const allocator = std.testing.allocator;
    const out = try parseSanitizedToString(allocator, "<a b=\"c\">hi</a>", 0);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("S(a)|A(b=c)|T(hi)|E(a)|EOS|", out);
}

test "xml sanitizer: duplicate attribute emits error and stops" {
    const allocator = std.testing.allocator;
    const out = try parseSanitizedToString(allocator, "<a x=\"1\" x=\"2\"/>", 0);
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "S(a)|A(x=1)|Err("));
}

test "xml sanitizer: mismatched end tag emits error" {
    const allocator = std.testing.allocator;
    const out = try parseSanitizedToString(allocator, "<a><b></a>", 0);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Err(MalformedMarkup)") != null);
}

test "xml sanitizer: non-ws text outside root emits error" {
    const allocator = std.testing.allocator;
    const out = try parseSanitizedToString(allocator, "oops<a/>", 0);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Err(MalformedMarkup)") != null);
}

test "xml sanitizer: whitespace outside root allowed" {
    const allocator = std.testing.allocator;
    const out = try parseSanitizedToString(allocator, " \n<a/> \n", 0);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "T( \n)") != null);
}

test "xml sanitizer: multiple roots emits error" {
    const allocator = std.testing.allocator;
    const out = try parseSanitizedToString(allocator, "<a/><b/>", 0);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Err(MalformedMarkup)") != null);
}

fn parseSanitizedToString(allocator: std.mem.Allocator, input: []const u8, chunk_size: usize) ![]u8 {
    var p = raw_element_parser.RawElementParser.init(allocator, .{ .mode = .xml });
    defer p.deinit();

    var s = XmlSanitizer.init(allocator, .{ .fail_fast = true });
    defer s.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const feedAndDrain = struct {
        fn drain(out_list: *std.ArrayList(u8), sanitizer: *XmlSanitizer) !void {
            while (true) {
                const ev = try sanitizer.nextEvent();
                switch (ev) {
                    .NeedMoreInput => break,
                    .EndOfStream => {
                        try out_list.appendSlice("EOS|");
                        return;
                    },
                    .ElementStart => |e| try out_list.writer().print("S({s})|", .{e.name}),
                    .ElementEnd => |e| try out_list.writer().print("E({s})|", .{e.name}),
                    .Attribute => |a| try out_list.writer().print("A({s}={s})|", .{ a.name, a.value }),
                    .Text => |t| try out_list.writer().print("T({s})|", .{t.bytes}),
                    .Comment => |c| try out_list.writer().print("C({s})|", .{c.bytes}),
                    .Cdata => |c| try out_list.writer().print("CD({s})|", .{c.bytes}),
                    .ProcessingInstruction => |pi| try out_list.writer().print("PI({s},{s})|", .{ pi.target, pi.data }),
                    .Error => |e| try out_list.writer().print("Err({s})|", .{@tagName(e.kind)}),
                }
            }
        }
    };

    if (chunk_size == 0) {
        try p.feed(input);
        p.finish();
        while (true) {
            const ev = try p.nextEvent();
            switch (ev) {
                .NeedMoreInput => continue,
                .EndOfStream => break,
                else => try s.push(ev),
            }
            try feedAndDrain.drain(&out, &s);
        }
        try s.finish();
        try feedAndDrain.drain(&out, &s);
        return try out.toOwnedSlice();
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
                else => try s.push(ev),
            }
            try feedAndDrain.drain(&out, &s);
        }
    }

    p.finish();
    while (true) {
        const ev = try p.nextEvent();
        switch (ev) {
            .NeedMoreInput => continue,
            .EndOfStream => break,
            else => try s.push(ev),
        }
        try feedAndDrain.drain(&out, &s);
    }

    try s.finish();
    try feedAndDrain.drain(&out, &s);
    return try out.toOwnedSlice();
}

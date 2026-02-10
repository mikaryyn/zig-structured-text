const std = @import("std");

pub const TokenizerError = error{
    InvalidUtf8,
};

pub const Reader = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, out: []u8) anyerror!usize,

    pub fn read(self: Reader, out: []u8) anyerror!usize {
        return self.readFn(self.ctx, out);
    }
};

pub const TxtTokenKind = enum {
    Word,
    LineBreak,
    ParagraphBreak,
    Eof,
};

pub const TxtToken = struct {
    kind: TxtTokenKind,
    start_offset: u32,
    end_offset: u32,
    word_len: usize,
};

pub const TxtByteReader = struct {
    reader: Reader,
    offset: u32,
    eof: bool,
    buf: [1024]u8,
    buf_pos: usize,
    buf_len: usize,

    pub fn init(reader: Reader, start_offset: u32) TxtByteReader {
        return TxtByteReader{
            .reader = reader,
            .offset = start_offset,
            .eof = false,
            .buf = undefined,
            .buf_pos = 0,
            .buf_len = 0,
        };
    }

    fn fill(self: *TxtByteReader) anyerror!void {
        if (self.eof) return;
        const n = try self.reader.read(self.buf[0..]);
        if (n == 0) {
            self.eof = true;
            self.buf_len = 0;
            self.buf_pos = 0;
            return;
        }
        self.buf_len = n;
        self.buf_pos = 0;
    }

    pub fn peek(self: *TxtByteReader) anyerror!?u8 {
        if (self.buf_pos >= self.buf_len) {
            try self.fill();
            if (self.eof) return null;
        }
        return self.buf[self.buf_pos];
    }

    pub fn get(self: *TxtByteReader) anyerror!?u8 {
        const b = try self.peek();
        if (b == null) return null;
        self.buf_pos += 1;
        self.offset += 1;
        return b;
    }
};

pub const TxtTokenizer = struct {
    br: *TxtByteReader,

    fn isSep(b: u8) bool {
        return b == ' ' or b == '\t' or b == '\n' or b == '\r';
    }

    fn utf8Advance(expected: *u8, b: u8) bool {
        if (expected.* == 0) {
            if (b < 0x80) return true;
            if (b >= 0xC2 and b <= 0xDF) {
                expected.* = 1;
                return true;
            }
            if (b >= 0xE0 and b <= 0xEF) {
                expected.* = 2;
                return true;
            }
            if (b >= 0xF0 and b <= 0xF4) {
                expected.* = 3;
                return true;
            }
            return false;
        }

        if (b >= 0x80 and b <= 0xBF) {
            expected.* -= 1;
            return true;
        }
        return false;
    }

    pub fn next(self: *TxtTokenizer, out_word: []u8) anyerror!TxtToken {
        const sep_start = self.br.offset;
        var newline_count: u32 = 0;
        var consumed_sep = false;

        while (true) {
            const maybe_b = try self.br.peek();
            if (maybe_b == null) {
                return TxtToken{
                    .kind = .Eof,
                    .start_offset = self.br.offset,
                    .end_offset = self.br.offset,
                    .word_len = 0,
                };
            }
            const b = maybe_b.?;

            if (b == ' ' or b == '\t') {
                consumed_sep = true;
                _ = try self.br.get();
                continue;
            }
            if (b == '\n') {
                consumed_sep = true;
                newline_count += 1;
                _ = try self.br.get();
                continue;
            }
            if (b == '\r') {
                consumed_sep = true;
                newline_count += 1;
                _ = try self.br.get();
                if (try self.br.peek()) |nxt| {
                    if (nxt == '\n') {
                        _ = try self.br.get();
                    }
                }
                continue;
            }

            break;
        }

        if (consumed_sep and newline_count >= 1) {
            if (newline_count == 1) {
                return TxtToken{
                    .kind = .LineBreak,
                    .start_offset = sep_start,
                    .end_offset = self.br.offset,
                    .word_len = 0,
                };
            } else {
                return TxtToken{
                    .kind = .ParagraphBreak,
                    .start_offset = sep_start,
                    .end_offset = self.br.offset,
                    .word_len = 0,
                };
            }
        }

        const word_start = self.br.offset;
        var stored_len: usize = 0;
        var last_boundary_len: usize = 0;
        var expected_cont: u8 = 0;

        while (true) {
            const maybe_b = try self.br.peek();
            if (maybe_b == null) break;
            const b = maybe_b.?;
            if (isSep(b)) break;
            _ = try self.br.get();

            if (!utf8Advance(&expected_cont, b)) {
                return TokenizerError.InvalidUtf8;
            }

            if (stored_len < out_word.len) {
                out_word[stored_len] = b;
                stored_len += 1;
                if (expected_cont == 0) {
                    last_boundary_len = stored_len;
                }
            }
        }

        if (expected_cont != 0) {
            return TokenizerError.InvalidUtf8;
        }

        return TxtToken{
            .kind = .Word,
            .start_offset = word_start,
            .end_offset = self.br.offset,
            .word_len = last_boundary_len,
        };
    }
};

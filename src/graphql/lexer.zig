const std = @import("std");
const unicode = std.unicode;

pub const TokenKind = enum {
    unknown,
    identifier,
    lbrack,
    rbrack,
    lsqbrack,
    rsqbrack,
    lparen,
    rparen,
    colon,
    at,
    whitespace,
    newline,
    comment,
    comma,
    bang,
    dquote,
    string,
    ampersand,
    bar,
    equals,
    int,
    float,
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
    lineNum: u64,
    offset: u64,
};

pub const Error = error{
    unknownToken,
    internalWrongNumBytes,
    internalNullNBytes,
    unexpectedEof,
    unterminatedString,
};

pub const LexResult = struct {
    tokens: []Token,
    _data: []const u8,
};

pub fn tokenize(alloc: std.mem.Allocator, path: []const u8) !LexResult {
    var tokenizer = try Tokenizer.create(alloc, path);
    const tokens = try tokenizer.tokenize(alloc);
    return .{
        .tokens = tokens,
        ._data = tokenizer.buf,
    };
}

const Tokenizer = struct {
    buf: []u8,
    iter: unicode.Utf8Iterator,

    lineNum: u64 = 0,
    pos: u64 = 0,
    currentOffset: u64 = 0,

    alloc: std.mem.Allocator,

    fn create(alloc: std.mem.Allocator, path: []const u8) !Tokenizer {
        const file = try std.fs.cwd().openFile(path, .{});
        const buf = try file.readToEndAlloc(alloc, 65535);

        var view = try unicode.Utf8View.init(buf);
        const iter = view.iterator();

        return .{
            .buf = buf,
            .iter = iter,
            .alloc = alloc,
        };
    }

    fn tokenize(self: *Tokenizer, alloc: std.mem.Allocator) ![]Token {
        var tokens = std.ArrayList(Token).init(alloc);

        // TODO move BOM check to standard lexing. Spec says we can just ignore it in the middle of files.
        const first = self.iter.peek(1);
        if (first.len == 3 and first[0] == 0xEF and first[1] == 0xBB and first[2] == 0xBF) {
            _ = self.iter.nextCodepointSlice();
            self.pos = 3;
        }

        while (true) {
            const next = self.iter.peek(1);
            if (next.len == 0) {
                break;
            }

            var token: Token = undefined;
            if (isNameStart(next)) {
                token = self.readIdent();
            } else if (isWhiteSpace(next)) {
                token = self.readWhiteSpace();
            } else if (isNewLine(next)) {
                token = try self.readNewLine(next[0]);
            } else if (isDigit(next)) {
                token = try self.readNumber();
            } else if (eq(next, '#')) {
                token = self.readComment();
            } else if (eq(next, '{')) {
                token = self.nextCharAs(.lbrack);
            } else if (eq(next, '}')) {
                token = self.nextCharAs(.rbrack);
            } else if (eq(next, '@')) {
                token = self.nextCharAs(.at);
            } else if (eq(next, '&')) {
                token = self.nextCharAs(.ampersand);
            } else if (eq(next, '|')) {
                token = self.nextCharAs(.bar);
            } else if (eq(next, ':')) {
                token = self.nextCharAs(.colon);
            } else if (eq(next, '!')) {
                token = self.nextCharAs(.bang);
            } else if (eq(next, '(')) {
                token = self.nextCharAs(.lparen);
            } else if (eq(next, ')')) {
                token = self.nextCharAs(.rparen);
            } else if (eq(next, ',')) {
                token = self.nextCharAs(.comma);
            } else if (eq(next, '[')) {
                token = self.nextCharAs(.lsqbrack);
            } else if (eq(next, ']')) {
                token = self.nextCharAs(.rsqbrack);
            } else if (eq(next, '=')) {
                token = self.nextCharAs(.equals);
            } else if (eq(next, '"')) {
                token = try self.readStringOrBlock();
            } else {
                return Error.unknownToken;
            }
            try tokens.append(token);
        }

        return tokens.toOwnedSlice();
    }

    fn eq(cp: []const u8, ci: comptime_int) bool {
        return cp.len == 1 and cp[0] == ci;
    }

    fn isWhiteSpace(cp: []const u8) bool {
        return cp.len == 1 and (cp[0] == ' ' or cp[0] == '\t');
    }

    fn isLetter(cp: []const u8) bool {
        return cp.len == 1 and ((cp[0] >= 'a' and cp[0] <= 'z') or (cp[0] >= 'A' and cp[0] <= 'Z'));
    }

    fn isDigit(cp: []const u8) bool {
        return cp.len == 1 and (cp[0] >= '0' and cp[0] <= '9');
    }

    fn isNameStart(cp: []const u8) bool {
        return isLetter(cp) or eq(cp, '_');
    }

    fn isNameContinue(cp: []const u8) bool {
        return isNameStart(cp) or isDigit(cp);
    }

    fn isNewLine(cp: []const u8) bool {
        return eq(cp, '\r') or eq(cp, '\n');
    }

    fn notNewLine(cp: []const u8) bool {
        return !(eq(cp, '\r') or eq(cp, '\n'));
    }

    fn readIdent(self: *Tokenizer) Token {
        return self.readWhile(.identifier, isNameContinue);
    }

    fn readWhiteSpace(self: *Tokenizer) Token {
        return self.readWhile(.whitespace, isWhiteSpace);
    }

    fn readComment(self: *Tokenizer) Token {
        return self.readWhile(.comment, notNewLine);
    }

    fn readNewLine(self: *Tokenizer, char: u8) !Token {
        const ret = blk: {
            if (char == '\n') {
                break :blk self.nextCharAs(.newline);
            }

            const next = self.iter.peek(2);
            if (std.mem.eql(u8, next, "\r\n")) {
                break :blk try self.nextNBytesAs(.newline, 2);
            }

            // I really cannot fathom why but the spec clearly says a lone carriage
            // return is a valid line terminator. I don't condone this, and I also
            // don't condone anyone who has random carriage returns in their file and
            // expects things to work correctly.
            //
            // This will not work correctly and whoever comes across this deserves as
            // such.
            break :blk self.nextCharAs(.newline);
        };

        self.currentOffset = 0;
        self.lineNum += 1;

        return ret;
    }

    fn readNumber(self: *Tokenizer) !Token {
        const startPos = self.pos;

        // TODO: negative
        // TODO: no leading zeros

        while (true) {
            const next = self.iter.peek(1);
            if (!isDigit(next)) {
                break;
            }
            _ = self.readChar();
            self.pos += next.len;
        }

        const peeked = self.iter.peek(1);
        if (!eq(peeked, '.')) {
            return .{
                .kind = .int,
                .value = self.buf[startPos..self.pos],

                .offset = self.currentOffset,
                .lineNum = self.lineNum,
            };
        }

        _ = try self.mustReadChar();

        // TODO: exponent form

        while (true) {
            const next = self.iter.peek(1);
            if (!isDigit(next)) {
                break;
            }
            _ = self.readChar();
            self.pos += next.len;
        }

        return .{
            .kind = .float,
            .value = self.buf[startPos..self.pos],

            .offset = self.currentOffset,
            .lineNum = self.lineNum,
        };
    }

    fn readStringOrBlock(self: *Tokenizer) !Token {
        const next3 = self.iter.peek(3);
        const memeql = std.mem.eql;
        if (next3.len == 1) {
            return Error.unknownToken;
        } else if (memeql(u8, next3, "\"\"\"")) {
            return self.readBlock();
        } else if (memeql(u8, next3[0..2], "\"\"")) {
            return try self.nextNBytesAs(.string, 2);
        } else if (memeql(u8, next3[0..1], "\"")) {
            return try self.readString();
        } else {
            return Error.unknownToken;
        }
    }

    fn readString(self: *Tokenizer) !Token {
        const startPos = self.pos + 1;
        const offset = self.currentOffset;

        // Assume the caller peeked. There's no chance we use this,
        // so it's safe to be the first prev.
        var prev = try self.mustReadChar();
        var len: u64 = 1;
        while (true) {
            const next = try self.mustReadChar();
            if (isNewLine(next)) {
                return Error.unterminatedString;
            }

            len += next.len;

            // TODO: this doesn't actually handle the escape sequence
            // past not terminating the string.
            if (eq(next, '"') and !eq(prev, '\\')) {
                break;
            }

            prev = next;
        }

        self.pos += len;
        const val = self.buf[startPos .. self.pos - 1];

        return .{
            .kind = .string,
            .value = val,
            .lineNum = self.lineNum,
            .offset = offset,
        };
    }

    fn readBlock(self: *Tokenizer) !Token {
        const offset = self.currentOffset;

        self.discardNChars(3);

        var lines = std.ArrayList([]u8).init(self.alloc);
        var indent: ?u64 = null;
        var currIndent: u64 = 0;
        var firstNonWhitespace = false;
        var linePos = self.pos;
        var firstLine = true;
        var removeFirstLine = true;
        while (true) {
            const next = try self.mustReadChar();
            self.pos += next.len;

            if (!firstLine and !firstNonWhitespace) {
                if (isWhiteSpace(next)) {
                    currIndent += 1;
                    continue;
                }

                firstNonWhitespace = true;
                if (indent == null or currIndent < indent.?) {
                    indent = currIndent;
                }
            }

            if (firstLine and !isWhiteSpace(next) and !isNewLine(next)) {
                removeFirstLine = false;
            }

            const memeql = std.mem.eql;
            var numNewlineChars: u64 = 1;
            if (memeql(u8, next, "\n")) {
                const peeked = self.iter.peek(1);
                if (memeql(u8, peeked, "\r")) {
                    numNewlineChars += 1;
                    _ = self.readChar();
                }
                try lines.append(self.buf[linePos .. self.pos - numNewlineChars]);
                currIndent = 0;
                linePos = self.pos;
                firstLine = false;
                self.lineNum += 1;
                self.currentOffset = 0;
            } else if (memeql(u8, next, "\r")) {
                try lines.append(self.buf[linePos .. self.pos - numNewlineChars]);
                currIndent = 0;
                linePos = self.pos;
                firstLine = false;
                self.lineNum += 1;
                self.currentOffset = 0;
            }

            // TODO: handle escape chars
            if (memeql(u8, self.iter.peek(3), "\"\"\"")) {
                try lines.append(self.buf[linePos..self.pos]);
                self.discardNChars(3);
                break;
            }
        }

        var output = std.ArrayList(u8).init(self.alloc);
        for (lines.items, 0..lines.items.len) |line, i| {
            if (i == 0) {
                if (removeFirstLine) {
                    continue;
                }

                try output.appendSlice(line);
            } else {
                try output.appendSlice(line[indent orelse 0 ..]);
            }
        }

        return .{
            .kind = .string,
            .value = try output.toOwnedSlice(),
            .lineNum = self.lineNum,
            .offset = offset,
        };
    }

    fn readWhile(self: *Tokenizer, kind: TokenKind, predicate: fn ([]const u8) bool) Token {
        const startPos = self.pos;
        const offset = self.currentOffset;
        var len: u64 = 0;
        while (predicate(self.iter.peek(1))) {
            const next = self.readChar();
            if (next == null) {
                break;
            }
            len += next.?.len;
        }

        self.pos += len;
        const val = self.buf[startPos..self.pos];

        return .{
            .kind = kind,
            .value = val,
            .lineNum = self.lineNum,
            .offset = offset,
        };
    }

    fn readChar(self: *Tokenizer) ?[]const u8 {
        self.currentOffset += 1;
        return self.iter.nextCodepointSlice();
    }

    inline fn mustReadChar(self: *Tokenizer) ![]const u8 {
        return self.readChar() orelse Error.unexpectedEof;
    }

    fn nextCharAs(self: *Tokenizer, kind: TokenKind) Token {
        const offset = self.currentOffset;
        // we peek before calling this, so val is never null
        const val = self.readChar().?;
        self.pos += val.len;
        return .{
            .kind = kind,
            .value = val,
            .offset = offset,
            .lineNum = self.lineNum,
        };
    }

    fn nextNBytesAs(self: *Tokenizer, kind: TokenKind, numBytes: usize) !Token {
        const offset = self.currentOffset;
        self.currentOffset += numBytes;

        const startPos = self.pos;
        const val = self.buf[startPos..(startPos + numBytes)];
        self.pos += numBytes;

        var i = numBytes;
        while (true) {
            const next = self.readChar();
            if (next == null) {
                return Error.internalNullNBytes;
            }
            i -= next.?.len;

            if (i == 0) {
                break;
            } else if (i < 0) {
                return Error.internalWrongNumBytes;
            }
        }

        return .{
            .kind = kind,
            .value = val,
            .lineNum = self.lineNum,
            .offset = offset,
        };
    }

    fn discardNChars(self: *Tokenizer, numChars: u8) void {
        self.currentOffset += numChars;
        for (0..numChars) |_| {
            const next = self.readChar();
            if (next != null) {
                self.pos += next.?.len;
            }
        }
    }
};

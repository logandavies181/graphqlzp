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
};

pub const Tokenizer = struct {
    allocator: std.mem.Allocator,
    buf: []u8,
    iter: unicode.Utf8Iterator,

    lineNum: u64 = 0,
    pos: u64 = 0,
    currentOffset: u64 = 0,

    pub fn create(path: []const u8, allocator: std.mem.Allocator) !Tokenizer {
        const file = try std.fs.cwd().openFile(path, .{});
        const buf = try file.readToEndAlloc(allocator, 65535);

        var view = try unicode.Utf8View.init(buf);
        const iter = view.iterator();

        return .{
            .allocator = allocator,
            .buf = buf,
            .iter = iter,
        };
    }

    pub fn tokenize(self: *Tokenizer) ![]Token {
        var tokens = std.ArrayList(Token).init(self.allocator);

        while (true) {
            const next = self.iter.peek(1);
            if (next.len == 0) {
                break;
            }

            var token: Token = undefined;
            if (isLetter(next)) {
                token = self.readIdent();
            } else if (isWhiteSpace(next)) {
                token = self.readWhiteSpace();
            } else if (isNewLine(next)) {
                token = try self.readNewLine(next[0]);
            } else if (eq(next, '#')) {
                token = self.readComment();
            } else if (eq(next, '{')) {
                token = self.nextCharAs(.lbrack);
            } else if (eq(next, '}')) {
                token = self.nextCharAs(.rbrack);
            } else if (eq(next, '@')) {
                token = self.nextCharAs(.at);
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

    fn isIdentChar(cp: []const u8) bool {
        return isDigit(cp) or isLetter(cp) or eq(cp, '_');
    }

    fn isNewLine(cp: []const u8) bool {
        return eq(cp, '\r') or eq(cp, '\n');
    }

    fn notNewLine(cp: []const u8) bool {
        return !(eq(cp, '\r') or eq(cp, '\n'));
    }

    fn readIdent(self: *Tokenizer) Token {
        return self.readWhile(.identifier, isIdentChar);
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

    fn readStringOrBlock(self: *Tokenizer) !Token {
        // TODO: check if next todo still needs doing
        // TODO: don't include quotes in the value

        const next3 = self.iter.peek(3);
        const memeql = std.mem.eql;
        if (next3.len == 1) {
            return Error.unknownToken;
        } else if (memeql(u8, next3, "\"\"\"")) {
            return self.readBlock();
        } else if (memeql(u8, next3[0..2], "\"\"")) {
            return try self.nextNBytesAs(.string, 2);
        } else if (memeql(u8, next3[0..1], "\"")) {
            return self.readString();
        } else {
            return Error.unknownToken;
        }
    }

    fn readString(self: *Tokenizer) Token {
        return self.readWhile(.string, _readStringWhileFunc());
    }

    fn _readStringWhileFunc() fn ([]const u8) bool {
        // at the very least this isn't threadsafe
        return struct {
            var numDquote: u8 = 0;
            fn func(cp: []const u8) bool {
                if (numDquote > 1) {
                    // _readStringWhileFunc seems to return the same anonymous struct instance
                    // each time, so we need to reset the var when done.
                    numDquote = 0;
                    return false;
                }
                if (eq(cp, '"')) {
                    numDquote += 1;
                }
                return true;
            }
        }.func;
    }

    fn readBlock(self: *Tokenizer) Token {
        const startPos = self.pos;
        const offset = self.currentOffset;
        self.discardNChars(3);

        var len: u64 = 6;
        while (!std.mem.eql(u8, self.iter.peek(3), "\"\"\"")) {
            const next = self.readChar();
            if (next == null) {
                break;
            }
            len += next.?.len;
        }
        self.discardNChars(3);

        self.pos += len;
        const val = self.buf[startPos..self.pos];

        return .{
            .kind = .string,
            .value = val,
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

    fn nextCharAs(self: *Tokenizer, kind: TokenKind) Token {
        const offset = self.currentOffset;
        self.currentOffset += 1;
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
            _ = self.readChar();
        }
    }
};

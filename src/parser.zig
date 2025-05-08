const std = @import("std");

const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

const Keyword = enum {
    unknown,
    type,
    interface,
};

const Error = error {
    badParse,
    noneNext,
    notImplemented,
    todo,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    iter: Iterator,

    pub fn create(alloc: std.mem.Allocator, tokens: []Token) Parser {
        return .{
            .alloc = alloc,
            .iter = Iterator.create(tokens),
        };
    }

    fn tryParse(self: *Parser) !Document {
        var types = std.ArrayList(Object).init(self.alloc);
        var interfaces = std.ArrayList(Interface).init(self.alloc);

        while (true) {
            const _next = self.iter.next();
            if (_next == null) {
                break;
            }
            const next = _next.?;

            switch (next.kind) {
                TokenKind.identifier => {
                    switch (checkKeyword(next.value)) {
                        .type => {
                            try types.append(try self.parseObject());
                        },
                        .interface => {
                            try interfaces.append(try self.parseInterface());
                        },
                        else => return Error.badParse,
                    }
                },
                TokenKind.comma => _ = void,
                TokenKind.comment => _ = void,
                TokenKind.newline => _ = void,
                TokenKind.whitespace => _ = void,
                // TODO: handle random strings, and docstrings
                else => return Error.todo,
            }
        }

        return .{
            .types = try types.toOwnedSlice(),
        };
    }

    pub fn parse(self: *Parser) !Document {
        return self.tryParse() catch |err|
            switch (err) {
                Error.badParse => blk: {
                    const curr = self.iter.current();
                    std.debug.print("\nBad parse at: {d}. Found: {s}\n", .{curr.startPos, @tagName(curr.kind)});
                    break :blk err;
                },
                else => blk: {
                    std.debug.print("unknown error: {any}\n", .{err});
                    break :blk err;
                },
            };
    }

    fn checkKeyword(id: []const u8) Keyword {
        const memeql = std.mem.eql;
        return if (memeql(u8, id, "type"))
            .type
        else if (memeql(u8, id, "interface"))
            .interface
        else
            .unknown;

    }

    fn parseIdent(self: *Parser) !void {
        const next = self.iter.next();
        const memeql = std.mem.eql;

        if (memeql(u8, next.value, "type")) {
            try self.parseTypeDef();
        }
    }

    fn parseObject(self: *Parser) !Object {
        const st = try self.parse_struct(true);

        return .{
            .description = st.description,
            .name = st.name,
            .nullable = st.nullable,
            .fields = st.fields,
            .pos = st.pos,
        };
    }

    fn parseInterface(self: *Parser) !Interface {
        const st = try self.parse_struct(false);

        return .{
            .description = st.description,
            .name = st.name,
            .nullable = st.nullable,
            .fields = st.fields,
            .pos = st.pos,
        };
    }

    fn parse_struct(self: *Parser, isObj: bool) !_struct {
        const name = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier});

        if (isObj) {
            // TODO: check for interfaces
            _ = void;
        }

        _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.lbrack});

        var fields = std.ArrayList(Field).init(self.alloc);

        while (true) {
            const next = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier, .rbrack, .string});
            switch (next.kind) {
                TokenKind.rbrack => break,
                TokenKind.string => return Error.notImplemented,
                TokenKind.identifier => {
                    try fields.append(try self.parseFieldDef(next, null));
                },
                else => return Error.badParse,
            }
        }

        return .{
            .description = null, // TODO
            .name = name.value,
            // TODO: nullable
            .fields = try fields.toOwnedSlice(),
            .pos = name.startPos,
        };
    }

    fn parseFieldDef(self: *Parser, name: Token, description: ?[]const u8) !Field {
        _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.colon});
        const next = try self.iter.requireNextMeaningful(&[_]TokenKind{.lsqbrack, .identifier});
        return switch (next.kind) {
            TokenKind.identifier => blk: {
                var nullable = true;
                const nnext = self.iter.peek(1);
                if (nnext.len != 0 and nnext[0].kind == TokenKind.bang) {
                    _ = self.iter.next();
                    nullable = false;
                }

                break :blk .{
                    .description = description,
                    .nullable = nullable,
                    .name = name.value,
                    .pos = name.startPos,
                    .type = next.value,
                };
            },
            TokenKind.lsqbrack => blk: {
                break :blk Error.notImplemented;
            },
            else => Error.badParse,
        };
    }
};

const Iterator = struct {
    index: u64 = 0,
    tokens: []Token,

    fn create(tokens: []Token) Iterator {
        return .{
            .tokens = tokens,
        };
    }

    fn copy(self: *Iterator) Iterator {
        return .{
            .index = self.index,
            .tokens = self.tokens,
        };
    }

    fn current(self: *Iterator) Token {
        return self.tokens[self.index];
    }

    fn next(self: *Iterator) ?Token {
        if (self.index == self.tokens.len) {
            return null;
        }

        const ret = self.tokens[self.index];
        std.debug.print("{s}", .{ret.value});
        self.index += 1;
        return ret;
    }

    fn peek(self: *Iterator, numPeek: u64) []Token {
        return if (self.tokens.len - self.index < numPeek)
            self.tokens[self.index..]
        else
            self.tokens[self.index..self.index+numPeek];
    }

    fn mustNext(self: *Iterator) !Token {
        return self.next() orelse Error.noneNext;
    }

    fn requireNextMeaningful(self: *Iterator, kinds: []const TokenKind) !Token {
        while (true) {
            const next_ = try self.mustNext();

            switch (next_.kind) {
                TokenKind.comma => _ = void,
                TokenKind.comment => _ = void,
                TokenKind.newline => _ = void,
                TokenKind.whitespace => _ = void,
                else => {
                    for (kinds) |kind| {
                        if (next_.kind == kind) {
                            return next_;
                        }
                    }
                    return Error.badParse;
                },
            }
        }
    }
};

const Ast = struct {

};

const Document = struct {
    types: []Object, // TODO
};

const Type = union {
    Scalar: Scalar,
    Object: Object,
    // Interface,
    // Union,
    // Enum,
    // Input,
};

const _struct = struct {
    description: ?[]const u8,
    nullable: bool = true,
    name: []const u8,
    fields: []Field,

    pos: u64,
};

const Object = struct {
    description: ?[]const u8,
    nullable: bool = true,
    name: []const u8,
    // interfaces: []*Interface,
    // directives: []*Directive,
    fields: []Field,

    pos: u64,
};

const Field = struct {
    description: ?[]const u8,
    nullable: bool = false,
    name: []const u8,
    type: []const u8, // TODO

    pos: u64,
};

const Interface = struct {
    description: ?[]const u8,
    name: []const u8,
    nullable: bool = true,
    fields: []Field,

    pos: u64,
};
const Directive = struct {};
const Scalar = struct {
};

const std = @import("std");

const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

const Keyword = enum {
    unknown,
    implements,
    interface,
    scalar,
    type,
};

const Error = error{
    badParse,
    badFieldDefParse,
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
        var scalars = std.ArrayList(Scalar).init(self.alloc);

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
                        .scalar => {
                            try scalars.append(try self.parseScalar());
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
                    std.debug.print("\nBad parse at: {d}. Found: {s}\n", .{ curr.startPos, @tagName(curr.kind) });
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
        else if (memeql(u8, id, "implements"))
            .implements
        else if (memeql(u8, id, "interface"))
            .interface
        else if (memeql(u8, id, "scalar"))
            .scalar
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
        return try self.parse_struct(Object);
    }

    fn parseInterface(self: *Parser) !Interface {
        return try self.parse_struct(Interface);
    }

    fn parse_struct(self: *Parser, ty: type) !ty {
        const name = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier});

        var implements: ?[]NamedType = null;
        if (ty == Object) {
            const next_ = self.iter.peekNextMeaningful();
            if (next_ != null and next_.?.kind == TokenKind.identifier) {
                const kw = checkKeyword(next_.?.value);
                if (kw != Keyword.implements) {
                    return Error.badParse;
                }

                _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier});
                implements = try self.parseImplements();
            }
        }

        _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.lbrack});

        var fields = std.ArrayList(Field).init(self.alloc);

        while (true) {
            const next = try self.iter.requireNextMeaningful(&[_]TokenKind{ .identifier, .rbrack, .string });
            switch (next.kind) {
                TokenKind.rbrack => break,
                TokenKind.string => return Error.notImplemented,
                TokenKind.identifier => {
                    const fld = try self.parseFieldDef(next, null);
                    try fields.append(fld);
                },
                else => return Error.badParse,
            }
        }

        var ret: ty = .{
            .description = null, // TODO
            .name = name.value,
            // TODO: nullable
            .fields = try fields.toOwnedSlice(),
            .pos = name.startPos,
        };

        if (ty == Object) {
            ret.implements = implements;
        }

        return ret;
    }

    fn parseImplements(self: *Parser) ![]NamedType {
        var implements = std.ArrayList(NamedType).init(self.alloc);

        // TODO ampersands / multiple interfaces
        const next_ = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier});
        try implements.append(.{
            .name = next_.value,
        });

        return try implements.toOwnedSlice();
    }

    fn parseFieldDef(self: *Parser, name: Token, description: ?[]const u8) !Field {
        _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.colon});
        const next = try self.iter.requireNextMeaningful(&[_]TokenKind{ .lsqbrack, .identifier });
        return switch (next.kind) {
            TokenKind.identifier => blk: {
                var nullable = true;
                const nnext = self.iter.peek(1);
                if (nnext.len != 0 and nnext[0].kind == TokenKind.bang) {
                    _ = self.iter.next();
                    nullable = false;
                }

                var directives: ?[]Directive = null;
                const nextMeaningful = self.iter.peekNextMeaningful();
                if (nextMeaningful != null and nextMeaningful.?.kind == TokenKind.at) {
                    directives = self.parseDirectives();
                }

                break :blk .{
                    .description = description,
                    .directives = directives,
                    .nullable = nullable,
                    .name = name.value,
                    .pos = name.startPos,
                    .type = next.value,
                };
            },
            TokenKind.lsqbrack => blk: {
                break :blk Error.notImplemented;
            },
            else => Error.badFieldDefParse,
        };
    }

    fn parseDirectives(self: *Parser) ?[]Directive {
        _ = self.iter.next();
        _ = self.iter.next();
        _ = self.iter.next();

        // TODO
        return null;
    }

    fn parseScalar(self: *Parser) !Scalar {
        const name = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier});

        // TODO: directives

        return .{
            .name = name.value,
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
        // TODO remove this print
        std.debug.print("{s}", .{ret.value});
        self.index += 1;
        return ret;
    }

    fn peek(self: *Iterator, numPeek: u64) []Token {
        return if (self.tokens.len - self.index < numPeek)
            self.tokens[self.index..]
        else
            self.tokens[self.index .. self.index + numPeek];
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

    fn requireNextMeaningfulSameLine(self: *Iterator) !Token {
        const curr = self.index;
        while (true) {
            const next_ = try self.mustNext();

            switch (next_.?.kind) {
                TokenKind.comma => _ = void,
                TokenKind.comment => _ = void,
                TokenKind.whitespace => _ = void,
                TokenKind.newline => _ = {
                    return Error.badParse;
                },
                else => {
                    self.index = curr;
                    return next_;
                },
            }
        }
    }

    fn peekNextMeaningful(self: *Iterator) ?Token {
        const curr = self.index;
        while (true) {
            const next_ = self.next();

            if (next_ == null) {
                return null;
            }

            switch (next_.?.kind) {
                TokenKind.comma => _ = void,
                TokenKind.comment => _ = void,
                TokenKind.newline => _ = void,
                TokenKind.whitespace => _ = void,
                else => {
                    self.index = curr;
                    return next_;
                },
            }
        }
    }
};

const Ast = struct {};

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
    implements: ?[]NamedType = null,
    // directives: []*Directive,
    fields: []Field,

    pos: u64,
};

const Field = struct {
    description: ?[]const u8,
    nullable: bool = false,
    name: []const u8,
    type: []const u8, // TODO
    directives: ?[]Directive = null,

    pos: u64,
};

const Interface = struct {
    description: ?[]const u8,
    name: []const u8,
    nullable: bool = true,
    fields: []Field,

    pos: u64,
};

const Directive = struct {
    args: ?[]Arg,
};

const Arg = struct {
    name: []const u8,
    typeName: []const u8,
};

const Scalar = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    directives: ?[]Directive = null,
};

const NamedType = struct {
    name: []const u8,
};

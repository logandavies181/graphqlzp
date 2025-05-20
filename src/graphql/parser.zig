const std = @import("std");

const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

const ast = @import("ast.zig");
const Arg = ast.Arg;
const Directive = ast.Directive;
const Document = ast.Document;
const Field = ast.Field;
const Interface = ast.Interface;
const NamedType = ast.NamedType;
const Object = ast.Object;
const Scalar = ast.Scalar;
const Schema = ast.Schema;
const TypeRef = ast.TypeRef;

const Keyword = enum {
    unknown,
    implements,
    interface,
    scalar,
    schema,
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
        var objects = std.ArrayList(Object).init(self.alloc);
        var interfaces = std.ArrayList(Interface).init(self.alloc);
        var scalars = std.ArrayList(Scalar).init(self.alloc);
        var schema: ?Schema = null;

        while (true) {
            const _next = self.iter.next();
            if (_next == null) {
                break;
            }
            const next = _next.?;

            var desc: ?[]const u8 = null;
            switch (next.kind) {
                TokenKind.identifier => {
                    switch (checkKeyword(next.value)) {
                        .type => {
                            var item = try self.parseObject();
                            item.description = desc;
                            desc = null;
                            try objects.append(item);
                        },
                        .interface => {
                            var item = try self.parseInterface();
                            item.description = desc;
                            desc = null;
                            try interfaces.append(item);
                        },
                        .scalar => {
                            var item = try self.parseScalar();
                            item.description = desc;
                            desc = null;
                            try scalars.append(item);
                        },
                        .schema => {
                            if (schema != null) {
                                return Error.badParse;
                            }

                            schema = try self.parseSchema(next.offset, next.lineNum);
                            schema.?.description = desc;
                            desc = null;
                        },
                        else => return Error.badParse,
                    }
                },
                TokenKind.string => {
                    if (desc == null) {
                        desc = next.value;
                    } else {
                        return Error.badParse;
                    }
                },
                TokenKind.comma => _ = void,
                TokenKind.comment => _ = void,
                TokenKind.newline => _ = void,
                TokenKind.whitespace => _ = void,
                else => return Error.todo,
            }
        }

        // ensure schema is set
        if (schema == null) {
            var query: ?NamedType = null;
            var mutation: ?NamedType = null;
            var subscription: ?NamedType = null;

            for (objects.items) |obj| {
                const memeql = std.mem.eql;
                if (memeql(u8, obj.name, "Query")) {
                    query = .{
                        .name = obj.name,
                        .offset = obj.offset,
                        .lineNum = obj.lineNum,
                    };
                } else if (memeql(u8, obj.name, "Mutation")) {
                    mutation = .{
                        .name = obj.name,
                        .offset = obj.offset,
                        .lineNum = obj.lineNum,
                    };
                } else if (memeql(u8, obj.name, "Subscription")) {
                    subscription = .{
                        .name = obj.name,
                        .offset = obj.offset,
                        .lineNum = obj.lineNum,
                    };
                }
            }

            if (query == null) {
                return Error.badParse;
            }

            schema = .{
                .query = query.?,
                .mutation = mutation,
                .subscription = subscription,
            };
        }

        return .{
            .objects = try objects.toOwnedSlice(),
            .interfaces = try interfaces.toOwnedSlice(),
            .scalars = try scalars.toOwnedSlice(),
            .schema = schema.?,
        };
    }

    pub fn parse(self: *Parser) !Document {
        return self.tryParse() catch |err|
            switch (err) {
                Error.badParse => blk: {
                    const curr = self.iter.current();
                    std.debug.print("\nBad parse at line: {d}, offset: {d}. Found: {s}\n", .{ curr.lineNum, curr.offset, @tagName(curr.kind) });
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
        else if (memeql(u8, id, "schema"))
            .schema
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
                _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier}); // impements keyword

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
            .fields = try fields.toOwnedSlice(),

            .offset = name.offset,
            .lineNum = name.lineNum,
        };

        if (ty == Object) {
            ret.implements = implements;
        }

        return ret;
    }

    fn parseSchema(self: *Parser, offset: u64, lineNum: u64) !Schema {
        var directives: ?[]Directive = null;
        const nextMeaningful = self.iter.peekNextMeaningful();
        if (nextMeaningful != null and nextMeaningful.?.kind == TokenKind.at) {
            directives = self.parseDirectives();
        }
        _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.lbrack});

        var query: ?NamedType = null;
        var mutation: ?NamedType = null;
        var subscription: ?NamedType = null;

        var desc: ?[]const u8 = null;

        while (true) {
            const next = try self.iter.requireNextMeaningful(&[_]TokenKind{ .identifier, .rbrack, .string });
            switch (next.kind) {
                TokenKind.rbrack => break,
                TokenKind.string => {
                    if (desc == null) {
                        desc = next.value;
                    } else {
                        return Error.badParse;
                    }
                },
                TokenKind.identifier => {
                    const opname = next.value;

                    const fld = try self.parseFieldDef(next, desc);
                    desc = null;

                    const memeql = std.mem.eql;
                    if (memeql(u8, opname, "query")) {
                        if (query != null) {
                            return Error.badParse;
                        }
                        query = .{
                            .name = fld.name,
                            .offset = fld.offset,
                            .lineNum = fld.lineNum,
                        };
                    } else if (memeql(u8, opname, "mutation")) {
                        if (mutation != null) {
                            return Error.badParse;
                        }
                        mutation = .{
                            .name = fld.name,
                            .offset = fld.offset,
                            .lineNum = fld.lineNum,
                        };
                    } else if (memeql(u8, opname, "subscription")) {
                        if (subscription != null) {
                            return Error.badParse;
                        }
                        subscription = .{
                            .name = fld.name,
                            .offset = fld.offset,
                            .lineNum = fld.lineNum,
                        };
                    } else {
                        return Error.badParse;
                    }
                },
                else => return Error.badParse,
            }
        }

        if (query == null) {
            return error.badParse;
        }

        return .{
            .description = desc,
            .directives = directives,
            .query = query.?,
            .mutation = mutation,
            .subscription = subscription,

            .lineNum = lineNum,
            .offset = offset,
        };
    }

    fn parseImplements(self: *Parser) ![]NamedType {
        var implements = std.ArrayList(NamedType).init(self.alloc);

        // TODO ampersands / multiple interfaces
        const next_ = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier});
        try implements.append(.{
            .name = next_.value,
            .offset = next_.offset,
            .lineNum = next_.lineNum,
        });

        return try implements.toOwnedSlice();
    }

    fn parseFieldDef(self: *Parser, name: Token, description: ?[]const u8) !Field {
        var args: ?[]Arg = null;
        const colOrParen = try self.iter.requireNextMeaningful(&[_]TokenKind{ .colon, .lparen });

        if (colOrParen.kind == TokenKind.lparen) {
            args = try self.parseArgs();
            _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.colon});
        }

        const ty = try self.parseTypeRef();

        var directives: ?[]Directive = null;
        const nextMeaningful = self.iter.peekNextMeaningful();
        if (nextMeaningful != null and nextMeaningful.?.kind == TokenKind.at) {
            directives = self.parseDirectives();
        }

        return .{
            .description = description,
            .directives = directives,
            .name = name.value,
            .type = ty,

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseTypeRef(self: *Parser) !TypeRef {
        const next = try self.iter.requireNextMeaningful(&[_]TokenKind{ .lsqbrack, .identifier });
        return switch (next.kind) {
            TokenKind.identifier => {
                var nullable = true;
                const nnext = self.iter.peekNextMeaningful();
                if (nnext != null and nnext.?.kind == TokenKind.bang) {
                    _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.bang});
                    nullable = false;
                }

                return .{
                    .namedType = .{
                        .name = next.value,
                        .nullable = nullable,

                        .offset = next.offset,
                        .lineNum = next.lineNum,
                    },
                };
            },
            TokenKind.lsqbrack => {
                var ty = try self.parseTypeRef();
                _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.rsqbrack});

                var nullable = true;
                const nnext = self.iter.peekNextMeaningful();
                if (nnext != null and nnext.?.kind == TokenKind.bang) {
                    _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.bang});
                    nullable = false;
                }

                return .{
                    .listType = .{
                        .ty = &ty,
                        .nullable = nullable,
                    },
                };
            },
            else => Error.badFieldDefParse,
        };
    }

    fn parseArgs(self: *Parser) ![]Arg {
        var args = std.ArrayList(Arg).init(self.alloc);
        while (true) {
            const peeked = self.iter.peekNextMeaningful();
            if (peeked == null) {
                return Error.noneNext;
            } else if (peeked.?.kind == TokenKind.rparen) {
                _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.rparen});
                break;
            }

            const next = try self.parseArg();
            try args.append(next);
        }
        return try args.toOwnedSlice();
    }

    fn parseArg(self: *Parser) !Arg {
        const name = try self.iter.requireNextMeaningful(&[_]TokenKind{.identifier});
        _ = try self.iter.requireNextMeaningful(&[_]TokenKind{.colon});
        const ty = try self.parseTypeRef();

        return .{
            .name = name.value,
            .ty = ty,
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

            .offset = name.offset,
            .lineNum = name.lineNum,
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
        // std.debug.print("{s}", .{ret.value});
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

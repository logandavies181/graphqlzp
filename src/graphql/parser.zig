const std = @import("std");

const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

const ast = @import("ast.zig");
const Argument = ast.Argument;
const ArgumentDefinition = ast.ArgumentDefinition;
const Directive = ast.Directive;
const DirectiveDef = ast.DirectiveDef;
const DirectiveLocation = ast.DirectiveLocation;
const Document = ast.Document;
const Enum = ast.Enum;
const EnumValue = ast.EnumValue;
const Field = ast.Field;
const Input = ast.Input;
const InputField = ast.InputField;
const Interface = ast.Interface;
const NamedType = ast.NamedType;
const Object = ast.Object;
const Scalar = ast.Scalar;
const Schema = ast.Schema;
const TypeRef = ast.TypeRef;
const Union = ast.Union;
const Value = ast.Value;

const Keyword = enum {
    unknown,
    directive,
    enum_,
    false,
    implements,
    input,
    interface,
    null,
    on,
    repeatable,
    scalar,
    schema,
    true,
    type,
    union_,
};

const Error = error{
    badParse,
    badFieldDefParse,
    noneNext,
    noSchema,
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
        var directiveDefs = std.ArrayList(DirectiveDef).init(self.alloc);
        var enums = std.ArrayList(Enum).init(self.alloc);
        var inputs = std.ArrayList(Input).init(self.alloc);
        var interfaces = std.ArrayList(Interface).init(self.alloc);
        var objects = std.ArrayList(Object).init(self.alloc);
        var scalars = std.ArrayList(Scalar).init(self.alloc);
        var schema: ?Schema = null;
        var unions = std.ArrayList(Union).init(self.alloc);

        var desc: ?[]const u8 = null;
        while (true) {
            const _next = self.iter.next();
            if (_next == null) {
                break;
            }
            const next = _next.?;

            switch (next.kind) {
                .identifier => {
                    switch (checkKeyword(next.value)) {
                        .directive => {
                            var item = try self.parseDirectiveDef();
                            item.description = desc;
                            desc = null;
                            try directiveDefs.append(item);
                        },
                        .enum_ => {
                            var item = try self.parseEnum();
                            item.description = desc;
                            desc = null;
                            try enums.append(item);
                        },
                        .input => {
                            var item = try self.parseInput();
                            item.description = desc;
                            desc = null;
                            try inputs.append(item);
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
                        .type => {
                            var item = try self.parseObject();
                            item.description = desc;
                            desc = null;
                            try objects.append(item);
                        },
                        .union_ => {
                            var item = try self.parseUnion();
                            item.description = desc;
                            desc = null;
                            try unions.append(item);
                        },
                        else => return Error.badParse,
                    }
                },
                .string => {
                    if (desc == null) {
                        desc = next.value;
                    } else {
                        return Error.badParse;
                    }
                },
                .comma => _ = void,
                .comment => _ = void,
                .newline => _ = void,
                .whitespace => _ = void,
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
                return Error.noSchema;
            }

            schema = .{
                .query = query.?,
                .mutation = mutation,
                .subscription = subscription,
            };
        }

        return .{
            .directiveDefinitions = try directiveDefs.toOwnedSlice(),
            .enums = try enums.toOwnedSlice(),
            .inputs = try inputs.toOwnedSlice(),
            .interfaces = try interfaces.toOwnedSlice(),
            .objects = try objects.toOwnedSlice(),
            .scalars = try scalars.toOwnedSlice(),
            .schema = schema.?,
            .unions = try unions.toOwnedSlice(),
        };
    }

    pub fn parse(self: *Parser) !Document {
        return self.tryParse() catch |err|
            switch (err) {
                Error.badParse, Error.todo, Error.notImplemented => blk: {
                    const _curr = self.iter.next();
                    if (_curr != null) {
                        const curr = _curr.?;
                        std.debug.print("\n{any} at line: {d}, offset: {d}. Found: {s}\n", .{ err, curr.lineNum + 1, curr.offset, @tagName(curr.kind) });
                    } else {
                        if (self.iter.tokens.len == 0) {
                            std.debug.print("No tokens\n", .{});
                        } else {
                            std.debug.print("Probably last token\n", .{});
                        }
                    }
                    break :blk err;
                },
                Error.noSchema => blk: {
                    std.debug.print("Failed validation - no schema\n", .{});
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
        return if (memeql(u8, id, "directive"))
            .directive
        else if (memeql(u8, id, "enum"))
            .enum_
        else if (memeql(u8, id, "implements"))
            .implements
        else if (memeql(u8, id, "input"))
            .input
        else if (memeql(u8, id, "interface"))
            .interface
        else if (memeql(u8, id, "on"))
            .on
        else if (memeql(u8, id, "repeatable"))
            .repeatable
        else if (memeql(u8, id, "scalar"))
            .scalar
        else if (memeql(u8, id, "schema"))
            .schema
        else if (memeql(u8, id, "type"))
            .type
        else if (memeql(u8, id, "union"))
            .union_
        else
            .unknown;
    }

    fn checkDirectiveLocation(loc: []const u8) DirectiveLocation {
        const memeql = std.mem.eql;
        return if (memeql(u8, loc, "QUERY"))
            .query
        else if (memeql(u8, loc, "MUTATION"))
            .mutation
        else if (memeql(u8, loc, "SUBSCRIPTION"))
            .subscription
        else if (memeql(u8, loc, "FIELD"))
            .field
        else if (memeql(u8, loc, "FRAGMENT_DEFINITION"))
            .fragmentDefinition
        else if (memeql(u8, loc, "FRAGMENT_SPREAD"))
            .fragmentSpread
        else if (memeql(u8, loc, "INLINE_FRAGMENT"))
            .inlineFragment
        else if (memeql(u8, loc, "VARIABLE_DEFINITION"))
            .variableDefinition
        else if (memeql(u8, loc, "SCHEMA"))
            .schema
        else if (memeql(u8, loc, "SCALAR"))
            .scalar
        else if (memeql(u8, loc, "OBJECT"))
            .fieldDefinition
        else if (memeql(u8, loc, "FIELD_DEFINITION"))
            .argumentDefinition
        else if (memeql(u8, loc, "ARGUMENT_DEFINITION"))
            .interface
        else if (memeql(u8, loc, "INTERFACE"))
            .interface
        else if (memeql(u8, loc, "UNION"))
            .union_
        else if (memeql(u8, loc, "ENUM"))
            .enum_
        else if (memeql(u8, loc, "ENUM_VALUE"))
            .enumValue
        else if (memeql(u8, loc, "INPUT_OBJECT"))
            .inputObject
        else if (memeql(u8, loc, "INPUT_FIELD_DEFINITION"))
            .inputFieldDefinition
        else
            .unknown;
    }

    fn parseEnum(self: *Parser) !Enum {
        // TODO: we don't support empty member list yet

        const name = try self.iter.requireNextMeaningful(&.{.identifier});

        var directives: []Directive = &.{};
        var peeked = self.iter.peekNextMeaningful();
        if (peeked == null) {
            return Error.noneNext;
        }
        switch (peeked.?.kind) {
            .at => {
                directives = try self.parseDirectives();
            },
            .lbrack => {
                _ = try self.iter.requireNextMeaningful(&.{.lbrack});
            },
            else => return Error.badParse,
        }

        var description: ?[]const u8 = null;
        var members = std.ArrayList(EnumValue).init(self.alloc);
        while (true) {
            const next = try self.iter.requireNextMeaningful(&.{ .rbrack, .identifier, .string });
            switch (next.kind) {
                .identifier => {
                    var memberDirectives: []Directive = &.{};

                    peeked = self.iter.peekNextMeaningful();
                    if (peeked != null and peeked.?.kind == .at) {
                        memberDirectives = try self.parseDirectives();
                    }

                    try members.append(.{
                        .name = next.value,
                        .description = description,
                        .directives = memberDirectives,
                        .offset = next.offset,
                        .lineNum = next.lineNum,
                    });
                    description = null;
                },
                .string => {
                    if (description != null) {
                        return Error.badParse;
                    }
                    description = next.value;
                },
                .rbrack => break,
                else => return Error.badParse,
            }
        }

        return .{
            .name = name.value,
            .directives = directives,
            .values = try members.toOwnedSlice(),

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseObject(self: *Parser) !Object {
        return try self.parse_struct(Object);
    }

    fn parseInterface(self: *Parser) !Interface {
        return try self.parse_struct(Interface);
    }

    fn parse_struct(self: *Parser, ty: type) !ty {
        const name = try self.iter.requireNextMeaningful(&.{.identifier});

        var implements = std.ArrayList(NamedType).init(self.alloc);
        blk: {
            // TODO break out parsing implements section.

            const _next = self.iter.peekNextMeaningful();
            if (_next == null) {
                return Error.badParse;
            }

            if (_next.?.kind != .identifier) {
                break :blk;
            }

            const kw = checkKeyword(_next.?.value);
            if (kw != Keyword.implements) {
                return Error.badParse;
            }

            _ = try self.iter.requireNextMeaningful(&.{.identifier});

            var lastWasAmp = true;
            while (true) {
                const next = self.iter.peekNextMeaningful();
                if (next == null) {
                    return Error.badParse;
                }

                switch (next.?.kind) {
                    .identifier => {
                        if (!lastWasAmp) {
                            return Error.badParse;
                        }
                        lastWasAmp = false;

                        _ = try self.iter.requireNextMeaningful(&.{.identifier}); // impements keyword

                        try implements.append(.{
                            .name = next.?.value,
                            .offset = next.?.offset,
                            .lineNum = next.?.lineNum,
                        });
                    },
                    .ampersand => {
                        if (lastWasAmp) {
                            return Error.badParse;
                        }
                        lastWasAmp = true;
                        _ = try self.iter.requireNextMeaningful(&.{.ampersand});
                    },
                    .lbrack => break,
                    .at => break,
                    else => return Error.badParse,
                }
            }
        }

        const peeked = self.iter.peekNextMeaningful();
        var directives: []Directive = &.{};
        if (peeked != null and peeked.?.kind == .at) {
            directives = try self.parseDirectives();
        }

        _ = try self.iter.requireNextMeaningful(&.{.lbrack});

        var fields = std.ArrayList(Field).init(self.alloc);

        var desc: ?[]const u8 = null;
        while (true) {
            const next = try self.iter.requireNextMeaningful(&.{ .identifier, .rbrack, .string });
            switch (next.kind) {
                .rbrack => break,
                .string => {
                    if (desc == null) {
                        desc = next.value;
                    } else {
                        return Error.badParse;
                    }
                },
                .identifier => {
                    const fld = try self.parseFieldDef(next, desc);
                    desc = null;
                    try fields.append(fld);
                },
                else => return Error.badParse,
            }
        }

        return .{
            .name = name.value,
            .fields = try fields.toOwnedSlice(),
            .directives = directives,

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseInput(self: *Parser) !Input {
        const name = try self.iter.requireNextMeaningful(&.{.identifier});

        const next = try self.iter.nextMeaningful();
        var directives: []Directive = &.{};
        switch (next.kind) {
            .at => {
                directives = try self.parseDirectives();
            },
            .identifier => {
                return .{
                    .name = name.value,

                    .offset = name.offset,
                    .lineNum = name.lineNum,
                };
            },
            .lbrack => {}, // continue
            else => {
                return Error.badParse;
            },
        }

        var fields = std.ArrayList(InputField).init(self.alloc);
        var desc: ?[]const u8 = null;
        while (true) {
            const _next = try self.iter.requireNextMeaningful(&.{ .identifier, .rbrack, .string });
            switch (_next.kind) {
                .rbrack => break,
                .string => {
                    if (desc == null) {
                        desc = _next.value;
                    } else {
                        return Error.badParse;
                    }
                },
                .identifier => {
                    var fld = try self.parseInputFieldDef(_next);
                    fld.description = desc;
                    desc = null;
                    try fields.append(fld);
                },
                else => return Error.badParse,
            }
        }

        return .{
            .name = name.value,
            .inputFields = try fields.toOwnedSlice(),
            .directives = directives,

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseInputFieldDef(self: *Parser, name: Token) !InputField {
        _ = try self.iter.requireNextMeaningful(&.{.colon});

        const ty = try self.parseTypeRef();

        var directives: []Directive = &.{};
        const nextMeaningful = self.iter.peekNextMeaningful();
        if (nextMeaningful != null and nextMeaningful.?.kind == .at) {
            directives = try self.parseDirectives();
        }

        return .{
            .directives = directives,
            .name = name.value,
            .type = ty,

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseSchema(self: *Parser, offset: u64, lineNum: u64) !Schema {
        var directives: []Directive = &.{};
        const nextMeaningful = self.iter.peekNextMeaningful();
        if (nextMeaningful != null and nextMeaningful.?.kind == .at) {
            directives = try self.parseDirectives();
        }
        _ = try self.iter.requireNextMeaningful(&.{.lbrack});

        var query: ?NamedType = null;
        var mutation: ?NamedType = null;
        var subscription: ?NamedType = null;

        var desc: ?[]const u8 = null;

        while (true) {
            const next = try self.iter.requireNextMeaningful(&.{ .identifier, .rbrack, .string });
            switch (next.kind) {
                .rbrack => break,
                .string => {
                    if (desc == null) {
                        desc = next.value;
                    } else {
                        return Error.badParse;
                    }
                },
                .identifier => {
                    const opname = next.value;

                    const fld = try self.parseFieldDef(next, desc);
                    desc = null;

                    // Only NamedType is allowed
                    const ty = switch (fld.type) {
                        .namedType => |nt| nt,
                        .listType => {
                            return Error.badParse;
                        },
                    };

                    const memeql = std.mem.eql;
                    if (memeql(u8, opname, "query")) {
                        if (query != null) {
                            return Error.badParse;
                        }
                        query = .{
                            .name = ty.name,
                            .offset = ty.offset,
                            .lineNum = ty.lineNum,
                        };
                    } else if (memeql(u8, opname, "mutation")) {
                        if (mutation != null) {
                            return Error.badParse;
                        }
                        mutation = .{
                            .name = ty.name,
                            .offset = ty.offset,
                            .lineNum = ty.lineNum,
                        };
                    } else if (memeql(u8, opname, "subscription")) {
                        if (subscription != null) {
                            return Error.badParse;
                        }
                        subscription = .{
                            .name = ty.name,
                            .offset = ty.offset,
                            .lineNum = ty.lineNum,
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

    fn parseUnion(self: *Parser) !Union {
        const name = try self.iter.requireNextMeaningful(&.{.identifier});

        var directives: []Directive = &.{};
        var peeked = self.iter.peekNextMeaningful();
        if (peeked == null) {
            return Error.noneNext;
        }
        if (peeked.?.kind == .at) {
            directives = try self.parseDirectives();
        } else if (peeked.?.kind != .equals) {
            return Error.badParse;
        }

        _ = try self.iter.requireNextMeaningful(&.{.equals});

        peeked = self.iter.peekNextMeaningful();
        var members = std.ArrayList(NamedType).init(self.alloc);
        if (peeked != null) {
            // This is intentionally backwards, so we don't error upon actually reading
            // the first one.
            var lastWasbar = switch (peeked.?.kind) {
                .bar => false,
                .identifier => true,
                else => return Error.badParse,
            };

            while (true) {
                const next = try self.iter.nextMeaningful();
                switch (next.kind) {
                    .bar => {
                        if (lastWasbar) {
                            return Error.badParse;
                        }
                        lastWasbar = true;
                    },
                    .identifier => {
                        if (!lastWasbar) {
                            if (checkKeyword(next.value) != .unknown) {
                                self.iter.unread();
                                break;
                            }

                            return Error.badParse;
                        }
                        lastWasbar = false;

                        try members.append(.{
                            .name = next.value,
                            .offset = next.offset,
                            .lineNum = next.lineNum,
                        });
                    },
                    .string => break,
                    else => return Error.badParse,
                }
            }
        }

        return .{
            .name = name.value,
            .directives = directives,
            .types = try members.toOwnedSlice(),

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseFieldDef(self: *Parser, name: Token, description: ?[]const u8) !Field {
        var args: ?[]ArgumentDefinition = null;
        const colOrParen = try self.iter.requireNextMeaningful(&.{ .colon, .lparen });

        if (colOrParen.kind == .lparen) {
            args = try self.parseArgumentDefinitions();
            _ = try self.iter.requireNextMeaningful(&.{.colon});
        }

        const ty = try self.parseTypeRef();

        var directives: []Directive = &.{};
        const nextMeaningful = self.iter.peekNextMeaningful();
        if (nextMeaningful != null and nextMeaningful.?.kind == .at) {
            directives = try self.parseDirectives();
        }

        return .{
            .args = args orelse &.{},
            .description = description,
            .directives = directives,
            .name = name.value,
            .type = ty,

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseTypeRef(self: *Parser) !TypeRef {
        const next = try self.iter.requireNextMeaningful(&.{ .lsqbrack, .identifier });
        return switch (next.kind) {
            .identifier => {
                var nullable = true;
                const nnext = self.iter.peekNextMeaningful();
                if (nnext != null and nnext.?.kind == .bang) {
                    _ = try self.iter.requireNextMeaningful(&.{.bang});
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
            .lsqbrack => {
                // TODO cleanup
                const ty = try self.alloc.create(TypeRef);
                ty.* = try self.parseTypeRef();
                _ = try self.iter.requireNextMeaningful(&.{.rsqbrack});

                var nullable = true;
                const nnext = self.iter.peekNextMeaningful();
                if (nnext != null and nnext.?.kind == .bang) {
                    _ = try self.iter.requireNextMeaningful(&.{.bang});
                    nullable = false;
                }

                return .{
                    .listType = .{
                        .ty = ty,
                        .nullable = nullable,
                    },
                };
            },
            else => Error.badFieldDefParse,
        };
    }

    fn parseArguments(self: *Parser) ![]Argument {
        var args = std.ArrayList(Argument).init(self.alloc);
        while (true) {
            const peeked = self.iter.peekNextMeaningful();
            if (peeked == null) {
                return Error.noneNext;
            } else if (peeked.?.kind == .rparen) {
                _ = try self.iter.requireNextMeaningful(&.{.rparen});
                break;
            }

            const next = try self.parseArgument();
            try args.append(next);
        }
        return try args.toOwnedSlice();
    }

    fn parseArgument(self: *Parser) !Argument {
        const name = try self.iter.requireNextMeaningful(&.{.identifier});
        _ = try self.iter.requireNextMeaningful(&.{.colon});
        const val = try self.parseValue() orelse return Error.badParse;

        return .{
            .name = name.value,
            .value = val,
        };
    }

    /// Only returns null upon ], which is only valid when parsing List Values and
    /// should be treated as an error otherwise.
    fn parseValue(self: *Parser) !?Value {
        const next = try self.iter.nextMeaningful();
        return switch (next.kind) {
            .string => .{
                .String = next.value,
            },
            .identifier => switch (checkKeyword(next.value)) {
                .false => .{
                    .Bool = false,
                },
                .true => .{
                    .Bool = true,
                },
                .null => .{
                    .Null = .{},
                },
                else => .{
                    .Enum = next.value,
                },
            },
            .int => .{
                .Int = try std.fmt.parseInt(i64, next.value, 10),
            },
            .float => .{
                .Float = try std.fmt.parseFloat(f64, next.value),
            },
            .lsqbrack => blk: {
                var listItems = std.ArrayList(Value).init(self.alloc);
                while (true) {
                    const _next = try self.parseValue();
                    if (_next == null) {
                        break :blk .{
                            .List = try listItems.toOwnedSlice(),
                        };
                    }
                    try listItems.append(_next.?);
                }
            },
            .rsqbrack => null,
            else => return Error.notImplemented,
        };
    }

    fn parseArgumentDefinitions(self: *Parser) ![]ArgumentDefinition {
        var args = std.ArrayList(ArgumentDefinition).init(self.alloc);
        var description: ?[]const u8 = null;
        while (true) {
            const peeked = self.iter.peekNextMeaningful();
            if (peeked == null) {
                return Error.noneNext;
            }

            switch (peeked.?.kind) {
                .rparen => {
                    if (description != null) {
                        // Floating docstring
                        return Error.badParse;
                    }

                    _ = try self.iter.requireNextMeaningful(&.{.rparen});
                    break;
                },
                .identifier => {
                    var next = try self.parseArgumentDefinition();
                    next.description = description;
                    description = null;

                    const npeeked = self.iter.peekNextMeaningful();
                    if (npeeked != null and npeeked.?.kind == .at) {
                        next.directives = try self.parseDirectives();
                    }

                    try args.append(next);
                },
                .string => {
                    if (description != null) {
                        // Two strings in a row
                        return Error.badParse;
                    }
                    const next = try self.iter.requireNextMeaningful(&.{.string});
                    description = next.value;
                },
                else => return Error.badParse,
            }
        }
        return try args.toOwnedSlice();
    }

    fn parseArgumentDefinition(self: *Parser) !ArgumentDefinition {
        const name = try self.iter.requireNextMeaningful(&.{.identifier});
        _ = try self.iter.requireNextMeaningful(&.{.colon});
        const ty = try self.parseTypeRef();

        const next = self.iter.peekNextMeaningful();
        var default: ?Value = null;
        if (next != null and next.?.kind == .equals) {
            _ = try self.iter.requireNextMeaningful(&.{.equals});
            default = try self.parseValue() orelse return Error.badParse;
        }

        return .{
            .name = name.value,
            .ty = ty,
            .default = default,

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    /// Assumes the caller has peeked for @ before calling.
    fn parseDirectives(self: *Parser) ![]Directive {
        var directives = std.ArrayList(Directive).init(self.alloc);

        while (true) {
            const next = self.iter.peekNextMeaningful();
            if (next == null) {
                return Error.badParse;
            }

            switch (next.?.kind) {
                .at => {
                    try directives.append(try self.parseDirective());
                },
                .lbrack, .lparen, .identifier, .equals, .rbrack, .rparen, .string => break,
                else => return Error.badParse,
            }
        }

        return try directives.toOwnedSlice();
    }

    fn parseDirective(self: *Parser) !Directive {
        _ = try self.iter.requireNextMeaningful(&.{.at});
        const name = try self.iter.requireNextMeaningful(&.{.identifier});

        const next = self.iter.peekNextMeaningful();
        if (next == null) {
            return Error.badParse;
        }

        var args: []Argument = &.{};
        if (next.?.kind == .lparen) {
            _ = try self.iter.requireNextMeaningful(&.{.lparen});
            args = try self.parseArguments();
        }

        return .{
            .name = name.value,
            .args = args,

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseDirectiveDef(self: *Parser) !DirectiveDef {
        _ = try self.iter.requireNextMeaningful(&.{.at});
        const name = try self.iter.requireNextMeaningful(&.{.identifier});

        const peeked = self.iter.peekNextMeaningful();
        if (peeked == null) {
            return Error.badParse;
        }

        var args: []ArgumentDefinition = &.{};
        switch (peeked.?.kind) {
            .lparen => {
                _ = try self.iter.requireNextMeaningful(&.{.lparen});
                args = try self.parseArgumentDefinitions();
            },
            .identifier => {},
            else => return Error.badParse,
        }

        var repeatable = false;
        const next = try self.iter.requireNextMeaningful(&.{.identifier});

        switch (checkKeyword(next.value)) {
            .repeatable => {
                repeatable = true;

                const _next = try self.iter.requireNextMeaningful(&.{.identifier});
                if (!std.mem.eql(u8, _next.value, "on")) {
                    return Error.badParse;
                }
            },
            .on => {},
            else => return Error.badParse,
        }

        var locations = std.ArrayList(DirectiveLocation).init(self.alloc);
        var lastWasBar = true;
        while (true) {
            const _next = self.iter.nextMeaningful() catch |err| {
                if (err == Error.noneNext) {
                    break;
                } else {
                    return err;
                }
            };
            switch (_next.kind) {
                .identifier => {
                    if (!lastWasBar) {
                        if (checkDirectiveLocation(_next.value) == .unknown) {
                            self.iter.unread();
                            break;
                        }
                        return Error.badParse;
                    }
                    const directiveLoc = checkDirectiveLocation(_next.value);
                    switch (directiveLoc) {
                        .unknown => break,
                        else => {
                            try locations.append(directiveLoc);
                        },
                    }
                    lastWasBar = false;
                },
                .bar => {
                    if (lastWasBar) {
                        return Error.badParse;
                    }
                    lastWasBar = true;
                },
                .string => break,
                else => unreachable,
            }
        }

        return .{
            .name = name.value,
            .args = args,
            .repeatable = repeatable,
            .locations = try locations.toOwnedSlice(),

            .offset = name.offset,
            .lineNum = name.lineNum,
        };
    }

    fn parseScalar(self: *Parser) !Scalar {
        const name = try self.iter.requireNextMeaningful(&.{.identifier});

        const next = self.iter.peekNextMeaningful();
        var directives: []Directive = &.{};
        if (next != null and next.?.kind == .at) {
            directives = try self.parseDirectives();
        }

        return .{
            .name = name.value,
            .directives = directives,

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

    fn unread(self: *Iterator) void {
        if (self.index > 0) {
            self.index -= 1;
        }
    }

    fn next(self: *Iterator) ?Token {
        if (self.tokens.len == 0 or self.index == self.tokens.len) {
            return null;
        }

        const ret = self.tokens[self.index];
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

    fn nextMeaningful(self: *Iterator) !Token {
        while (true) {
            const next_ = try self.mustNext();

            switch (next_.kind) {
                .comma => _ = void,
                .comment => _ = void,
                .newline => _ = void,
                .whitespace => _ = void,
                else => return next_,
            }
        }
    }

    fn requireNextMeaningful(self: *Iterator, kinds: []const TokenKind) !Token {
        while (true) {
            const next_ = try self.mustNext();

            switch (next_.kind) {
                .comma => _ = void,
                .comment => _ = void,
                .newline => _ = void,
                .whitespace => _ = void,
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
                .comma => _ = void,
                .comment => _ = void,
                .newline => _ = void,
                .whitespace => _ = void,
                else => {
                    self.index = curr;
                    return next_;
                },
            }
        }
    }
};

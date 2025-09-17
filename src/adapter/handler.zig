const std = @import("std");

const config = @import("config");

const lsp = @import("lsp");
const Error = lsp.types.ErrorCodes;

const ast = @import("../graphql/ast.zig");
const lexer = @import("../graphql/lexer.zig");
const parser = @import("../graphql/parser.zig");
const Locator = @import("locator.zig");

const utils = @import("utils.zig");

const Handler = @This();

alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator) Handler {
    return .{
        .alloc = alloc,
    };
}

pub fn deinit(_: *Handler) void {
}

pub fn initialize(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
    return .{
        .serverInfo = .{
            .name = "graphqlzp",
            .version = config.version,
        },
        .capabilities = .{
            .positionEncoding = .@"utf-8",

            .definitionProvider = .{ .bool = true },
            .hoverProvider = .{ .bool = true },
            .implementationProvider = .{ .bool = true },
            .referencesProvider = .{ .bool = true },
        },
    };
}

pub fn initialized(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.InitializedParams,
) void {
    std.log.debug("Received 'initialized' notification", .{});
}

pub fn shutdown(
    _: *Handler,
    _: std.mem.Allocator,
    _: void,
) ?void {
    std.log.debug("Received 'shutdown' request", .{});
    return null;
}

pub fn exit(
    _: *Handler,
    _: std.mem.Allocator,
    _: void,
) void {
    std.log.debug("Received 'exit' notification", .{});
}

pub fn onResponse(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.JsonRPCMessage.Response,
) void {
}

pub fn getDocAndLocator(alloc: std.mem.Allocator, furi: []const u8) !struct { ast.Document, Locator.Locator } {
    // trim file:// if present
    const fname =
        if (std.mem.eql(u8, furi[0..7], "file://"))
            furi[6..]
        else
            furi;

    const lexResult = try lexer.tokenize(alloc, fname);

    var _parser = parser.Parser.create(alloc, lexResult.tokens);
    const doc = try _parser.parse();

    const locator = try Locator.Locator.init(doc, alloc);

    return .{ doc, locator };
}

pub fn @"textDocument/hover" (_: *Handler, alloc: std.mem.Allocator, params: lsp.types.HoverParams) !?lsp.types.Hover {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    _, const locator = try getDocAndLocator(aa, params.textDocument.uri);

    const item = locator.getItemAt(params.position.character, params.position.line);
    if (item == null) {
        std.debug.print("nothing found\n", .{}); // TODO
        return null;
    }

    const def = locator.getItemDefinition(item.?) orelse {
        return null;
    };

    var content = std.ArrayList(u8){};
    const allocprint = std.fmt.allocPrint;

    const description = utils.descriptionOf(def);
    if (description != null) {
        try content.appendSlice(aa, try allocprint(aa, "{s}\n", .{description.?}));
    }
    const keyword = utils.keywordFromType(def);
    if (keyword != null) {
        const name = switch (def) {
            .directive, .directiveDefinition => try allocprint(aa, "@{s}", .{utils.nameOf(def)}),
            else => utils.nameOf(def),
        };

        try content.appendSlice(aa, try allocprint(aa, "```graphql\n{s} {s}\n```", .{ keyword.?, name }));
    } else {
        switch (def) {
            .fieldDefinition => |fld| {
                const parentKw = switch (fld.parent.type) {
                    .object => "type",
                    .interface => "interface",
                    .input => "input",
                };
                try content
                    .appendSlice(aa, try allocprint(aa, "```graphql\n{s} {s} {{\n  ,,,\n  {s}{s}: {s}\n}}\n```", .{ parentKw, fld.parent.name, fld.field.name, try utils.formatArgDefs(aa, fld.field.args), try utils.formatTypeRef(aa, fld.field.type) }));
            },
            .argumentDefinition => |ad| {
                try content
                    .appendSlice(aa, try allocprint(aa, "```graphql\n{s}: {s}\n```", .{ ad.name, try utils.formatTypeRef(aa, ad.ty) }));
            },
            else => {
                std.debug.print("warn: unreachable arm rendering hover\n", .{});
                return null;
            },
        }
    }

    return .{
        .contents = .{
            .MarkupContent = .{ .kind = .markdown, .value = try content.toOwnedSlice(aa) },
        },
    };
}

pub fn @"textDocument/definition" (_: *Handler, alloc: std.mem.Allocator, params: lsp.types.DefinitionParams) !lsp.ResultType("textDocument/definition") {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    _, const locator = try getDocAndLocator(aa, params.textDocument.uri);

    const item = locator.getItemAt(params.position.character, params.position.line);
    if (item == null) {
        std.debug.print("nothing found in locator\n", .{}); // TODO
        return null;
    }

    const def = locator.getItemDefinition(item.?);
    if (def == null) {
        std.debug.print("warn: definition not found\n", .{}); // TODO
        return null;
    }

    const len, const pos = Locator.getItemLenAndPos(def.?);

    return .{
        .Definition = .{
            .Location = .{
                .uri = params.textDocument.uri,
                .range = .{
                    .start = pos,
                    .end = .{
                        .line = @intCast(pos.line),
                        .character = @intCast(pos.character + len),
                    },
                },
            },
        },
    };
}

pub fn @"textDocument/references" (_: *Handler, alloc: std.mem.Allocator, params: lsp.types.ReferenceParams) !lsp.ResultType("textDocument/references") {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    _, const locator = try getDocAndLocator(aa, params.textDocument.uri);

    const item = locator.getItemAt(params.position.character, params.position.line);
    if (item == null) {
        std.debug.print("nothing found in locator\n", .{}); // TODO
        return null;
    }

    const itemName = utils.nameOf(item.?);

    const matches = utils.matcher{
        .n = itemName,
    };

    var locs = std.ArrayList(lsp.types.Location){};
    for (locator.locations) |loc| {
        switch (loc.item) {
            .object, .input, .interface, .namedType => {
                if (matches.m(loc.item)) {
                    try locs.append(aa, .{
                        .uri = params.textDocument.uri,
                        .range = utils.rangeOf(loc.item),
                    });
                }
            },
            else => continue,
        }
    }

    return try locs.toOwnedSlice(aa);
}

pub fn @"textDocument/implementation" (_: *Handler, alloc: std.mem.Allocator, params: lsp.types.ImplementationParams) !lsp.ResultType("textDocument/implementation") {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const doc, const locator = try getDocAndLocator(aa, params.textDocument.uri);

    const item = locator.getItemAt(params.position.character, params.position.line);
    if (item == null) {
        std.debug.print("nothing found in locator\n", .{}); // TODO
        return null;
    }

    const itemName = utils.nameOf(item.?);

    const matches = utils.matcher{
        .n = itemName,
    };

    var locs = std.ArrayList(lsp.types.Location){};

    switch (item.?) {
        .object, .interface => {
            try locs.append(aa, .{
                .uri = params.textDocument.uri,
                .range = utils.rangeOf(item.?),
            });
        },
        else => {},
    }

    for (doc.objects) |obj| {
        for (obj.implements) |impl| {
            if (matches.str(impl.name)) {
                try locs.append(aa, .{
                    .uri = params.textDocument.uri,
                    .range = utils.rangeOf(.{ .object = obj }),
                });
            }
        }
    }
    for (doc.interfaces) |ifce| {
        for (ifce.implements) |impl| {
            if (matches.str(impl.name)) {
                try locs.append(aa, .{
                    .uri = params.textDocument.uri,
                    .range = utils.rangeOf(.{ .interface = ifce }),
                });
            }
        }
    }

    return .{
        .Definition = .{
            .array_of_Location = try locs.toOwnedSlice(aa),
        },
    };
}

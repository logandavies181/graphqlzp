const std = @import("std");

const ast = @import("../graphql/ast.zig");
const lexer = @import("../graphql/lexer.zig");
const parser = @import("../graphql/parser.zig");

const Errors = @import("../lzp/errors.zig");
const Error = Errors.Error;
const lsp = @import("lsp");

const _handler = @import("../lzp/handler.zig");

const Locator = @import("locator.zig");

const Handler = @This();

alloc: std.mem.Allocator,
document: ?ast.Document = null,

pub fn init(alloc: std.mem.Allocator) Handler {
    return .{
        .alloc = alloc,
    };
}

pub fn handler(self: *Handler) _handler {
    return .{
        .ptr = self,
        .vtable = &.{
            .hover = hover,
            .gotoDefinition = gotoDefinition,
        },
    };
}

fn keywordFromType(item: Locator.AstItem) []const u8 {
    return switch (item) {
        .schema => "schema",
        .scalar => "scalar",
        .object => "type",
        .namedType => unreachable,
        .interface => "interface",
    };
}

fn nameOf(item: Locator.AstItem) []const u8 {
    return switch (item) {
        .schema => "schema",
        .scalar => |_item| _item.name,
        .object => |_item| _item.name,
        .namedType => unreachable,
        .interface => |_item| _item.name,
    };
}

fn descriptionOf(item: Locator.AstItem) ?[]const u8 {
    return switch (item) {
        .schema => |_item| _item.description,
        .scalar => |_item| _item.description,
        .object => |_item| _item.description,
        .namedType => unreachable,
        .interface => |_item| _item.description,
    };
}

fn hover(_self: *anyopaque, params: lsp.types.HoverParams) Error!?lsp.types.Hover {
    return tryHover(_self, params) catch |err| {
        std.debug.print("got error: {any}", .{err});
        return Error.InternalError;
    };
}

fn tryHover(_self: *anyopaque, params: lsp.types.HoverParams) !?lsp.types.Hover {
    const self: *Handler = @ptrCast(@alignCast(_self));

    _, const locator = try self.getDocAndLocator(params.textDocument.uri);

    const item = locator.getItemAt(params.position.character, params.position.line);
    if (item == null) {
        std.debug.print("nothing found\n", .{}); // TODO
        return null;
    }

    const def = locator.getItemDefinition(item.?);
    if (def == null) {
        return null;
    }

    // TODO: mem mgmt
    const content = try std.fmt.allocPrint(self.alloc, "```graphql\n{s} {s}\n```\n{s}", .{keywordFromType(def.?), nameOf(def.?), descriptionOf(def.?) orelse ""});

    return .{
        .contents = .{
            .MarkupContent = .{ .kind = .markdown, .value = content },
        },
    };
}

fn gotoDefinition(_self: *anyopaque, params: lsp.types.DefinitionParams) Error!lsp.ResultType("textDocument/definition") {
    return tryGotoDefinition(_self, params) catch |err| {
        std.debug.print("got error: {any}", .{err});
        return Error.InternalError;
    };
}

fn getDocAndLocator(self: *Handler, furi: []const u8) !struct { ast.Document, Locator.Locator } {
    // trim file:// if present
    const fname =
        if (std.mem.eql(u8, furi[0..7], "file://"))
            furi[6..]
        else
            furi;

    const lexResult = try lexer.tokenize(self.alloc, fname);
    // TODO
    // var lexResult = try lexer.tokenize(self.alloc, fname);
    // defer lexResult.deinit(self.alloc);

    var _parser = parser.Parser.create(self.alloc, lexResult.tokens);
    const doc = try _parser.parse();

    const locator = try Locator.Locator.init(doc, self.alloc);

    return .{ doc, locator };
}

fn tryGotoDefinition(_self: *anyopaque, params: lsp.types.DefinitionParams) !lsp.ResultType("textDocument/definition") {
    const self: *Handler = @ptrCast(@alignCast(_self));

    _, const locator = try self.getDocAndLocator(params.textDocument.uri);

    const item = locator.getItemAt(params.position.character, params.position.line);
    if (item == null) {
        std.debug.print("nothing found\n", .{}); // TODO
        return null;
    }

    const def = locator.getItemDefinition(item.?);
    if (def == null) {
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

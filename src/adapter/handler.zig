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

fn keywordFromType(item: Locator.AstItem) ?[]const u8 {
    return switch (item) {
        .schema => "schema",
        .scalar => "scalar",
        .object => "type",
        .namedType => unreachable,
        .interface => "interface",
        .fieldDefinition => null,
        .directive => unreachable,
        .directiveDefinition => "directive",
        .argumentDefinition => null,
        .input => "input",
        .inputField => null,
        .enum_ => "enum",
        .enumValue => null,
        .union_ => "union",
    };
}

fn nameOf(item: Locator.AstItem) []const u8 {
    return switch (item) {
        .schema => "schema",
        .scalar => |_item| _item.name,
        .object => |_item| _item.name,
        .namedType => unreachable,
        .interface => |_item| _item.name,
        .fieldDefinition => |_item| _item.field.name,
        .directive => |_item| _item.name,
        .directiveDefinition => |_item| _item.name,
        .argumentDefinition => |_item| _item.name,
        .input => |_item| _item.name,
        .inputField => |_item| _item.field.name,
        .enum_ => |_item| _item.name,
        .enumValue => |_item| _item.name,
        .union_ => |_item| _item.name,
    };
}

fn descriptionOf(item: Locator.AstItem) ?[]const u8 {
    return switch (item) {
        .schema => |_item| _item.description,
        .scalar => |_item| _item.description,
        .object => |_item| _item.description,
        .namedType => unreachable, // expect resolved type instead
        .interface => |_item| _item.description,
        .fieldDefinition => |_item| _item.field.description,
        .directive => unreachable, // expect resolved directive def
        .directiveDefinition => |_item| _item.description,
        .argumentDefinition => |_item| _item.description,
        .input => |_item| _item.description,
        .inputField => |_item| _item.field.description,
        .enum_ => |_item| _item.description,
        .enumValue => |_item| _item.description,
        .union_ => |_item| _item.description,
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

    const def = locator.getItemDefinition(item.?) orelse {
        return null;
    };

    // TODO: mem mgmt
    var content = std.ArrayList(u8).init(self.alloc);
    const allocprint = std.fmt.allocPrint;

    const description = descriptionOf(def);
    if (description != null) {
        try content.appendSlice(try allocprint(self.alloc, "{s}\n", .{description.?}));
    }
    const keyword = keywordFromType(def);
    if (keyword != null) {
        const name = switch (def) {
            .directive, .directiveDefinition => try allocprint(self.alloc, "@{s}", .{nameOf(def)}),
            else => nameOf(def),
        };

        try content.appendSlice(try allocprint(self.alloc, "```graphql\n{s} {s}\n```", .{ keyword.?, name }));
    } else {
        switch (def) {
            .fieldDefinition => |fld| {
                const parentKw = switch (fld.parent.type) {
                    .object => "type",
                    .interface => "interface",
                    .input => "input",
                };
                try content
                    .appendSlice(try allocprint(self.alloc, "```graphql\n{s} {s} {{\n  ,,,\n  {s}{s}: {s}\n}}\n```", .{ parentKw, fld.parent.name, fld.field.name, try formatArgDefs(self.alloc, fld.field.args), try formatTypeRef(self.alloc, fld.field.type) }));
            },
            .argumentDefinition => |ad| {
                try content
                    .appendSlice(try allocprint(self.alloc, "```graphql\n{s}: {s}\n```", .{ ad.name, try formatTypeRef(self.alloc, ad.ty) }));
            },
            else => {
                std.debug.print("warn: unreachable arm rendering hover\n", .{});
                return null;
            },
        }
    }

    return .{
        .contents = .{
            .MarkupContent = .{ .kind = .markdown, .value = try content.toOwnedSlice() },
        },
    };
}

fn formatArgDefs(alloc: std.mem.Allocator, args: []ast.ArgumentDefinition) ![]const u8 {
    if (args.len == 0) {
        return "";
    }

    var content = std.ArrayList(u8).init(alloc);
    try content.append('(');

    for (args, 0..args.len) |arg, i| {
        try content
            .appendSlice(try std.fmt.allocPrint(
            alloc,
            "{s}: {s}",
            .{ arg.name, try formatTypeRef(alloc, arg.ty) },
        ));
        if (i < args.len - 1) {
            try content.appendSlice(", ");
        } else {
            try content.append(')');
        }
    }

    return try content.toOwnedSlice();
}

fn formatTypeRef(alloc: std.mem.Allocator, tr: ast.TypeRef) ![]const u8 {
    return switch (tr) {
        .namedType => |nt| if (nt.nullable) nt.name else try std.fmt.allocPrint(alloc, "{s}!", .{nt.name}),
        .listType => |lt| {
            const childContent = try formatTypeRef(alloc, lt.ty.*);
            return try std.fmt.allocPrint(alloc, "[{s}]{s}", .{ childContent, if (lt.nullable) "" else "!" });
        },
    };
}

fn gotoDefinition(_self: *anyopaque, params: lsp.types.DefinitionParams) Error!lsp.ResultType("textDocument/definition") {
    return tryGotoDefinition(_self, params) catch |err| {
        std.debug.print("got error: {any}", .{err});
        return Error.InternalError;
    };
}

pub fn getDocAndLocator(self: *Handler, furi: []const u8) !struct { ast.Document, Locator.Locator } {
    // trim file:// if present
    const fname =
        if (std.mem.eql(u8, furi[0..7], "file://"))
            furi[6..]
        else
            furi;

    const lexResult = try lexer.tokenize(self.alloc, fname);
    // TODO memory mgmt

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

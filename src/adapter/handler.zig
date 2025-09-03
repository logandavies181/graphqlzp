const std = @import("std");

const config = @import("config");

const ast = @import("../graphql/ast.zig");
const lexer = @import("../graphql/lexer.zig");
const parser = @import("../graphql/parser.zig");

const Error = lsp.types.ErrorCodes;
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
            //.hoverProvider = .{ .bool = true },
            // TODO, other caps
        },
    };
}

pub fn hover(_self: *anyopaque, params: lsp.types.HoverParams) Error!?lsp.types.Hover {
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


fn gotoDefinition(_self: *anyopaque, params: lsp.types.DefinitionParams) Error!lsp.ResultType("textDocument/definition") {
    return tryGotoDefinition(_self, params) catch |err| {
        std.debug.print("got error: {any}", .{err});
        return Error.InternalError;
    };
}



fn references(_self: *anyopaque, params: lsp.types.ReferenceParams) Error!?[]lsp.types.Location {
    return tryReferences(_self, params) catch |err| {
        std.debug.print("got error: {any}", .{err});
        return Error.InternalError;
    };
}


fn gotoImplementation(_self: *anyopaque, params: lsp.types.ImplementationParams) Error!lsp.ResultType("textDocument/implementation") {
    return tryGotoImplementation(_self, params) catch |err| {
        std.debug.print("got error: {any}", .{err});
        return Error.InternalError;
    };
}

fn tryGotoImplementation(_self: *anyopaque, params: lsp.types.ImplementationParams) !lsp.ResultType("textDocument/implementation") {
    const self: *Handler = @ptrCast(@alignCast(_self));

    const doc, const locator = try self.getDocAndLocator(params.textDocument.uri);

    const item = locator.getItemAt(params.position.character, params.position.line);
    if (item == null) {
        std.debug.print("nothing found in locator\n", .{}); // TODO
        return null;
    }

    const itemName = nameOf(item.?);

    const matches = matcher{
        .n = itemName,
    };

    var locs = std.ArrayList(lsp.types.Location).init(self.alloc);

    switch (item.?) {
        .object, .interface => {
            try locs.append(.{
                .uri = params.textDocument.uri,
                .range = rangeOf(item.?),
            });
        },
        else => {},
    }

    for (doc.objects) |obj| {
        for (obj.implements) |impl| {
            if (matches.str(impl.name)) {
                try locs.append(.{
                    .uri = params.textDocument.uri,
                    .range = rangeOf(.{ .object = obj }),
                });
            }
        }
    }
    for (doc.interfaces) |ifce| {
        for (ifce.implements) |impl| {
            if (matches.str(impl.name)) {
                try locs.append(.{
                    .uri = params.textDocument.uri,
                    .range = rangeOf(.{ .interface = ifce }),
                });
            }
        }
    }

    return .{
        .Definition = .{
            .array_of_Location = try locs.toOwnedSlice(),
        },
    };
}

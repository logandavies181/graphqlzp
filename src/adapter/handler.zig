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

fn hover(_: *anyopaque, _: lsp.types.HoverParams) Error!?lsp.types.Hover {
    return .{
        .contents = .{
            .MarkupContent = .{
                .kind = .markdown,
                .value =
                    \\```
                    \\zar!
                    \\```
            },
        },
    };
}

fn gotoDefinition(_self: *anyopaque, params: lsp.types.DefinitionParams) Error!lsp.ResultType("textDocument/definition") {
    return tryGotoDefinition(_self, params) catch |err| {
        std.debug.print("got error: {any}", .{err});
        return Error.InternalError;
    };
}

fn tryGotoDefinition(_self: *anyopaque, params: lsp.types.DefinitionParams) !lsp.ResultType("textDocument/definition") {
    const self: *Handler = @ptrCast(@alignCast(_self));

    // trim file:// if present
    const furi = params.textDocument.uri;
    const fname =
        if (std.mem.eql(u8, furi[0..7], "file://"))
            furi[6..]
        else
            furi;

    var tokenizer = try lexer.Tokenizer.create(fname, self.alloc);
    defer self.alloc.free(tokenizer.buf);
    const tokens = try tokenizer.tokenize();
    defer self.alloc.free(tokens);

    var _parser = parser.Parser.create(self.alloc, tokens);
    const doc = try _parser.parse();

    const locator = try Locator.Locator.init(doc, self.alloc);

    const item = locator.getItemAt(params.position.character - 1, params.position.line - 1);

    if (item == null) {
        return null;
    }

    var pos: lsp.types.Position = undefined;
    var len: u64 = undefined;

    switch (item.?) {
        .object => |obj| {
            len = obj.name.len;
            pos = .{
                .line = @intCast(obj.lineNum),
                .character = @intCast(obj.offset),
            };
        },
        else => {
            return null;
        },
    }

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

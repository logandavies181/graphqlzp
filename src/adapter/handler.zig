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

    // TODO proper memory management

    var tokenizer = try lexer.Tokenizer.create("test/schema.graphql", self.alloc);
    const tokens = try tokenizer.tokenize();

    var _parser = parser.Parser.create(self.alloc, tokens);
    const doc = try _parser.parse();

    _ = try Locator.Locator.init(doc, self.alloc);
    //const locator = Locator.Locator.init(doc, self.alloc);
    // locator.getItemAt(params.textDocument.)

    const uri = params.textDocument.uri;

    return .{
        .Definition = .{
            .Location = .{
                .uri = uri,
                .range = .{
                    .start = .{
                        .line = 0,
                        .character = 0,
                    },
                    .end = .{
                        .line = 0,
                        .character = 0,
                    },
                },
            },
        },
    };
}

const std = @import("std");

const ast = @import("../graphql/ast.zig");
const lexer = @import("../graphql/lexer.zig");
const parser = @import("../graphql/parser.zig");

const Errors = @import("../lzp/errors.zig");
const Error = Errors.Error;
const lsp = @import("lsp");

const _handler = @import("../lzp/handler.zig");

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
        },
    };
}

pub fn hover(_: *anyopaque, _: lsp.types.HoverParams) Error!?lsp.types.Hover {
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

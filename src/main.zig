const std = @import("std");
const lsp = @import("lsp");
const Errors = @import("lzp/errors.zig");
const Error = Errors.Error;
const Handler = @import("lzp/handler.zig");
const Server = @import("lzp/server.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();

    var transport: lsp.ThreadSafeTransport(.{
        .ChildTransport = lsp.TransportOverStdio,
        .thread_safe_read = false,
        .thread_safe_write = true,
    }) = .{ .child_transport = .init(std.io.getStdIn(), std.io.getStdOut()) };

    var himple: Himpl = .{};
    const handler = himple.handler();

    const server = try Server.create(alloc, handler);
    defer server.destroy();
    server.setTransport(transport.any());

    try server.loop();
}

const Himpl = struct {
    pub fn hover(_: *anyopaque, _: lsp.types.HoverParams) Error!?lsp.types.Hover {
        return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .markdown,
                    .value =
                        \\```
                        \\bar!
                        \\```
                },
            },
        };
    }

    pub fn handler(self: *Himpl) Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .hover = hover,
            },
        };
    }
};

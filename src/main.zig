const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("adapter/handler.zig");
const Server = @import("lzp/server.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();

    var transport: lsp.ThreadSafeTransport(.{
        .ChildTransport = lsp.TransportOverStdio,
        .thread_safe_read = false,
        .thread_safe_write = true,
    }) = .{ .child_transport = .init(std.io.getStdIn(), std.io.getStdOut()) };

    var h = Handler.init(alloc);

    const server = try Server.create(alloc, h.handler());
    defer server.destroy();
    server.setTransport(transport.any());

    try server.loop();
}

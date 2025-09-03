const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("adapter/handler.zig");
const Server = @import("lzp/server.zig");
const config = @import("config");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // binary name
    if (std.mem.eql(u8, args.next() orelse "", "--version")) {
        std.debug.print("{s}\n", .{config.version});
        std.process.exit(0);
    }

    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();

    var transport: lsp.ThreadSafeTransport(.{
        .ChildTransport = lsp.Transport.Stdio,
        .thread_safe_read = false,
        .thread_safe_write = true,
    }) = .{ .child_transport = .init(std.io.getStdIn(), std.io.getStdOut()) };

    var h = Handler.init(alloc);

    const server = try Server.create(alloc, h.handler());
    defer server.destroy();
    server.setTransport(transport.any());

    try server.loop();
}

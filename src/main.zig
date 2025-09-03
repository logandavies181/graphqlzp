const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("adapter/handler2.zig");
const Server = @import("lzp/server.zig");
const config = @import("config");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // binary name
    if (std.mem.eql(u8, args.next() orelse "", "--version")) {
        std.debug.print("{s}\n", .{config.version});
        std.process.exit(0);
    }

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();

    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler: Handler = .init(gpa);
    defer handler.deinit();

    try lsp.basic_server.run(
        gpa,
        transport,
        &handler,
        std.log.err,
    );
}

const std = @import("std");
const lsp = @import("lsp");
const Handler = @import("adapter/handler.zig");
const config = @import("config");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);

    if (std.mem.eql(u8, if (args.len > 1) args[1] else "", "--version")) {
        std.debug.print("{s}\n", .{config.version});
        std.process.exit(0);
    }

    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler: Handler = .init(init.io, init.gpa);
    defer handler.deinit();

    try lsp.basic_server.run(
        init.io,
        init.gpa,
        transport,
        &handler,
        std.log.err,
    );
}

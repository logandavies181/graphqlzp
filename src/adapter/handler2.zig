const std = @import("std");

const config = @import("config");

const lsp = @import("lsp");

const Handler = @This();

alloc: std.mem.Allocator,

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
            .hoverProvider = .{ .bool = true },
            // TODO, other caps
        },
    };
}

pub fn initialized(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.InitializedParams,
) void {
    std.log.debug("Received 'initialized' notification", .{});
}

pub fn shutdown(
    _: *Handler,
    _: std.mem.Allocator,
    _: void,
) ?void {
    std.log.debug("Received 'shutdown' request", .{});
    return null;
}

pub fn exit(
    _: *Handler,
    _: std.mem.Allocator,
    _: void,
) void {
    std.log.debug("Received 'exit' notification", .{});
}

pub fn onResponse(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.JsonRPCMessage.Response,
) void {
}

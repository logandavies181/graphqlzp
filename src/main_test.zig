const std = @import("std");

const lexer = @import("graphql/lexer.zig");
const parser = @import("graphql/parser.zig");

const gftftr = @import("adapter/locator.zig").getNamedTypeFromTypeRef;

fn testmain() !void {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const dir = try std.Io.Dir.cwd().openDir(io, "test", .{
        .iterate = true,
    });
    var iter = dir.iterate();

    while (try iter.next(io)) |next| {
        var fname: [4096]u8 = undefined;
        const len = next.name.len + 5;
        @memcpy(fname[0..5], "test/");
        @memcpy(fname[5..len], next.name);

        std.debug.print("=== {s} ===\n", .{fname[0..len]});

        const lexResult = try lexer.tokenize(io, aa, fname[0..len]);

        var _parser = parser.Parser.create(aa, lexResult.tokens);
        const doc = try _parser.parse();

        for (doc.objects) |ty| {
            std.debug.print("{s} at line: {d}, offset: {d}\n", .{ ty.name, ty.lineNum, ty.offset });

            for (ty.fields) |fld| {
                std.debug.print("  fields:\n", .{});
                const fty = gftftr(fld.type);
                std.debug.print("    {s} at line: {d}, offset: {d}\n", .{ fld.name, fld.lineNum, fld.offset });
                std.debug.print("    type: {s} at line: {d}, offset: {d}\n", .{ fty.name, fty.lineNum, fty.offset });
            }
        }
    }
}

test "test main" {
    try testmain();
}

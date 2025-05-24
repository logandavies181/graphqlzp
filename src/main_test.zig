const std = @import("std");

const lexer = @import("graphql/lexer.zig");
const parser = @import("graphql/parser.zig");

const gftftr = @import("adapter/locator.zig").getNamedTypeFromTypeRef;

fn testmain() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();

    var lexResult = try lexer.tokenize(alloc, "test/schema.graphql");
    defer lexResult.deinit(alloc);

    var _parser = parser.Parser.create(alloc, lexResult.tokens);
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

const expect = std.testing.expect;

test "test main" {
    try testmain();
}

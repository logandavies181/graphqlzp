const std = @import("std");

const lexer = @import("graphql/lexer.zig");
const parser = @import("graphql/parser.zig");

fn testmain() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();

    var tokenizer = try lexer.Tokenizer.create("test/schema.graphql", alloc);
    const tokens = try tokenizer.tokenize();

    var _parser = parser.Parser.create(alloc, tokens);
    const doc = try _parser.parse();

    for (doc.objects) |ty| {
        std.debug.print("{s} at line: {d}, offset: {d}\n", .{ty.name, ty.lineNum, ty.offset});
    }
}

const expect = std.testing.expect;

test "test main" {
    try testmain();
}

const std = @import("std");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

fn testmain() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();

    var tokenizer = try lexer.Tokenizer.create("test/schema.graphql", alloc);
    const tokens = try tokenizer.tokenize();

    var _parser = parser.Parser.create(alloc, tokens);
    const doc = try _parser.parse();

    for (doc.types) |ty| {
        std.debug.print("{s}\n", .{ty.name});
    }
}

const expect = std.testing.expect;

test "test main" {
    try testmain();
}

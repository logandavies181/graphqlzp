const std = @import("std");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();

    var tokenizer = try lexer.Tokenizer.create("schema.graphql", alloc);
    const tokens = try tokenizer.tokenize();

    var _parser = parser.Parser.create(alloc, tokens);
    // var doc = try parser.Parser.create(alloc, tokens).parse();
    _ = try _parser.parse();

}

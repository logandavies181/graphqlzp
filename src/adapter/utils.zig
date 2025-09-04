const std = @import("std");

const lsp = @import("lsp");

const ast = @import("../graphql/ast.zig");
const Locator = @import("locator.zig");

pub fn keywordFromType(item: Locator.AstItem) ?[]const u8 {
    return switch (item) {
        .schema => "schema",
        .scalar => "scalar",
        .object => "type",
        .namedType => unreachable,
        .interface => "interface",
        .fieldDefinition => null,
        .directive => unreachable,
        .directiveDefinition => "directive",
        .argumentDefinition => null,
        .input => "input",
        .inputField => null,
        .enum_ => "enum",
        .enumValue => null,
        .union_ => "union",
    };
}

pub fn nameOf(item: Locator.AstItem) []const u8 {
    return switch (item) {
        .schema => "schema",
        .scalar => |_item| _item.name,
        .object => |_item| _item.name,
        .namedType => |_item| _item.name,
        .interface => |_item| _item.name,
        .fieldDefinition => |_item| _item.field.name,
        .directive => |_item| _item.name,
        .directiveDefinition => |_item| _item.name,
        .argumentDefinition => |_item| _item.name,
        .input => |_item| _item.name,
        .inputField => |_item| _item.field.name,
        .enum_ => |_item| _item.name,
        .enumValue => |_item| _item.name,
        .union_ => |_item| _item.name,
    };
}

pub fn descriptionOf(item: Locator.AstItem) ?[]const u8 {
    return switch (item) {
        .schema => |_item| _item.description,
        .scalar => |_item| _item.description,
        .object => |_item| _item.description,
        .namedType => unreachable, // expect resolved type instead
        .interface => |_item| _item.description,
        .fieldDefinition => |_item| _item.field.description,
        .directive => unreachable, // expect resolved directive def
        .directiveDefinition => |_item| _item.description,
        .argumentDefinition => |_item| _item.description,
        .input => |_item| _item.description,
        .inputField => |_item| _item.field.description,
        .enum_ => |_item| _item.description,
        .enumValue => |_item| _item.description,
        .union_ => |_item| _item.description,
    };
}

pub fn rangeOf(item: Locator.AstItem) lsp.types.Range {
    const len, const pos = Locator.getItemLenAndPos(item);
    return .{
        .start = pos,
        .end = .{
            .line = @intCast(pos.line),
            .character = @intCast(pos.character + len),
        },
    };
}

pub fn formatArgDefs(alloc: std.mem.Allocator, args: []ast.ArgumentDefinition) ![]const u8 {
    if (args.len == 0) {
        return "";
    }

    var content = std.ArrayList(u8){};
    try content.append(alloc, '(');

    for (args, 0..args.len) |arg, i| {
        try content
            .appendSlice(alloc, try std.fmt.allocPrint(
            alloc,
            "{s}: {s}",
            .{ arg.name, try formatTypeRef(alloc, arg.ty) },
        ));
        if (i < args.len - 1) {
            try content.appendSlice(alloc, ", ");
        } else {
            try content.append(alloc, ')');
        }
    }

    return try content.toOwnedSlice(alloc);
}

pub fn formatTypeRef(alloc: std.mem.Allocator, tr: ast.TypeRef) ![]const u8 {
    return switch (tr) {
        .namedType => |nt| if (nt.nullable) nt.name else try std.fmt.allocPrint(alloc, "{s}!", .{nt.name}),
        .listType => |lt| {
            const childContent = try formatTypeRef(alloc, lt.ty.*);
            return try std.fmt.allocPrint(alloc, "[{s}]{s}", .{ childContent, if (lt.nullable) "" else "!" });
        },
    };
}

pub const matcher = struct {
    n: []const u8,
    pub fn m(self_: @This(), item_: Locator.AstItem) bool {
        return std.mem.eql(u8, self_.n, nameOf(item_));
    }
    pub fn str(self_: @This(), item_: []const u8) bool {
        return std.mem.eql(u8, self_.n, item_);
    }
};

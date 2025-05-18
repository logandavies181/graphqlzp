const std = @import("std");

const ast = @import("../graphql/ast.zig");

pub const AstItem = union {
    schema: ast.Schema,
    scalar: ast.Scalar,
    namedType: ast.NamedType,
    object: ast.Object,
    interface: ast.Interface,

    // TODO etc
};

pub const location = struct {
    item: AstItem,
    startPos: u64,
    len: u64,
};

pub const Locator = struct {
    locations: []location,

    pub fn init(doc: ast.Document, alloc: std.mem.Allocator) !Locator {
        var locations = std.ArrayList(location).init(alloc);

        for (doc.objects) |item| {
            try locations.append(.{
                .item = .{
                    .object = item,
                },
                .startPos = item.pos,
                .len = item.name.len,
            });
        }

        for (doc.scalars) |item| {
            try locations.append(.{
                .item = .{
                    .scalar = item,
                },
                .startPos = item.pos,
                .len = item.name.len,
            });
        }

        for (doc.interfaces) |item| {
            try locations.append(.{
                .item = .{
                    .interface = item,
                },
                .startPos = item.pos,
                .len = item.name.len,
            });
        }

        return .{
            .locations = try locations.toOwnedSlice(),
        };
    }

    pub fn getItemAt(self: Locator, pos: u64) ?AstItem {
        for (self.locations) |loc| {
            if (overlaps(loc, pos)) {
                return loc.item;
            }
        }
        return null;
    }

    fn overlaps(loc: location, pos: u64) bool {
        return pos >= loc.startPos and pos <= loc.startPos + loc.len;
    }
};

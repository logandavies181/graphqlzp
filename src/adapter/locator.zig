const std = @import("std");

const ast = @import("../graphql/ast.zig");

pub const AstItem = union(enum) {
    schema: ast.Schema,
    scalar: ast.Scalar,
    namedType: ast.NamedType,
    object: ast.Object,
    interface: ast.Interface,

    // TODO etc
};

pub const location = struct {
    item: AstItem,
    len: u64,
    offset: u64,
    lineNum: u64,
};

pub fn getNamedTypeFromTypeRef(tr: ast.TypeRef) ast.NamedType {
    return switch (tr) {
        .namedType => |nt| {
            return nt;
        },
        .listType => |lt| {
            return getNamedTypeFromTypeRef(lt.ty.*);
        },
    };
}

pub const Locator = struct {
    locations: []location,

    pub fn init(doc: ast.Document, alloc: std.mem.Allocator) !Locator {
        var locations = std.ArrayList(location).init(alloc);

        for (doc.objects) |item| {
            try locations.append(.{ .item = .{
                .object = item,
            }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });
            for (item.implements) |impl| {
                try locations.append(.{ .item = .{
                    .namedType = impl,
                }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });
            }
            for (item.fields) |fld| {
                const nt = getNamedTypeFromTypeRef(fld.type);
                //std.debug.print("found {s}\n", .{nt.name});
                try locations.append(.{ .item = .{
                    .namedType = nt,
                }, .len = nt.name.len, .offset = nt.offset, .lineNum = nt.lineNum });
            }
        }

        for (doc.scalars) |item| {
            try locations.append(.{ .item = .{
                .scalar = item,
            }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });
        }

        for (doc.interfaces) |item| {
            try locations.append(.{ .item = .{
                .interface = item,
            }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });
        }

        return .{
            .locations = try locations.toOwnedSlice(),
        };
    }

    pub fn getItemAt(self: Locator, offset: u64, lineNum: u64) ?AstItem {
        for (self.locations) |loc| {
            if (overlaps(loc, offset, lineNum)) {
                return loc.item;
            }
        }
        return null;
    }

    fn overlaps(loc: location, offset: u64, lineNum: u64) bool {
        return lineNum == loc.lineNum and offset >= loc.offset and offset < loc.offset + loc.len;
    }
};

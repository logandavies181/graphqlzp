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

fn locateObjectFields(ty: type, obj: ty, locations: *std.ArrayList(location)) !void {
    try locations.append(.{ .item = .{
        .object = obj,
    }, .len = obj.name.len, .offset = obj.offset, .lineNum = obj.lineNum });


    if (ty == ast.Object) {
        for (obj.implements) |impl| {
            try locations.append(.{ .item = .{
                .namedType = impl,
            }, .len = impl.name.len, .offset = impl.offset, .lineNum = impl.lineNum });
        }
    }

    for (obj.fields) |fld| {
        const nt = getNamedTypeFromTypeRef(fld.type);
        try locations.append(.{ .item = .{
            .namedType = nt,
        }, .len = nt.name.len, .offset = nt.offset, .lineNum = nt.lineNum });

        for (fld.args) |arg| {
            const _nt = getNamedTypeFromTypeRef(arg.ty);
            try locations.append(.{ .item = .{
                .namedType = _nt,
            }, .len = _nt.name.len, .offset = _nt.offset, .lineNum = _nt.lineNum });
        }
    }
}

pub const Locator = struct {
    locations: []location,

    pub fn init(doc: ast.Document, alloc: std.mem.Allocator) !Locator {
        var locations = std.ArrayList(location).init(alloc);

        for (doc.objects) |item| {
            try locateObjectFields(ast.Object, item, &locations);
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
            for (item.fields) |fld| {
                const nt = getNamedTypeFromTypeRef(fld.type);
                try locations.append(.{ .item = .{
                    .namedType = nt,
                }, .len = nt.name.len, .offset = nt.offset, .lineNum = nt.lineNum });
            }
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

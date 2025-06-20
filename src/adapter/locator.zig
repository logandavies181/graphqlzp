const std = @import("std");

const ast = @import("../graphql/ast.zig");

const lsp = @import("lsp");

pub const AstItem = union(enum) {
    schema: ast.Schema,
    scalar: ast.Scalar,
    namedType: ast.NamedType,
    object: ast.Object,
    interface: ast.Interface,
    fieldDefinition: Field,

    // TODO etc
};

pub const location = struct {
    item: AstItem,
    len: u64,
    offset: u64,
    lineNum: u64,
};

pub const Field = struct {
    field: ast.Field,
    parent: struct {
        type: ObjectType,
        name: []const u8,
    },
};

pub const ObjectType = enum {
    object,
    interface,
};

fn _getItemLenAndPos(item: anytype) struct { u64, lsp.types.Position } {
    return .{
        item.name.len,
        .{
            .line = @intCast(item.lineNum),
            .character = @intCast(item.offset),
        },
    };
}

pub fn getItemLenAndPos(item: AstItem) struct { u64, lsp.types.Position } {
    return switch (item) {
        .scalar => |_item| _getItemLenAndPos(_item),
        .namedType => |_item| _getItemLenAndPos(_item),
        .object => |_item| _getItemLenAndPos(_item),
        .interface => |_item| _getItemLenAndPos(_item),
        .fieldDefinition => |_item| _getItemLenAndPos(_item.field),
        .schema => |sch| {
            return .{
                6,
                .{
                    .line = @intCast(sch.lineNum orelse 0),
                    .character = @intCast(sch.offset orelse 0),
                },
            };
        },
    };
}

pub fn getTypeDefFromNamedType(doc: ast.Document, nt: ast.NamedType) ?AstItem {
    const memeql = std.mem.eql;
    for (doc.objects) |obj| {
        if (memeql(u8, obj.name, nt.name)) {
            return .{
                .object = obj
            };
        }
    }
    for (doc.interfaces) |ifce| {
        if (memeql(u8, ifce.name, nt.name)) {
            return .{
                .interface = ifce
            };
        }
    }
    for (doc.scalars) |scl| {
        if (memeql(u8, scl.name, nt.name)) {
            return .{
                .scalar = scl,
            };
        }
    }
    return null;
}

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


    for (obj.implements) |impl| {
        try locations.append(.{ .item = .{
            .namedType = impl,
        }, .len = impl.name.len, .offset = impl.offset, .lineNum = impl.lineNum });
    }

    for (obj.fields) |fld| {
        try locations.append(.{
            .item = .{
                .fieldDefinition = .{
                    .field = fld,
                    .parent = .{
                        .type = if (ty == ast.Interface) .interface else .object,
                        .name = obj.name,
                    },
                },
            }, .len = fld.name.len, .offset = fld.offset, .lineNum = fld.lineNum,
        });

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
    doc: ast.Document,

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
            .doc = doc,
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

    pub fn getItemDefinition(self: Locator, item: AstItem) ?AstItem {
        switch (item) {
            .object => |obj| {
                return .{
                    .object = obj,
                };
            },
            .namedType => |nt| {
                const ty = getTypeDefFromNamedType(self.doc, nt);
                if (ty == null) {
                    return null;
                }

                switch (ty.?) {
                    .object => |obj| {
                        return .{
                            .object = obj,
                        };
                    },
                    .interface => |ifce| {
                        return .{
                            .interface = ifce,
                        };
                    },
                    .scalar => |scl| {
                        return .{
                            .scalar = scl,
                        };
                    },

                    // TODO: other types

                    else => {
                        std.debug.print("warn: getItemDefinition.namedType not implemented arm", .{});
                        return null;
                    },
                }
            },
            .fieldDefinition => |fd| {
                return .{
                    .fieldDefinition = fd,
                };
            },
            else => {
                std.debug.print("warn: getItemDefinition not implemented arm", .{});
                return null;
            },
        }
    }

    fn overlaps(loc: location, offset: u64, lineNum: u64) bool {
        return lineNum == loc.lineNum and offset >= loc.offset and offset < loc.offset + loc.len;
    }
};

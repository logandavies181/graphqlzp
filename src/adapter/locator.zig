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
    directive: ast.Directive,
    directiveDefinition: ast.DirectiveDef,

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
        .directive => |_item| _getItemLenAndPos(_item),
        .directiveDefinition => |_item| _getItemLenAndPos(_item),
    };
}

pub fn getTypeDefFromNamedType(doc: ast.Document, nt: ast.NamedType) ?AstItem {
    const memeql = std.mem.eql;
    for (doc.objects) |obj| {
        if (memeql(u8, obj.name, nt.name)) {
            return .{ .object = obj };
        }
    }
    for (doc.interfaces) |ifce| {
        if (memeql(u8, ifce.name, nt.name)) {
            return .{ .interface = ifce };
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

const locatorBuilder = struct {
    locations: *std.ArrayList(location),

    fn init(locations: *std.ArrayList(location)) locatorBuilder {
        return .{
            .locations = locations,
        };
    }

    fn addObject(self: *locatorBuilder, ty: type, obj: ty) !void {
        const item: AstItem =
            if (ty == ast.Object)
                .{ .object = obj }
            else if (ty == ast.Interface)
                .{ .interface = obj }
            else
                return;

        try self.locations.append(.{ .item = item, .len = obj.name.len, .offset = obj.offset, .lineNum = obj.lineNum });

        for (obj.implements) |impl| {
            try self.locations.append(.{ .item = .{
                .namedType = impl,
            }, .len = impl.name.len, .offset = impl.offset, .lineNum = impl.lineNum });
        }

        try self.addDirectives(obj);
        try self.addFieldDefinitions(obj.fields, ty, obj);
    }

    fn addDirectives(self: *locatorBuilder, obj: anytype) !void {
        for (obj.directives) |dr| {
            try self.locations.append(.{
                .item = .{
                    .directive = dr,
                },
                // hackily include the preceding @
                .len = dr.name.len + 1,
                .offset = dr.offset - 1,
                .lineNum = dr.lineNum,
            });
        }
    }

    fn addDirectiveDefinitions(self: *locatorBuilder, directiveDef: ast.DirectiveDef) !void {
        try self.locations.append(.{
            .item = .{
                .directiveDefinition = directiveDef,
            },
            // hackily include the preceding @
            .len = directiveDef.name.len + 1,
            .offset = directiveDef.offset - 1,
            .lineNum = directiveDef.lineNum,
        });
    }

    fn addFieldDefinitions(self: *locatorBuilder, fields: []ast.Field, parentTy: type, parent: parentTy) !void {
        for (fields) |fld| {
            try self.locations.append(.{
                .item = .{
                    .fieldDefinition = .{
                        .field = fld,
                        .parent = .{
                            .type = if (parentTy == ast.Interface) .interface else .object,
                            .name = parent.name,
                        },
                    },
                },
                .len = fld.name.len,
                .offset = fld.offset,
                .lineNum = fld.lineNum,
            });

            const nt = getNamedTypeFromTypeRef(fld.type);
            try self.locations.append(.{ .item = .{
                .namedType = nt,
            }, .len = nt.name.len, .offset = nt.offset, .lineNum = nt.lineNum });

            for (fld.args) |arg| {
                const _nt = getNamedTypeFromTypeRef(arg.ty);
                try self.locations.append(.{ .item = .{
                    .namedType = _nt,
                }, .len = _nt.name.len, .offset = _nt.offset, .lineNum = _nt.lineNum });
            }
        }
    }

    fn addScalar(self: *locatorBuilder, item: ast.Scalar) !void {
        try self.locations.append(.{ .item = .{
            .scalar = item,
        }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });
    }
};

pub const Locator = struct {
    locations: []location,
    doc: ast.Document,

    pub fn init(doc: ast.Document, alloc: std.mem.Allocator) !Locator {
        var locations = std.ArrayList(location).init(alloc);
        var lb = locatorBuilder.init(&locations);

        for (doc.objects) |item| {
            try lb.addObject(ast.Object, item);
        }

        for (doc.scalars) |item| {
            try lb.addScalar(item);
        }

        for (doc.interfaces) |item| {
            try lb.addObject(ast.Interface, item);
        }

        for (doc.directiveDefinitions) |dd| {
            try lb.addDirectiveDefinitions(dd);
        }

        //for (doc.unions) |item|

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
                        std.debug.print("warn: getItemDefinition.namedType not implemented arm ", .{});
                        return null;
                    },
                }
            },
            .interface => |ifce| {
                return .{
                    .interface = ifce,
                };
            },
            .fieldDefinition => |fd| {
                return .{
                    .fieldDefinition = fd,
                };
            },
            .directive => |dr| {
                for (self.doc.directiveDefinitions) |dd| {
                    if (std.mem.eql(u8, dr.name, dd.name)) {
                        return .{
                            .directiveDefinition = dd,
                        };
                    }
                }
                return null;
            },
            .directiveDefinition => |dd| {
                return .{
                    .directiveDefinition = dd,
                };
            },
            else => {
                std.debug.print("warn: getItemDefinition not implemented arm ", .{});
                return null;
            },
        }
    }

    fn overlaps(loc: location, offset: u64, lineNum: u64) bool {
        return lineNum == loc.lineNum and offset >= loc.offset and offset < loc.offset + loc.len;
    }
};

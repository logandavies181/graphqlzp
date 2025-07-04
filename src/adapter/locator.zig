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
    argumentDefinition: ast.ArgumentDefinition,
    input: ast.Input,
    inputField: InputField,
    enum_: ast.Enum,
    enumValue: ast.EnumValue,
    union_: ast.Union,
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

pub const InputField = struct {
    field: ast.InputField,
    parentName: []const u8,
};

pub const ObjectType = enum {
    object,
    interface,
    input,
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
        .argumentDefinition => |_item| _getItemLenAndPos(_item),
        .input => |_item| _getItemLenAndPos(_item),
        .inputField => |_item| _getItemLenAndPos(_item.field),
        .enum_ => |_item| _getItemLenAndPos(_item),
        .enumValue => |_item| _getItemLenAndPos(_item),
        .union_ => |_item| _getItemLenAndPos(_item),
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
    for (doc.inputs) |in| {
        if (memeql(u8, in.name, nt.name)) {
            return .{
                .input = in,
            };
        }
    }
    for (doc.enums) |en| {
        if (memeql(u8, en.name, nt.name)) {
            return .{
                .enum_ = en,
            };
        }
    }
    for (doc.unions) |un| {
        if (memeql(u8, un.name, nt.name)) {
            return .{
                .union_ = un,
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
            else if (ty == ast.Input)
                .{ .input = obj }
            else
                return;

        try self.locations.append(.{ .item = item, .len = obj.name.len, .offset = obj.offset, .lineNum = obj.lineNum });

        if (ty != ast.Input) {
            for (obj.implements) |impl| {
                try self.locations.append(.{ .item = .{
                    .namedType = impl,
                }, .len = impl.name.len, .offset = impl.offset, .lineNum = impl.lineNum });
            }
        }

        try self.addDirectives(obj);
        try self.addFields(ty, obj);
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

    fn addFields(self: *locatorBuilder, ty: type, obj: ty) !void {
        if (ty == ast.Input) {
            try self.addInputFields(obj.inputFields, obj);
        } else {
            try self.addFieldDefinitions(obj.fields, ty, obj);
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
                try self.locations.append(.{
                    .item = .{
                        .argumentDefinition = arg,
                    },
                    .len = arg.name.len,
                    .offset = arg.offset,
                    .lineNum = arg.lineNum,
                });

                const _nt = getNamedTypeFromTypeRef(arg.ty);
                try self.locations.append(.{ .item = .{
                    .namedType = _nt,
                }, .len = _nt.name.len, .offset = _nt.offset, .lineNum = _nt.lineNum });
            }

            try self.addDirectives(fld);
        }
    }

    fn addInputFields(self: *locatorBuilder, fields: []ast.InputField, parent: ast.Input) !void {
        for (fields) |fld| {
            try self.locations.append(.{
                .item = .{
                    .inputField = .{
                        .field = fld,
                        .parentName = parent.name,
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

            try self.addDirectives(fld);
        }
    }

    fn addScalar(self: *locatorBuilder, item: ast.Scalar) !void {
        try self.locations.append(.{ .item = .{
            .scalar = item,
        }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });
    }

    fn addEnum(self: *locatorBuilder, item: ast.Enum) !void {
        try self.locations.append(.{ .item = .{
            .enum_ = item,
        }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });

        for (item.values) |val| {
            try self.locations.append(.{ .item = .{
                .enumValue = val,
            }, .len = val.name.len, .offset = val.offset, .lineNum = val.lineNum });
        }

        try self.addDirectives(item);
    }

    fn addUnion(self: *locatorBuilder, item: ast.Union) !void {
        try self.locations.append(.{ .item = .{
            .union_ = item,
        }, .len = item.name.len, .offset = item.offset, .lineNum = item.lineNum });

        for (item.types) |ty| {
            try self.locations.append(.{ .item = .{
                .namedType = ty,
            }, .len = ty.name.len, .offset = ty.offset, .lineNum = ty.lineNum });
        }

        try self.addDirectives(item);
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
        for (doc.inputs) |item| {
            try lb.addObject(ast.Input, item);
        }
        for (doc.interfaces) |item| {
            try lb.addObject(ast.Interface, item);
        }
        for (doc.directiveDefinitions) |dd| {
            try lb.addDirectiveDefinitions(dd);
        }
        for (doc.enums) |en| {
            try lb.addEnum(en);
        }
        for (doc.unions) |un| {
            try lb.addUnion(un);
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
                    std.debug.print("warn: getItemDefinition.namedType typedef not found\n", .{});
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
                    .input => |in| {
                        return .{
                            .input = in,
                        };
                    },
                    .union_ => return ty.?,
                    .enum_ => return ty.?,
                    .enumValue => return ty.?,

                    // TODO: other types

                    else => {
                        std.debug.print("warn: getItemDefinition.namedType not implemented arm\n", .{});
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
            .argumentDefinition => |ad| {
                return .{
                    .argumentDefinition = ad,
                };
            },
            .input => |in| {
                return .{
                    .input = in,
                };
            },
            .inputField => |inf| {
                return .{
                    .inputField = inf,
                };
            },
            .union_ => return item,
            .enum_ => return item,
            .enumValue => return item,
            else => {
                std.debug.print("warn: getItemDefinition not implemented arm\n", .{});
                return null;
            },
        }
    }

    fn overlaps(loc: location, offset: u64, lineNum: u64) bool {
        return lineNum == loc.lineNum and offset >= loc.offset and offset < loc.offset + loc.len;
    }
};

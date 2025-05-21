pub const Document = struct {
    objects: []Object = &[_]Object{},
    scalars: []Scalar = &[_]Scalar{},
    interfaces: []Interface = &[_]Interface{},
    schema: Schema,

    namedTypes: []NamedType = &[_]NamedType{},
};

pub const Schema = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &[_]Directive{},

    query: NamedType,
    mutation: ?NamedType,
    subscription: ?NamedType,

    offset: ?u64 = null,
    lineNum: ?u64 = null,
};

pub const TypeRef = union(enum) {
    namedType: NamedType,
    listType: ListType,
};

pub const NamedType = struct {
    name: []const u8,
    nullable: bool = true,

    offset: u64,
    lineNum: u64,
};

pub const ListType = struct {
    ty: *TypeRef,
    nullable: bool = true,
};

pub const Object = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &[_]Directive{},
    fields: []Field,
    implements: []NamedType = &[_]NamedType{},
    nullable: bool = true,
    name: []const u8,

    offset: u64,
    lineNum: u64,
};

pub const Field = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &[_]Directive{},
    name: []const u8,
    type: TypeRef,

    offset: u64,
    lineNum: u64,
};

pub const Interface = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    nullable: bool = true,
    fields: []Field,

    offset: u64,
    lineNum: u64,
};

pub const Directive = struct {
    args: ?[]Arg,
    name: []const u8,
};

pub const DirectiveDef = struct {
    description: ?[]const u8 = null,
    name: []const u8,
};

pub const Arg = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    ty: TypeRef,
};

pub const Scalar = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    directives: []Directive = &[_]Directive{},

    offset: u64,
    lineNum: u64,
};

pub const Document = struct {
    objects: []Object = &.{},
    scalars: []Scalar = &.{},
    interfaces: []Interface = &.{},
    schema: Schema,

    namedTypes: []NamedType = &.{},
};

pub const Schema = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &.{},

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
    directives: []Directive = &.{},
    fields: []Field,
    implements: []NamedType = &.{},
    nullable: bool = true,
    name: []const u8,

    offset: u64,
    lineNum: u64,
};

pub const Field = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &.{},
    name: []const u8,
    type: TypeRef,
    args: []ArgumentDefinition = &.{},

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
    name: []const u8,
    args: ?[]Argument,
};

pub const DirectiveDef = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    args: []ArgumentDefinition = &.{},
    repeatable: bool,
    locations: []DirectiveLocation,
};

pub const DirectiveLocation = enum {
    unknown,
    query,
    mutation,
    subscription,
    field,
    fragmentDefinition,
    fragmentSpread,
    inlineFragment,
    variableDefinition,
    schema,
    scalar,
    object,
    fieldDefinition,
    argumentDefinition,
    interface,
    union_,
    enum_,
    enumValue,
    inputObject,
    inputFieldDefinition,
};

pub const Value = union(enum) {
    String: []const u8,
    // Int: u64,
    // Float: f64,
    // Null: null,
    // TODO
    // Enum: ,
    // List: ,
    // Object: ,
};

pub const Argument = struct {
    name: []const u8,
    value: Value,
};

pub const ArgumentDefinition = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    ty: TypeRef,
};

pub const Scalar = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    directives: []Directive = &.{},

    offset: u64,
    lineNum: u64,
};

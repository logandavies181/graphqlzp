pub const Document = struct {
    directiveDefinitions: []DirectiveDef = &.{},
    enums: []Enum = &.{},
    inputs: []Input = &.{},
    interfaces: []Interface = &.{},
    objects: []Object = &.{},
    scalars: []Scalar = &.{},
    schema: Schema,
    unions: []Union = &.{},
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

pub const Input = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &.{},
    name: []const u8,
    inputFields: []InputField = &.{},

    offset: u64,
    lineNum: u64,
};

pub const InputField = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &.{},
    name: []const u8,
    type: TypeRef,

    offset: u64,
    lineNum: u64,
};

pub const Interface = struct {
    description: ?[]const u8 = null,
    directives: []Directive = &.{},
    name: []const u8,
    fields: []Field,
    implements: []NamedType = &.{},

    offset: u64,
    lineNum: u64,
};

pub const Directive = struct {
    name: []const u8,
    args: ?[]Argument,

    offset: u64,
    lineNum: u64,
};

pub const Enum = struct {
    description: ?[]const u8 = null,
    name: []const u8,

    directives: []Directive = &.{},
    values: []EnumValue = &.{},

    offset: u64,
    lineNum: u64,
};

pub const EnumValue = struct {
    description: ?[]const u8 = null,
    name: []const u8,

    directives: []Directive = &.{},

    offset: u64,
    lineNum: u64,
};

pub const DirectiveDef = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    args: []ArgumentDefinition = &.{},
    repeatable: bool,
    locations: []DirectiveLocation,

    offset: u64,
    lineNum: u64,
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
    Int: i64,
    Float: f64,
    Bool: bool,
    Enum: []const u8,
    Null: struct {},
    List: []Value,
    // TODO
    // Object: ,
};

pub const Argument = struct {
    name: []const u8,
    value: Value,
};

pub const ArgumentDefinition = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    directives: []Directive = &.{},
    ty: TypeRef,
    default: ?Value,

    offset: u64,
    lineNum: u64,
};

pub const Scalar = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    directives: []Directive = &.{},

    offset: u64,
    lineNum: u64,
};

pub const Union = struct {
    description: ?[]const u8 = null,
    name: []const u8,
    directives: []Directive = &.{},

    types: []NamedType = &.{},

    offset: u64,
    lineNum: u64,
};

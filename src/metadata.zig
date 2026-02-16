const std = @import("std");
const metadata = @This();

pub const Api = struct {
    Constants: []const Constant,
    Types: []const Type,
    Functions: []const Function,
    UnicodeAliases: []const []const u8,

    pub fn parse(
        allocator: std.mem.Allocator,
        api_path: []const u8,
        filename: []const u8,
        content: []const u8,
    ) Api {
        var diagnostics = std.json.Diagnostics{};
        var scanner = std.json.Scanner.initCompleteInput(allocator, content);
        defer scanner.deinit();
        scanner.enableDiagnostics(&diagnostics);
        return std.json.parseFromTokenSourceLeaky(
            Api,
            allocator,
            &scanner,
            .{},
        ) catch |err| {
            std.log.err(
                "{s}{c}{s}:{}:{}: {s}",
                .{
                    api_path,              std.fs.path.sep,         filename,
                    diagnostics.getLine(), diagnostics.getColumn(), @errorName(err),
                },
            );
            @panic("json error");
        };
    }
};

pub const ValueType = enum {
    Byte,
    UInt16,
    Int32,
    UInt32,
    Int64,
    UInt64,
    Single,
    Double,
    String,
    PropertyKey,
};

pub const TypeRefNative = enum {
    Void,
    Boolean,
    SByte,
    Byte,
    Int16,
    UInt16,
    Int32,
    UInt32,
    Int64,
    UInt64,
    Char,
    Single,
    Double,
    String,
    IntPtr,
    UIntPtr,
    Guid,
};

pub const Constant = struct {
    Name: []const u8,
    Type: TypeRef,
    ValueType: ValueType,
    Value: std.json.Value,
    Attrs: ConstantAttrs,
};
pub const ConstantAttrs = struct {
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!ConstantAttrs {
        return try parseAttrsArray(ConstantAttrs, allocator, source, options);
    }
};

pub const EnumIntegerBase = enum { Byte, SByte, UInt16, UInt32, Int32, UInt64 };

const TypeKind = enum {
    NativeTypedef,
    Enum,
    Struct,
    Union,
    ComClassID,
    Com,
    FunctionPointer,
};
const type_kinds = std.StaticStringMap(TypeKind).initComptime(.{
    .{ "NativeTypedef", .NativeTypedef },
    .{ "Enum", .Enum },
    .{ "Struct", .Struct },
    .{ "Union", .Union },
    .{ "ComClassID", .ComClassID },
    .{ "Com", .Com },
    .{ "FunctionPointer", .FunctionPointer },
});
pub const Type = struct {
    Name: []const u8,
    Architectures: Architectures,
    Platform: ?Platform,
    Kind: union(enum) {
        NativeTypedef: NativeTypedef,
        Enum: Enum,
        Struct: StructOrUnion,
        Union: StructOrUnion,
        ComClassID: ComClassID,
        Com: Com,
        FunctionPointer: FunctionPointer,
    },

    pub const Enum = struct {
        Flags: bool,
        Scoped: bool,
        Values: []EnumField,
        IntegerBase: ?EnumIntegerBase,
    };
    pub const EnumField = struct {
        Name: []const u8,
        Value: std.json.Value,
    };

    pub const ComClassID = struct {
        Guid: []const u8,
    };

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Type {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        try expectFieldName(source, "Name");
        const name = switch (try source.next()) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        };
        try expectFieldName(source, "Architectures");
        const arches = try Architectures.jsonParse(allocator, source, options);
        try expectFieldName(source, "Platform");
        const platform = try std.json.innerParse(?Platform, allocator, source, options);
        switch (try jsonParseUnionKind(TypeKind, "Type", source, type_kinds)) {
            .NativeTypedef => return .{ .Name = name, .Architectures = arches, .Platform = platform, .Kind = .{
                .NativeTypedef = try parseUnionObject(NativeTypedef, allocator, source, options),
            } },
            .Enum => return .{ .Name = name, .Architectures = arches, .Platform = platform, .Kind = .{
                .Enum = try parseUnionObject(Enum, allocator, source, options),
            } },
            .Struct => return .{ .Name = name, .Architectures = arches, .Platform = platform, .Kind = .{
                .Struct = try parseUnionObject(StructOrUnion, allocator, source, options),
            } },
            .Union => return .{ .Name = name, .Architectures = arches, .Platform = platform, .Kind = .{
                .Union = try parseUnionObject(StructOrUnion, allocator, source, options),
            } },
            .ComClassID => return .{ .Name = name, .Architectures = arches, .Platform = platform, .Kind = .{
                .ComClassID = try parseUnionObject(ComClassID, allocator, source, options),
            } },
            .Com => return .{ .Name = name, .Architectures = arches, .Platform = platform, .Kind = .{
                .Com = try parseUnionObject(Com, allocator, source, options),
            } },
            .FunctionPointer => return .{ .Name = name, .Architectures = arches, .Platform = platform, .Kind = .{
                .FunctionPointer = try parseUnionObject(FunctionPointer, allocator, source, options),
            } },
        }
    }
};

pub const FunctionPointer = struct {
    SetLastError: bool,
    ReturnType: TypeRef,
    //ReturnAttrs: ReturnAttrs,
    ReturnAttrs: ParamAttrs,
    Attrs: FunctionAttrs,
    Params: []const Param,
};

pub const StructOrUnion = struct {
    Size: u32,
    PackingSize: u32,
    Attrs: StructOrUnionAttrs,
    Fields: []const StructOrUnionField,
    NestedTypes: []const Type,
    Comment: ?[]const u8 = null,
};
pub const StructOrUnionField = struct {
    Name: []const u8,
    Type: TypeRef,
    Attrs: FieldAttrs,
};

pub const FieldAttrs = struct {
    Const: bool = false,
    Obsolete: ?ObsoleteAttr = null,
    Optional: bool = false,
    NotNullTerminated: bool = false,
    NullNullTerminated: bool = false,
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!FieldAttrs {
        return parseAttrsArray(FieldAttrs, allocator, source, options);
    }
};

pub const NativeTypedef = struct {
    AlsoUsableFor: ?[]const u8,
    Def: TypeRef,
    FreeFunc: ?[]const u8,
    InvalidHandleValue: ?i64,
};

pub const Com = struct {
    Guid: ?[]const u8,
    Attrs: ComAttrs,
    Interface: ?TypeRef,
    Methods: []const ComMethod,
};
pub const ComAttrs = struct {
    Agile: bool = false,
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!ComAttrs {
        return parseAttrsArray(ComAttrs, allocator, source, options);
    }
};

pub const ComMethod = struct {
    Name: []const u8,
    SetLastError: bool,
    ReturnType: TypeRef,
    //ReturnAttrs: ReturnAttrs,
    ReturnAttrs: ParamAttrs,
    Architectures: Architectures,
    Platform: ?Platform,
    Attrs: FunctionAttrs,
    Params: []const Param,
};
//pub const ComMethodAttrs = struct {
//    SpecialName: bool = false,
//    PreserveSig: bool = false,
//    pub fn jsonParse(
//        allocator: std.mem.Allocator,
//        source: anytype,
//        options: std.json.ParseOptions,
//    ) std.json.ParseError(@TypeOf(source.*))!ComMethodAttrs {
//        return parseAttrsArray(ComMethodAttrs, allocator, source, options);
//    }
//};

//pub const ComMethodParam = struct {
//    Name: []const u8,
//    Type: TypeRef,
//    Attrs: ComMethodParamAttrs,
//};
//pub const ComMethodParamAttrs = struct {
//    In: bool = false,
//    Out: bool = false,
//    Const: bool = false,
//    Optional: bool = false,
//    ComOutPtr: bool = false,
//    RetVal: bool = false,
//    Reserved: bool = false,
//    NotNullTerminated: bool = false,
//    NullNullTerminated: bool = false,
//    MemorySize: ?MemorySize = null,
//    FreeWith: ?FreeWith = null,
//
//    pub fn jsonParse(
//        allocator: std.mem.Allocator,
//        source: anytype,
//        options: std.json.ParseOptions,
//    ) std.json.ParseError(@TypeOf(source.*))!ComMethodParamAttrs {
//        return parseAttrsArray(ComMethodParamAttrs, allocator, source, options);
//    }
//};

pub const Function = struct {
    Name: []const u8,
    SetLastError: bool,
    DllImport: []const u8,
    ReturnType: TypeRef,
    //ReturnAttrs: ReturnAttrs,
    ReturnAttrs: ParamAttrs,
    Architectures: Architectures,
    Platform: ?Platform,
    Attrs: FunctionAttrs,
    Params: []const Param,
};
pub const Platform = enum {
    windowsServer2000,
    windowsServer2003,
    windowsServer2008,
    windowsServer2012,
    windowsServer2016,
    windowsServer2020,
    @"windows5.0",
    @"windows5.1.2600",
    @"windows6.0.6000",
    @"windows6.1",
    @"windows8.0",
    @"windows8.1",
    @"windows10.0.10240",
    @"windows10.0.10586",
    @"windows10.0.14393",
    @"windows10.0.15063",
    @"windows10.0.16299",
    @"windows10.0.17134",
    @"windows10.0.17763",
    @"windows10.0.18362",
    @"windows10.0.19041",
};

pub const Architectures = struct {
    filter: ?Filter = null,

    pub const Filter = struct {
        X86: bool = false,
        X64: bool = false,
        Arm64: bool = false,
        //pub fn allAreSet(self: Filter) bool {
        //return self.X86 and self.X64 and self.Arm64;
        //}
        pub fn eql(self: Filter, other: Filter) bool {
            return self.X86 == other.X86 and
                self.X64 == other.X64 and
                self.Arm64 == other.Arm64;
        }
        pub fn unionWith(self: Filter, other: Filter) ?Filter {
            const new_filter: Filter = .{
                .X86 = self.X86 or other.X86,
                .X64 = self.X64 or other.X64,
                .Arm64 = self.Arm64 or other.Arm64,
            };
            if (new_filter.X86 and new_filter.X64 and new_filter.Arm64)
                return null;
            return new_filter;
        }
    };

    pub fn eql(self: Architectures, other: Architectures) bool {
        const self_filter = self.filter orelse return other.filter == null;
        const other_filter = other.filter orelse return false;
        return self_filter.eql(other_filter);
    }

    pub fn unionWith(self: Architectures, other: Architectures) Architectures {
        const self_filter = self.filter orelse return .{};
        const other_filter = other.filter orelse return .{};
        return .{ .filter = self_filter.unionWith(other_filter) };
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Architectures {
        _ = allocator;
        _ = options;
        if (.array_begin != try source.next()) return error.UnexpectedToken;
        const filter_struct_info = @typeInfo(Filter).@"struct";
        var result: Architectures = .{};
        while (true) {
            switch (try source.next()) {
                .array_end => return result,
                .string => |s| {
                    if (result.filter == null) {
                        result.filter = .{};
                    }

                    inline for (filter_struct_info.fields) |field| {
                        if (field.type == bool and std.mem.eql(u8, s, field.name)) {
                            @field(result.filter.?, field.name) = true;
                            break;
                        }
                    } else {
                        std.log.err("unknown Architecture attribute '{s}'", .{s});
                        return error.UnexpectedToken;
                    }
                },
                else => |token| {
                    std.log.err(
                        "expected string or array_close but got {s}",
                        .{@tagName(token)},
                    );
                    return error.UnexpectedToken;
                },
            }
        }
    }
};

const MemorySize = struct {
    BytesParamIndex: u16,
};
const FreeWith = struct {
    Func: []const u8,
};

pub const FunctionAttrs = struct {
    SpecialName: bool = false,
    PreserveSig: bool = false,
    DoesNotReturn: bool = false,
    Obsolete: ?ObsoleteAttr = null,
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!FunctionAttrs {
        return parseAttrsArray(FunctionAttrs, allocator, source, options);
    }
};

const ObsoleteAttr = struct {
    Message: ?[]const u8 = null,
};

pub const StructOrUnionAttrs = struct {
    Obsolete: ?ObsoleteAttr = null,
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!StructOrUnionAttrs {
        return parseAttrsArray(StructOrUnionAttrs, allocator, source, options);
    }
};

//pub const ReturnAttrs = struct {
//    Optional: bool = false,
//    pub fn jsonParse(
//        allocator: std.mem.Allocator,
//        source: anytype,
//        options: std.json.ParseOptions,
//    ) std.json.ParseError(@TypeOf(source.*))!ReturnAttrs {
//        return parseAttrsArray(ReturnAttrs, allocator, source, options);
//    }
//};
pub const ParamAttrs = struct {
    Const: bool = false,
    In: bool = false,
    Out: bool = false,
    Optional: bool = false,
    NotNullTerminated: bool = false,
    NullNullTerminated: bool = false,
    RetVal: bool = false,
    ComOutPtr: bool = false,
    DoNotRelease: bool = false,
    Reserved: bool = false,
    MemorySize: ?MemorySize = null,
    FreeWith: ?FreeWith = null,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!ParamAttrs {
        return parseAttrsArray(ParamAttrs, allocator, source, options);
    }
};

pub const Param = struct {
    Name: []const u8,
    Type: TypeRef,
    Attrs: ParamAttrs,
};

const TargetKind = enum {
    Default,
    Com,
    FunctionPointer,
};

const TypeRefKind = enum {
    Native,
    ApiRef,
    PointerTo,
    Array,
    LPArray,
    MissingClrType,
};
const type_ref_kinds = std.StaticStringMap(TypeRefKind).initComptime(.{
    .{ "Native", .Native },
    .{ "ApiRef", .ApiRef },
    .{ "PointerTo", .PointerTo },
    .{ "Array", .Array },
    .{ "LPArray", .LPArray },
    .{ "MissingClrType", .MissingClrType },
});

const Native = struct {
    Name: TypeRefNative,
};
const ApiRef = struct {
    Name: []const u8,
    TargetKind: TargetKind,
    Api: []const u8,
    Parents: []const []const u8,
};
const PointerTo = struct {
    Child: *const TypeRef,
};
const PointerToAttrs = struct {
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!PointerToAttrs {
        return parseAttrsArray(PointerToAttrs, allocator, source, options);
    }
};
const Array = struct {
    Shape: ?ArrayShape,
    Child: *const TypeRef,
};
const ArrayShape = struct {
    Size: u32,
};
const LPArray = struct {
    NullNullTerm: bool,
    CountConst: i32,
    CountParamIndex: i32,
    Child: *const TypeRef,
};
const MissingClrType = struct {
    Name: []const u8,
    Namespace: []const u8,
};

pub const TypeRef = union(TypeRefKind) {
    Native: Native,
    ApiRef: ApiRef,
    PointerTo: PointerTo,
    Array: Array,
    LPArray: LPArray,
    MissingClrType: MissingClrType,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!TypeRef {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        switch (try jsonParseUnionKind(TypeRefKind, "TypeRef", source, type_ref_kinds)) {
            .Native => return .{
                .Native = try parseUnionObject(Native, allocator, source, options),
            },
            .ApiRef => return .{
                .ApiRef = try parseUnionObject(ApiRef, allocator, source, options),
            },
            .PointerTo => return .{
                .PointerTo = try parseUnionObject(PointerTo, allocator, source, options),
            },
            .Array => return .{
                .Array = try parseUnionObject(Array, allocator, source, options),
            },
            .LPArray => return .{
                .LPArray = try parseUnionObject(LPArray, allocator, source, options),
            },
            .MissingClrType => return .{
                .MissingClrType = try parseUnionObject(MissingClrType, allocator, source, options),
            },
        }
    }
};

fn parseAttrsArray(
    comptime Attrs: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!Attrs {
    const structInfo = switch (@typeInfo(Attrs)) {
        .@"struct" => |i| i,
        else => @compileError("Unable to parse attribute array into non-struct type '" ++ @typeName(Attrs) ++ "'"),
    };

    if (.array_begin != try source.next()) return error.UnexpectedToken;
    var result: Attrs = .{};

    while (true) {
        switch (try source.next()) {
            .array_end => return result,
            .string => |s| {
                inline for (structInfo.fields) |field| {
                    if (std.mem.eql(u8, s, field.name)) {
                        if (field.type == bool) {
                            @field(result, field.name) = true;
                            break;
                        }
                        if (field.type == ?ObsoleteAttr) {
                            @field(result, field.name) = .{};
                            break;
                        }
                        std.log.err("unable to interpret array string attribute as {s}", .{@typeName(field.type)});
                        return error.UnexpectedToken;
                    }
                } else {
                    std.log.err(
                        "unknown attribute '{s}' for type {s}",
                        .{ s, @typeName(Attrs) },
                    );
                    return error.UnexpectedToken;
                }
            },
            .object_begin => {
                const kind = blk: {
                    const field_name = switch (try source.next()) {
                        .string => |s| s,
                        else => return error.UnexpectedToken,
                    };
                    if (!std.mem.eql(u8, field_name, "Kind"))
                        return error.UnexpectedToken;
                    break :blk switch (try source.next()) {
                        .string => |s| s,
                        else => return error.UnexpectedToken,
                    };
                };
                if (@hasField(Attrs, "MemorySize")) {
                    if (std.mem.eql(u8, kind, "MemorySize")) {
                        result.MemorySize = try parseUnionObject(
                            MemorySize,
                            allocator,
                            source,
                            options,
                        );
                        continue;
                    }
                }
                if (@hasField(Attrs, "FreeWith")) {
                    if (std.mem.eql(u8, kind, "FreeWith")) {
                        result.FreeWith = try parseUnionObject(
                            FreeWith,
                            allocator,
                            source,
                            options,
                        );
                        continue;
                    }
                }
                if (@hasField(Attrs, "Obsolete")) {
                    if (std.mem.eql(u8, kind, "Obsolete")) {
                        result.Obsolete = try parseUnionObject(
                            ObsoleteAttr,
                            allocator,
                            source,
                            options,
                        );
                        continue;
                    }
                }
                std.log.err(
                    "unknown object attribute object kind '{s}' for type {s}",
                    .{ kind, @typeName(Attrs) },
                );
                return error.UnknownField;
            },
            else => |token| {
                std.log.err(
                    "expected token string, object or array_close but got {s} for attr type {s}",
                    .{ @tagName(token), @typeName(Attrs) },
                );
                return error.UnexpectedToken;
            },
        }
    }
}

pub fn jsonParseUnionKind(
    comptime KindEnum: type,
    type_name: []const u8,
    source: anytype,
    map: std.StaticStringMap(KindEnum),
) std.json.ParseError(@TypeOf(source.*))!KindEnum {
    switch (try source.next()) {
        .string => |field_name| if (!std.mem.eql(u8, field_name, "Kind")) {
            std.log.err(
                "expected first field of {s} to be 'Kind' but got '{s}'",
                .{ type_name, field_name },
            );
            return error.UnexpectedToken;
        },
        else => return error.UnexpectedToken,
    }
    const kind_str = switch (try source.next()) {
        .string => |s| s,
        else => return error.UnexpectedToken,
    };
    return map.get(kind_str) orelse {
        std.log.err("unknown {s} Kind '{s}'", .{ type_name, kind_str });
        return error.UnexpectedToken;
    };
}

pub fn parseUnionObject(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !T {
    const structInfo = switch (@typeInfo(T)) {
        .@"struct" => |i| i,
        else => @compileError("Unable to parse into non-struct type '" ++ @typeName(T) ++ "'"),
    };

    var r: T = undefined;
    var fields_seen = [_]bool{false} ** structInfo.fields.len;

    while (true) {
        var name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const field_name = switch (name_token.?) {
            inline .string, .allocated_string => |slice| slice,
            .object_end => { // No more fields.
                break;
            },
            else => {
                return error.UnexpectedToken;
            },
        };

        inline for (structInfo.fields, 0..) |field, i| {
            if (field.is_comptime) @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
            if (std.mem.eql(u8, field.name, field_name)) {
                // Free the name token now in case we're using an allocator that optimizes freeing the last allocated object.
                // (Recursing into innerParse() might trigger more allocations.)
                freeAllocated(allocator, name_token.?);
                name_token = null;
                if (fields_seen[i]) {
                    switch (options.duplicate_field_behavior) {
                        .use_first => {
                            // Parse and ignore the redundant value.
                            // We don't want to skip the value, because we want type checking.
                            _ = try std.json.innerParse(field.type, allocator, source, options);
                            break;
                        },
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    }
                }
                @field(r, field.name) = try std.json.innerParse(field.type, allocator, source, options);
                fields_seen[i] = true;
                break;
            }
        } else {
            // Didn't match anything.
            std.log.err("unknown field '{s}' on type {s}", .{ field_name, @typeName(T) });
            freeAllocated(allocator, name_token.?);
            if (options.ignore_unknown_fields) {
                try source.skipValue();
            } else {
                return error.UnknownField;
            }
        }
    }
    inline for (structInfo.fields, 0..) |field, i| {
        if (!fields_seen[i] and !std.mem.eql(u8, field.name, "Comment")) {
            std.log.err("field '{s}' has not been set", .{field.name});
            return error.MissingField;
        }
    }
    return r;
}

fn freeAllocated(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}

fn expectFieldName(
    source: anytype,
    name: []const u8,
) !void {
    switch (try source.next()) {
        .string => |s| {
            if (!std.mem.eql(u8, s, name)) {
                std.log.err(
                    "expected field '{s}' but got '{s}'",
                    .{ name, s },
                );
                return error.UnexpectedToken;
            }
        },
        else => return error.UnexpectedToken,
    }
}

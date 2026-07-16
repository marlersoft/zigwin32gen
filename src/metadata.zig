pub const Api = struct {
    Constants: []const Constant,
    Types: []const Type,
    Functions: []const Function,
    UnicodeAliases: []const []const u8,
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

// A typed constant/enum value holds a constant or enum value. The
// `integer` case covers all integer widths (its exact zig type comes from the
// accompanying ValueType); `float` is rendered in scientific form.
pub const Value = union(enum) {
    null,
    string: []const u8,
    integer: i128,
    float: f64,
    property_key: PropertyKey,

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .integer => |av| switch (b) {
                .integer => |bv| av == bv,
                else => false,
            },
            else => @panic("Value.eql: only integers are compared (enum values)"),
        };
    }
};
pub const PropertyKey = struct {
    Fmtid: []const u8,
    Pid: u64,
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
    Value: Value,
    Attrs: ConstantAttrs,
};
pub const ConstantAttrs = struct {};

pub const EnumIntegerBase = enum { Byte, SByte, UInt16, UInt32, Int32, UInt64 };

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
        Value: Value,
    };

    pub const ComClassID = struct {
        Guid: []const u8,
    };
};

pub const FunctionPointer = struct {
    SetLastError: bool,
    ReturnType: TypeRef,
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
};

pub const ComMethod = struct {
    Name: []const u8,
    SetLastError: bool,
    ReturnType: TypeRef,
    ReturnAttrs: ParamAttrs,
    Architectures: Architectures,
    Platform: ?Platform,
    Attrs: FunctionAttrs,
    Params: []const Param,
};

pub const Function = struct {
    Name: []const u8,
    SetLastError: bool,
    DllImport: []const u8,
    ReturnType: TypeRef,
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
    Cdecl: bool = false,
};

pub const ObsoleteAttr = struct {
    Message: ?[]const u8 = null,
};

pub const StructOrUnionAttrs = struct {
    Obsolete: ?ObsoleteAttr = null,
};

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

pub const TypeRef = union(enum) {
    Native: Native,
    ApiRef: ApiRef,
    PointerTo: PointerTo,
    Array: Array,
    LPArray: LPArray,
    MissingClrType: MissingClrType,
};

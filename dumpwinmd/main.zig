//! dumpwinmd: decode a winmd file into the line-based text described in
//! `dumpwinmd-grammar.md`. Standalone and decode-only: depends solely on the
//! `winmd` package, emits *literal* winmd content (no patches, no corrections,
//! no metadata.zig model). The win32 layer (textparse) applies corrections and
//! rebuilds metadata.Api from this text.

const std = @import("std");
const winmd = @import("winmd");

const global = struct {
    var context: Context = .{};
};

var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const arena = arena_instance.allocator();

pub fn main() !void {
    const args = try std.process.argsAlloc(arena);
    if (args.len != 2) {
        std.log.err("usage: dumpwinmd <winmd-path>", .{});
        std.process.exit(0xff);
    }
    try dump(args[1]);
}

fn dump(winmd_path: []const u8) !void {
    const winmd_content = blk: {
        var file = try std.fs.cwd().openFile(winmd_path, .{});
        defer file.close();
        const size = try file.getEndPos();
        var reader = file.reader(&.{});
        break :blk try reader.interface.readAlloc(arena, @intCast(size));
    };

    var loader = init(winmd_content);

    // Namespaces (apis) are emitted sorted; within an api, members stay in winmd
    // declaration order (phase 1 — keeps generated bindings byte-identical).
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = loader.api_map.keyIterator();
    while (it.next()) |key| names.append(arena, key.*) catch |e| oom(e);
    std.mem.sort([]const u8, names.items, {}, asciiLessThanIgnoreCase);

    var buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    const w = &out.interface;
    for (names.items) |name| {
        emitApi(w, &loader, name) catch return out.err.?;
    }
    w.flush() catch return out.err.?;
}

fn asciiLessThanIgnoreCase(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(lhs, rhs);
}

// A native typedef / obsolete message, decoded but not yet interpreted.
const ObsoleteAttr = struct { Message: ?[]const u8 = null };

// Scans the winmd once; `emitApi` then walks a single api on demand.
pub const Loader = struct {
    md: Metadata,
    api_map: std.StringHashMapUnmanaged(ApiTypeDefs),
};

pub fn init(winmd_content: []const u8) Loader {
    const metadata_file_offset = blk: {
        var err: winmd.MetadataError = undefined;
        break :blk winmd.locateMetadata(&err, winmd_content) catch errExit("{f}", .{err});
    };

    const streams = blk: {
        var err: winmd.MetadataError = undefined;
        break :blk winmd.parseStreams(&err, winmd_content, metadata_file_offset) catch errExit("{f}", .{err});
    };

    const tables_stream = streams.tables orelse errExit("missing the tables stream '#~'", .{});
    // Allocated on the arena so md.tables stays valid after init returns.
    const tables = arena.create(winmd.Tables) catch |e| oom(e);
    tables.* = blk: {
        var err: winmd.MetadataError = undefined;
        break :blk winmd.parseTables(&err, winmd_content, metadata_file_offset + tables_stream.offset) catch errExit("{f}", .{err});
    };

    const md: Metadata = .{
        .tables = tables,
        .string_heap = if (streams.strings) |strings| castArray(u8, winmd_content, metadata_file_offset + strings.offset, strings.size) else null,
        .blob_heap = if (streams.blob) |blob| castArray(u8, winmd_content, metadata_file_offset + blob.offset, blob.size) else null,
        .type_map = TypeMap.init(arena, tables) catch |e| oom(e),
        .interface_map = winmd.Map(.InterfaceImpl).alloc(arena, tables) catch |e| oom(e),
        .constant_map = winmd.Map(.Constant).alloc(arena, tables) catch |e| oom(e),
        .layout_map = winmd.Map(.ClassLayout).init(arena, tables) catch |e| oom(e),
        // reverse for now to match origin C# generator
        .custom_attr_map = winmd.Map(.CustomAttr).alloc(arena, tables, .{ .reverse = true }) catch |e| oom(e),
        .nested_map = winmd.Map(.NestedClass).alloc(arena, tables) catch |e| oom(e),
        .impl_map_map = winmd.Map(.ImplMap).alloc(arena, tables) catch |e| oom(e),
    };

    // first scan all top-level types and sort them by namespace
    var api_map: std.StringHashMapUnmanaged(ApiTypeDefs) = .{};

    for (0..tables.row_counts.TypeDef) |type_def_index| {
        const type_def = tables.row(.TypeDef, type_def_index);

        const name = md.getString(type_def.name);
        const namespace = md.getString(type_def.namespace);
        if (type_def.attributes.visibility.isNested()) {
            std.debug.assert(std.mem.eql(u8, namespace, ""));
            continue;
        }

        if (std.mem.eql(u8, namespace, "")) {
            if (std.mem.eql(u8, name, "<Module>")) continue;
            @panic("unexpected");
        }

        const api_name = apiFromNamespace(namespace);
        const entry = api_map.getOrPut(arena, api_name) catch |e| oom(e);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        const api = entry.value_ptr;

        // The "Apis" type is a specially-named type reserved to contain all the constant
        // and function declarations for an api.
        if (std.mem.eql(u8, name, "Apis")) {
            enforce(
                api.apis_type_def_index == null,
                "multiple 'Apis' types in the same namespace",
                .{},
            );
            api.apis_type_def_index = @intCast(type_def_index);
        } else {
            api.type_defs.append(arena, @intCast(type_def_index)) catch |e| oom(e);
        }
    }

    return .{
        .md = md,
        .api_map = api_map,
    };
}

fn castArray(comptime Element: type, winmd_content: []const u8, offset: u64, len: u64) []align(1) const Element {
    const array_size: u64 = len * @sizeOf(Element);
    if (offset + array_size > winmd_content.len) errExit(
        "file truncated, required {}-bytes (array of {s}) at offset {}",
        .{ array_size, @typeName(Element), offset },
    );
    return @as([*]align(1) const Element, @ptrCast(winmd_content.ptr + offset))[0..len];
}

const shared_namespace_prefix = "Windows.Win32.";
fn apiFromNamespace(namespace: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, namespace, shared_namespace_prefix)) std.debug.panic(
        "Unexpected Namespace '{s}' (does not start with '{s}')",
        .{ namespace, shared_namespace_prefix },
    );
    return namespace[shared_namespace_prefix.len..];
}

fn enforce(cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (!cond) std.debug.panic(fmt, args);
}

const ApiTypeDefs = struct {
    // The special "Apis" type whose fields are constants and methods are functions
    apis_type_def_index: ?u32 = null,
    type_defs: std.ArrayListUnmanaged(u32) = .{},
};

const sigs = struct {
    const PSTR = [_]u8{@intFromEnum(winmd.ElementType.u1)};
    const PWSTR = [_]u8{@intFromEnum(winmd.ElementType.char)};
};

fn getChildSig(md: *const Metadata, sig: []const u8) []const u8 {
    if (sig.len == 0) @panic("sig truncated");
    return switch (winmd.ElementType.decode(sig[0]) orelse @panic("invalid sig")) {
        .ptr => sig[1..],
        .valuetype => {
            const token_bytes = sig[1..];
            if (token_bytes.len == 0) @panic("truncated");
            const token_len = winmd.decodeSigUnsignedLen(token_bytes[0]);
            if (token_bytes.len < token_len.int(usize)) @panic("truncated token");
            const token_encoded: winmd.TypeToken = @enumFromInt(winmd.decodeSigUnsigned(token_bytes[0..token_len.int(usize)]));
            const token = token_encoded.decode() catch @panic("invalid type token");
            switch (token.table) {
                .TypeDef => @panic("todo: a"),
                .TypeRef => {
                    const type_ref = md.tables.row(.TypeRef, token.index);
                    const name = md.getString(type_ref.name);
                    const namespace = md.getString(type_ref.namespace);
                    if (std.mem.eql(u8, namespace, "Windows.Win32.Foundation")) {
                        if (std.mem.eql(u8, name, "PWSTR")) return &sigs.PWSTR;
                        if (std.mem.eql(u8, name, "PSTR")) return &sigs.PSTR;
                    }
                    std.debug.panic("unable to get Child type for '{s}:{s}'", .{ namespace, name });
                },
                .TypeSpec => @panic("TypeSpec unsupported"),
                _ => @panic("invalid table"),
            }
        },
        else => |t| std.debug.panic("\"todo: implement scanSigToChild for {t}\"", .{t}),
    };
}

const BuildFnAttrs = struct {
    cdecl: bool,
    obsolete: ?ObsoleteAttr,
};

const EnumBase = enum {
    SByte,
    Byte,
    UInt16,
    Int32,
    UInt32,
    UInt64,
    pub fn Type(self: EnumBase) type {
        return switch (self) {
            .SByte => i8,
            .Byte => u8,
            .UInt16 => u16,
            .Int32 => i32,
            .UInt32 => u32,
            .UInt64 => u64,
        };
    }
};


const TypeAttrs = struct {
    flags: winmd.TypeAttributes,
    guid: ?Guid = null,
    is_native_typedef: bool = false,
    is_flags: bool = false,
    raii_free: ?[]const u8 = null,
    also_usable_for: ?[]const u8 = null,
    supported_os_platform: ?[]const u8 = null,
    arches: ?ArchBits = null,
    scoped_enum: bool = false,
    invalid_handle_value: ?u64 = null,
    is_agile: bool = false,
    Obsolete: ?ObsoleteAttr = null,
    calling_convention: ?CallingConvention = null,
};

const ConstantValue = union(enum) {
    guid: Guid,
    property_key: PropertyKey,
    default: void,
};
fn analyzeConstValue(
    md: *const Metadata,
    custom_attrs: *winmd.LinkIterator,
    field: winmd.Row(.Field),
    name: []const u8,
) !ConstantValue {
    const has_value_attributes: winmd.FieldAttributes = .{
        .access = .public,
        .static = true,
        .literal = true,
        .has_default = true,
    };
    const no_value_attributes: winmd.FieldAttributes = .{
        .access = .public,
        .static = true,
    };
    const has_default_value = if (field.attributes == has_value_attributes)
        true
    else if (field.attributes == no_value_attributes)
        false
    else
        errExit("unexpected constant field definition attributes: {}", .{field.attributes});

    var maybe_guid: ?Guid = null;
    var maybe_property_key: ?PropertyKey = null;

    while (custom_attrs.next()) |custom_attr_index| {
        const custom_attr_row = md.tables.row(.CustomAttr, custom_attr_index);
        const custom_attr = CustomAttr.decode(md, custom_attr_row);
        switch (custom_attr) {
            .Guid => |guid| {
                if (maybe_guid != null) @panic("multiple guids");
                maybe_guid = guid;
            },
            .PropertyKey => |key| {
                if (maybe_property_key != null) @panic("multiple property keys");
                maybe_property_key = key;
            },
            else => |c| std.debug.panic("unexpected custom attribute '{s}'", .{@tagName(c)}),
        }
    }

    if (maybe_guid) |guid| {
        if (has_default_value) std.debug.panic("constant '{s}' has default value and guid", .{name});
        if (maybe_property_key != null) @panic("has guid and property key");
        return .{ .guid = guid };
    } else if (maybe_property_key) |key| {
        if (has_default_value) @panic("has default value and property  key");
        return .{ .property_key = key };
    }
    if (!has_default_value) @panic("has no default value, guid nor property key");
    return .default;
}

fn withinFixedPointRange(comptime T: type, float: T) bool {
    if (float == 0) return true;
    return @abs(float) >= 1e-4 and @abs(float) < 1.7e7;
}

fn writeEnumValue(writer: *std.Io.Writer, base: EnumBase, bytes: []const u8) error{WriteFailed}!void {
    switch (base) {
        inline else => |t| try writeConstValue(writer, t.Type(), bytes),
    }
}
fn writeConstValue(writer: *std.Io.Writer, comptime T: type, bytes: []const u8) error{WriteFailed}!void {
    std.debug.assert(bytes.len == @sizeOf(T));
    switch (@typeInfo(T)) {
        .int => try writer.print("{d}", .{std.mem.readInt(T, bytes[0..@sizeOf(T)], .little)}),
        .float => {
            const Int = @Type(.{ .int = .{ .bits = 8 * @sizeOf(T), .signedness = .unsigned } });
            const value: T = @bitCast(std.mem.readInt(Int, bytes[0..@sizeOf(T)], .little));
            if (withinFixedPointRange(T, value)) {
                try writer.print("{d}", .{value});
            } else {
                var buf: [100]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{e}", .{value}) catch unreachable;
                const e_index = std.mem.indexOfScalar(u8, str, 'e') orelse unreachable;
                const mantissa = str[0..e_index];
                const exp = str[e_index + 1 ..];
                const sign: []const u8 = if (exp[0] == '-') "" else "+";
                try writer.print("{s}E{s}{s:0>2}", .{ mantissa, sign, exp });
            }
        },
        else => @compileError("todo: support type " ++ @typeName(T)),
    }
}

const Guid = std.os.windows.GUID;
fn fmtGuid(guid: ?Guid) FmtGuid {
    return .{ .guid = guid };
}
const FmtGuid = struct {
    guid: ?Guid,
    pub fn format(self: FmtGuid, writer: *std.Io.Writer) error{WriteFailed}!void {
        const guid = self.guid orelse return try writer.writeAll("null");
        try writer.print(
            "\"{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x}\"",
            .{
                guid.Data1,
                guid.Data2,
                guid.Data3,
                guid.Data4[0],
                guid.Data4[1],
                guid.Data4[2..],
            },
        );
    }
};
const PropertyKey = struct {
    guid: Guid,
    pid: u32,
};

const NativeArray = struct {
    CountConst: i32,
    CountParamIndex: i16,
};

const ArchBits = packed struct(u32) {
    X86: bool,
    X64: bool,
    Arm64: bool,
    reserved: u29,
};

const CallingConvention = enum {
    Winapi,
    Cdecl,
};

const CustomAttr = union(enum) {
    Guid: Guid,
    PropertyKey: PropertyKey,
    NativeTypedef,
    Flags,
    RaiiFree: []const u8,
    UnmanagedFunctionPointer: CallingConvention,
    AlsoUsableFor: []const u8,
    SupportedOSPlatform: []const u8,
    SupportedArchitecture: ArchBits,
    ScopedEnum,
    DoNotRelease,
    Reserved,
    InvalidHandleValue: u64,
    Agile,
    Const,
    NativeArray: NativeArray,
    Obsolete: ObsoleteAttr,
    NotNullTerminated,
    NullNullTerminated,
    ComOutPtr,
    RetVal,
    FreeWith: []const u8,
    MemorySize: i16,
    DoesNotReturn,
    pub fn decode(
        md: *const Metadata,
        custom_attr: winmd.Row(.CustomAttr),
    ) CustomAttr {
        const value_blob = md.getBlob(custom_attr.value);
        if (!std.mem.startsWith(u8, value_blob, &[_]u8{ 1, 0 })) @panic("CustomAttr value unexpected prolog");
        const value = value_blob[2..];
        switch (custom_attr.method.table) {
            .MethodDef => @panic("todo"),
            .MemberRef => {
                const member_ref = md.tables.row(.MemberRef, custom_attr.method.index.asIndex().?);
                const signature = md.getBlob(member_ref.signature);
                if (signature[0] != 0x20) @panic("unexpected MemberRef sig");
                switch (member_ref.parent.table) {
                    .TypeRef => {
                        const type_ref = md.tables.row(.TypeRef, member_ref.parent.index.asIndex().?);
                        return decodeCustomAttr(.{
                            .namespace = md.getString(type_ref.namespace),
                            .name = md.getString(type_ref.name),
                        }, value);
                    },
                    else => @panic("todo"),
                    _ => @panic("invalid MemberRef parent table"),
                }
            },
            _ => @panic("invalid custom attr method"),
        }
    }
};

fn decodeCustomAttr(
    name: QualifiedName,
    value: []const u8,
) CustomAttr {
    if (name.eql("System", "FlagsAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .Flags;
    }
    if (name.eql("System", "ObsoleteAttribute")) {
        if (std.mem.eql(u8, value, &[_]u8{ 0, 0 })) {
            return .{ .Obsolete = .{ .Message = null } };
        }
        // 1 fixed arg (string), 0 named args
        const string = decodeString(value);
        std.debug.assert(std.mem.eql(u8, value[string.end..], &[_]u8{ 0, 0 }));
        return .{ .Obsolete = .{ .Message = string.bytes } };
    }

    if (name.eql("System.Runtime.InteropServices", "UnmanagedFunctionPointerAttribute")) {
        // NOTE: 1 fixed arg, 0 named args
        if (std.mem.eql(u8, value, &[_]u8{ 1, 0, 0, 0, 0, 0 })) return .{ .UnmanagedFunctionPointer = .Winapi };
        if (std.mem.eql(u8, value, &[_]u8{ 2, 0, 0, 0, 0, 0 })) return .{ .UnmanagedFunctionPointer = .Cdecl };
        std.debug.panic("unexpected data 0x{x}", .{value});
    }

    if (name.eql("System.Diagnostics.CodeAnalysis", "DoesNotReturnAttribute")) {
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .DoesNotReturn;
    }

    if (name.eql("Windows.Win32.Interop", "ConstAttribute")) {
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .Const;
    }

    if (name.eql("Windows.Win32.Interop", "NotNullTerminatedAttribute")) {
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .NotNullTerminated;
    }
    if (name.eql("Windows.Win32.Interop", "NullNullTerminatedAttribute")) {
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .NullNullTerminated;
    }

    if (name.eql("Windows.Win32.Interop", "ComOutPtrAttribute")) {
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .ComOutPtr;
    }

    if (name.eql("Windows.Win32.Interop", "RetValAttribute")) {
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .RetVal;
    }

    if (name.eql("Windows.Win32.Interop", "FreeWithAttribute")) {
        // 1 fixed arg (string), 0 named args
        const string = decodeString(value);
        return .{ .FreeWith = string.bytes };
    }

    if (name.eql("Windows.Win32.Interop", "MemorySizeAttribute")) {
        // 0 fixed args, 1 named arg
        var it = NamedArgIterator.init(value);
        const arg = it.next() orelse @panic("expected named arg");
        if (!std.mem.eql(u8, arg.name, "BytesParamIndex")) {
            @panic("expected BytesParamIndex named arg");
        }
        if (arg.elem_type != @intFromEnum(winmd.ElementType.i2)) {
            @panic("Expected BytesParamIndex to be of type i2");
        }
        const bytes_param_index = it.readI16(arg.value_offset);
        return .{ .MemorySize = bytes_param_index };
    }

    if (name.eql("Windows.Win32.Interop", "GuidAttribute")) {
        std.debug.assert(value.len == 18);
        std.debug.assert(std.mem.eql(u8, value[16..18], &[_]u8{ 0, 0 }));
        return .{ .Guid = .{
            .Data1 = std.mem.readInt(u32, value[0..4], .little),
            .Data2 = std.mem.readInt(u16, value[4..6], .little),
            .Data3 = std.mem.readInt(u16, value[6..8], .little),
            .Data4 = value[8..16].*,
        } };
    }
    if (name.eql("Windows.Win32.Interop", "PropertyKeyAttribute")) {
        std.debug.assert(value.len == 22);
        std.debug.assert(std.mem.eql(u8, value[20..22], &[_]u8{ 0, 0 }));
        return .{ .PropertyKey = .{
            .guid = .{
                .Data1 = std.mem.readInt(u32, value[0..4], .little),
                .Data2 = std.mem.readInt(u16, value[4..6], .little),
                .Data3 = std.mem.readInt(u16, value[6..8], .little),
                .Data4 = value[8..16].*,
            },
            .pid = std.mem.readInt(u32, value[16..20], .little),
        } };
    }

    if (name.eql("Windows.Win32.Interop", "NativeArrayInfoAttribute")) {
        // 0 fixed args, 2 named args
        var it = NamedArgIterator.init(value);
        var count_const: ?i32 = null;
        var count_param_index: ?i16 = null;

        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg.name, "CountConst")) {
                if (arg.elem_type != @intFromEnum(winmd.ElementType.i4)) {
                    @panic("Expected CountConst to be of type i4");
                }
                count_const = it.readI32(arg.value_offset);
            } else if (std.mem.eql(u8, arg.name, "CountParamIndex")) {
                if (arg.elem_type != @intFromEnum(winmd.ElementType.i2)) {
                    @panic("Expected CountParamIndex to be of type i2");
                }
                count_param_index = it.readI16(arg.value_offset);
            } else {
                @panic("Unexpected named argument for NativeArrayInfoAttribute");
            }
        }

        return .{ .NativeArray = .{
            .CountConst = count_const orelse -1,
            .CountParamIndex = count_param_index orelse -1,
        } };
    }

    if (name.eql("Windows.Win32.Interop", "RAIIFreeAttribute")) {
        // 1 fixed arg (string), 0 named args
        const string = decodeString(value);
        std.debug.assert(std.mem.eql(u8, value[string.end..], &[_]u8{ 0, 0 }));
        return .{ .RaiiFree = string.bytes };
    }

    if (name.eql("Windows.Win32.Interop", "NativeTypedefAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .NativeTypedef;
    }

    if (name.eql("Windows.Win32.Interop", "AlsoUsableForAttribute")) {
        // 1 fixed arg (string), 0 named args
        const string = decodeString(value);
        std.debug.assert(std.mem.eql(u8, value[string.end..], &[_]u8{ 0, 0 }));
        return .{ .AlsoUsableFor = string.bytes };
    }

    if (name.eql("Windows.Win32.Interop", "SupportedOSPlatformAttribute")) {
        // 1 fixed arg (string), 0 named args
        const string = decodeString(value);
        std.debug.assert(std.mem.eql(u8, value[string.end..], &[_]u8{ 0, 0 }));
        return .{ .SupportedOSPlatform = string.bytes };
    }

    if (name.eql("Windows.Win32.Interop", "SupportedArchitectureAttribute")) {
        // 1 fixed arg (enum), 0 named args
        std.debug.assert(value.len == 6);
        std.debug.assert(std.mem.eql(u8, value[4..], &[_]u8{ 0, 0 }));
        const int = std.mem.readInt(u32, value[0..4], .little);
        const arches: ArchBits = @bitCast(int);
        std.debug.assert(arches.reserved == 0);
        return .{ .SupportedArchitecture = arches };
    }

    if (name.eql("Windows.Win32.Interop", "ScopedEnumAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .ScopedEnum;
    }

    if (name.eql("Windows.Win32.Interop", "DoNotReleaseAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .DoNotRelease;
    }

    if (name.eql("Windows.Win32.Interop", "ReservedAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .Reserved;
    }

    if (name.eql("Windows.Win32.Interop", "InvalidHandleValueAttribute")) {
        // 1 fixed arg (u64), 0 named args
        std.debug.assert(value.len == 10);
        std.debug.assert(std.mem.eql(u8, value[8..], &[_]u8{ 0, 0 }));
        return .{ .InvalidHandleValue = std.mem.readInt(u64, value[0..8], .little) };
    }

    if (name.eql("Windows.Win32.Interop", "AgileAttribute")) {
        // NOTE: 0 fixed args, 0 named args
        std.debug.assert(std.mem.eql(u8, value, &[_]u8{ 0, 0 }));
        return .Agile;
    }

    std.debug.panic(
        "TODO: decode CustomAttr Namespace='{s}' Name='{s}' Value({} bytes)={x}",
        .{
            name.namespace,
            name.name,
            value.len,
            value,
        },
    );
}

fn decodeString(value: []const u8) struct { bytes: []const u8, end: usize } {
    std.debug.assert(value.len >= 1);
    const unsigned_len: usize = @intFromEnum(winmd.decodeSigUnsignedLen(value[0]));
    const string_len = winmd.decodeSigUnsigned(value[0..unsigned_len]);
    const remaining = value[unsigned_len..];
    std.debug.assert(remaining.len >= string_len);
    return .{ .bytes = remaining[0..string_len], .end = unsigned_len + string_len };
}

const QualifiedName = struct {
    namespace: []const u8,
    name: []const u8,
    pub fn eql(self: QualifiedName, namespace: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, self.namespace, namespace) and
            std.mem.eql(u8, self.name, name);
    }
};

const TypeDefOrRef = struct {
    table: enum { TypeDef, TypeRef },
    index: u32,
};
const WinmdTargetKind = enum {
    Default,
    FunctionPointer,
    Com,

    pub fn initTypeDef(md: *const Metadata, type_def_index: u32) WinmdTargetKind {
        const type_def = md.tables.row(.TypeDef, type_def_index);

        const base_type_index = type_def.extends.value() orelse return .Com;
        switch (base_type_index.table) {
            .TypeRef => {},
            else => @panic("unexpected base type table"),
        }
        const base_type_ref = md.tables.row(.TypeRef, base_type_index.index);
        const base_type_qn: QualifiedName = .{
            .namespace = md.getString(base_type_ref.namespace),
            .name = md.getString(base_type_ref.name),
        };
        if (base_type_qn.eql("System", "MulticastDelegate")) return .FunctionPointer;
        return .Default;
    }
};

const Parents = struct {
    count: usize,
    buffer: [max][]const u8,

    const max = 3;
    pub const none: Parents = .{ .count = 0, .buffer = undefined };
    pub fn slice(parents: *const Parents) []const []const u8 {
        return parents.buffer[0..parents.count];
    }
    pub fn append(parents: *Parents, name: []const u8) void {
        if (parents.count == max) @panic("increase Parents.max");
        parents.buffer[parents.count] = name;
        parents.count += 1;
    }
};

const TypeRefTarget = union(enum) {
    guid,
    // An external (AssemblyRef-scoped) type reference other than System.Guid.
    // dumpwinmd stays literal here: it does NOT classify these as "missing" — the
    // win32 layer maps the known ones (isKnownMissingClrType) to MissingClrType.
    extref: struct {
        namespace: []const u8,
        name: []const u8,
    },
    api: struct {
        kind: WinmdTargetKind,
        parents: Parents,
    },
    pub fn init(md: *const Metadata, type_ref_index: u32) TypeRefTarget {
        const type_ref = md.tables.row(.TypeRef, type_ref_index);
        const name = md.getString(type_ref.name);
        const namespace = md.getString(type_ref.namespace);
        switch (type_ref.resolution_scope.table) {
            .AssemblyRef => {
                if (std.mem.eql(u8, namespace, "System")) {
                    if (std.mem.eql(u8, name, "Guid")) return .guid;
                }
                return .{ .extref = .{ .namespace = namespace, .name = name } };
            },
            .ModuleRef => {},
            .Module => {
                {
                    const module_index = type_ref.resolution_scope.index.asIndex().?;
                    const module = md.tables.row(.Module, module_index);
                    const module_name = md.getString(module.name);
                    std.debug.assert(std.mem.eql(u8, module_name, "Windows.Win32.winmd"));
                }
                const qn: TypeName = .{ .namespace = type_ref.namespace, .name = type_ref.name };
                var maybe_kind: ?WinmdTargetKind = null;
                var it = md.type_map.getIterator(qn);
                while (it.next()) |type_def_index| {
                    const kind: WinmdTargetKind = .initTypeDef(md, type_def_index);
                    if (maybe_kind) |old_kind| {
                        std.debug.assert(old_kind == kind);
                    }
                    maybe_kind = kind;
                }
                return .{ .api = .{
                    .kind = maybe_kind orelse std.debug.panic(
                        "TypeRef '{s}:{s}' missing",
                        .{ md.getString(qn.namespace), md.getString(qn.name) },
                    ),
                    .parents = .none,
                } };
            },
            .TypeRef => {
                std.debug.assert(namespace.len == 0);
                const parent_type_ref_index = type_ref.resolution_scope.index.asIndex().?;
                std.debug.assert(parent_type_ref_index != type_ref_index);
                return initNested(md, parent_type_ref_index, name);
            },
        }
        std.debug.panic(
            "unsupported TypeRef '{s}:{s}' (scope {s})",
            .{ namespace, name, @tagName(type_ref.resolution_scope.table) },
        );
    }
    pub fn initNested(
        md: *const Metadata,
        type_ref_index: u32,
        nested_name: []const u8,
    ) TypeRefTarget {
        const type_ref = md.tables.row(.TypeRef, type_ref_index);
        const name = md.getString(type_ref.name);
        const namespace = md.getString(type_ref.namespace);
        switch (type_ref.resolution_scope.table) {
            .AssemblyRef => @panic("unexpected"),
            .ModuleRef => @panic("unexpected"),
            .Module => {
                const qn: TypeName = .{ .namespace = type_ref.namespace, .name = type_ref.name };
                var maybe_kind: ?WinmdTargetKind = null;
                var it = md.type_map.getIterator(qn);
                while (it.next()) |type_def_index| {
                    var iterator = md.nested_map.getIterator(type_def_index);
                    while (iterator.next()) |nested_class_index| {
                        const entry = md.tables.row(.NestedClass, nested_class_index);
                        const nested_type_def_index = entry.nested.asIndex().?;
                        const nested_type_def = md.tables.row(.TypeDef, nested_type_def_index);
                        if (std.mem.eql(u8, md.getString(nested_type_def.name), nested_name)) {
                            const kind: WinmdTargetKind = .initTypeDef(md, nested_type_def_index);
                            if (maybe_kind) |old_kind| {
                                std.debug.assert(old_kind == kind);
                            }
                            maybe_kind = kind;
                        }
                    }
                }
                return .{ .api = .{
                    .kind = maybe_kind orelse std.debug.panic(
                        "nested type '{s}' is missing from module TypeRef '{s}:{s}'",
                        .{ nested_name, namespace, name },
                    ),
                    .parents = .none,
                } };
            },
            .TypeRef => {
                std.debug.assert(namespace.len == 0);
                const parent_type_ref_index = type_ref.resolution_scope.index.asIndex().?;
                std.debug.assert(parent_type_ref_index != type_ref_index);
                var result = initNested(md, parent_type_ref_index, name);
                switch (result) {
                    .guid, .extref => @panic("invalid"),
                    .api => |*api| {
                        api.parents.append(name);
                        return result;
                    },
                }
            },
        }
    }
};

fn countTypeSigBytes(sig: []const u8) !usize {
    if (sig.len == 0) return error.SigTruncated;

    const elem_type = winmd.ElementType.decode(sig[0]) orelse return error.InvalidSig;
    return switch (elem_type) {
        .void, .boolean, .char, .i1, .u1, .i2, .u2, .i4, .u4, .i8, .u8, .r4, .r8, .string, .intptr, .uintptr => 1,
        .ptr, .byref, .szarray => 1 + try countTypeSigBytes(sig[1..]),
        // Valuetype/Class: 1 byte + compressed token
        .valuetype, .class => {
            if (sig.len < 2) return error.SigTruncated;
            const token_len = winmd.decodeSigUnsignedLen(sig[1]);
            return 1 + @intFromEnum(token_len);
        },
        // Array: 1 byte + element type + array shape
        .array => {
            const elem_len = try countTypeSigBytes(sig[1..]);
            var offset: usize = 1 + elem_len;
            if (offset + 2 > sig.len) return error.SigTruncated;

            // Skip: Rank (1 byte), NumSizes (1 byte), Sizes (compressed ints), NumLoBounds (1 byte), LoBounds (compressed ints)
            offset += 1; // Rank
            const num_sizes = sig[offset];
            offset += 1;

            // Skip sizes
            for (0..num_sizes) |_| {
                if (offset >= sig.len) return error.SigTruncated;
                const size_len = winmd.decodeSigUnsignedLen(sig[offset]);
                offset += @intFromEnum(size_len);
            }

            // Skip NumLoBounds and LoBounds
            if (offset >= sig.len) return error.SigTruncated;
            const num_lo_bounds = sig[offset];
            offset += 1;

            for (0..num_lo_bounds) |_| {
                if (offset >= sig.len) return error.SigTruncated;
                const lo_bound_len = winmd.decodeSigUnsignedLen(sig[offset]);
                offset += @intFromEnum(lo_bound_len);
            }

            return offset;
        },

        else => @panic("countTypeSigBytes: unsupported type"),
    };
}

const Metadata = struct {
    tables: *const winmd.Tables,
    string_heap: ?[]const u8,
    blob_heap: ?[]const u8,

    type_map: TypeMap,
    interface_map: winmd.Map(.InterfaceImpl),
    constant_map: winmd.Map(.Constant),
    layout_map: winmd.Map(.ClassLayout),
    custom_attr_map: winmd.Map(.CustomAttr),
    nested_map: winmd.Map(.NestedClass),
    impl_map_map: winmd.Map(.ImplMap),

    fn getString(md: *const Metadata, index: winmd.StringHeapIndex) [:0]const u8 {
        return winmd.getString(md.string_heap, index) orelse std.debug.panic(
            "invalid string heap index {}",
            .{index},
        );
    }
    fn getBlob(md: *const Metadata, index: winmd.BlobHeapIndex) []const u8 {
        return winmd.getBlob(md.blob_heap, index) orelse std.debug.panic(
            "invalid blob heap index {}",
            .{index},
        );
    }
};

const TypeName = struct {
    namespace: winmd.StringHeapIndex,
    name: winmd.StringHeapIndex,
};

pub const TypeMap = struct {
    links: []const winmd.OptionalIndex(u32),
    map: std.AutoHashMapUnmanaged(TypeName, u32),
    pub fn init(
        allocator: std.mem.Allocator,
        tables: *const winmd.Tables,
    ) error{OutOfMemory}!TypeMap {
        const links = try allocator.alloc(winmd.OptionalIndex(u32), tables.row_counts.TypeDef);
        errdefer allocator.free(links);

        var map: std.AutoHashMapUnmanaged(TypeName, u32) = .{};
        errdefer map.deinit(allocator);

        for (0..tables.row_counts.TypeDef) |i| {
            const type_def = tables.row(.TypeDef, i);
            if (type_def.attributes.visibility.isNested()) {
                links[i] = .none;
            } else {
                const entry = map.getOrPut(allocator, .{
                    .namespace = type_def.namespace,
                    .name = type_def.name,
                }) catch |e| oom(e);
                links[i] = if (entry.found_existing) .fromIndex(entry.value_ptr.*) else .none;
                entry.value_ptr.* = @intCast(i);
            }
        }
        return .{ .links = links, .map = map };
    }
    pub fn getIterator(self: *const TypeMap, n: TypeName) winmd.LinkIterator {
        return .{
            .links = self.links,
            .index = if (self.map.get(n)) |i| .fromIndex(i) else .none,
        };
    }
};

const NamedArgIterator = struct {
    value: []const u8,
    offset: usize,

    pub fn init(value: []const u8) NamedArgIterator {
        // Value has prolog already stripped
        // Format: u16 NumNamed, then named args
        // We start at offset 2 to skip the NumNamed count
        return .{
            .value = value,
            .offset = if (value.len >= 2) 2 else 0,
        };
    }

    // Returns a struct with decoded named argument info
    pub fn next(self: *NamedArgIterator) ?struct {
        is_field: bool,
        elem_type: u8,
        name: []const u8,
        value_offset: usize,
    } {
        if (self.offset >= self.value.len) return null;

        // Each named arg starts with a byte indicating field (0x53) or property (0x54)
        const field_or_prop = self.value[self.offset];
        self.offset += 1;

        if (field_or_prop != 0x53 and field_or_prop != 0x54) {
            @panic("Invalid field/property marker in named argument");
        }

        // Next byte is the element type
        if (self.offset >= self.value.len) @panic("Truncated named argument");
        const elem_type = self.value[self.offset];
        self.offset += 1;

        // Decode the name (compressed string)
        if (self.offset >= self.value.len) @panic("Truncated named argument name");
        const string_result = decodeString(self.value[self.offset..]);
        const name = string_result.bytes;
        self.offset += string_result.end;

        // Store current offset for value access
        const value_offset = self.offset;

        // Advance offset based on element type
        switch (winmd.ElementType.decode(elem_type) orelse @panic("Invalid element type")) {
            .boolean => self.offset += 1,
            .char => self.offset += 2,
            .i1, .u1 => self.offset += 1,
            .i2, .u2 => self.offset += 2,
            .i4, .u4 => self.offset += 4,
            .i8, .u8 => self.offset += 8,
            .r4 => self.offset += 4,
            .r8 => self.offset += 8,
            .string => {
                if (self.offset >= self.value.len) @panic("Truncated string value");
                if (self.value[self.offset] == 0xFF) {
                    // null string
                    self.offset += 1;
                } else {
                    const str_result = decodeString(self.value[self.offset..]);
                    self.offset += str_result.end;
                }
            },
            inline else => |t| @panic(std.fmt.comptimePrint("Unsupported element type for named argument: {t}", .{t})),
        }

        return .{
            .is_field = field_or_prop == 0x53,
            .elem_type = elem_type,
            .name = name,
            .value_offset = value_offset,
        };
    }

    // Helper methods to read values of specific types
    pub fn readI16(self: *const NamedArgIterator, offset: usize) i16 {
        return std.mem.readInt(i16, self.value[offset..][0..2], .little);
    }

    pub fn readI32(self: *const NamedArgIterator, offset: usize) i32 {
        return std.mem.readInt(i32, self.value[offset..][0..4], .little);
    }
};

const Context = struct {
    api: ?[]const u8 = null,
    type: ?[]const u8 = null,
    func: ?[]const u8 = null,
    param: ?[]const u8 = null,

    pub const Kind = enum { api, type, func, param };

    fn equals(context: *Context, comptime kind: Kind, value: ?[]const u8) bool {
        return std.meta.eql(@field(context, @tagName(kind)), value);
    }

    pub fn set(context: *Context, comptime kind: Kind, value: []const u8) void {
        std.debug.assert(context.equals(kind, null));
        @field(context, @tagName(kind)) = value;
        std.debug.assert(context.equals(kind, value));
    }
    pub fn unset(context: *Context, comptime kind: Kind, value: []const u8) void {
        std.debug.assert(context.equals(kind, value));
        @field(context, @tagName(kind)) = null;
        std.debug.assert(context.equals(kind, null));
    }

    pub fn logErrorPrefix(context: *Context) void {
        if (context.api) |api| {
            std.log.err("  current api '{s}'", .{api});
        }
        if (context.type) |t| {
            std.log.err("  current type '{s}'", .{t});
        }
        if (context.func) |f| {
            std.log.err("  current function '{s}'", .{f});
        }
    }
};

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    global.context.logErrorPrefix();
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

// ============================================================================
// Emit the line-based text (see dumpwinmd-grammar.md) directly from the winmd
// tables. Literal: no patches, no corrections, no metadata.zig model. The win32
// layer (textparse) applies corrections and rebuilds metadata.Api from this.
// ============================================================================

fn writeConstDefaultValue(writer: *std.Io.Writer, constant_type: u8, encoded_value: []const u8) error{WriteFailed}!void {
    switch (winmd.ElementType.decode(constant_type) orelse @panic("invalid type byte")) {
        .u1 => try writeConstValue(writer, u8, encoded_value),
        .u2 => try writeConstValue(writer, u16, encoded_value),
        .i4 => try writeConstValue(writer, i32, encoded_value),
        .u4 => try writeConstValue(writer, u32, encoded_value),
        .i8 => try writeConstValue(writer, i64, encoded_value),
        .u8 => try writeConstValue(writer, u64, encoded_value),
        .r4 => try writeConstValue(writer, f32, encoded_value),
        .r8 => try writeConstValue(writer, f64, encoded_value),
        .string => {
            if (encoded_value.len == 0) {
                try writer.writeAll("null");
            } else {
                try writer.writeAll("\"");
                const ptr: [*]align(1) const u16 = @ptrCast(@alignCast(encoded_value.ptr));
                const slice_u16 = ptr[0..@divTrunc(encoded_value.len, 2)];
                for (slice_u16) |c| {
                    const one_char = [_]u16{c};
                    switch (c) {
                        0x00, 0x0f, 0x10, 0x1e => try writer.print("\\u{x:0>4}", .{c}),
                        '\n' => try writer.writeAll("\\n"),
                        '\\' => try writer.writeAll("\\\\"),
                        else => try writer.print("{f}", .{std.unicode.fmtUtf16Le(&one_char)}),
                    }
                }
                try writer.writeAll("\"");
            }
        },
        else => |n| std.debug.panic("unhandled element type {s}", .{@tagName(n)}),
    }
}

fn writeToArena(comptime Ctx: type, ctx: Ctx) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    ctx.write(&aw.writer) catch @panic("out of memory");
    return aw.written();
}

fn fmtGuidText(guid: Guid) []const u8 {
    return writeToArena(struct {
        g: Guid,
        fn write(self: @This(), w: *std.Io.Writer) error{WriteFailed}!void {
            try fmtGuid(self.g).format(w);
        }
    }, .{ .g = guid });
}
fn guidStr(guid: Guid) []const u8 {
    const quoted = fmtGuidText(guid);
    return quoted[1 .. quoted.len - 1];
}

fn constValueTypeName(constant_type: u8) []const u8 {
    return switch (winmd.ElementType.decode(constant_type) orelse @panic("invalid type byte")) {
        .u1 => "Byte",
        .u2 => "UInt16",
        .i4 => "Int32",
        .u4 => "UInt32",
        .i8 => "Int64",
        .u8 => "UInt64",
        .r4 => "Single",
        .r8 => "Double",
        .string => "String",
        else => |n| std.debug.panic("unhandled value element type {s}", .{@tagName(n)}),
    };
}

fn indent(w: *std.Io.Writer, depth: usize) error{WriteFailed}!void {
    try w.splatByteAll('\t', depth + 1);
}

fn writeQuoted(w: *std.Io.Writer, s: []const u8) error{WriteFailed}!void {
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

fn emitObsolete(w: *std.Io.Writer, o: ObsoleteAttr) error{WriteFailed}!void {
    if (o.Message) |m| {
        try w.writeAll(" obsolete=");
        try writeQuoted(w, m);
    } else try w.writeAll(" obsolete");
}

fn emitArchPlat(w: *std.Io.Writer, arches: ?ArchBits, platform: ?[]const u8) error{WriteFailed}!void {
    if (arches) |f| {
        if (f.X86 or f.X64 or f.Arm64) {
            try w.writeAll(" arch=");
            var first = true;
            inline for (.{ "X86", "X64", "Arm64" }) |name| {
                if (@field(f, name)) {
                    if (!first) try w.writeAll(",");
                    try w.writeAll(name);
                    first = false;
                }
            }
        }
    }
    if (platform) |p| try w.print(" platform={s}", .{p});
}

// Writes one typeref token (see the grammar's typeref mini-grammar) decoded from
// `sig`, returning the number of signature bytes consumed.
fn emitTypeRefSig(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, sig: []const u8) error{WriteFailed}!usize {
    if (sig.len == 0) @panic("sig truncated");
    switch (winmd.ElementType.decode(sig[0]) orelse @panic("invalid sig")) {
        .void => {
            try w.writeAll("Void");
            return 1;
        },
        .boolean => {
            try w.writeAll("Boolean");
            return 1;
        },
        .char => {
            try w.writeAll("Char");
            return 1;
        },
        .i1 => {
            try w.writeAll("SByte");
            return 1;
        },
        .u1 => {
            try w.writeAll("Byte");
            return 1;
        },
        .i2 => {
            try w.writeAll("Int16");
            return 1;
        },
        .u2 => {
            try w.writeAll("UInt16");
            return 1;
        },
        .i4 => {
            try w.writeAll("Int32");
            return 1;
        },
        .u4 => {
            try w.writeAll("UInt32");
            return 1;
        },
        .i8 => {
            try w.writeAll("Int64");
            return 1;
        },
        .u8 => {
            try w.writeAll("UInt64");
            return 1;
        },
        .r4 => {
            try w.writeAll("Single");
            return 1;
        },
        .r8 => {
            try w.writeAll("Double");
            return 1;
        },
        .string => {
            try w.writeAll("String");
            return 1;
        },
        .intptr => {
            try w.writeAll("IntPtr");
            return 1;
        },
        .uintptr => {
            try w.writeAll("UIntPtr");
            return 1;
        },
        .ptr => {
            try w.writeAll("*");
            return 1 + try emitTypeRefSig(w, md, api_name, sig[1..]);
        },
        .class, .valuetype => {
            const token_bytes = sig[1..];
            if (token_bytes.len == 0) @panic("truncated");
            const token_len = winmd.decodeSigUnsignedLen(token_bytes[0]);
            if (token_bytes.len < token_len.int(usize)) @panic("truncated token");
            const token_encoded: winmd.TypeToken = @enumFromInt(winmd.decodeSigUnsigned(token_bytes[0..token_len.int(usize)]));
            const token = token_encoded.decode() catch @panic("invalid type token");
            try emitTypeDefOrRef(w, md, api_name, .{
                .table = switch (token.table) {
                    .TypeDef => .TypeDef,
                    .TypeRef => .TypeRef,
                    .TypeSpec => @panic("TypeSpec unsupported"),
                    _ => @panic("invalid table"),
                },
                .index = token.index,
            });
            return 1 + token_len.int(usize);
        },
        .array => {
            const elem_type_len = countTypeSigBytes(sig[1..]) catch @panic("invalid array elem sig");
            const shape_start = 1 + elem_type_len;
            if (shape_start + 3 > sig.len) @panic("array sig truncated");
            const num_sizes = sig[shape_start + 1];
            if (num_sizes != 1) @panic("expected num_sizes==1");
            var offset = shape_start + 2;
            const size_len = winmd.decodeSigUnsignedLen(sig[offset]);
            const size = winmd.decodeSigUnsigned(sig[offset..][0..@intFromEnum(size_len)]);
            offset += @intFromEnum(size_len);
            const num_lo_bounds = sig[offset];
            offset += 1;
            for (0..num_lo_bounds) |_| {
                const lo_bound_len = winmd.decodeSigUnsignedLen(sig[offset]);
                offset += @intFromEnum(lo_bound_len);
            }
            if (size == 1) try w.writeAll("[]") else try w.print("[{d}]", .{size});
            const child_len = try emitTypeRefSig(w, md, api_name, sig[1..]);
            std.debug.assert(child_len == elem_type_len);
            return offset;
        },
        else => |t| std.debug.panic("emitTypeRefSig: unsupported type {t}", .{t}),
    }
}

fn emitTypeDefOrRef(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, t: TypeDefOrRef) error{WriteFailed}!void {
    const name, const namespace, const target: TypeRefTarget = blk: switch (t.table) {
        .TypeDef => {
            const type_def = md.tables.row(.TypeDef, t.index);
            break :blk .{
                md.getString(type_def.name),
                md.getString(type_def.namespace),
                .{ .api = .{ .kind = .initTypeDef(md, t.index), .parents = .none } },
            };
        },
        .TypeRef => {
            const type_ref = md.tables.row(.TypeRef, t.index);
            break :blk .{
                md.getString(type_ref.name),
                md.getString(type_ref.namespace),
                .init(md, t.index),
            };
        },
    };
    switch (target) {
        .guid => try w.writeAll("Guid"),
        .extref => |m| try w.print("extref({s},{s})", .{ m.namespace, m.name }),
        .api => |api| {
            const resolved_api = if (std.mem.eql(u8, namespace, ""))
                api_name
            else if (std.mem.startsWith(u8, namespace, shared_namespace_prefix))
                apiFromNamespace(namespace)
            else
                std.debug.panic("Unexpected Namespace '{s}' for type '{s}'", .{ namespace, name });
            try w.print("ref({s},{s},{s}", .{ resolved_api, name, @tagName(api.kind) });
            for (api.parents.slice()) |parent| try w.print(",{s}", .{parent});
            try w.writeAll(")");
        },
    }
}

fn emitApi(w: *std.Io.Writer, loader: *Loader, api_name: []const u8) error{WriteFailed}!void {
    const md = &loader.md;
    const api = loader.api_map.getPtr(api_name) orelse std.debug.panic("unknown api '{s}'", .{api_name});

    global.context.set(.api, api_name);
    defer global.context.unset(.api, api_name);

    try w.print("namespace {s}\n", .{api_name});
    try emitConstants(w, md, api_name, api);
    for (api.type_defs.items) |type_def_index| {
        try emitType(w, md, api_name, type_def_index, 0);
    }
    const methods: winmd.RowRange = if (api.apis_type_def_index) |i| md.tables.typeDefRange(i, .methods) else .empty;
    for (methods.start..methods.limit) |method_index| {
        try emitMethod(w, md, api_name, method_index, 0, .func, null);
    }
}

fn emitConstants(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, api: *const ApiTypeDefs) error{WriteFailed}!void {
    const fields: winmd.RowRange = if (api.apis_type_def_index) |i| md.tables.typeDefRange(i, .fields) else .empty;
    for (fields.start..fields.limit) |field_index| {
        const field = md.tables.row(.Field, field_index);
        const name = md.getString(field.name);
        var it = md.custom_attr_map.getIterator(.init(.Field, @intCast(field_index)));
        const value = analyzeConstValue(md, &it, field, name) catch @panic("analyzeConstValue failed");
        const field_type = md.getBlob(field.signature);
        if (field_type.len == 0 or field_type[0] != 6) errExit("invalid constant type signature", .{});
        const type_sig = field_type[1..];

        try indent(w, 0);
        try w.print("const {s} ", .{name});
        switch (value) {
            .guid => |guid| {
                try w.writeAll("String ");
                try w.writeAll(fmtGuidText(guid));
            },
            .property_key => |key| {
                try w.print("PropertyKey propkey({s},{d})", .{ guidStr(key.guid), key.pid });
            },
            .default => {
                const coded_index: winmd.ConstantParent = .init(.Field, @intCast(field_index));
                const constant_index = md.constant_map.get(coded_index) orelse std.debug.panic(
                    "constant '{s}' has default value but no entry in constant table",
                    .{name},
                );
                const constant = md.tables.row(.Constant, constant_index);
                const constant_type: u8 = @intCast(0xff & constant.type);
                const encoded_value = md.getBlob(constant.value);
                try w.print("{s} ", .{constValueTypeName(constant_type)});
                try writeConstDefaultValue(w, constant_type, encoded_value);
            },
        }
        try w.writeAll(" ");
        const consumed = try emitTypeRefSig(w, md, api_name, type_sig);
        std.debug.assert(consumed == type_sig.len);
        try w.writeAll("\n");
    }
}

fn emitType(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, type_def_index: u32, depth: usize) error{WriteFailed}!void {
    const type_def = md.tables.row(.TypeDef, type_def_index);
    const name = md.getString(type_def.name);

    const save = global.context.type;
    defer global.context.type = save;
    global.context.type = null;
    global.context.set(.type, name);
    defer global.context.unset(.type, name);

    var attrs: TypeAttrs = .{ .flags = type_def.attributes };
    {
        var it = md.custom_attr_map.getIterator(.init(.TypeDef, @intCast(type_def_index)));
        while (it.next()) |custom_attr_index| {
            const custom_attr_row = md.tables.row(.CustomAttr, custom_attr_index);
            switch (CustomAttr.decode(md, custom_attr_row)) {
                .Guid => |guid| {
                    if (attrs.guid != null) @panic("multiple guids");
                    attrs.guid = guid;
                },
                .RaiiFree => |func| {
                    if (attrs.raii_free != null) @panic("multiple RAIIFree attributes");
                    attrs.raii_free = func;
                },
                .NativeTypedef => {
                    std.debug.assert(!attrs.is_native_typedef);
                    attrs.is_native_typedef = true;
                },
                .Flags => {
                    std.debug.assert(!attrs.is_flags);
                    attrs.is_flags = true;
                },
                .UnmanagedFunctionPointer => |cc| {
                    std.debug.assert(attrs.calling_convention == null);
                    attrs.calling_convention = cc;
                },
                .AlsoUsableFor => |usable| {
                    std.debug.assert(attrs.also_usable_for == null);
                    attrs.also_usable_for = usable;
                },
                .SupportedOSPlatform => |p| {
                    std.debug.assert(attrs.supported_os_platform == null);
                    attrs.supported_os_platform = p;
                },
                .SupportedArchitecture => |a| {
                    std.debug.assert(attrs.arches == null);
                    attrs.arches = a;
                },
                .ScopedEnum => {
                    std.debug.assert(!attrs.scoped_enum);
                    attrs.scoped_enum = true;
                },
                .InvalidHandleValue => |v| {
                    attrs.invalid_handle_value = v;
                },
                .Agile => {
                    std.debug.assert(!attrs.is_agile);
                    attrs.is_agile = true;
                },
                .Obsolete => |o| attrs.Obsolete = o,
                else => |c| std.debug.panic("unexpected custom attribute '{s}' on TypeDef", .{@tagName(c)}),
            }
        }
    }

    if (attrs.is_native_typedef) {
        try emitNativeTypedef(w, md, api_name, type_def_index, &attrs, name, depth);
        return;
    }

    const base_type_index = type_def.extends.value() orelse {
        try emitCom(w, md, api_name, type_def_index, &attrs, name, depth);
        return;
    };
    const base_type_ref = md.tables.row(.TypeRef, base_type_index.index);
    const base_type_qn: QualifiedName = .{
        .namespace = md.getString(base_type_ref.namespace),
        .name = md.getString(base_type_ref.name),
    };
    const base_type: enum { @"enum", value, delegate } = if (base_type_qn.eql("System", "Enum"))
        .@"enum"
    else if (base_type_qn.eql("System", "ValueType"))
        .value
    else if (base_type_qn.eql("System", "MulticastDelegate"))
        .delegate
    else
        std.debug.panic("unexpected base type '{s}:{s}'", .{ base_type_qn.namespace, base_type_qn.name });

    switch (base_type) {
        .@"enum" => try emitEnum(w, md, type_def_index, &attrs, name, depth),
        .value => try emitStructOrUnion(w, md, api_name, type_def_index, &attrs, name, depth),
        .delegate => try emitFunctionPointer(w, md, api_name, type_def_index, &attrs, name, depth),
    }
}

fn emitNativeTypedef(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, type_def_index: u32, attrs: *const TypeAttrs, name: []const u8, depth: usize) error{WriteFailed}!void {
    try indent(w, depth);
    try w.print("typedef {s} ", .{name});
    const fields = md.tables.typeDefRange(type_def_index, .fields);
    if (fields.start >= fields.limit) @panic("NativeTypedef with no field");
    const field = md.tables.row(.Field, fields.start);
    const field_type = md.getBlob(field.signature);
    if (field_type.len == 0 or field_type[0] != 6) errExit("invalid NativeTypedef field signature", .{});
    _ = try emitTypeRefSig(w, md, api_name, field_type[1..]);
    if (attrs.also_usable_for) |a| try w.print(" alsousablefor={s}", .{a});
    if (attrs.raii_free) |f| try w.print(" freefunc={s}", .{f});
    if (attrs.invalid_handle_value) |v| try w.print(" invalidhandle={d}", .{@as(i64, @intCast(v))});
    try emitArchPlat(w, attrs.arches, attrs.supported_os_platform);
    try w.writeAll("\n");
}

fn emitEnum(w: *std.Io.Writer, md: *const Metadata, type_def_index: u32, attrs: *const TypeAttrs, name: []const u8, depth: usize) error{WriteFailed}!void {
    const value__attrs: winmd.FieldAttributes = .{ .access = .public, .static = false, .special_name = true, .rt_special_name = true };
    const values_range = md.tables.typeDefRange(type_def_index, .fields);

    var maybe_base: ?EnumBase = null;
    for (values_range.start..values_range.limit) |field_index| {
        const field = md.tables.row(.Field, field_index);
        if (field.attributes == value__attrs) continue;
        const coded_index: winmd.ConstantParent = .init(.Field, @intCast(field_index));
        const constant_index = md.constant_map.get(coded_index) orelse std.debug.panic("enum value has no constant table entry", .{});
        const constant = md.tables.row(.Constant, constant_index);
        const base_type: EnumBase = switch (winmd.ElementType.decodeU32(constant.type) orelse @panic("invalid constant type")) {
            .i1 => .SByte,
            .u1 => .Byte,
            .u2 => .UInt16,
            .i4 => .Int32,
            .u4 => .UInt32,
            .u8 => .UInt64,
            else => |t| std.debug.panic("todo: support enum value type '{s}'", .{@tagName(t)}),
        };
        if (maybe_base) |b| std.debug.assert(b == base_type) else maybe_base = base_type;
    }

    try indent(w, depth);
    try w.print("enum {s}", .{name});
    if (maybe_base) |b| try w.print(" base={s}", .{@tagName(b)});
    if (attrs.is_flags) try w.writeAll(" flags");
    if (attrs.scoped_enum) try w.writeAll(" scoped");
    try emitArchPlat(w, attrs.arches, attrs.supported_os_platform);
    try w.writeAll("\n");

    for (values_range.start..values_range.limit) |field_index| {
        const field = md.tables.row(.Field, field_index);
        const vname = md.getString(field.name);
        if (field.attributes == value__attrs) {
            std.debug.assert(std.mem.eql(u8, vname, "value__"));
            continue;
        }
        const coded_index: winmd.ConstantParent = .init(.Field, @intCast(field_index));
        const constant_index = md.constant_map.get(coded_index).?;
        const constant = md.tables.row(.Constant, constant_index);
        const encoded_value = md.getBlob(constant.value);
        try indent(w, depth + 1);
        try w.print("value {s} ", .{vname});
        try writeEnumValue(w, maybe_base.?, encoded_value);
        try w.writeAll("\n");
    }
}

fn emitStructOrUnion(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, type_def_index: u32, attrs: *const TypeAttrs, name: []const u8, depth: usize) error{WriteFailed}!void {
    const is_union = switch (attrs.flags.layout) {
        .sequential => false,
        .explicit => true,
        else => |l| std.debug.panic("todo: handle layout {s}", .{@tagName(l)}),
    };
    const packing_size = blk: {
        const layout_index = md.layout_map.get(type_def_index) orelse break :blk 0;
        break :blk md.tables.row(.ClassLayout, layout_index).packing_size;
    };

    try indent(w, depth);
    try w.print("{s} {s} pack={d}", .{ if (is_union) "union" else "struct", name, packing_size });
    if (attrs.guid) |g| try w.print(" guid={s}", .{guidStr(g)});
    if (attrs.Obsolete) |o| try emitObsolete(w, o);
    try emitArchPlat(w, attrs.arches, attrs.supported_os_platform);
    try w.writeAll("\n");

    const const_field_attrs: winmd.FieldAttributes = .{ .access = .public, .static = true, .literal = true, .has_default = true };
    const fields = md.tables.typeDefRange(type_def_index, .fields);
    for (fields.start..fields.limit) |field_index| {
        const field = md.tables.row(.Field, field_index);
        const fname = md.getString(field.name);
        const field_type = md.getBlob(field.signature);
        if (field_type.len == 0 or field_type[0] != 6) errExit("invalid field signature", .{});
        const type_sig = field_type[1..];

        if (field.attributes == const_field_attrs) {
            try indent(w, depth + 1);
            try w.print("constfield {s} ", .{fname});
            const consumed = try emitTypeRefSig(w, md, api_name, type_sig);
            std.debug.assert(consumed == type_sig.len);
            try w.writeAll("\n");
            continue;
        }

        var fa_const = false;
        var fa_notnull = false;
        var fa_nullnull = false;
        var fa_obsolete: ?ObsoleteAttr = null;
        var maybe_native_array: ?NativeArray = null;
        {
            var it = md.custom_attr_map.getIterator(.init(.Field, @intCast(field_index)));
            while (it.next()) |custom_attr_index| {
                const custom_attr_row = md.tables.row(.CustomAttr, custom_attr_index);
                switch (CustomAttr.decode(md, custom_attr_row)) {
                    .Const => fa_const = true,
                    .NotNullTerminated => fa_notnull = true,
                    .NullNullTerminated => fa_nullnull = true,
                    .Obsolete => |o| fa_obsolete = o,
                    .NativeArray => |na| {
                        std.debug.assert(maybe_native_array == null);
                        maybe_native_array = na;
                    },
                    else => |c| std.debug.panic("unhandled field custom attr '{s}'", .{@tagName(c)}),
                }
            }
        }

        try indent(w, depth + 1);
        try w.print("field {s} ", .{fname});
        if (maybe_native_array) |na| {
            const child_sig = getChildSig(md, type_sig);
            try w.print("[lparray,nullnull={},const={d},param={d}]", .{ false, na.CountConst, na.CountParamIndex });
            const child_len = try emitTypeRefSig(w, md, api_name, child_sig);
            std.debug.assert(child_len == child_sig.len);
        } else {
            const consumed = try emitTypeRefSig(w, md, api_name, type_sig);
            std.debug.assert(consumed == type_sig.len);
        }
        if (fa_const) try w.writeAll(" const");
        if (fa_notnull) try w.writeAll(" notnullterm");
        if (fa_nullnull) try w.writeAll(" nullnullterm");
        if (fa_obsolete) |o| try emitObsolete(w, o);
        try w.writeAll("\n");
    }

    var iterator = md.nested_map.getIterator(type_def_index);
    while (iterator.next()) |nested_class_index| {
        const entry = md.tables.row(.NestedClass, nested_class_index);
        std.debug.assert(entry.enclosing.asIndex().? == type_def_index);
        const nested_type_def_index = entry.nested.asIndex().?;
        try emitType(w, md, api_name, nested_type_def_index, depth + 1);
    }
}

fn emitCom(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, type_def_index: u32, attrs: *const TypeAttrs, name: []const u8, depth: usize) error{WriteFailed}!void {
    std.debug.assert(md.tables.typeDefRange(type_def_index, .fields).count() == 0);
    try indent(w, depth);
    try w.print("com {s}", .{name});
    if (attrs.guid) |g| try w.print(" guid={s}", .{guidStr(g)});
    if (attrs.is_agile) try w.writeAll(" agile");
    if (md.interface_map.get(type_def_index)) |interface| {
        try w.writeAll(" interface=");
        try emitTypeDefOrRef(w, md, api_name, .{
            .table = switch (interface.table) {
                .TypeDef => @panic("all interfaces are TypeRef's so far"),
                .TypeRef => .TypeRef,
                .TypeSpec => @panic("TypeSpec unsupported"),
                _ => @panic("invalid table"),
            },
            .index = interface.index.asIndex().?,
        });
    }
    try emitArchPlat(w, attrs.arches, attrs.supported_os_platform);
    try w.writeAll("\n");
    std.debug.assert(null == md.nested_map.getIterator(type_def_index).index.asIndex());
    const method_range = md.tables.typeDefRange(type_def_index, .methods);
    for (method_range.start..method_range.limit) |i| {
        try emitMethod(w, md, api_name, i, depth + 1, .method, null);
    }
}

fn emitFunctionPointer(w: *std.Io.Writer, md: *const Metadata, api_name: []const u8, type_def_index: u32, attrs: *const TypeAttrs, name: []const u8, depth: usize) error{WriteFailed}!void {
    std.debug.assert(md.tables.typeDefRange(type_def_index, .fields).count() == 0);
    const methods = md.tables.typeDefRange(type_def_index, .methods);
    std.debug.assert(methods.count() == 2);
    {
        const ctor = md.tables.row(.MethodDef, methods.start);
        std.debug.assert(std.mem.eql(u8, md.getString(ctor.name), ".ctor"));
    }
    const fn_attrs: BuildFnAttrs = .{
        .cdecl = if (attrs.calling_convention) |cc| switch (cc) {
            .Winapi => false,
            .Cdecl => true,
        } else false,
        .obsolete = attrs.Obsolete,
    };
    try emitMethod(w, md, api_name, methods.start + 1, depth, .funcptr, .{
        .name = name,
        .arches = attrs.arches,
        .platform = attrs.supported_os_platform,
        .fn_attrs = fn_attrs,
    });
}

const MethodOverride = struct {
    name: []const u8,
    arches: ?ArchBits,
    platform: ?[]const u8,
    fn_attrs: BuildFnAttrs,
};

fn emitMethod(
    w: *std.Io.Writer,
    md: *const Metadata,
    api_name: []const u8,
    method_index: usize,
    depth: usize,
    kind: enum { func, method, funcptr },
    override: ?MethodOverride,
) error{WriteFailed}!void {
    const method = md.tables.row(.MethodDef, method_index);
    const method_name = md.getString(method.name);

    global.context.set(.func, method_name);
    defer global.context.unset(.func, method_name);

    var dll_import: ?[]const u8 = null;
    var set_last_error = false;
    {
        const member_forwarded: winmd.MemberForwarded = .{
            .table = .MethodDef,
            .index = .fromIndex(@intCast(method_index)),
        };
        if (md.impl_map_map.get(member_forwarded)) |impl_map_index| {
            const impl_map = md.tables.row(.ImplMap, impl_map_index);
            set_last_error = impl_map.flags.supports_last_error;
            if (impl_map.import_scope.asIndex()) |import_scope_index| {
                const module_ref = md.tables.row(.ModuleRef, import_scope_index);
                dll_import = md.getString(module_ref.name);
            }
        }
    }

    var platform_str: ?[]const u8 = null;
    var arches: ?ArchBits = null;
    var does_not_return = false;
    var method_obsolete: ?ObsoleteAttr = null;
    {
        var it = md.custom_attr_map.getIterator(.init(.MethodDef, @intCast(method_index)));
        while (it.next()) |custom_attr_index| {
            const custom_attr_row = md.tables.row(.CustomAttr, custom_attr_index);
            switch (CustomAttr.decode(md, custom_attr_row)) {
                .SupportedOSPlatform => |p| {
                    std.debug.assert(platform_str == null);
                    platform_str = p;
                },
                .SupportedArchitecture => |a| {
                    std.debug.assert(arches == null);
                    arches = a;
                },
                .DoesNotReturn => does_not_return = true,
                .Obsolete => |o| method_obsolete = o,
                else => |c| std.debug.panic("unhandled function attribute '{s}'", .{@tagName(c)}),
            }
        }
    }

    // For a funcptr, the arch/platform/attrs shown on the line come from the
    // type (the inner Invoke method's own arch/platform are ignored, matching
    // the reference generator).
    const out_name = if (override) |o| o.name else method_name;
    const out_arches = if (override) |o| o.arches else arches;
    const out_platform = if (override) |o| o.platform else platform_str;
    var fn_cdecl = false;
    var fn_obsolete: ?ObsoleteAttr = null;
    if (override) |o| {
        fn_cdecl = o.fn_attrs.cdecl;
        if (o.fn_attrs.obsolete) |ob| {
            std.debug.assert(method_obsolete == null);
            fn_obsolete = ob;
        } else fn_obsolete = method_obsolete;
    } else fn_obsolete = method_obsolete;

    const sig_blob = md.getBlob(method.signature);
    if (sig_blob.len < 2) @panic("method signature too short");
    const param_count_len = winmd.decodeSigUnsignedLen(sig_blob[1]);
    var sig_offset: usize = 1 + param_count_len.int(usize);

    try indent(w, depth);
    switch (kind) {
        .func => {
            const dll = dll_import orelse std.debug.panic("function '{s}' has no DllImport", .{method_name});
            try w.print("func {s} dll={s} ret=", .{ out_name, dll });
        },
        .method => try w.print("method {s} ret=", .{out_name}),
        .funcptr => try w.print("funcptr {s} ret=", .{out_name}),
    }
    const ret_len = try emitTypeRefSig(w, md, api_name, sig_blob[sig_offset..]);
    sig_offset += ret_len;
    if (set_last_error) try w.writeAll(" setlasterror");
    if (method.attributes.special_name) try w.writeAll(" specialname");
    if (method.impl_flags.preserve_sig) try w.writeAll(" preservesig");
    if (does_not_return) try w.writeAll(" doesnotreturn");
    if (fn_cdecl) try w.writeAll(" cdecl");
    if (fn_obsolete) |o| try emitObsolete(w, o);
    try emitArchPlat(w, out_arches, out_platform);
    try w.writeAll("\n");

    const method_params = md.tables.methodParams(@intCast(method_index));
    for (method_params.start..method_params.limit) |param_index| {
        const param = md.tables.row(.Param, param_index);
        if (param.sequence == 0) continue;
        const param_name = md.getString(param.name);
        global.context.set(.param, param_name);
        defer global.context.unset(.param, param_name);

        const param_type_sig = blk: {
            const remaining = sig_blob[sig_offset..];
            const len = countTypeSigBytes(remaining) catch @panic("failed to decode parameter type");
            break :blk remaining[0..len];
        };

        var maybe_native_array: ?NativeArray = null;
        var pa_const = false;
        var pa_comoutptr = false;
        var pa_notnull = false;
        var pa_nullnull = false;
        var pa_retval = false;
        var pa_donotrelease = false;
        var pa_reserved = false;
        var pa_memorysize: ?i16 = null;
        var pa_freewith: ?[]const u8 = null;
        {
            var it = md.custom_attr_map.getIterator(.init(.Param, @intCast(param_index)));
            while (it.next()) |custom_attr_index| {
                const custom_attr_row = md.tables.row(.CustomAttr, custom_attr_index);
                switch (CustomAttr.decode(md, custom_attr_row)) {
                    .Const => pa_const = true,
                    .ComOutPtr => pa_comoutptr = true,
                    .NotNullTerminated => pa_notnull = true,
                    .NullNullTerminated => pa_nullnull = true,
                    .RetVal => pa_retval = true,
                    .FreeWith => |func| pa_freewith = func,
                    .MemorySize => |idx| pa_memorysize = idx,
                    .DoNotRelease => pa_donotrelease = true,
                    .Reserved => pa_reserved = true,
                    .NativeArray => |na| {
                        std.debug.assert(maybe_native_array == null);
                        maybe_native_array = na;
                    },
                    else => {},
                }
            }
        }

        try indent(w, depth + 1);
        try w.print("param {s} ", .{param_name});
        if (maybe_native_array) |na| {
            const child_sig = getChildSig(md, param_type_sig);
            try w.print("[lparray,nullnull={},const={d},param={d}]", .{ false, na.CountConst, na.CountParamIndex });
            const child_len = try emitTypeRefSig(w, md, api_name, child_sig);
            std.debug.assert(child_len == child_sig.len);
        } else {
            const consumed = try emitTypeRefSig(w, md, api_name, param_type_sig);
            std.debug.assert(consumed == param_type_sig.len);
        }
        if (pa_const) try w.writeAll(" const");
        if (param.attributes.in) try w.writeAll(" in");
        if (param.attributes.out) try w.writeAll(" out");
        if (param.attributes.optional) try w.writeAll(" optional");
        if (pa_notnull) try w.writeAll(" notnullterm");
        if (pa_nullnull) try w.writeAll(" nullnullterm");
        if (pa_retval) try w.writeAll(" retval");
        if (pa_comoutptr) try w.writeAll(" comoutptr");
        if (pa_donotrelease) try w.writeAll(" donotrelease");
        if (pa_reserved) try w.writeAll(" reserved");
        if (pa_memorysize) |ms| try w.print(" memorysize={d}", .{@as(u16, @intCast(ms))});
        if (pa_freewith) |fw| try w.print(" freewith={s}", .{fw});
        try w.writeAll("\n");

        sig_offset += param_type_sig.len;
    }
    std.debug.assert(sig_offset == sig_blob.len);
}

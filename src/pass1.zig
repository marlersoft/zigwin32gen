//! Produces the "pass1" index consumed by genzig: a per-api map of type name ->
//! category (Integral/Enum/Struct/Union/Pointer/FunctionPointer/Com) plus, for
//! com types, the base interface. genzig needs this cross-api view before it can
//! resolve ApiRefs, so it is computed for every api up front (in memory), built
//! directly from the loaded metadata.

const std = @import("std");
const metadata = @import("metadata.zig");
const common = @import("common.zig");
const pass1data = @import("pass1data.zig");
const handletypes = @import("handletypes.zig");
const oom = common.oom;

/// Builds the whole pass1 index directly from the loaded api models. `names[i]`
/// is the api name for `apis[i]`. Everything is allocated on `arena`.
pub fn buildIndex(arena: std.mem.Allocator, names: []const []const u8, apis: []const metadata.Api) pass1data.Root {
    var root = std.StringArrayHashMap(pass1data.TypeMap).init(arena);
    for (names, apis) |name, api| {
        var type_map = std.StringArrayHashMap(pass1data.Type).init(arena);
        for (api.Types) |t| {
            const entry = classifyType(t) orelse continue; // ComClassID has no pass1 entry
            type_map.put(t.Name, entry) catch |e| oom(e);
        }
        root.put(name, type_map) catch |e| oom(e);
    }
    return root;
}

fn classifyType(t: metadata.Type) ?pass1data.Type {
    return switch (t.Kind) {
        .NativeTypedef => |n| classifyNativeTypedef(t, n),
        .Enum => .{ .Enum = .{} },
        .Struct => .{ .Struct = .{} },
        .Union => .{ .Union = .{} },
        .ComClassID => null,
        .Com => |com| classifyCom(t, com),
        .FunctionPointer => .{ .FunctionPointer = .{} },
    };
}

fn classifyNativeTypedef(t: metadata.Type, native_typedef: metadata.NativeTypedef) pass1data.Type {
    // HANDLE PSTR and PWSTR specially because win32metadata is not properly declaring them as arrays, only pointers
    if (std.mem.eql(u8, t.Name, "PSTR") or std.mem.eql(u8, t.Name, "PWSTR")) {
        return .{ .Pointer = .{} };
    }

    // NOTE: for now, I'm just hardcoding a few types to redirect to the ones defined in 'std'
    //       this allows apps to use values of these types interchangeably with bindings in std
    if (handletypes.std_handle_types.get(t.Name)) |_| return .{ .Pointer = .{} };
    // workaround https://github.com/microsoft/win32metadata/issues/395
    if (handletypes.handle_types.get(t.Name)) |_| return .{ .Pointer = .{} };

    return switch (native_typedef.Def) {
        .Native => |native| if (isIntegral(native.Name))
            .{ .Integral = .{} }
        else
            std.debug.panic("unhandled Native kind in NativeTypedef '{s}'", .{@tagName(native.Name)}),
        .PointerTo => .{ .Pointer = .{} },
        else => |kind| std.debug.panic("unhandled NativeTypedef kind '{s}'", .{@tagName(kind)}),
    };
}

fn classifyCom(t: metadata.Type, com: metadata.Com) pass1data.Type {
    const interface: ?metadata.TypeRef = blk: {
        if (com.Interface) |iface| {
            // Normalize to the same ApiRef shape the reference generator produced.
            const ci = common.getComInterface(iface);
            break :blk .{ .ApiRef = .{
                .Name = ci.name,
                .TargetKind = .Com,
                .Api = ci.api,
                .Parents = &[_][]const u8{},
            } };
        }
        if (!std.mem.eql(u8, t.Name, "IUnknown")) {
            std.log.warn("com type '{s}' does not have an interface (file bug if we're on the latest metadata version)", .{t.Name});
        }
        break :blk null;
    };
    return .{ .Com = .{ .Interface = interface } };
}

fn isIntegral(native: metadata.TypeRefNative) bool {
    return switch (native) {
        .Void => false,
        .Boolean => false,
        .SByte => true,
        .Byte => true,
        .Int16 => true,
        .UInt16 => true,
        .Int32 => true,
        .UInt32 => true,
        .Int64 => true,
        .UInt64 => true,
        .Char => false,
        .Single => false,
        .Double => false,
        .String => false,
        .IntPtr => true,
        .UIntPtr => true,
        .Guid => false,
    };
}

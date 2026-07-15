pub fn apiPatchMap(al: std.mem.Allocator) error{OutOfMemory}!std.StringHashMapUnmanaged(ApiPatches) {
    var api_patches: std.StringHashMapUnmanaged(ApiPatches) = .{};

    {
        const api = try addApiPatches(al, &api_patches, "System.Console");
        try api.func(al, .{ .name = "WriteConsoleA", .optional_params = .copy(&.{
            .{ .name = "lpReserved" },
        }) });
        try api.func(al, .{ .name = "WriteConsoleW", .optional_params = .copy(&.{
            .{ .name = "lpReserved" },
        }) });
    }
    {
        const api = try addApiPatches(al, &api_patches, "System.Memory");
        try api.func(al, .{ .name = "CreateFileMappingA", .optional_return = .{} });
        try api.func(al, .{ .name = "CreateFileMappingW", .optional_return = .{} });
        try api.func(al, .{ .name = "MapViewOfFile", .optional_return = .{} });
        try api.func(al, .{ .name = "MapViewOfFileEx", .optional_return = .{} });
    }
    {
        const api = try addApiPatches(al, &api_patches, "UI.WindowsAndMessaging");
        try api.func(al, .{ .name = "CreateWindowExA", .optional_return = .{} });
        try api.func(al, .{ .name = "CreateWindowExW", .optional_return = .{} });
        try api.func(al, .{ .name = "ShowWindow", .optional_params = .copy(&.{
            .{ .name = "hWnd" },
        }) });
        try api.struct_(al, .{ .name = "WNDCLASSA", .optional_fields = .copy(&.{
            .{ .name = "hIcon" },
            .{ .name = "hCursor" },
            .{ .name = "hbrBackground" },
            .{ .name = "lpszMenuName" },
        }) });
        try api.struct_(al, .{ .name = "WNDCLASSW", .optional_fields = .copy(&.{
            .{ .name = "hIcon" },
            .{ .name = "hCursor" },
            .{ .name = "hbrBackground" },
            .{ .name = "lpszMenuName" },
        }) });
    }
    {
        const api = try addApiPatches(al, &api_patches, "Graphics.Gdi");
        try api.func(al, .{ .name = "CreateFontA", .optional_return = .{} });
        try api.func(al, .{ .name = "CreateFontW", .optional_return = .{} });
    }
    return api_patches;
}

pub fn verifyApiPatches(api_patch_map: *const std.StringHashMapUnmanaged(ApiPatches)) void {
    var it = api_patch_map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.verify();
    }
}

fn addApiPatches(
    al: std.mem.Allocator,
    api_patches: *std.StringHashMapUnmanaged(ApiPatches),
    name: []const u8,
) error{OutOfMemory}!*ApiPatches {
    const entry = try api_patches.getOrPut(al, name);
    if (entry.found_existing) std.debug.panic("api '{s}' patched multiple times", .{name});
    entry.value_ptr.* = .{
        .name = name,
        .func_map = .{},
        .struct_map = .{},
    };
    return entry.value_ptr;
}

pub const ApiPatches = struct {
    name: []const u8,
    func_map: std.StringHashMapUnmanaged(FuncPatches),
    struct_map: std.StringHashMapUnmanaged(StructPatches),

    pub const none: ApiPatches = .{
        .name = "",
        .func_map = .{},
        .struct_map = .{},
    };

    pub fn verify(api_patches: *const ApiPatches) void {
        {
            var it = api_patches.func_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.verify(api_patches.name);
            }
        }
        {
            var it = api_patches.struct_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.verify(api_patches.name);
            }
        }
    }
    pub fn func(
        api_patches: *ApiPatches,
        al: std.mem.Allocator,
        func_patches: FuncPatches,
    ) error{OutOfMemory}!void {
        const entry = try api_patches.func_map.getOrPut(al, func_patches.name);
        if (entry.found_existing) std.debug.panic("api '{s}' function '{s}' patched multiple times", .{ api_patches.name, func_patches.name });
        entry.value_ptr.* = func_patches;
    }
    pub fn struct_(
        api_patches: *ApiPatches,
        al: std.mem.Allocator,
        struct_patches: StructPatches,
    ) error{OutOfMemory}!void {
        const entry = try api_patches.struct_map.getOrPut(al, struct_patches.name);
        if (entry.found_existing) std.debug.panic("api '{s}' struct '{s}' patched multiple times", .{ api_patches.name, struct_patches.name });
        entry.value_ptr.* = struct_patches;
    }
};

fn BoundedArray(comptime T: type, comptime max: usize) type {
    return struct {
        count: std.math.IntFittingRange(0, max),
        buffer: [max]T,

        const Self = @This();

        pub const empty: Self = .{ .count = 0, .buffer = undefined };

        pub fn copy(source: []const T) Self {
            if (source.len > max) std.debug.panic("slice {} too long (max {})", .{ source.len, max });
            var result: Self = .{ .count = @intCast(source.len), .buffer = undefined };
            @memcpy(result.buffer[0..source.len], source);
            return result;
        }
        pub fn slice(self: *const Self) []const T {
            return self.buffer[0..self.count];
        }
        pub fn sliceMut(self: *Self) []T {
            return self.buffer[0..self.count];
        }
    };
}

pub const StructPatches = struct {
    name: []const u8,
    optional_fields: BoundedArray(NamedOptional, 4) = .empty,

    pub const none: StructPatches = .{ .name = "" };

    pub fn verify(patches: *const StructPatches, api_name: []const u8) void {
        for (patches.optional_fields.slice()) |f| if (!f.applied) std.debug.panic(
            "api '{s}' struct '{s}' field '{s}' optional not applied",
            .{ api_name, patches.name, f.name },
        );
    }

    pub fn queryOptionalField(patches: *StructPatches, name: []const u8) bool {
        for (patches.optional_fields.sliceMut()) |*p| {
            if (std.mem.eql(u8, name, p.name)) {
                std.debug.assert(!p.applied);
                p.applied = true;
                return true;
            }
        }
        return false;
    }
};

pub const FuncPatches = struct {
    name: []const u8,
    optional_return: ?OptionalReturn = null,
    optional_params: BoundedArray(NamedOptional, 1) = .empty,

    pub const none: FuncPatches = .{ .name = "" };

    pub fn verify(patches: *const FuncPatches, api_name: []const u8) void {
        if (patches.optional_return) |r| if (!r.applied) std.debug.panic(
            "api '{s}' function '{s}' optional return not applied",
            .{ api_name, patches.name },
        );
        for (patches.optional_params.slice()) |p| if (!p.applied) std.debug.panic(
            "api '{s}' function '{s}' param '{s}' optional not applied",
            .{ api_name, patches.name, p.name },
        );
    }

    pub fn queryOptionalReturn(patches: *FuncPatches) bool {
        const optional_return: *OptionalReturn = &(patches.optional_return orelse return false);
        std.debug.assert(!optional_return.applied);
        optional_return.applied = true;
        return true;
    }
    pub fn queryOptionalParam(patches: *FuncPatches, name: []const u8) bool {
        for (patches.optional_params.sliceMut()) |*p| {
            if (std.mem.eql(u8, name, p.name)) {
                std.debug.assert(!p.applied);
                p.applied = true;
                return true;
            }
        }
        return false;
    }
};
const OptionalReturn = struct {
    applied: bool = false,
};
const NamedOptional = struct {
    name: []const u8,
    applied: bool = false,
};

const std = @import("std");

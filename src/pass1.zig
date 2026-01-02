const std = @import("std");
const Io = std.Io;
const metadata = @import("metadata.zig");

const common = @import("common.zig");
const fatal = common.fatal;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !u8 {
    const all_args = try std.process.argsAlloc(allocator);
    // don't care about freeing args

    const gpa = std.heap.smp_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cmd_args = all_args[1..];
    if (cmd_args.len != 2) {
        std.log.err("expected 2 arguments but got {}", .{cmd_args.len});
        return 1;
    }
    const win32json_path = cmd_args[0];
    const out_filename = cmd_args[1];

    const api_path = try std.fs.path.join(allocator, &.{ win32json_path, "api" });
    var api_dir = try Io.Dir.cwd().openDir(io, api_path, .{ .iterate = true });
    defer api_dir.close(io);

    var api_list = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (api_list.items) |api_name| {
            allocator.free(api_name);
        }
        api_list.deinit();
    }
    try common.readApiList(io, api_dir, &api_list);

    // sort so our data is always in the same order
    std.mem.sort([]const u8, api_list.items, {}, common.asciiLessThanIgnoreCase);

    const out_file = try Io.Dir.cwd().createFile(io, out_filename, .{});
    defer out_file.close(io);
    var out_buf: [4096]u8 = undefined;
    var file_writer = out_file.writer(io, &out_buf);
    const out = &file_writer.interface;

    try out.writeAll("{\n");
    var json_obj_prefix: []const u8 = "";

    for (api_list.items) |api_json_basename| {
        const name = api_json_basename[0 .. api_json_basename.len - 5];
        try out.print("    {s}\"{s}\": {{\n", .{ json_obj_prefix, name });
        var file = try api_dir.openFile(io, api_json_basename, .{});
        defer file.close(io);
        try pass1OnFile(io, out, api_path, api_json_basename, file);
        try out.writeAll("    }\n");
        json_obj_prefix = ",";
    }

    try out.writeAll("}\n");
    try out.flush();
    std.log.info("wrote {s}", .{out_filename});
    return 0;
}

fn pass1OnFile(io: Io, out: *std.Io.Writer, api_dir: []const u8, filename: []const u8, file: std.Io.File) !void {
    var json_arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer json_arena_instance.deinit();
    const json_arena = json_arena_instance.allocator();

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const content = try reader.interface.allocRemaining(json_arena, .unlimited);

    // no need to free, owned by json_arena
    const parse_start = try std.time.Instant.now();

    const api = metadata.Api.parse(json_arena, api_dir, filename, content);
    // no need to free, owned by json_arena
    const parse_time = (try std.time.Instant.now()).since(parse_start);
    std.log.info("{} ms: parse time for '{s}'", .{ @divTrunc(parse_time, std.time.ns_per_ms), filename });

    try pass1OnJson(out, api);
}

fn writeType(out: *std.Io.Writer, json_obj_prefix: []const u8, name: []const u8, kind: []const u8) !void {
    try out.print("        {s}\"{s}\": {{\"Kind\":\"{s}\"}}\n", .{ json_obj_prefix, name, kind });
}

fn pass1OnJson(out: *std.Io.Writer, api: metadata.Api) !void {
    var json_obj_prefix: []const u8 = "";

    for (api.Types) |t| {
        switch (t.Kind) {
            .NativeTypedef => |n| try generateNativeTypedef(out, json_obj_prefix, t, n),
            .Enum => try writeType(out, json_obj_prefix, t.Name, "Enum"),
            .Struct => try writeType(out, json_obj_prefix, t.Name, "Struct"),
            .Union => try writeType(out, json_obj_prefix, t.Name, "Union"),
            .ComClassID => continue,
            .Com => |com| try writeComType(out, json_obj_prefix, t, com),
            .FunctionPointer => try writeType(out, json_obj_prefix, t.Name, "FunctionPointer"),
        }
        json_obj_prefix = ",";
    }
}

fn generateNativeTypedef(
    out: *std.Io.Writer,
    json_obj_prefix: []const u8,
    t: metadata.Type,
    native_typedef: metadata.NativeTypedef,
) !void {
    // HANDLE PSTR and PWSTR specially because win32metadata is not properly declaring them as arrays, only pointers
    // not sure if this is a real issue with the metadata or intentional
    const special: enum { pstr, pwstr, other } = blk: {
        if (std.mem.eql(u8, t.Name, "PSTR")) break :blk .pstr;
        if (std.mem.eql(u8, t.Name, "PWSTR")) break :blk .pwstr;
        break :blk .other;
    };
    if (special == .pstr or special == .pwstr) {
        try writeType(out, json_obj_prefix, t.Name, "Pointer");
        return;
    }

    // we should be able to ignore also_usable_for_node because the def_type should be the same as the type being defined
    //switch (also_usable_for_node) {
    //    .string => |also_usable_for| {
    //        if (also_usable_type_api_map.get(also_usable_for)) |api| {
    //            try sdk_file.addApiImport(arches, also_usable_for, api, json.Array { .items = &[_]json.Value{}, .capacity = 0, .allocator = allocator });
    //            try writer.linef("//TODO: type '{s}' is \"AlsoUsableFor\" '{s}' which means this type is implicitly", .{tmp_name, also_usable_for});
    //            try writer.linef("//      convertible to '{s}' but not the other way around.  I don't know how to do this", .{also_usable_for});
    //            try writer.line("//      in Zig so for now I'm just defining it as an alias");
    //            try writer.linef("pub const {s} = {s};", .{tmp_name, also_usable_for});
    //            //try writer.linef("pub const {s} = extern struct {{ base: {s} }};", .{tmp_name, also_usable_for});
    //        } else std.debug.panic("AlsoUsableFor type '{s}' is missing from alsoUsableForApiMap", .{also_usable_for});
    //        return;
    //    },
    //    .Null => {},
    //    else => jsonPanic(),
    //}

    // NOTE: for now, I'm just hardcoding a few types to redirect to the ones defined in 'std'
    //       this allows apps to use values of these types interchangeably with bindings in std
    if (@import("handletypes.zig").std_handle_types.get(t.Name)) |_| {
        try writeType(out, json_obj_prefix, t.Name, "Pointer");
        return;
    }
    // workaround https://github.com/microsoft/win32metadata/issues/395
    if (@import("handletypes.zig").handle_types.get(t.Name)) |_| {
        try writeType(out, json_obj_prefix, t.Name, "Pointer");
        return;
    }

    switch (native_typedef.Def) {
        .Native => |native| if (isIntegral(native.Name)) {
            try writeType(out, json_obj_prefix, t.Name, "Integral");
        } else std.debug.panic("unhandled Native kind in NativeTypedef '{s}'", .{@tagName(native.Name)}),
        .PointerTo => try writeType(out, json_obj_prefix, t.Name, "Pointer"),
        else => |kind| std.debug.panic("unhandled NativeTypedef kind '{s}'", .{@tagName(kind)}),
    }
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

fn writeComType(
    out: *std.Io.Writer,
    json_obj_prefix: []const u8,
    t: metadata.Type,
    com: metadata.Com,
) !void {
    const iface: ?common.ComInterface = blk: {
        if (com.Interface) |iface|
            break :blk common.getComInterface(iface);
        if (!std.mem.eql(u8, t.Name, "IUnknown")) {
            std.log.warn("com type '{s}' does not have an interface (file bug if we're on the latest metadata version)", .{t.Name});
        }
        break :blk null;
    };

    try out.print(
        "        {s}\"{s}\": {{\"Kind\":\"Com\",\"Interface\":{?f}}}\n",
        .{ json_obj_prefix, t.Name, iface },
    );
}

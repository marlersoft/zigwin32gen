const std = @import("std");
const json = std.json;

const common = @import("common.zig");
const fatal = common.fatal;
const Nothing = common.Nothing;
const jsonPanicMsg = common.jsonPanicMsg;
const jsonObjEnforceKnownFieldsOnly = common.jsonObjEnforceKnownFieldsOnly;
const fmtJson = common.fmtJson;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const BufferedWriter = std.io.BufferedWriter(std.mem.page_size, std.fs.File.Writer);
const OutWriter = BufferedWriter.Writer;

pub fn main() !u8 {
    const all_args = try std.process.argsAlloc(allocator);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 1) {
        std.log.err("expected 1 argument (path to the win32json repository) but got {}", .{cmd_args.len});
        return 1;
    }
    const win32json_path = cmd_args[0];

    var win32json_dir = try std.fs.cwd().openDir(win32json_path, .{});
    defer win32json_dir.close();


    {
        const need_update = blk: {
            const dest_mtime = (try common.getModifyTime(std.fs.cwd(), "pass1.json"))
                orelse break :blk true;
            break :blk try common.win32jsonIsNewerThan(win32json_dir, dest_mtime);
        };
        if (!need_update) {
            std.log.info("pass1 is already done", .{});
            return 0;
        }
    }

    var api_dir = try win32json_dir.openIterableDir("api", .{}) ;
    defer api_dir.close();

    var api_list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (api_list.items) |api_name| {
            allocator.free(api_name);
        }
        api_list.deinit();
    }
    try common.readApiList(api_dir, &api_list);

    // sort so our data is always in the same order
    std.sort.sort([]const u8, api_list.items, Nothing {}, common.asciiLessThanIgnoreCase);

    const out_file = try std.fs.cwd().createFile("pass1.json.generating", .{});
    defer out_file.close();
    var buffered_writer =  BufferedWriter{
        .unbuffered_writer = out_file.writer(),
    };
    const out = buffered_writer.writer();

    try out.writeAll("{\n");
    var json_obj_prefix: []const u8 = "";

    for (api_list.items) |api_json_basename| {
        const name = api_json_basename[0..api_json_basename.len-5];
        try out.print("    {s}\"{s}\": {{\n", .{json_obj_prefix, name});
        var file = try api_dir.dir.openFile(api_json_basename, .{});
        defer file.close();
        try pass1OnFile(out, api_json_basename, file);
        try out.writeAll("    }\n");
        json_obj_prefix = ",";
    }

    try out.writeAll("}\n");
    try buffered_writer.flush();
    try std.fs.cwd().rename("pass1.json.generating", "pass1.json");
    return 0;
}

fn pass1OnFile(out: OutWriter, filename: []const u8, file: std.fs.File) !void {
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);
    const parse_start = std.time.milliTimestamp();
    const start = if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) 3 else @as(usize, 0);
    var json_tree = blk: {
        var parser = json.Parser.init(allocator, false); // false is copy_strings
        defer parser.deinit();
        break :blk try parser.parse(content[start..]);
    };
    defer json_tree.deinit();
    const parse_time = std.time.milliTimestamp() - parse_start;
    std.log.info("{} ms: parse time for '{s}'", .{parse_time, filename});

    try pass1OnJson(out, filename, json_tree.root.Object);
}

fn writeType(out: OutWriter, json_obj_prefix: []const u8, name: []const u8, kind: []const u8) !void {
    try out.print("        {s}\"{s}\": {{\"Kind\":\"{s}\"}}\n", .{json_obj_prefix, name, kind});
}

fn pass1OnJson(out: OutWriter, filename: []const u8, root_obj: json.ObjectMap) !void {
    const types_array = (try jsonObjGetRequired(root_obj, "Types", filename)).Array;

    var json_obj_prefix: []const u8 = "";
    for (types_array.items) |*type_node| {
        const type_obj = type_node.Object;
        const kind = (try jsonObjGetRequired(type_obj, "Kind", filename)).String;
        const name = (try jsonObjGetRequired(type_obj, "Name", filename)).String;
        //const arches = ArchFlags.initJson((try jsonObjGetRequired(type_obj, "Architectures", filename)).Array.items);

        if (std.mem.eql(u8, kind, "ComClassID")) {
            continue;
        }

        if (std.mem.eql(u8, kind, "NativeTypedef")) {
            try generateNativeTypedef(out, filename, json_obj_prefix, type_obj, name);
        } else if (std.mem.eql(u8, kind, "Enum")) {
            try writeType(out, json_obj_prefix, name, "Enum");
        } else if (std.mem.eql(u8, kind, "Union")) {
            try writeType(out, json_obj_prefix, name, "Union");
        } else if (std.mem.eql(u8, kind, "Struct")) {
            try writeType(out, json_obj_prefix, name, "Struct");
        } else if (std.mem.eql(u8, kind, "FunctionPointer")) {
            try writeType(out, json_obj_prefix, name, "FunctionPointer");
        } else if (std.mem.eql(u8, kind, "Com")) {
            try writeType(out, json_obj_prefix, name, "Com");
        } else {
            jsonPanicMsg("{s}: unknown type Kind '{s}'", .{filename, kind});
        }
        json_obj_prefix = ",";
    }
}

const native_integral_types = std.ComptimeStringMap(Nothing, .{
    .{ "Byte", .{} },
    .{ "Int32", .{} }, .{ "UInt32", .{} },
    .{ "UInt64", .{} },
    .{ "IntPtr", .{} }, .{ "UIntPtr", .{} },
});

fn generateNativeTypedef(
    out: OutWriter,
    filename: []const u8,
    json_obj_prefix: []const u8,
    type_obj: std.json.ObjectMap,
    name: []const u8,
) !void {
    try jsonObjEnforceKnownFieldsOnly(type_obj, &[_][]const u8 {"Name", "Platform", "Architectures",
        "AlsoUsableFor", "Kind", "Def", "FreeFunc"}, filename);
    //const platform_node = try jsonObjGetRequired(type_obj, "Platform", sdk_file);
    //const also_usable_for_node = try jsonObjGetRequired(type_obj, "AlsoUsableFor", sdk_file);
    const def_type = (try jsonObjGetRequired(type_obj, "Def", filename)).Object;

    // HANDLE PSTR and PWSTR specially because win32metadata is not properly declaring them as arrays, only pointers
    // not sure if this is a real issue with the metadata or intentional
    const special : enum { pstr, pwstr, other } = blk: {
        if (std.mem.eql(u8, name, "PSTR")) break :blk .pstr;
        if (std.mem.eql(u8, name, "PWSTR")) break :blk .pwstr;
        break :blk .other;
    };
    if (special == .pstr or special == .pwstr) {
        try writeType(out, json_obj_prefix, name, "Pointer");
        return;
    }

    // we should be able to ignore also_usable_for_node because the def_type should be the same as the type being defined
    //switch (also_usable_for_node) {
    //    .String => |also_usable_for| {
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
    if (@import("handletypes.zig").std_handle_types.get(name)) |_| {
        try writeType(out, json_obj_prefix, name, "Pointer");
        return;
    }
    // workaround https://github.com/microsoft/win32metadata/issues/395
    if (@import("handletypes.zig").handle_types.get(name)) |_| {
        try writeType(out, json_obj_prefix, name, "Pointer");
        return;
    }

    const kind = (try jsonObjGetRequired(def_type, "Kind", filename)).String;
    if (std.mem.eql(u8, kind, "Native")) {
        try jsonObjEnforceKnownFieldsOnly(def_type, &[_][]const u8 {"Kind", "Name"}, filename);
        const native_type_name = (try jsonObjGetRequired(def_type, "Name", filename)).String;
        if (native_integral_types.get(native_type_name)) |_| {
            try writeType(out, json_obj_prefix, name, "Integral");
            return;
        }
        jsonPanicMsg("unhandled Native kind in NativeTypedef '{s}'", .{native_type_name});
    }

    if (std.mem.eql(u8, kind, "PointerTo")) {
        try writeType(out, json_obj_prefix, name, "Pointer");
        return;
    }

    jsonPanicMsg("unhandled NativeTypedef kind '{s}'", .{kind});
}

fn jsonObjGetRequired(map: json.ObjectMap, field: []const u8, file_for_error: []const u8) !json.Value {
    return map.get(field) orelse {
        // TODO: print file location?
        std.log.err("{s}: json object is missing '{s}' field: {}\n", .{file_for_error, field, fmtJson(map)});
        common.jsonPanic();
    };
}

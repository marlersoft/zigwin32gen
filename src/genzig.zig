const std = @import("std");
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const json = std.json;
const StringPool = @import("./stringpool.zig").StringPool;
const path_sep = std.fs.path.sep_str;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

const zig_keywords = [_][]const u8 {
    "defer", "align", "error", "resume", "suspend", "var", "callconv",
};
var global_zig_keyword_map = StringHashMap(bool).init(allocator);

const TypeMetadata = struct {
    builtin: bool,
};
const TypeEntry = struct {
    zig_type_from_pool: []const u8,
    metadata: TypeMetadata,
};

var global_void_type_from_pool_ptr : [*]const u8 = undefined;
var global_symbol_pool = StringPool.init(allocator);
var global_type_map = StringHashMap(TypeEntry).init(allocator);

var global_c_native_to_zig_map = StringHashMap([]const u8).init(allocator);

const Nothing = struct {};

const SdkFile = struct {
    json_basename: []const u8,
    name: []const u8,
    zig_filename: []const u8,
    includes: ArrayList([]const u8),
    type_refs: StringHashMap(TypeEntry),
    type_exports: StringHashMap(TypeEntry),
    func_exports: StringHashMap(Nothing),
    const_exports: ArrayList([]const u8),
    /// type_imports is made up of all the type_refs excluding any types that have been exported
    /// it is populated after all type_refs and type_exports have been analyzed
    type_imports: ArrayList([]const u8),

    pub fn create(json_basename: []const u8) !*SdkFile {
        const sdk_file = try allocator.create(SdkFile);
        const name = init: {
            const name_no_ext = json_basename[0..json_basename.len - ".json".len];
            if (std.mem.eql(u8, name_no_ext, "gdi+")) break :init "gdip";
            if (std.mem.eql(u8, name_no_ext, "microsoft_management_console_2.0")) break :init "microsoft_management_console_2_0";
            break :init name_no_ext;
        };
        sdk_file.* = .{
            .json_basename = json_basename,
            .name = name,
            .zig_filename = try std.mem.concat(allocator, u8, &[_][]const u8 {name, ".zig"}),
            .includes = ArrayList([]const u8).init(allocator),
            .type_refs = StringHashMap(TypeEntry).init(allocator),
            .type_exports = StringHashMap(TypeEntry).init(allocator),
            .func_exports = StringHashMap(Nothing).init(allocator),
            .const_exports = ArrayList([]const u8).init(allocator),
            .type_imports = ArrayList([]const u8).init(allocator),
        };
        return sdk_file;
    }

    pub fn addTypeRef(self: *SdkFile, type_entry: TypeEntry) !void {
        if (type_entry.metadata.builtin)
            return;
        try self.type_refs.put(type_entry.zig_type_from_pool, type_entry);
    }

    pub fn populateImports(self: *SdkFile) !void {
        var type_ref_it = self.type_refs.iterator();
        while (type_ref_it.next()) |kv| {
            std.debug.assert(!kv.value.metadata.builtin); // code verifies no builtin types get added to type_refs
            const symbol = kv.key;
            if (self.type_exports.contains(symbol))
                continue;
            try self.type_imports.append(symbol);
        }
    }
};

fn getTypeWithTempString(temp_string: []const u8) !TypeEntry {
    return getTypeWithPoolString(try global_symbol_pool.add(temp_string));
}
fn getTypeWithPoolString(pool_string: []const u8) !TypeEntry {
    return global_type_map.get(pool_string) orelse {
        const type_metadata = TypeEntry {
            .zig_type_from_pool = pool_string,
            .metadata = .{ .builtin = false },
        };
        try global_type_map.put(pool_string, type_metadata);
        return type_metadata;
    };
}

const SharedTypeExportEntry = struct {
    first_sdk_file_ptr: *SdkFile,
    duplicates: u32,
};

fn addCToZigType(c: []const u8, zig: []const u8) !void {
    const c_type_pool = try global_symbol_pool.add(c);
    const zig_type_pool = try global_symbol_pool.add(zig);
    const type_metadata = TypeEntry {
        .zig_type_from_pool = zig_type_pool,
        .metadata = .{ .builtin = true },
    };
    try global_type_map.put(c_type_pool, type_metadata);
    //try global_type_map.put(zig_type_pool, type_metadata);
}


const Times = struct {
    parse_time_millis : i64 = 0,
    read_time_millis : i64 = 0,
    generate_time_millis : i64 = 0,
};
var global_times = Times {};

pub fn main() !u8 {
    return main2() catch |e| switch (e) {
        error.AlreadyReported => return 0xff,
        else => return e,
    };
}
fn main2() !u8 {
    const main_start_millis = std.time.milliTimestamp();
    var print_time_summary = false;
    defer {
        if (print_time_summary) {
            var total_millis = std.time.milliTimestamp() - main_start_millis;
            if (total_millis == 0) total_millis = 1; // prevent divide by 0
            std.debug.warn("Parse Time: {} millis ({}%)\n", .{global_times.parse_time_millis, @divTrunc(100 * global_times.parse_time_millis, total_millis)});
            std.debug.warn("Read Time : {} millis ({}%)\n", .{global_times.read_time_millis , @divTrunc(100 * global_times.read_time_millis, total_millis)});
            std.debug.warn("Gen Time  : {} millis ({}%)\n", .{global_times.generate_time_millis , @divTrunc(100 * global_times.generate_time_millis, total_millis)});
            std.debug.warn("Total Time: {} millis\n", .{total_millis});
        }
    }

    for (zig_keywords) |keyword| {
        try global_zig_keyword_map.put(keyword, true);
    }

    {
        const void_type_from_pool = try global_symbol_pool.add("void");
        global_void_type_from_pool_ptr = void_type_from_pool.ptr;
        try global_type_map.put(void_type_from_pool, TypeEntry { .zig_type_from_pool = void_type_from_pool, .metadata = .{ .builtin = true } });
    }
    // TODO: should I have special case handling for the windws types like INT64, DWORD, etc?
    //       maybe I should just add comptime asserts for now, such as comptime { assert(@sizeOf(INT64) == 8) }, etc

    // native types taken from https://github.com/marler8997/windows-api/blob/master/nativetypes.py
    // NOTE: void is specially handled
    try global_c_native_to_zig_map.put("int", "c_int");
    try global_c_native_to_zig_map.put("unsigned", "c_uint");
    try global_c_native_to_zig_map.put("uint8_t", "u8");
    try global_c_native_to_zig_map.put("uint16_t", "u16");
    try global_c_native_to_zig_map.put("uint32_t", "u32");
    try global_c_native_to_zig_map.put("uint64_t", "u64");
    try global_c_native_to_zig_map.put("size_t", "usize");
    try global_c_native_to_zig_map.put("int8_t", "i8");
    try global_c_native_to_zig_map.put("int16_t", "i16");
    try global_c_native_to_zig_map.put("int32_t", "i32");
    try global_c_native_to_zig_map.put("int64_t", "i64");
    try global_c_native_to_zig_map.put("ssize_t", "isize");
    try global_c_native_to_zig_map.put("char", "u8");
    try global_c_native_to_zig_map.put("wchar_t", "u16");

    const windows_api_dir_name = "deps" ++ path_sep ++ "windows-api";
    // TODO: change this to a SHA!!!
    const windows_api_checkout = "master";
    var windows_api_dir = std.fs.cwd().openDir(windows_api_dir_name, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.warn("Error: repository '{}' does not exist, clone it with:\n", .{windows_api_dir_name});
            std.debug.warn("    git clone https://github.com/marler8997/windows-api {0}" ++ path_sep ++ windows_api_dir_name
                ++ " && git -C {0}" ++ path_sep ++ windows_api_dir_name ++ " checkout " ++ windows_api_checkout ++ " -b release\n", .{
                    try getcwd(allocator)
            });
            return error.AlreadyReported;
        },
        else => return e,
    };
    defer windows_api_dir.close();

    const func_dll_map = try loadDllJson(windows_api_dir_name, &windows_api_dir);

    const api_json_sub_path = "out" ++ path_sep ++ "json";
    var api_json_dir = windows_api_dir.openDir(api_json_sub_path, .{.iterate = true}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.warn("Error: JSON files have not been generated in '{}{}{}', generate them with:\n", .{windows_api_dir_name, path_sep, api_json_sub_path});
            std.debug.warn("    python3 {}" ++ path_sep ++ windows_api_dir_name ++ path_sep ++ "json-gen\n", .{try getcwd(allocator)});
            return error.AlreadyReported;
        },
        else => return e,
    };
    defer api_json_dir.close();

    const cwd = std.fs.cwd();

    const out_dir_string = "out";
    try cleanDir(cwd, out_dir_string);
    var out_dir = try cwd.openDir(out_dir_string, .{});
    defer out_dir.close();

    try out_dir.makeDir("windows");
    var out_windows_dir = try out_dir.openDir("windows", .{});
    defer out_windows_dir.close();

    var shared_type_export_map = StringHashMap(SharedTypeExportEntry).init(allocator);
    defer shared_type_export_map.deinit();

    var sdk_files = ArrayList(*SdkFile).init(allocator);
    defer sdk_files.deinit();
    {
        try out_windows_dir.makeDir("header");
        var out_header_dir = try out_windows_dir.openDir("header", .{});
        defer out_header_dir.close();

        // copy gluezig.zig module
        {
            var src_dir = try cwd.openDir("src", .{});
            defer src_dir.close();
            try src_dir.copyFile("gluezig.zig", out_header_dir, "gluezig.zig", .{});
        }

        std.debug.warn("-----------------------------------------------------------------------\n", .{});
        std.debug.warn("loading api json files...\n", .{});
        var dir_it = api_json_dir.iterate();
        while (try dir_it.next()) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) {
                std.debug.warn("Error: expected all files to end in '.json' but got '{}'\n", .{entry.name});
                return error.AlreadyReported;
            }
            std.debug.warn("loading '{}'\n", .{entry.name});
            //
            // TODO: would things run faster if I just memory mapped the file?
            //
            var file = try api_json_dir.openFile(entry.name, .{});
            defer file.close();
            try readAndGenerateApiFile(out_header_dir, func_dll_map, &sdk_files, entry.name, file);
        }

        // populate the shared_type_export_map
        for (sdk_files.items) |sdk_file| {
            var type_export_it = sdk_file.type_exports.iterator();
            while (type_export_it.next()) |kv| {
                const type_name = kv.key;
                if (shared_type_export_map.get(type_name)) |entry| {
                    // handle duplicates symbols (https://github.com/ohjeongwook/windows_sdk_data/issues/2)
                    // TODO: uncomment this warning after all types start being generated
                    // For now, a warning about this will be included in the generated everything.zig file below
                    //std.debug.warn("WARNING: type '{}' in '{}' conflicts with type in '{}'\n", .{
                    //    type_name, sdk_file.name, entry.first_sdk_file_ptr.name});
                    try shared_type_export_map.put(type_name, .{ .first_sdk_file_ptr = entry.first_sdk_file_ptr, .duplicates = entry.duplicates + 1 });
                } else {
                    try shared_type_export_map.put(type_name, .{ .first_sdk_file_ptr = sdk_file, .duplicates = 0 });
                }
            }
        }

        // Write the import footer for each file
        for (sdk_files.items) |sdk_file| {
            var out_file = try out_header_dir.openFile(sdk_file.zig_filename, .{.read = false, .write = true});
            defer out_file.close();
            try out_file.seekFromEnd(0);
            const writer = out_file.writer();
            try writer.writeAll(
                \\
                \\//=====================================================================
                \\// Imports
                \\//=====================================================================
                \\
            );
            try writer.print("usingnamespace struct {{\n", .{});
            for (sdk_file.type_imports.items) |type_name| {
                if (shared_type_export_map.get(type_name)) |entry| {
                    try writer.print("    pub const {} = @import(\"./{}.zig\").{};\n", .{type_name, entry.first_sdk_file_ptr.name, type_name});
                } else {
                    // TODO: uncomment this warning after all types start being generated
                    //std.debug.warn("WARNING: module '{}' uses undefined type '{}'\n", .{ sdk_file.name, type_name});
                    try writer.print("    pub const {} = c_int; // WARNING: this is a placeholder because this type is undefined\n", .{type_name});
                }
            }
            try writer.print("}};\n", .{});
        }
        {
            var header_file = try out_windows_dir.createFile("header.zig", .{});
            defer header_file.close();
            const writer = header_file.writer();
            try writer.writeAll("//! This file is autogenerated\n");
            try writer.print("pub const gluezig = @import(\"./header/gluezig.zig\");\n", .{});
            for (sdk_files.items) |sdk_file| {
                try writer.print("pub const {} = @import(\"./header/{}.zig\");\n", .{sdk_file.name, sdk_file.name});
            }
            try writer.writeAll(
                \\const std = @import("std");
                \\test "" {
                \\    std.testing.refAllDecls(@This());
                \\}
                \\
            );
        }

        {
            var everything_file = try out_windows_dir.createFile("everything.zig", .{});
            defer everything_file.close();
            const writer = everything_file.writer();
            try writer.writeAll(
                \\//! This file is autogenerated.
                \\//! This module contains aliases to ALL symbols inside the windows SDK.  It allows
                \\//! an application to access any and all symbols through a single import.
                \\
                \\pub const L = @import("./header/gluezig.zig").L;
            );

            // TODO: workaround issue where constants/functions are defined more than once, not sure what the right solution
            //       is for all these, maybe some modules are not compatible with each other.  This could just be the permanent
            //       solution as well, if there are conflicts, we could just say the user has to import the specific module they want.
            var shared_const_map = StringHashMap(*SdkFile).init(allocator);
            defer shared_const_map.deinit();
            var shared_func_map = StringHashMap(*SdkFile).init(allocator);
            defer shared_func_map.deinit();

            for (sdk_files.items) |sdk_file| {
                try writer.print("\nconst {} = @import(\"./header/{}.zig\");\n", .{sdk_file.name, sdk_file.name});
                try writer.print("// {} exports {} constants:\n", .{sdk_file.name, sdk_file.const_exports.items.len});
                for (sdk_file.const_exports.items) |constant| {
                    if (shared_const_map.get(constant)) |other_sdk_file| {
                        try writer.print("// WARNING: redifinition of constant '{}' in module '{}' (going with module '{}')\n", .{
                            constant, sdk_file.name, other_sdk_file.name});
                    } else {
                        try writer.print("pub const {} = {}.{};\n", .{constant, sdk_file.name, constant});
                        try shared_const_map.put(constant, sdk_file);
                    }
                }
                try writer.print("// {} exports {} types:\n", .{sdk_file.name, sdk_file.type_exports.count()});
                var export_it = sdk_file.type_exports.iterator();
                while (export_it.next()) |kv| {
                    const type_name = kv.key;
                    const type_entry = shared_type_export_map.get(type_name) orelse unreachable;
                    if (type_entry.first_sdk_file_ptr != sdk_file) {
                        try writer.print("// WARNING: type '{}.{}' has {} definitions, going with '{}'\n", .{
                            sdk_file.name, type_name, type_entry.duplicates + 1, type_entry.first_sdk_file_ptr.name});
                    } else {
                        try writer.print("pub const {} = {}.{};\n", .{type_name, sdk_file.name, type_name});
                    }
                }
                try writer.print("// {} exports {} functions:\n", .{sdk_file.name, sdk_file.func_exports.count()});
                var func_it = sdk_file.func_exports.iterator();
                while (func_it.next()) |kv| {
                    const func = kv.key;
                    if (shared_func_map.get(func)) |other_sdk_file| {
                        try writer.print("// WARNING: redifinition of function '{}' in module '{}' (going with module '{}')\n", .{
                            func, sdk_file.name, other_sdk_file.name});
                    } else {
                        try writer.print("pub const {} = {}.{};\n", .{func, sdk_file.name, func});
                        try shared_func_map.put(func, sdk_file);
                    }
                }
            }
        }
    }

    {
        var windows_file = try out_dir.createFile("windows.zig", .{});
        defer windows_file.close();
        const writer = windows_file.writer();
        try writer.writeAll(
            \\//! This file is autogenerated
            \\pub const header = @import("./windows/header.zig");
            \\pub const everything = @import("./windows/everything.zig");
            \\
            \\const std = @import("std");
            \\test "" {
            \\    std.testing.refAllDecls(@This());
            \\}
            \\
        );
    }
    print_time_summary = true;
    return 0;
}

const FuncDllEntry = struct {
    dlls: ArrayList([]const u8),
};
fn loadDllJson(windows_api_dir_name: []const u8, windows_api_dir: *std.fs.Dir) !StringHashMap(*FuncDllEntry) {
    const dll_json_sub_path = "out" ++ path_sep ++ "dll-json";
    var dll_json_dir = windows_api_dir.openDir(dll_json_sub_path, .{.iterate = true}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.warn("Error: dll JSON files have not been generated in '{}{}{}'.\n", .{windows_api_dir_name, path_sep, dll_json_sub_path});
            std.debug.warn("    !! Run the following in a Visual Studio Command Prompt !!\n", .{});
            std.debug.warn("    python3 {}{}{}{}dll-json-gen\n", .{
                try getcwd(allocator), path_sep, windows_api_dir_name, path_sep});
            return error.AlreadyReported;
        },
        else => return e,
    };
    defer dll_json_dir.close();

    var func_dll_map = StringHashMap(*FuncDllEntry).init(allocator);

    std.debug.warn("Loading dll json files...\n", .{});
    var dir_it = dll_json_dir.iterate();
    while (try dir_it.next()) |dir_entry| {
        const json_basename = dir_entry.name;
        if (!std.mem.endsWith(u8, json_basename, ".json")) {
            std.debug.warn("Error: expected all files to end in '.json' but got '{}'\n", .{json_basename});
            return error.AlreadyReported;
        }
        std.debug.warn("loading '{}'\n", .{json_basename});
        const dll_name = try global_symbol_pool.add(json_basename[0..json_basename.len - 5]);
        //
        // TODO: would things run faster if I just memory mapped the file?
        //
        var file = try dll_json_dir.openFile(json_basename, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(content);
        std.debug.warn("  read {} bytes\n", .{content.len});
        var parser = json.Parser.init(allocator, false); // false is copy_strings
        defer parser.deinit();
        var jsonTree = try parser.parse(content);
        defer jsonTree.deinit();
        for (jsonTree.root.Array.items) |func_node| {
            const func_obj = func_node.Object;
            try jsonObjEnforceKnownFieldsOnly(func_obj, &[_][]const u8 {"name", "ordinal"}, json_basename);
            const name_tmp = (try jsonObjGetRequired(func_obj, "name", json_basename)).String;
            const ordinal = (try jsonObjGetRequired(func_obj, "ordinal", json_basename)).Integer;
            const name_pool = try global_symbol_pool.add(name_tmp);
            var func_entry = init: {
                if (func_dll_map.get(name_pool)) |existing| break :init existing;
                var new_entry = try allocator.create(FuncDllEntry);
                new_entry.* = .{
                    .dlls = ArrayList([]const u8).init(allocator),
                };
                try func_dll_map.put(name_pool, new_entry);
                break :init new_entry;
            };
            try func_entry.dlls.append(dll_name);
        }
    }
    return func_dll_map;
}

fn readAndGenerateApiFile(out_dir: std.fs.Dir, func_dll_map: StringHashMap(*FuncDllEntry), sdk_files: *ArrayList(*SdkFile), json_basename: []const u8, file: std.fs.File) !void {

    const read_start_millis = std.time.milliTimestamp();
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    global_times.read_time_millis += std.time.milliTimestamp() - read_start_millis;
    defer allocator.free(content);
    std.debug.warn("  read {} bytes\n", .{content.len});

    // Parsing the JSON is VERY VERY SLOW!!!!!!
    var parser = json.Parser.init(allocator, false); // false is copy_strings
    defer parser.deinit();
    const parse_start_millis = std.time.milliTimestamp();
    var jsonTree = try parser.parse(content);
    global_times.parse_time_millis += std.time.milliTimestamp() - parse_start_millis;

    defer jsonTree.deinit();

    var sdk_file = try SdkFile.create(try std.mem.dupe(allocator, u8, json_basename));
    try sdk_files.append(sdk_file);
    const generate_start_millis = std.time.milliTimestamp();
    try generateFile(out_dir, func_dll_map, sdk_file, jsonTree);
    global_times.generate_time_millis += std.time.milliTimestamp() - generate_start_millis;
}

fn generateFile(out_dir: std.fs.Dir, func_dll_map: StringHashMap(*FuncDllEntry), sdk_file: *SdkFile, tree: json.ValueTree) !void {
    var out_file = try out_dir.createFile(sdk_file.zig_filename, .{});
    defer out_file.close();
    const out_writer = out_file.writer();

    try out_writer.writeAll("//! This file is autogenerated\n");
    // We can't import the everything module because it will re-introduce the same symbols we are exporting
    //try out_writer.print("usingnamespace @import(\"./everything.zig\");\n", .{});
    const root_obj = tree.root.Object;
    const includes_array = (try jsonObjGetRequired(root_obj, "includes", sdk_file)).Array;
    const types_array = (try jsonObjGetRequired(root_obj, "types", sdk_file)).Array;
    const constants_array = (try jsonObjGetRequired(root_obj, "constants", sdk_file)).Array;
    const functions_array = (try jsonObjGetRequired(root_obj, "functions", sdk_file)).Array;
    const unicode_names = (try jsonObjGetRequired(root_obj, "unicode_names", sdk_file)).Array;
    try out_writer.print("//\n", .{});
    try out_writer.print("// {} includes\n", .{includes_array.items.len});
    try out_writer.print("//\n", .{});
    for (includes_array.items) |include_node| {
        const include_obj = include_node.Object;
        try jsonObjEnforceKnownFieldsOnly(include_obj, &[_][]const u8 {"filename"}, sdk_file);
        const filename = (try jsonObjGetRequired(include_obj, "filename", sdk_file)).String;
        try out_writer.print("// this creates symbol conflicts because of: https://github.com/ziglang/zig/issues/7085\n", .{});
        try out_writer.print("// pub usingnamespace @import(\"./{}.zig\");\n", .{filename});
    }
    try out_writer.print("//\n", .{});
    try out_writer.print("// {} types\n", .{types_array.items.len});
    try out_writer.print("//\n", .{});
    for (types_array.items) |type_node| {
        try generateTypeLevelType(sdk_file, out_writer, type_node.Object);
    }
    try out_writer.print("//\n", .{});
    try out_writer.print("// {} constants\n", .{constants_array.items.len});
    try out_writer.print("//\n", .{});
    for (constants_array.items) |constant_node| {
        try generateConstant(sdk_file, out_writer, constant_node.Object);
    }
    try out_writer.print("//\n", .{});
    try out_writer.print("// {} functions\n", .{functions_array.items.len});
    try out_writer.print("//\n", .{});
    for (functions_array.items) |function_node| {
        try generateFunction(func_dll_map, sdk_file, out_writer, function_node.Object);
    }
    try out_writer.print("//\n", .{});
    try out_writer.print("// {} unicode_names\n", .{unicode_names.items.len});
    try out_writer.print("//\n", .{});
    for (unicode_names.items) |unicode_name_node| {
        try generateUnicodeName(sdk_file, out_writer, unicode_name_node.Object);
    }

    try sdk_file.populateImports();
    try out_writer.print(
        \\
        \\test "" {{
        \\    const type_import_count = {};
        \\    const constant_export_count = {};
        \\    const type_export_count = {};
        \\    const func_export_count = {};
        \\    @setEvalBranchQuota(type_import_count + constant_export_count + type_export_count + func_export_count);
        \\    @import("std").testing.refAllDecls(@This());
        \\}}
        \\
    , .{sdk_file.type_imports.items.len, sdk_file.const_exports.items.len, sdk_file.type_exports.count(), sdk_file.func_exports.count()});
}

fn typeIsVoid(type_obj: json.ObjectMap, sdk_file: *SdkFile) !bool {
    const kind = (try jsonObjGetRequired(type_obj, "kind", sdk_file)).String;
    if (std.mem.eql(u8, kind, "native")) {
        const name = (try jsonObjGetRequired(type_obj, "name", sdk_file)).String;
        return std.mem.eql(u8, name, "void");
    }
    return false;
}

fn addTypeRefs(sdk_file: *SdkFile, type_ref: json.ObjectMap) anyerror!void {
    const kind = (try jsonObjGetRequired(type_ref, "kind", sdk_file)).String;
    if (std.mem.eql(u8, kind, "native")) {
        try jsonObjEnforceKnownFieldsOnly(type_ref, &[_][]const u8 {"kind", "name"}, sdk_file);
    } else if (std.mem.eql(u8, kind, "alias")) {
        try jsonObjEnforceKnownFieldsOnly(type_ref, &[_][]const u8 {"kind", "name"}, sdk_file);
        const type_entry = try getTypeWithTempString((try jsonObjGetRequired(type_ref, "name", sdk_file)).String);
        try sdk_file.addTypeRef(type_entry);
    } else {
        const is_arrayptr = std.mem.eql(u8, kind, "arrayptr");
        if (is_arrayptr or std.mem.eql(u8, kind, "singleptr")) {
            try jsonObjEnforceKnownFieldsOnly(type_ref, &[_][]const u8 {"kind", "const", "subtype"}, sdk_file);
            try addTypeRefs(sdk_file, (try jsonObjGetRequired(type_ref, "subtype", sdk_file)).Object);
        } else if (std.mem.eql(u8, kind, "funcptr")) {
            try jsonObjEnforceKnownFieldsOnly(type_ref, &[_][]const u8 {"kind", "return_type", "args"}, sdk_file);
            try addTypeRefs(sdk_file, (try jsonObjGetRequired(type_ref, "return_type", sdk_file)).Object);
            for ((try jsonObjGetRequired(type_ref, "args", sdk_file)).Array.items) |arg_node| {
                const arg_obj = arg_node.Object;
                try jsonObjEnforceKnownFieldsOnly(arg_obj, &[_][]const u8 {"type", "name"}, sdk_file);
                try addTypeRefs(sdk_file, (try jsonObjGetRequired(arg_obj, "type", sdk_file)).Object);
            }
        } else {
            std.debug.assert(std.mem.eql(u8, kind, "fixedlenarray"));
            try jsonObjEnforceKnownFieldsOnly(type_ref, &[_][]const u8 {"kind", "len", "subtype"}, sdk_file);
            try addTypeRefs(sdk_file, (try jsonObjGetRequired(type_ref, "subtype", sdk_file)).Object);
        }
    }
}

const DepthContext = enum {top_level, child};
const TypeRefFormatter = struct {
    type_ref: json.ObjectMap,
    // we need to know if the type is the top-level type or a child type of something like a pointer
    // so we can generate the correct `void` type.  Top level void types become void, but pointers
    // to void types must become pointers to the `opaque{}` type.
    depth_context: DepthContext,
    sdk_file: *SdkFile,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) std.os.WriteError!void {
        const kind = (jsonObjGetRequired(self.type_ref, "kind", self.sdk_file) catch unreachable).String;
        if (std.mem.eql(u8, kind, "native")) {
            jsonObjEnforceKnownFieldsOnly(self.type_ref, &[_][]const u8 {"kind", "name"}, self.sdk_file) catch unreachable;
            const name = (jsonObjGetRequired(self.type_ref, "name", self.sdk_file) catch unreachable).String;
            // void is special
            if (std.mem.eql(u8, name, "void")) {
                try writer.writeAll(if (self.depth_context == .child) "opaque{}" else "void");
            } else {
                try writer.writeAll(global_c_native_to_zig_map.get(name) orelse std.debug.panic("unhandled native type '{}'", .{name}));
            }
        } else if (std.mem.eql(u8, kind, "alias")) {
            jsonObjEnforceKnownFieldsOnly(self.type_ref, &[_][]const u8 {"kind", "name"}, self.sdk_file) catch unreachable;
            try writer.writeAll((jsonObjGetRequired(self.type_ref, "name", self.sdk_file) catch unreachable).String);
        } else {
            const is_arrayptr = std.mem.eql(u8, kind, "arrayptr");
            if (is_arrayptr or std.mem.eql(u8, kind, "singleptr")) {
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // TODO: need to know if this is a sentinal terminated pointer
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                jsonObjEnforceKnownFieldsOnly(self.type_ref, &[_][]const u8 {"kind", "const", "subtype"}, self.sdk_file) catch unreachable;
                const is_const = (jsonObjGetRequired(self.type_ref, "const", self.sdk_file) catch unreachable).Bool;
                const subtype = (jsonObjGetRequired(self.type_ref, "subtype", self.sdk_file) catch unreachable).Object;
                try writer.writeAll(if (is_arrayptr) "?[*]" else "?*");
                if (is_const) {
                    try writer.writeAll("const ");
                }
                try formatTypeRef(subtype, .child, self.sdk_file).format(fmt, options, writer);
            } else if (std.mem.eql(u8, kind, "funcptr")) {
                jsonObjEnforceKnownFieldsOnly(self.type_ref, &[_][]const u8 {"kind", "return_type", "args"}, self.sdk_file) catch unreachable;
                try writer.writeAll("fn(");
                var arg_prefix : []const u8 = "";
                for ((jsonObjGetRequired(self.type_ref, "args", self.sdk_file) catch unreachable).Array.items) |arg_node| {
                    const arg_obj = arg_node.Object;
                    jsonObjEnforceKnownFieldsOnly(arg_obj, &[_][]const u8 {"name", "type"}, self.sdk_file) catch unreachable;
                    const arg_name = (jsonObjGetRequired(arg_obj, "name", self.sdk_file) catch unreachable).String;
                    const arg_type = (jsonObjGetRequired(arg_obj, "type", self.sdk_file) catch unreachable).Object;
                    try writer.print("{}{}: ", .{arg_prefix, arg_name});
                    try formatTypeRef(arg_type, .top_level, self.sdk_file).format(fmt, options, writer);
                    arg_prefix = ", ";
                }
                try writer.writeAll(") callconv(.Stdcall) ");
                const return_type = (jsonObjGetRequired(self.type_ref, "return_type", self.sdk_file) catch unreachable).Object;
                try formatTypeRef(return_type, .top_level, self.sdk_file).format(fmt, options, writer);
            } else {
                std.debug.assert(std.mem.eql(u8, kind, "fixedlenarray"));
                jsonObjEnforceKnownFieldsOnly(self.type_ref, &[_][]const u8 {"kind", "len", "subtype"}, self.sdk_file) catch unreachable;
                const len = (jsonObjGetRequired(self.type_ref, "len", self.sdk_file) catch unreachable).Integer;
                const subtype = (jsonObjGetRequired(self.type_ref, "subtype", self.sdk_file) catch unreachable).Object;
                try writer.print("[{}]", .{len});
                try formatTypeRef(subtype, .child, self.sdk_file).format(fmt, options, writer);
            }
        }
    }
};
pub fn formatTypeRef(type_ref: json.ObjectMap, depth_context: DepthContext, sdk_file: *SdkFile) TypeRefFormatter {
    return .{ .type_ref = type_ref, .depth_context = depth_context, .sdk_file = sdk_file };
}

fn generateTypeLevelType(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, type_obj: json.ObjectMap) !void {
    const kind = (try jsonObjGetRequired(type_obj, "kind", sdk_file)).String;
    const name_tmp = (try jsonObjGetRequired(type_obj, "name", sdk_file)).String;
    const type_entry = try getTypeWithTempString(name_tmp);
    if (type_entry.metadata.builtin) {
        std.debug.warn("Error: type '{}' is defined and builtin?\n", .{name_tmp});
        return error.AlreadyReported;
    }
    std.debug.assert(std.mem.eql(u8, name_tmp, type_entry.zig_type_from_pool));
    if (sdk_file.type_exports.get(name_tmp)) |type_entry_conflict| {
        // TODO: open an issue for these (there's over 600 redefinitions!)
        std.debug.warn("Error: redefinition of type '{}' in the same module\n", .{name_tmp});
        return error.AlreadyReported;
    }
    try sdk_file.type_exports.put(type_entry.zig_type_from_pool, type_entry);

    if (std.mem.eql(u8, kind, "typedef")) {
        try jsonObjEnforceKnownFieldsOnly(type_obj, &[_][]const u8 {"kind", "name", "definition"}, sdk_file);
        const def_type = (try jsonObjGetRequired(type_obj, "definition", sdk_file)).Object;
        try addTypeRefs(sdk_file, def_type);
        try out_writer.print("pub const {} = {};\n", .{name_tmp, formatTypeRef(def_type, .top_level, sdk_file)});
    } else if (std.mem.eql(u8, kind, "struct")) {
        try jsonObjEnforceKnownFieldsOnly(type_obj, &[_][]const u8 {"kind", "name", "fields"}, sdk_file);
        const struct_name = (try jsonObjGetRequired(type_obj, "name", sdk_file)).String;
        const fields = (try jsonObjGetRequired(type_obj, "fields", sdk_file)).Array;
        try out_writer.print("pub const {} = extern struct {{\n", .{struct_name});
        for (fields.items) |field_node| {
            const field_obj = field_node.Object;
            const field_name = (try jsonObjGetRequired(field_obj, "name", sdk_file)).String;
            const field_type = (try jsonObjGetRequired(field_obj, "type", sdk_file)).Object;
            try addTypeRefs(sdk_file, field_type);
            try out_writer.print("    {}: {},\n", .{field_name, formatTypeRef(field_type, .top_level, sdk_file)});
        }
        try out_writer.print("}};\n", .{});
    } else {
            std.debug.warn("{}: Error: unknown type kind '{}'", .{sdk_file.name, kind});
            return error.AlreadyReported;
    }
}
fn generateConstant(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, constant_obj: json.ObjectMap) !void {
    try jsonObjEnforceKnownFieldsOnly(constant_obj, &[_][]const u8 {"name", "type", "value"}, sdk_file);
    const name_tmp = (try jsonObjGetRequired(constant_obj, "name", sdk_file)).String;
    const constant_type = (try jsonObjGetRequired(constant_obj, "type", sdk_file)).Object;
    // TODO: need to resolve value_node correctly, it can reference other constants from
    //       other files
    const value_node = try jsonObjGetRequired(constant_obj, "value", sdk_file);

    const name_pool = try global_symbol_pool.add(name_tmp);
    try sdk_file.const_exports.append(name_pool);
    if (try typeIsVoid(constant_type, sdk_file)) {
        try out_writer.print("pub const {} = {};\n", .{name_pool, formatJson(value_node)});
    } else {
        try addTypeRefs(sdk_file, constant_type);
        try out_writer.print("pub const {} = @import(\"gluezig.zig\").typedConstant({}, {});\n", .{name_pool, formatTypeRef(constant_type, .top_level, sdk_file), formatJson(value_node)});
    }
}

fn generateFunction(func_dll_map: StringHashMap(*FuncDllEntry), sdk_file: *SdkFile, out_writer: std.fs.File.Writer, function_obj: json.ObjectMap) !void {
    try jsonObjEnforceKnownFieldsOnly(function_obj, &[_][]const u8 {"name", "return_type", "args"}, sdk_file);
    const func_name_tmp = (try jsonObjGetRequired(function_obj, "name", sdk_file)).String;
    const return_type = (try jsonObjGetRequired(function_obj, "return_type", sdk_file)).Object;
    const args = (try jsonObjGetRequired(function_obj, "args", sdk_file)).Array;

    const func_name_pool = try global_symbol_pool.add(func_name_tmp);
    try sdk_file.func_exports.put(func_name_pool, .{});

    const func_entry = func_dll_map.get(func_name_pool) orelse {
        std.debug.warn("Error: function '{}' is not in any dll json file\n", .{func_name_pool});
        return error.AlreadyReported;
    };
    if (func_entry.dlls.items.len != 1) {
        std.debug.warn("Error: function '{}' is found in these {} dlls:\n", .{func_name_pool, func_entry.dlls.items.len});
        for (func_entry.dlls.items) |dll| {
            std.debug.warn("    {}\n", .{dll});
        }
        return error.AlreadyReported;
    }

    try out_writer.print("pub extern \"{}\" fn {}(\n", .{func_entry.dlls.items[0], func_name_pool});
    for (args.items) |arg_node| {
        const arg_obj = arg_node.Object;
        try jsonObjEnforceKnownFieldsOnly(arg_obj, &[_][]const u8 {"name", "type"}, sdk_file);
        const arg_name = (try jsonObjGetRequired(arg_obj, "name", sdk_file)).String;
        const arg_type = (try jsonObjGetRequired(arg_obj, "type", sdk_file)).Object;
        try addTypeRefs(sdk_file, arg_type);
        try out_writer.print("    {}: {},\n", .{arg_name, formatTypeRef(arg_type, .top_level, sdk_file)});
    }
    try addTypeRefs(sdk_file, return_type);
    try out_writer.print(") callconv(.Stdcall) {};\n", .{formatTypeRef(return_type, .top_level, sdk_file)});
}

fn getPoolStringWithParts(a: *std.mem.Allocator, slices: []const []const u8) ![]const u8 {
    const tmp = try std.mem.concat(a, u8, slices);
    defer a.free(tmp);
    return try global_symbol_pool.add(tmp);
}

fn generateUnicodeName(sdk_file: *SdkFile, out_writer: std.fs.File.Writer, unicode_name_obj: json.ObjectMap) !void {
    try jsonObjEnforceKnownFieldsOnly(unicode_name_obj, &[_][]const u8 {"name"}, sdk_file);
    const name_tmp = (try jsonObjGetRequired(unicode_name_obj, "name", sdk_file)).String;

    const name_ansi_pool = try getPoolStringWithParts(allocator, &[_][]const u8 {name_tmp, "A"});
    const name_unicode_pool = try getPoolStringWithParts(allocator, &[_][]const u8 {name_tmp, "W"});

    const NameKind = enum { none, type, func };
    const ansi_kind : NameKind = init: {
        if (sdk_file.type_exports.get(name_ansi_pool)) |_| break :init .type;
        if (sdk_file.func_exports.get(name_ansi_pool)) |_| break :init .func;
        break :init .none;
    };
    const unicode_kind : NameKind = init: {
        if (sdk_file.type_exports.get(name_unicode_pool)) |_| break :init .type;
        if (sdk_file.func_exports.get(name_unicode_pool)) |_| break :init .func;
        break :init .none;
    };
    if (ansi_kind == .none and unicode_kind == .none) {
        std.debug.warn("Error: unicode name '{}' does not have a corresponding Ansi or Unicode name ({} or {})\n", .{name_tmp, name_ansi_pool, name_unicode_pool});
        return error.AlreadyReported;
    }
    if (ansi_kind != .none and unicode_kind != .none and ansi_kind != unicode_kind) {
        std.debug.warn("Error: ansi name '{}' is a {} but the unicode name '{}' is a {}\n", .{name_ansi_pool, ansi_kind, name_unicode_pool, unicode_kind});
        return error.AlreadyReported;
    }

    const name_pool = try global_symbol_pool.add(name_tmp);
    const common_kind = if (ansi_kind != .none) ansi_kind else unicode_kind;
    switch (common_kind) {
        .none => unreachable,
        .type => try sdk_file.type_exports.put(name_pool, try getTypeWithPoolString(name_pool)),
        .func => try sdk_file.func_exports.put(name_pool, .{}),
    }

    // TODO: would it be better to generate code that checks the unicode mode once for all symbols?
    try out_writer.print("pub const {} = switch (@import(\"gluezig.zig\").unicode_mode) {{\n", .{name_pool});
    if (ansi_kind == .none) {
        try out_writer.print("    .ansi    => @compileError(\"'{}' does not exist\"),\n", .{name_ansi_pool});
    } else {
        try out_writer.print("    .ansi    => {},\n", .{name_ansi_pool});
    }
    if (unicode_kind == .none) {
        try out_writer.print("    .unicode => @compileError(\"'{}' does not exist\"),\n", .{name_unicode_pool});
    } else {
        try out_writer.print("    .unicode => {},\n", .{name_unicode_pool});
    }
    try out_writer.print("    .unspecified => if (@import(\"builtin\").is_test) opaque{{}} else @compileError(\"Cannot call '{}' because the root module has not set UNICODE to true or false.\"),\n", .{name_pool});
    try out_writer.print("}};\n", .{});
}

//const CToZigSymbolFormatter = struct {
//    symbol: []const u8,
//    pub fn format(
//        self: @This(),
//        comptime fmt: []const u8,
//        options: std.fmt.FormatOptions,
//        writer: anytype,
//    ) !void {
//        if (global_zig_keyword_map.get(self.symbol) orelse false) {
//            try writer.print("@\"{}\"", .{self.symbol});
//        } else {
//            try writer.writeAll(self.symbol);
//        }
//    }
//};
//pub fn formatCToZigSymbol(symbol: []const u8) CToZigSymbolFormatter {
//    return .{ .symbol = symbol };
//}

//const FixIntegerLiteralFormatter = struct {
//    literal: []const u8,
//    is_c_int: bool,
//    pub fn format(
//        self: @This(),
//        comptime fmt: []const u8,
//        options: std.fmt.FormatOptions,
//        writer: anytype,
//    ) !void {
//        var literal = self.literal;
//        if (std.mem.endsWith(u8, literal, "UL") or std.mem.endsWith(u8, literal, "ul")) {
//            literal = literal[0..literal.len - 2];
//        } else if (std.mem.endsWith(u8, literal, "L") or std.mem.endsWith(u8, literal, "U")) {
//            literal = literal[0..literal.len - 1];
//        }
//        var radix : u8 = 10;
//        if (std.mem.startsWith(u8, literal, "0x")) {
//            literal = literal[2..];
//            radix = 16;
//        } else if (std.mem.startsWith(u8, literal, "0X")) {
//            std.debug.warn("[WARNING] found integer literal that begins with '0X' instead of '0x': '{}' (should probably file an issue)\n", .{self.literal});
//            literal = literal[2..];
//            radix = 16;
//        }
//
//        var literal_buf: [30]u8 = undefined;
//        if (self.is_c_int) {
//            // we have to parse the integer literal and convert it to a negative since Zig
//            // doesn't allow casting largs positive integer literals to c_int if they overflow 31 bits
//            const value = std.fmt.parseInt(i64, literal, radix) catch @panic("failed to parse integer literal (TODO: print better error)");
//            std.debug.assert(value >= 0); // negative not implemented, haven't found any yet
//            if (value > std.math.maxInt(c_int)) {
//                // TODO: print better error message if this fails
//                std.debug.assert(value <= std.math.maxInt(c_uint));
//                literal_buf[0] = '-';
//                literal = literal_buf[0..1 + std.fmt.formatIntBuf(literal_buf[1..],
//                    @as(i64, std.math.maxInt(c_uint)) + 1 - value, 10, false, .{})];
//                radix = 10;
//            }
//        }
//
//        const prefix : []const u8 = if (radix == 16) "0x" else "";
//        try writer.print("{}{}", .{prefix, literal});
//    }
//};
//pub fn fixIntegerLiteral(literal: []const u8, is_c_int: bool) FixIntegerLiteralFormatter {
//    return .{ .literal = literal, .is_c_int = is_c_int };
//}

//const CToZigPtrFormatter = struct {
//    type_name_from_pool: []const u8,
//    pub fn format(
//        self: @This(),
//        comptime fmt: []const u8,
//        options: std.fmt.FormatOptions,
//        writer: anytype,
//    ) !void {
//        if (self.type_name_from_pool.ptr == global_void_type_from_pool_ptr) {
//            try writer.writeAll("*c_void");
//        } else {
//            // TODO: would be nice if we could use either *T or [*]T zig pointer semantics
//            try writer.print("[*c]{}", .{self.type_name_from_pool});
//        }
//    }
//};
//pub fn formatCToZigPtr(type_name_from_pool: []const u8) CToZigPtrFormatter {
//    return .{ .type_name_from_pool = type_name_from_pool };
//}

pub fn SliceFormatter(comptime T: type) type { return struct {
    slice: []const T,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var first : bool = true;
        for (self.slice) |e| {
            if (first) {
                first = false;
            } else {
                try writer.writeAll(", ");
            }
            try std.fmt.format(writer, "{}", .{e});
        }
    }
};}
pub fn formatSliceT(comptime T: type, slice: []const T) SliceFormatter(T) {
    return .{ .slice = slice };
}
// TODO: implement this
//pub fn formatSlice(slice: anytype) SliceFormatter(T) {
//    return .{ .slice = slice };
//}

fn jsonObjEnforceKnownFieldsOnly(map: json.ObjectMap, known_fields: []const []const u8, file_thing: anytype) !void {
    if (@TypeOf(file_thing) == *SdkFile)
        return jsonObjEnforceKnownFieldsOnlyImpl(map, known_fields, file_thing.json_basename);
    if (@TypeOf(file_thing) == []const u8)
        return jsonObjEnforceKnownFieldsOnlyImpl(map, known_fields, file_thing);
    @compileError("unhandled file_thing type: " ++ @typeName(@TypeOf(file_thing)));
}

fn jsonObjEnforceKnownFieldsOnlyImpl(map: json.ObjectMap, known_fields: []const []const u8, file_for_error: []const u8) !void {
    var it = map.iterator();
    fieldLoop: while (it.next()) |kv| {
        for (known_fields) |known_field| {
            if (std.mem.eql(u8, known_field, kv.key))
                continue :fieldLoop;
        }
        std.debug.warn("{}: Error: JSON object has unknown field '{}', expected one of: {}\n", .{file_for_error, kv.key, formatSliceT([]const u8, known_fields)});
        return error.AlreadyReported;
    }
}

fn jsonObjGetRequired(map: json.ObjectMap, field: []const u8, file_thing: anytype) !json.Value {
    if (@TypeOf(file_thing) == *SdkFile)
        return jsonObjGetRequiredImpl(map, field, file_thing.json_basename);
    if (@TypeOf(file_thing) == []const u8)
        return jsonObjGetRequiredImpl(map, field, file_thing);
    @compileError("unhandled file_thing type: " ++ @typeName(@TypeOf(file_thing)));
}
fn jsonObjGetRequiredImpl(map: json.ObjectMap, field: []const u8, file_for_error: []const u8) !json.Value {
    return map.get(field) orelse {
        // TODO: print file location?
        std.debug.warn("{}: json object is missing '{}' field: {}\n", .{file_for_error, field, formatJson(map)});
        return error.AlreadyReported;
    };
}

const JsonFormatter = struct {
    value: json.Value,
    pub fn format(
        self: JsonFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try std.json.stringify(self.value, .{}, writer);
    }
};
pub fn formatJson(value: anytype) JsonFormatter {
    if (@TypeOf(value) == json.ObjectMap) {
        return .{ .value = .{ .Object = value } };
    }
    if (@TypeOf(value) == json.Array) {
        return .{ .value = .{ .Array = value } };
    }
    if (@TypeOf(value) == []json.Value) {
        return .{ .value = .{ .Array = json.Array  { .items = value, .capacity = value.len, .allocator = undefined } } };
    }
    return .{ .value = value };
}

fn cleanDir(dir: std.fs.Dir, sub_path: []const u8) !void {
    try dir.deleteTree(sub_path);
    const MAX_ATTEMPTS = 30;
    var attempt : u32 = 1;
    while (true) : (attempt += 1) {
        if (attempt > MAX_ATTEMPTS) {
            std.debug.warn("Error: failed to delete '{}' after {} attempts\n", .{sub_path, MAX_ATTEMPTS});
            return error.AlreadyReported;
        }
        // ERROR: windows.OpenFile is not handling error.Unexpected NTSTATUS=0xc0000056
        dir.makeDir(sub_path) catch |e| switch (e) {
            else => {
                std.debug.warn("[DEBUG] makedir failed with {}\n", .{e});
                //return error.AlreadyReported;
                continue;
            },
        };
        break;
    }

}

fn getcwd(a: *std.mem.Allocator) ![]u8 {
    var path_buf : [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.os.getcwd(&path_buf);
    const path_allocated = try a.alloc(u8, path.len);
    std.mem.copy(u8, path_allocated, path);
    return path_allocated;
}

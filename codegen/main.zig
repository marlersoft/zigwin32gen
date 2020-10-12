const std = @import("std");
const json = std.json;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

const SdkFile = struct {
    jsonFilename: []const u8,
    name: []const u8,
    symbols: std.ArrayList([]const u8),
};


//
// Temporary Filtering Code to disable invalid configuration
//
const SdkFileFilter = struct {
    functions: []const []const u8,
    pub fn filterFunc(self: SdkFileFilter, func: []const u8) bool {
        for (self.functions) |f| {
            if (std.mem.eql(u8, f, func))
                return true;
        }
        return false;
    }
};
const globalFileFilters = [_]struct {name: []const u8, filter: SdkFileFilter } {
    .{ .name = "scrnsave", .filter = .{
        .functions = &[_][]const u8 {
            // these functions are filtered because api_locations is invalid, it is just an array of one string "None"
            "ScreenSaverProc",
            "RegisterDialogClasses",
            "ScreenSaverConfigureDialog",
            "DefScreenSaverProc",
        },
    }},
    .{ .name = "perflib", .filter = .{
        .functions = &[_][]const u8 {
            // this function is defined twice (see https://github.com/ohjeongwook/windows_sdk_data/issues/3)
            "PerfStartProvider",
        },
    }},
    .{ .name = "ole", .filter = .{
        .functions = &[_][]const u8 {
            // these functions are defined twice
            "OleCreate",
            "OleCreateFromFile",
            "OleLoadFromStream",
            "OleSaveToStream",
            "OleDraw",
        },
    }},
};
fn getFilter(name: []const u8) ?*const SdkFileFilter {
    for (globalFileFilters) |*fileFilter| {
        if (std.mem.eql(u8, name, fileFilter.name))
            return &fileFilter.filter;
    }
    return null;
}


pub fn main() !u8 {
    return main2() catch |e| switch (e) {
        error.AlreadyReported => return 0xff,
        else => return e,
    };
}
fn main2() !u8 {
    var sdk_data_dir = try std.fs.cwd().openDir("windows_sdk_data\\data", .{.iterate = true});
    defer sdk_data_dir.close();

    const outDirString = "out";
    var cwd = std.fs.cwd();
    defer cwd.close();
    try cleanDir(cwd, outDirString);
    var outDir = try cwd.openDir(outDirString, .{});
    defer outDir.close();

    var sdkFiles = std.ArrayList(*SdkFile).init(allocator);
    defer sdkFiles.deinit();
    {
        try outDir.makeDir("windows");
        var outWindowsDir = try outDir.openDir("windows", .{});
        defer outWindowsDir.close();

        var dirIt = sdk_data_dir.iterate();
        while (try dirIt.next()) |entry| {
            // temporarily skip most files to speed up initial development
            //const optional_filter : ?[]const u8 = "f";
            const optional_filter : ?[]const u8 = null;
            if (optional_filter) |filter| {
                if (!std.mem.startsWith(u8, entry.name, filter)) {
                    std.debug.warn("temporarily skipping '{}'\n", .{entry.name});
                    continue;
                }
            }

            if (!std.mem.endsWith(u8, entry.name, ".json")) {
                std.debug.warn("Error: expected all files to end in '.json' but got '{}'\n", .{entry.name});
                return 1; // fail
            }
            if (std.mem.eql(u8, entry.name, "windows.json")) {
                // ignore this one, it's just an object with 3 empty arrays, not an array like all the others
                continue;
            }

            std.debug.warn("loading '{}'\n", .{entry.name});
            //
            // TODO: would things run faster if I just memory mapped the file?
            //
            var file = try sdk_data_dir.openFile(entry.name, .{});
            defer file.close();
            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(content);
            std.debug.warn("  read {} bytes\n", .{content.len});

            // Parsing the JSON is VERY VERY SLOW!!!!!!
            var parser = json.Parser.init(allocator, false); // false is copy_strings
            defer parser.deinit();
            var jsonTree = try parser.parse(content);
            defer jsonTree.deinit();

            const sdkFile = try allocator.create(SdkFile);
            const jsonFilename = try std.mem.dupe(allocator, u8, entry.name);
            sdkFile.* = .{
                .jsonFilename = jsonFilename,
                .name = jsonFilename[0..jsonFilename.len - ".json".len],
                .symbols = std.ArrayList([]const u8).init(allocator),
            };
            try sdkFiles.append(sdkFile);
            try generateFile(outWindowsDir, jsonTree, sdkFile);
        }
    }

    {
        var symbolFile = try outDir.createFile("windows.zig", .{});
        defer symbolFile.close();
        const writer = symbolFile.writer();
        for (sdkFiles.items) |sdkFile| {
            try writer.print("pub const {} = @import(\"./windows/{}.zig\");\n", .{sdkFile.name, sdkFile.name});
        }
        try writer.writeAll(
            \\
            \\const std = @import("std");
            \\test "" {
            \\    std.meta.refAllDecls(@This());
            \\}
            \\
        );
    }

    // find duplicates symbols (https://github.com/ohjeongwook/windows_sdk_data/issues/2)
    var symbolCountMap = std.StringHashMap(u32).init(allocator);
    defer symbolCountMap.deinit();
    for (sdkFiles.items) |sdkFile| {
        for (sdkFile.symbols.items) |symbol| {
            if (symbolCountMap.get(symbol)) |count| {
                try symbolCountMap.put(symbol, count + 1);
            } else {
                try symbolCountMap.put(symbol, 1);
            }
        }
    }
    {
        var symbolFile = try outDir.createFile("symbols.zig", .{});
        defer symbolFile.close();
        const writer = symbolFile.writer();
        for (sdkFiles.items) |sdkFile| {
            try writer.writeAll(
                \\ //! This module contains aliases to ALL symbols inside the windows SDK.  It allows
                \\ //! an application to access any and all symbols through a single import.
                \\
            );
            try writer.print("\nconst {} = @import(\"./windows/{}.zig\");\n", .{sdkFile.name, sdkFile.name});
            for (sdkFile.symbols.items) |symbol| {
                const count = symbolCountMap.get(symbol) orelse @panic("codebug");
                if (count != 1) {
                    try writer.print("// symbol '{}.{}' has {} conflicts\n", .{sdkFile.name, symbol, count});
                } else {
                    try writer.print("pub const {} = {}.{};\n", .{symbol, sdkFile.name, symbol});
                }
            }
        }
    }
    return 0;
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

fn generateFile(outDir: std.fs.Dir, tree: json.ValueTree, sdkFile: *SdkFile) !void {
    const filename = try std.mem.concat(allocator, u8, &[_][]const u8 {sdkFile.name, ".zig"});
    defer allocator.free(filename);
    var outFile = try outDir.createFile(filename, .{});
    defer outFile.close();
    const outWriter = outFile.writer();

    // Temporary filter code
    const optional_filter = getFilter(sdkFile.name);

    const entryArray = tree.root.Array;
    try outWriter.print("// {}: {} items\n", .{sdkFile.name, entryArray.items.len});
    // We can't import the symbols module because it will re-introduce the same symbols we are exporting
    //try outWriter.print("usingnamespace @import(\"../symbols.zig\");\n", .{});
    for (entryArray.items) |declNode| {
        const declObj = declNode.Object;
        const optional_data_type = declObj.get("data_type");

        if (optional_data_type) |data_type_node| {
            const data_type = data_type_node.String;
            if (std.mem.eql(u8, data_type, "FuncDecl")) {
                const name = (try jsonObjGetRequired(declObj, "name", sdkFile.jsonFilename)).String;

                if (optional_filter) |filter| {
                    if (filter.filterFunc(name)) {
                        try outWriter.print("// FuncDecl has been filtered: {}\n", .{formatJson(declNode)});
                        continue;
                    }
                }
                try jsonObjEnforceKnownFields(declObj, &[_][]const u8 {"data_type", "name", "arguments", "api_locations", "type"}, sdkFile.jsonFilename);

                const arguments = (try jsonObjGetRequired(declObj, "arguments", sdkFile.jsonFilename)).Array;
                const optional_api_locations = declObj.get("api_locations");
                const return_type = try jsonObjGetRequired(declObj, "type", sdkFile.jsonFilename);
                if (optional_api_locations) |api_locations_node| {
                    const api_locations = api_locations_node.Array;
                    try outWriter.print("// FuncDecl JSON: {}\n", .{formatJson(declNode)});
                    try outWriter.print("// Function '{}' has the following {} api_locations:\n", .{name, api_locations.items.len});
                    var first_dll : ?[]const u8 = null;
                    for (api_locations.items) |api_location_node| {
                        const api_location = api_location_node.String;
                        try outWriter.print("// - {}\n", .{api_location});

                        // TODO: probably use endsWithIgnoreCase instead of checking each case
                        if (std.mem.endsWith(u8, api_location, ".dll") or std.mem.endsWith(u8, api_location, ".Dll")) {
                            if (first_dll) |f| { } else {
                                first_dll = api_location;
                            }
                        } else if (std.mem.endsWith(u8, api_location, ".lib")) {
                        } else if (std.mem.endsWith(u8, api_location, ".sys")) {
                        } else if (std.mem.endsWith(u8, api_location, ".h")) {
                        } else if (std.mem.endsWith(u8, api_location, ".cpl")) {
                        } else if (std.mem.endsWith(u8, api_location, ".exe")) {
                        } else if (std.mem.endsWith(u8, api_location, ".drv")) {
                        } else {
                            std.debug.warn("{}: Error: in function '{}', api_location '{}' does not have one of these extensions: dll, lib, sys, h, cpl, exe, drv\n", .{
                                sdkFile.jsonFilename, name, api_location});
                            return error.AlreadyReported;
                        }
                    }
                    if (first_dll == null) {
                        try outWriter.print("// function '{}' is not in a dll, so omitting its declaration\n", .{name});
                        //std.debug.warn("{}: function '{}' has no dll in its {} api_location(s):\n", .{sdkFile.jsonFilename, name, api_locations.items.len});
                        //for (api_locations.items) |api_location_node| {
                        //    std.debug.warn("    - {}\n", .{api_location_node.String});
                        //}
                        //return error.AlreadyReported;
                    } else {
                        const extern_string = first_dll.?[0 .. first_dll.?.len - ".dll".len];
                        try outWriter.print("pub extern \"{}\" fn {}() void;\n", .{extern_string, name});
                    }
                } else {
                    try outWriter.print("// FuncDecl with no api_locations (is this a compiler intrinsic or something?): {}\n", .{formatJson(declNode)});
                }
            } else {
                try outWriter.print("// data_type '{}': {}\n", .{data_type, formatJson(declNode)});
            }
        } else {
            try jsonObjEnforceKnownFields(declObj, &[_][]const u8 {"name", "type"}, sdkFile.jsonFilename);
            const name = (try jsonObjGetRequired(declObj, "name", sdkFile.jsonFilename)).String;
            const type_value = try jsonObjGetRequired(declObj, "type", sdkFile.jsonFilename);
            switch (type_value) {
                .String => |s| {
                    if (std.mem.eql(u8, s, "unsigned long")) {
                        try outWriter.print("pub const {} = u32;\n", .{name});
                    } else {
                        try outWriter.print("// const {} = (String) {}\n", .{name, formatJson(type_value)});
                    }
                    try sdkFile.symbols.append(try std.mem.dupe(allocator, u8, name));
                },
                else => {
                    try outWriter.print("// const {} = {}\n", .{name, formatJson(type_value)});
                },
            }
        }
        // orelse {
        //    std.debug.warn("{}: json object missing 'data_type' field:\n", .{sdkFile.name});
        //    try std.json.stringify(declNode, .{}, std.io.getStdErr().writer());
        //    return 1;
        //}).String;
    }
}

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

fn jsonObjEnforceKnownFields(map: json.ObjectMap, knownFields: []const []const u8, fileForError: []const u8) !void {
    var it = map.iterator();
    fieldLoop: while (it.next()) |kv| {
        for (knownFields) |knownField| {
            if (std.mem.eql(u8, knownField, kv.key))
                continue :fieldLoop;
        }
        std.debug.warn("{}: Error: JSON object has unknown field '{}', expected one of: {}\n", .{fileForError, kv.key, formatSliceT([]const u8, knownFields)});
        return error.AlreadyReported;
    }
}

fn jsonObjGetRequired(map: json.ObjectMap, field: []const u8, fileForError: []const u8) !json.Value {
    return map.get(field) orelse {
        // TODO: print file location?
        std.debug.warn("{}: json object is missing '{}' field\n", .{fileForError, field});
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
    return .{ .value = value };
}

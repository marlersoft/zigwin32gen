const std = @import("std");
const json = std.json;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

const SdkFile = struct {
    jsonFilename: []const u8,
    name: []const u8,
    symbols: std.ArrayList([]const u8),
    //tree: json.ValueTree,
};

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
    {
        var symbolFile = try outDir.createFile("symbols.zig", .{});
        defer symbolFile.close();
        const writer = symbolFile.writer();
        for (sdkFiles.items) |sdkFile| {
            try writer.print("\nconst {} = @import(\"./windows/{}.zig\");\n", .{sdkFile.name, sdkFile.name});
            for (sdkFile.symbols.items) |symbol| {
                try writer.print("pub const {} = {}.{};\n", .{symbol, sdkFile.name, symbol});
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

    const entryArray = tree.root.Array;
    try outWriter.print("// {}: {} items\n", .{sdkFile.name, entryArray.items.len});
    try outWriter.print("usingnamespace @import(\"../symbols.zig\");\n", .{});
    for (entryArray.items) |declNode| {
        const declObj = declNode.Object;
        const optional_data_type = declObj.get("data_type");

        if (optional_data_type) |data_type_node| {
            const data_type = data_type_node.String;
            try outWriter.print("// data_type '{}': {}n", .{data_type, formatJson(declNode)});
        } else {
            const name = (declObj.get("name") orelse @panic("missing 'name'")).String;
            const type_value = declObj.get("type") orelse @panic("missing 'type'");
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

const JsonFormatter = struct {
    value: json.Value,
    pub fn format(
        self: JsonFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        try std.json.stringify(self.value, .{}, out_stream);
    }
};
pub fn formatJson(value: anytype) JsonFormatter {
    return .{ .value = value };
}

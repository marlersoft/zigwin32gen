const std = @import("std");
const json = std.json;

const common = @import("common.zig");
const StringPool = @import("stringpool.zig").StringPool;

fn oom(e: error{OutOfMemory}) noreturn { @panic(@errorName(e)); }

const jsonObjGetRequired = common.jsonObjGetRequired;
const jsonObjEnforceKnownFieldsOnly = common.jsonObjEnforceKnownFieldsOnly;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn fatalTrace(trace: ?*std.builtin.StackTrace, comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    if (trace) |t| {
        std.debug.dumpStackTrace(t.*);
    } else {
        std.log.err("no error return trace", .{});
    }
    std.process.exit(0xff);
}

pub fn main() !u8 {
    const start_time = std.time.milliTimestamp();
    const all_args = try std.process.argsAlloc(allocator);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 2) {
        std.log.err("expected 2 arguments but got {}", .{cmd_args.len});
        return 1;
    }
    const win32json_path = cmd_args[0];
    const out_path = cmd_args[1];

    var win32json_dir = try std.fs.cwd().openDir(win32json_path, .{});
    defer win32json_dir.close();

    var api_dir = try win32json_dir.openDir("api", .{ .iterate = true });
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
    std.mem.sort([]const u8, api_list.items, {}, common.asciiLessThanIgnoreCase);


    try common.cleanDir(std.fs.cwd(), out_path);
    var out_dir = try std.fs.cwd().openDir(out_path, .{});
    defer out_dir.close();


    var dll_jsons = DllJsons{
        .out_dir = out_dir,
        .string_pool = StringPool.init(allocator),
    };

    for (api_list.items) |api_json_basename| {
        const content = blk: {
            var file = try api_dir.openFile(api_json_basename, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        };
        defer allocator.free(content);
        const start = if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) 3 else @as(usize, 0);
        var json_tree = blk: {
            // TODO: call parseFromSliceLeaky because we are using an arena allocator?
            break :blk json.parseFromSlice(json.Value, allocator, content[start..], .{}) catch |e|
                fatalTrace(@errorReturnTrace(), "failed to parse '{s}' with {s}", .{api_json_basename, @errorName(e)});
        };
        defer json_tree.deinit();
        const root_obj = json_tree.value.object;
        try jsonObjEnforceKnownFieldsOnly(root_obj, &.{ "Constants", "Types", "Functions", "UnicodeAliases" }, api_json_basename);
        const functions = (try jsonObjGetRequired(root_obj, "Functions", api_json_basename)).array;
        try writeFunctions(&dll_jsons, api_json_basename, functions);
        dll_jsons.closeAll();
    }

    std.log.info("finalizing DLL json files...", .{});
    {
        var it = dll_jsons.dll_map.iterator();
        while (it.next()) |entry| {
            const out_json = try dll_jsons.open(entry.key_ptr.*);
            std.debug.assert(out_json.is_first == false);
            defer out_json.file.close();
            try out_json.file.writer().writeAll("]\n");
        }
    }
    const run_time = std.time.milliTimestamp() - start_time;
    std.log.info("took {} ms to write {} DLL json files to {s}", .{run_time, dll_jsons.dll_map.size, out_path});
    return 0;
}

const DllJson = struct {
    maybe_open_file: ?std.fs.File = null,
    fn close(self: *DllJson) void {
        if (self.maybe_open_file) |*open_file| {
            open_file.close();
            self.maybe_open_file = null;
        }
    }
};

const DllJsons = struct {
    out_dir: std.fs.Dir,
    string_pool: StringPool,
    dll_map: std.StringHashMapUnmanaged(DllJson) = .{},
    pub fn closeAll(self: DllJsons) void {
        var it = self.dll_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.close();
        }
    }
    pub fn open(self: *DllJsons, dll_import: []const u8) !struct {
        is_first: bool,
        file: std.fs.File,
    } {
        const dll_import_pool = blk: {
            var lower_buf: [100]u8 = undefined;
            const lower = std.ascii.lowerString(&lower_buf, dll_import);
            break :blk try self.string_pool.add(lower);
        };
        const entry = self.dll_map.getOrPut(allocator, dll_import_pool.slice) catch |e| oom(e);

        const file = blk: {
            if (entry.found_existing) {
                if (entry.value_ptr.maybe_open_file) |f| break :blk f;
                const file = try self.out_dir.openFile(
                    dll_import_pool.slice,
                    .{ .mode = .write_only },
                );
                try file.seekFromEnd(0);
                entry.value_ptr.maybe_open_file = file;
                break :blk file;
            }

            std.log.info("new dll '{s}'", .{dll_import_pool});
            const file = try self.out_dir.createFile(
                dll_import_pool.slice,
                .{},
            );
            entry.value_ptr.* = .{ .maybe_open_file = file };
            break :blk file;
        };
        return .{
            .is_first = !entry.found_existing,
            .file = file,
        };
    }
};

fn writeFunctions(
    dll_jsons: *DllJsons,
    json_basename: []const u8,
    functions: json.Array,
) !void {
    // TODO: keep a set of all currently open dll files

    for (functions.items) |*function_node_ptr| {
        const function_obj = function_node_ptr.object;
        try jsonObjEnforceKnownFieldsOnly(function_obj, &.{
            "Name", "Platform", "Architectures", "SetLastError", "DllImport",
            "ReturnType", "ReturnAttrs", "Attrs", "Params",
        }, json_basename);
        const dll_import = (try jsonObjGetRequired(function_obj, "DllImport", json_basename)).string;
        const out_json = try dll_jsons.open(dll_import);
        const prefix: []const u8 = if (out_json.is_first) "[\n " else ",";
        try out_json.file.writer().writeAll(prefix);
        try json.stringify(function_node_ptr.*, .{}, out_json.file.writer());
        try out_json.file.writer().writeAll("\n");
    }
}

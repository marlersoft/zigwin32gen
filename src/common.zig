const std = @import("std");

const path_sep = std.fs.path.sep_str;

pub const Nothing = struct {};

pub fn getcwd(a: *std.mem.Allocator) ![]u8 {
    var path_buf : [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.os.getcwd(&path_buf);
    const path_allocated = try a.alloc(u8, path.len);
    std.mem.copy(u8, path_allocated, path);
    return path_allocated;
}

pub fn openWin32JsonDir(repo_root: std.fs.Dir) !std.fs.Dir {
    const win32json_dir_name = "deps" ++ path_sep ++ "win32json";
    const win32json_branch = "10.2.118-preview";
    return repo_root.openDir(win32json_dir_name, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.warn("Error: repository '{s}' does not exist, clone it with:\n", .{win32json_dir_name});
            std.debug.warn("    git clone https://github.com/marlersoft/win32json " ++
                "{s}" ++ path_sep ++ win32json_dir_name ++
                " -b " ++ win32json_branch ++ "\n", .{
                try getcwd(std.heap.page_allocator)
            });
            return error.AlreadyReported;
        },
        else => return e,
    };
}

pub fn readApiList(api_dir: std.fs.Dir, api_list: *std.ArrayList([]const u8)) !void {
    var dir_it = api_dir.iterate();
    while (try dir_it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) {
            std.debug.warn("Error: expected all files to end in '.json' but got '{s}'\n", .{entry.name});
            return error.AlreadyReported;
        }
        try api_list.append(try api_list.allocator.dupe(u8, entry.name));
    }
}

pub fn asciiLessThanIgnoreCase(_: Nothing, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(lhs, rhs);
}

fn SliceFormatter(comptime T: type, comptime spec: []const u8) type { return struct {
    slice: []const T,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var first : bool = true;
        for (self.slice) |e| {
            if (first) {
                first = false;
            } else {
                try writer.writeAll(", ");
            }
            try std.fmt.format(writer, "{" ++ spec ++ "}", .{e});
        }
    }
};}
pub fn formatSliceT(comptime T: type, comptime spec: []const u8, slice: []const T) SliceFormatter(T, spec) {
    return .{ .slice = slice };
}
// TODO: implement this
//pub fn formatSlice(slice: anytype) SliceFormatter(T) {
//    return .{ .slice = slice };
//}

pub fn jsonPanic() noreturn {
    @panic("an assumption about the json format was violated");
}
pub fn jsonPanicMsg(comptime msg: []const u8, args: anytype) noreturn {
    std.debug.panic("an assumption about the json format was violated: " ++ msg, args);
}

pub fn jsonEnforce(cond: bool) void {
    if (!cond) {
        jsonPanic();
    }
}
pub fn jsonEnforceMsg(cond: bool, comptime msg: []const u8, args: anytype) void {
    if (!cond) {
        jsonPanicMsg(msg, args);
    }
}

pub fn jsonObjEnforceKnownFieldsOnly(map: std.json.ObjectMap, known_fields: []const []const u8, file_for_error: []const u8) !void {
    var it = map.iterator();
    fieldLoop: while (it.next()) |kv| {
        for (known_fields) |known_field| {
            if (std.mem.eql(u8, known_field, kv.key_ptr.*))
                continue :fieldLoop;
        }
        std.debug.warn("{s}: Error: JSON object has unknown field '{s}', expected one of: {}\n", .{file_for_error, kv.key_ptr.*, formatSliceT([]const u8, "s", known_fields)});
        jsonPanic();
    }
}

const JsonFormatter = struct {
    value: std.json.Value,
    pub fn format(
        self: JsonFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.json.stringify(self.value, .{}, writer);
    }
};
pub fn fmtJson(value: anytype) JsonFormatter {
    if (@TypeOf(value) == std.json.ObjectMap) {
        return .{ .value = .{ .Object = value } };
    }
    if (@TypeOf(value) == std.json.Array) {
        return .{ .value = .{ .Array = value } };
    }
    if (@TypeOf(value) == []std.json.Value) {
        return .{ .value = .{ .Array = std.json.Array  { .items = value, .capacity = value.len, .allocator = undefined } } };
    }
    return .{ .value = value };
}

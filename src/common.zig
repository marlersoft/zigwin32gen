const std = @import("std");

const path_sep = std.fs.path.sep_str;

pub const Nothing = struct {};

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

const Time = i128;

pub fn getModifyTime(dir: std.fs.Dir, path: []const u8) !?Time {
    const pass1_file = dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer pass1_file.close();
    return (try pass1_file.stat()).mtime;
}

pub fn win32jsonIsNewerThan(win32json_dir: std.fs.Dir, time: Time) !bool {
    var api_dir = try win32json_dir.openIterableDir("api", .{}) ;
    defer api_dir.close();

    var dir_it = api_dir.iterate();
    while (try dir_it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json"))
            fatal("expected all files to end in '.json' but got '{s}'", .{entry.name});

        // TODO: should be able to get stat without opening file
        const file = try api_dir.dir.openFile(entry.name, .{});
        defer file.close();
        const stat = try file.stat();
        if (stat.mtime > time) {
            std.log.info("file '{s}' is newer than pass1.json", .{entry.name});
            return true;
        }
        //std.log.info("'{s}' time {} is older than {}", .{entry.name, stat.mtime, mtime});
    }

    return false;
}

pub fn getcwd(a: std.mem.Allocator) ![]u8 {
    var path_buf : [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.os.getcwd(&path_buf);
    const path_allocated = try a.alloc(u8, path.len);
    std.mem.copy(u8, path_allocated, path);
    return path_allocated;
}

pub fn readApiList(api_dir: std.fs.IterableDir, api_list: *std.ArrayList([]const u8)) !void {
    var dir_it = api_dir.iterate();
    while (try dir_it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) {
            std.log.err("expected all files to end in '.json' but got '{s}'\n", .{entry.name});
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
        std.log.err("{s}: JSON object has unknown field '{s}', expected one of: {}\n", .{file_for_error, kv.key_ptr.*, formatSliceT([]const u8, "s", known_fields)});
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

// TODO: this should be in std, maybe  method on HashMap?
pub fn allocMapValues(alloc: std.mem.Allocator, comptime T: type, map: anytype) ![]T {
    var values = try alloc.alloc(T, map.count());
    errdefer alloc.free(values);
    {
        var i: usize = 0;
        var it = map.iterator();
        while (it.next()) |entry| : (i += 1) {
            values[i] = entry.value_ptr.*;
        }
        std.debug.assert(i == map.count());
    }
    return values;
}

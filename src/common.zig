const std = @import("std");
const metadata = @import("metadata.zig");

const path_sep = std.fs.path.sep_str;

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

pub fn getcwd(a: std.mem.Allocator) ![]u8 {
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.os.getcwd(&path_buf);
    const path_allocated = try a.alloc(u8, path.len);
    @memcpy(path_allocated, path);
    return path_allocated;
}

pub fn readApiList(api_dir: std.fs.Dir, api_list: *std.ArrayList([]const u8)) !void {
    var dir_it = api_dir.iterate();
    while (try dir_it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) {
            std.log.err("expected all files to end in '.json' but got '{s}'\n", .{entry.name});
            return error.AlreadyReported;
        }
        try api_list.append(try api_list.allocator.dupe(u8, entry.name));
    }
}

pub fn asciiLessThanIgnoreCase(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(lhs, rhs);
}

fn SliceFormatter(comptime T: type, comptime spec: []const u8) type {
    return struct {
        slice: []const T,
        pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
            var first: bool = true;
            for (self.slice) |e| {
                if (first) {
                    first = false;
                } else {
                    try writer.writeAll(", ");
                }
                try writer.printValue(spec, .{}, e, std.options.fmt_max_depth);
            }
        }
    };
}
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

const JsonFormatter = struct {
    value: std.json.Value,
    pub fn format(self: JsonFormatter, writer: *std.io.Writer) std.io.Writer.Error!void {
        switch (self.value) {
            // avoid issues where std.json adds quotes to big numbers
            // (potential fix: https://github.com/ziglang/zig/pull/16707)
            .integer => |i| try writer.printInt(i, 10, .lower, .{}),
            .number_string => |s| try writer.writeAll(s),
            else => {
                // Adapting the new writer API to the old one: https://github.com/ziglang/zig/issues/24468
                const Adapter = struct {
                    fn writeFn(context: *std.io.Writer, bytes: []const u8) std.io.Writer.Error!usize {
                        return try context.write(bytes);
                    }
                };

                const adapter: std.io.GenericWriter(
                    *std.io.Writer,
                    std.io.Writer.Error,
                    Adapter.writeFn,
                ) = .{ .context = writer };

                try std.json.stringify(self.value, .{}, adapter);
            },
        }
    }
};
pub fn fmtJson(value: anytype) JsonFormatter {
    if (@TypeOf(value) == std.json.ObjectMap) {
        return .{ .value = .{ .object = value } };
    }
    if (@TypeOf(value) == std.json.Array) {
        return .{ .value = .{ .array = value } };
    }
    if (@TypeOf(value) == []std.json.Value) {
        return .{ .value = .{ .array = std.json.Array{ .items = value, .capacity = value.len, .allocator = undefined } } };
    }
    return .{ .value = value };
}

pub const ComInterface = struct {
    name: []const u8,
    api: []const u8,
    pub fn format(self: ComInterface, writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print(
            "{{\"Kind\":\"ApiRef\",\"Name\":\"{s}\",\"TargetKind\":\"Com\",\"Api\":\"{s}\",\"Parents\":[]}}",
            .{ self.name, self.api },
        );
    }
};

pub fn getComInterface(type_ref: metadata.TypeRef) ComInterface {
    const api_ref = switch (type_ref) {
        .api_ref => |r| r,
        else => jsonPanic(),
    };
    jsonEnforce(api_ref.TargetKind == .Com);
    jsonEnforce(api_ref.Parents.len == 0);
    return .{
        .api = api_ref.Api,
        .name = api_ref.Name,
    };
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

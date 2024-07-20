const std = @import("std");
const metadata = @import("metadata.zig");

const path_sep = std.fs.path.sep_str;

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
        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            var first: bool = true;
            for (self.slice) |e| {
                if (first) {
                    first = false;
                } else {
                    try writer.writeAll(", ");
                }
                try std.fmt.format(writer, "{" ++ spec ++ "}", .{e});
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

pub fn jsonObjEnforceKnownFieldsOnly(map: std.json.ObjectMap, known_fields: []const []const u8, file_for_error: []const u8) !void {
    var it = map.iterator();
    fieldLoop: while (it.next()) |kv| {
        for (known_fields) |known_field| {
            if (std.mem.eql(u8, known_field, kv.key_ptr.*))
                continue :fieldLoop;
        }
        std.log.err("{s}: JSON object has unknown field '{s}', expected one of: {}\n", .{ file_for_error, kv.key_ptr.*, formatSliceT([]const u8, "s", known_fields) });
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
        switch (self.value) {
            // avoid issues where std.json adds quotes to big numbers
            // (potential fix: https://github.com/ziglang/zig/pull/16707)
            .integer => |i| try std.fmt.formatIntValue(i, "", .{}, writer),
            .number_string => |s| try writer.writeAll(s),
            else => try std.json.stringify(self.value, .{}, writer),
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

pub fn jsonObjGetRequired(
    map: std.json.ObjectMap,
    field: []const u8,
    file_for_error: []const u8,
) !std.json.Value {
    return map.get(field) orelse {
        // TODO: print file location?
        std.log.err("{s}: json object is missing '{s}' field: {}\n", .{ file_for_error, field, fmtJson(map) });
        jsonPanic();
    };
}

pub const ComInterface = struct {
    name: []const u8,
    api: []const u8,
    pub fn format(
        self: ComInterface,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "{{\"Kind\":\"ApiRef\",\"Name\":\"{s}\",\"TargetKind\":\"Com\",\"Api\":\"{s}\",\"Parents\":[]}}",
            .{ self.name, self.api },
        );
    }
};
pub fn parseComInterface(
    type_ref: std.json.ObjectMap,
    file_for_error: []const u8,
) ComInterface {
    const kind = (try jsonObjGetRequired(type_ref, "Kind", file_for_error)).string;
    jsonEnforce(std.mem.eql(u8, kind, "ApiRef"));
    try jsonObjEnforceKnownFieldsOnly(type_ref, &[_][]const u8{
        "Kind", "Name", "TargetKind", "Api", "Parents"
    }, file_for_error);
    const tmp_name = (try jsonObjGetRequired(type_ref, "Name", file_for_error)).string;
    const target_kind = (try jsonObjGetRequired(type_ref, "TargetKind", file_for_error)).string;
    const api = (try jsonObjGetRequired(type_ref, "Api", file_for_error)).string;
    const parents = (try jsonObjGetRequired(type_ref, "Parents", file_for_error)).array;
    jsonEnforce(std.mem.eql(u8, target_kind, "Com"));
    jsonEnforce(parents.items.len == 0);
    return .{
        .api = api,
        .name = tmp_name
    };
}

pub fn getComInterface(
    type_ref: metadata.TypeRef
) ComInterface {
    const api_ref = switch (type_ref) {
        .ApiRef => |r| r,
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

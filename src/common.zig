const std = @import("std");
const metadata = @import("metadata.zig");

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

pub fn asciiLessThanIgnoreCase(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(lhs, rhs);
}

fn SliceFormatter(comptime T: type, comptime spec: []const u8) type {
    return struct {
        slice: []const T,
        pub fn format(self: @This(), writer: anytype) !void {
            var first: bool = true;
            for (self.slice) |e| {
                if (first) {
                    first = false;
                } else {
                    try writer.writeAll(", ");
                }
                try writer.print("{" ++ spec ++ "}", .{e});
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

pub fn fail() noreturn {
    @panic("an assumption about the metadata was violated");
}
pub fn failMsg(comptime msg: []const u8, args: anytype) noreturn {
    std.debug.panic("an assumption about the metadata was violated: " ++ msg, args);
}

pub fn enforce(cond: bool) void {
    if (!cond) {
        fail();
    }
}
pub fn enforceMsg(cond: bool, comptime msg: []const u8, args: anytype) void {
    if (!cond) {
        failMsg(msg, args);
    }
}

pub const ComInterface = struct {
    name: []const u8,
    api: []const u8,
    pub fn format(self: ComInterface, writer: anytype) !void {
        try writer.print(
            "{{\"Kind\":\"ApiRef\",\"Name\":\"{s}\",\"TargetKind\":\"Com\",\"Api\":\"{s}\",\"Parents\":[]}}",
            .{ self.name, self.api },
        );
    }
};

pub fn getComInterface(type_ref: metadata.TypeRef) ComInterface {
    const api_ref = switch (type_ref) {
        .ApiRef => |r| r,
        else => fail(),
    };
    enforce(api_ref.TargetKind == .Com);
    enforce(api_ref.Parents.len == 0);
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

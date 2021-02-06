// NOTE: this was copied from https://github.com/marler8997/zog/blob/master/stringpool.zig
const std = @import("std");
const StringHashMap = std.hash_map.StringHashMap;

const zog = @import("./zog.zig");

/// Takes an allocator and manages a set of strings.
/// Every string in the pool is owned by the pool.
pub const StringPool = struct {
    pub const Val = struct {
        slice: []const u8,
        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) std.os.WriteError!void {
            return writer.writeAll(self.slice);
        }
    };

    allocator: *std.mem.Allocator,
    map: StringHashMap(Val),
    pub fn init(allocator: *std.mem.Allocator) @This() {
        return @This() {
            .allocator = allocator,
            .map = StringHashMap(Val).init(allocator),
        };
    }
    /// If the pool already contains this a string that matches the contents
    /// of the given string, return the existing string from this pool.
    /// Otherwise, create a copy of this string, add it to the pool and return
    /// the new copy.
    pub fn add(self: *@This(), s: []const u8) !Val {
        if (self.map.get(s)) |entry| {
            return entry;
        }
        var newString = try self.allocator.alloc(u8, s.len);
        std.mem.copy(u8, newString, s);
        const val = Val { .slice = newString };
        _ = try self.map.put(newString, val);
        return val;
    }

    fn eqlVal(a: Val, b: Val) bool {
        return std.hash_map.eqlString(a.slice, b.slice);
    }
    fn hashVal(s: Val) u64 {
        return std.hash_map.hashString(s.slice);
    }

    pub fn HashMap(comptime V: type) type {
        return std.HashMap(Val, V, hashVal, eqlVal, std.hash_map.DefaultMaxLoadPercentage);
    }
};

test "stringpool"
{
    var pool = StringPool.init(std.testing.allocator);
    const s = try pool.add("hello");
    {
        var buf : [5]u8 = undefined;
        zog.mem.copy(buf[0..], "hello");
        const s2 = try pool.add(buf[0..]);
        std.testing.expect(s.ptr == s2.ptr);
    }
}

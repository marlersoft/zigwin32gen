const std = @import("std");

pub fn ArrayHashMap(comptime T: type) type {
    return struct {
        map: std.StringArrayHashMap(T),

        const Self = @This();
        pub fn get(self: Self, name: []const u8) ?T {
            return self.map.get(name);
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!Self {

            var map = std.StringArrayHashMap(T).init(allocator);
            errdefer map.deinit();

            if (.object_begin != try source.next()) return error.UnexpectedToken;
            while (true) {
                const api_name = switch (try source.next()) {
                    .string => |s| s,
                    .object_end => return .{ .map = map },
                    else => return error.UnexpectedToken,
                };
                const value = try std.json.innerParse(T, allocator, source, options);
                try map.put(api_name, value);
            }
        }
    };
}

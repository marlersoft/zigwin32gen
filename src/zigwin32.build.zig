const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    switch (builtin.zig_version.minor) {
        11 => {
            _ = b.addModule("zigwin32", .{
                .source_file = .{ .path = "win32.zig" },
            });
        },
        12 => {
            _ = b.addModule("zigwin32", .{
                .root_source_file = .{ .path = "win32.zig" },
            });
        },
        else => {
            _ = b.addModule("zigwin32", .{
                .root_source_file = b.path("win32.zig"),
            });
        },
    }
}

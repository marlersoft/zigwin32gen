const std = @import("std");
const common = @import("common.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    // NOTE: currently depends on ensuring the bindings
    //       are already generated/installed from build.zig
    const win32 = b.dependency("win32", .{}).module("win32");
    common.addExamples(b, optimize, win32, b.dependency("examples", .{}).path("."));
}

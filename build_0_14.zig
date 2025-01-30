const std = @import("std");
const buildcommon = @import("buildcommon.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    // NOTE: currently depends on ensuring the bindings
    //       are already generated/installed from build.zig
    const win32 = b.createModule(.{
        .root_source_file = b.path("zig-out/win32.zig"),
    });
    buildcommon.addExamples(b, optimize, win32);
}

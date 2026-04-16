pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const autoexit = b.option(bool, "autoexit", "Automatically exit examples without waiting for the user to close them.") orelse false;
    // NOTE: currently depends on ensuring the bindings
    //       are already generated/installed from build.zig
    const win32_dep = b.dependency("win32", .{});
    const win32 = win32_dep.module("win32");
    common.addExamples(b, optimize, win32, b.dependency("examples", .{}).path("."), if (autoexit) .yes else .no);

    {
        const test_step = b.step("test", "Run all the tests (except the examples)");
        const unittest_step = b.step("unittest", "Unit test the generated bindings");
        test_step.dependOn(unittest_step);

        // TODO: see note in ../build.zig; running requires import libs (e.g.
        // bcp47mrm) that aren't bundled with Zig.
        const run_unittest = false;
        for ([_][]const u8{ "x86_64-windows", "aarch64-windows" }) |arch_os_abi| {
            const target_query = std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi }) catch unreachable;
            const target = b.resolveTargetQuery(target_query);
            const unittest = b.addTest(.{
                .root_source_file = win32_dep.path("win32.zig"),
                .target = target,
                .optimize = optimize,
            });
            unittest.pie = true;
            const runnable = run_unittest and builtin.os.tag == .windows and
                target.result.cpu.arch == builtin.cpu.arch;
            if (runnable) {
                unittest_step.dependOn(&b.addRunArtifact(unittest).step);
            } else {
                unittest_step.dependOn(&unittest.step);
            }
        }
    }
}
const builtin = @import("builtin");
const std = @import("std");
const common = @import("common.zig");

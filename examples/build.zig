const std = @import("std");
const Builder = std.build.Builder;
const CrossTarget = std.zig.CrossTarget;
const Mode = std.builtin.Mode;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    try makeExe(b, target, mode, "helloworld");
    try makeExe(b, target, mode, "helloworld-window");
}

fn makeExe(b: *Builder, target: CrossTarget, mode: Mode, root: []const u8) !void {
    const src = try std.mem.concat(b.allocator, u8, &[_][]const u8 {root, ".zig"});
    const exe = b.addExecutable(root, src);
    exe.single_threaded = true;
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
    exe.addPackage(.{
        .name = "windows",
        .path = "../out/windows.zig",
    });

    //const run_cmd = exe.run();
    //run_cmd.step.dependOn(b.getInstallStep());

    //const run_step = b.step("run", "Run the app");
    //run_step.dependOn(&run_cmd.step);
}
const builtin = @import("builtin");
const std = @import("std");
const Builder = std.build.Builder;
const CrossTarget = std.zig.CrossTarget;
const Mode = std.builtin.Mode;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    if (builtin.os.tag != .windows) {
        if (target.os_tag == null or target.os_tag.? != .windows) {
            std.log.err("target is not windows", .{});
            std.log.info("try building with one of -Dtarget=native-windows, -Dtarget=x86-windows or -Dtarget=x86_64-windows\n", .{});
            std.os.exit(1);
        }
    }

    const win32 = b.createModule(.{
        .source_file = .{ .path = "../zigwin32/win32.zig" },
    });

    const mode = b.standardOptimizeOption(.{});
    try makeExe(b, target, mode, win32, "helloworld", .Console);
    try makeExe(b, target, mode, win32, "helloworld-window", .Windows);
    try makeExe(b, target, mode, win32, "d2dcircle", .Windows);
    try makeExe(b, target, mode, win32, "opendialog", .Windows);
    try makeExe(b, target, mode, win32, "wasapi", .Console);
    try makeExe(b, target, mode, win32, "net", .Console);
}

fn makeExe(
    b: *Builder,
    target: CrossTarget,
    optimize: Mode,
    win32: *std.Build.Module,
    root: []const u8,
    subsystem: std.Target.SubSystem,
) !void {
    const exe = b.addExecutable(.{
        .name = root,
        .root_source_file = .{ .path = try std.mem.concat(b.allocator, u8, &[_][]const u8 {root, ".zig"}) },
        .target = target,
        .optimize = optimize,
    });
    exe.single_threaded = true;
    exe.subsystem = subsystem;
    b.installArtifact(exe);
    exe.addModule("win32", win32);

    //const run_cmd = exe.run();
    //run_cmd.step.dependOn(b.getInstallStep());

    //const run_step = b.step("run", "Run the app");
    //run_step.dependOn(&run_cmd.step);
}

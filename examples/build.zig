const std = @import("std");
const Builder = std.build.Builder;
const CrossTarget = std.zig.CrossTarget;
const Mode = std.builtin.Mode;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    if (std.builtin.os.tag != .windows) {
        if (target.os_tag == null or target.os_tag.? != .windows) {
            std.log.err("target is not windows", .{});
            std.log.info("try building with one of -Dtarget=native-windows, -Dtarget=i386-windows or -Dtarget=x86_64-windows\n", .{});
            std.os.exit(1);
        }
    }

    const mode = b.standardReleaseOptions();
    try makeExe(b, target, mode, "helloworld");
    try makeExe(b, target, mode, "helloworld-window");
    try makeExe(b, target, mode, "d2dcircle");
    try makeExe(b, target, mode, "opendialog");
    try makeExe(b, target, mode, "wasapi");
}

fn makeExe(b: *Builder, target: CrossTarget, mode: Mode, root: []const u8) !void {
    const src = try std.mem.concat(b.allocator, u8, &[_][]const u8 {root, ".zig"});
    const exe = b.addExecutable(root, src);
    exe.single_threaded = true;
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
    exe.addPackage(.{
        .name = "win32",
        .path = .{ .path = "../zigwin32/win32.zig" },
    });

    //const run_cmd = exe.run();
    //run_cmd.step.dependOn(b.getInstallStep());

    //const run_step = b.step("run", "Run the app");
    //run_step.dependOn(&run_cmd.step);
}
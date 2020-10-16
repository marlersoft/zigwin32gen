const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("helloworld", "helloworld.zig");
    exe.single_threaded = true;
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
    exe.addPackage(.{
        .name = "windows",
        .path = "../out/windows.zig",
    });

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

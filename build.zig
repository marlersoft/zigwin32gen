const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const genzig_exe = b.addExecutable("genzig", "src/genzig.zig");
    genzig_exe.setTarget(target);
    genzig_exe.setBuildMode(mode);
    genzig_exe.install();

    const run_genzig_exe = genzig_exe.run();
    run_genzig_exe.step.dependOn(&genzig_exe.install_step.?.step);

    const run_genzig = b.step("genzig", "Generate Zig bindings from the win32json JSON files");
    run_genzig.dependOn(&run_genzig_exe.step);

    // run genzig by default
    b.getInstallStep().dependOn(run_genzig);
}

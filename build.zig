const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const run_pass1 = blk: {
        const pass1_exe = b.addExecutable("pass1", "src/pass1.zig");
        pass1_exe.setTarget(target);
        pass1_exe.setBuildMode(mode);
        pass1_exe.install();

        const run_pass1_exe = pass1_exe.run();
        run_pass1_exe.step.dependOn(&pass1_exe.install_step.?.step);

        const run_pass1 = b.step("pass1", "Generate pass1.json from win32json files");
        run_pass1.dependOn(&run_pass1_exe.step);

        // run pass1 by default
        b.getInstallStep().dependOn(run_pass1);
        break :blk run_pass1;
    };

    const genzig_exe = b.addExecutable("genzig", "src/genzig.zig");
    genzig_exe.setTarget(target);
    genzig_exe.setBuildMode(mode);
    genzig_exe.install();

    const run_genzig_without_pass1 = genzig_exe.run();
    run_genzig_without_pass1.step.dependOn(&genzig_exe.install_step.?.step);

    const run_genzig_with_pass1 = genzig_exe.run();
    run_genzig_with_pass1.step.dependOn(&genzig_exe.install_step.?.step);
    run_genzig_with_pass1.step.dependOn(run_pass1);

    const run_genzig = b.step("genzig", "Generate Zig bindings from the win32json JSON files (without pass1)");
    run_genzig.dependOn(&run_genzig_without_pass1.step);

    // run genzig by default
    b.getInstallStep().dependOn(&run_genzig_with_pass1.step);
}

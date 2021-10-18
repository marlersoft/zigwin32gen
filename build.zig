const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const win32json_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/win32json",
        .branch = "10.3.16-preview",
        .sha = "ef937288bee6aea8763f0071cbfdf7d9fef62ff4",
    });

    const run_pass1 = blk: {
        const pass1_exe = b.addExecutable("pass1", "src/pass1.zig");
        pass1_exe.setTarget(target);
        pass1_exe.setBuildMode(mode);

        const run_pass1 = std.build.RunStep.create(b, "run pass1");
        run_pass1.addArtifactArg(pass1_exe);

        run_pass1.step.dependOn(&win32json_repo.step);
        run_pass1.addArg(win32json_repo.getPath(&run_pass1.step));

        b.step("pass1", "Generate pass1.json from win32json files").dependOn(&run_pass1.step);
        break :blk run_pass1;
    };

    {
        const genzig_exe = b.addExecutable("genzig", "src/genzig.zig");
        genzig_exe.setTarget(target);
        genzig_exe.setBuildMode(mode);

        const run_genzig = std.build.RunStep.create(b, "run genzig");
        run_genzig.addArtifactArg(genzig_exe);

        run_genzig.step.dependOn(&run_pass1.step);
        run_genzig.addArg(win32json_repo.getPath(&run_genzig.step));

        b.step("genzig", "Generate Zig bindings").dependOn(&run_genzig.step);

        b.getInstallStep().dependOn(&run_genzig.step);
    }
}

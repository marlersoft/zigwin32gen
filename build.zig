const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;
const GitRepoStep = @import("GitRepoStep.zig");
const patchstep = @import("patchstep.zig");

pub fn build(b: *Builder) !void {
    patchstep.init(b.allocator);
    const mode = b.standardReleaseOptions();

    const win32json_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/win32json",
        .branch = "15.0.1-preview",
        .sha = "a0cef2ae9d4c2a46cb9cf16aafaad5e470fa1cee",
    });

    const run_pass1 = blk: {
        const pass1_exe = b.addExecutable("pass1", "src/pass1.zig");
        pass1_exe.setBuildMode(mode);

        const run_pass1 = pass1_exe.run();
        patchstep.patch(&run_pass1.step, runStepMake);
        run_pass1.step.dependOn(&win32json_repo.step);
        run_pass1.addArg(win32json_repo.getPath(&run_pass1.step));

        b.step("pass1", "Generate pass1.json from win32json files").dependOn(&run_pass1.step);
        break :blk run_pass1;
    };

    {
        const genzig_exe = b.addExecutable("genzig", "src/genzig.zig");
        genzig_exe.setBuildMode(mode);
        const run_genzig = genzig_exe.run();
        patchstep.patch(&run_genzig.step, runStepMake);
        run_genzig.step.dependOn(&run_pass1.step);
        run_genzig.addArg(win32json_repo.getPath(&run_genzig.step));

        b.step("genzig", "Generate Zig bindings").dependOn(&run_genzig.step);

        b.getInstallStep().dependOn(&run_genzig.step);
    }
}

fn runStepMake(step: *std.build.Step, original_make_fn: patchstep.MakeFn) anyerror!void {
    original_make_fn(step) catch |err| switch (err) {
        // just exit if subprocess failed with error exit code
        error.UnexpectedExitCode => std.os.exit(0xff),
        else => |e| return e,
    };
}

const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *Builder) !void {
    const mode = b.standardReleaseOptions();

    const win32json_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/win32json",
        .branch = "10.3.16-preview",
        .sha = "ef937288bee6aea8763f0071cbfdf7d9fef62ff4",
    });

    const run_pass1 = blk: {
        const pass1_exe = b.addExecutable("pass1", "src/pass1.zig");
        pass1_exe.setBuildMode(mode);

        const run_pass1 = pass1_exe.run();
        run_pass1.step.dependOn(&win32json_repo.step);
        run_pass1.addArg(win32json_repo.getPath(&run_pass1.step));

        b.step("pass1", "Generate pass1.json from win32json files").dependOn(&run_pass1.step);
        break :blk run_pass1;
    };

    {
        const genzig_exe = b.addExecutable("genzig", "src/genzig.zig");
        genzig_exe.setBuildMode(mode);
        const run_genzig = genzig_exe.run();
        run_genzig.step.dependOn(&run_pass1.step);
        run_genzig.addArg(win32json_repo.getPath(&run_genzig.step));

        b.step("genzig", "Generate Zig bindings").dependOn(&run_genzig.step);

        b.getInstallStep().dependOn(&run_genzig.step);
    }


    const cpp_sdk_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/microsoft_windows_sdk_cpp",
        .branch = "10.0.220000.196",
        .sha = "16b53593a29860fea1706e7a862b2145c0f1b6ee",
    });

    {
        const exe = b.addExecutable("scrapecpp", "src/scrapecpp.zig");
        exe.setBuildMode(mode);
        const run = exe.run();
        run.step.dependOn(&win32json_repo.step);
        run.addArg(win32json_repo.getPath(&run_pass1.step));
        run.step.dependOn(&cpp_sdk_repo.step);
        run.addArg(cpp_sdk_repo.getPath(&run.step));
        b.step("scrape", "Scrape the Windows SDK Cpp headers").dependOn(&run.step);
    }

    {
        const genc_exe = b.addExecutable("genc", "src/genc.zig");
        genc_exe.setBuildMode(mode);
        const run_genc = genc_exe.run();
        // NOTE: not sure if this will use pass1 yet
        //run_genc.step.dependOn(&run_pass1.step);
        run_genc.step.dependOn(&win32json_repo.step);
        run_genc.addArg(win32json_repo.getPath(&run_genc.step));

        b.step("genc", "Generate Zig bindings").dependOn(&run_genc.step);

        b.getInstallStep().dependOn(&run_genc.step);
    }
}

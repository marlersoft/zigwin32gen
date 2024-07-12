const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const desc_line_prefix = [_]u8{ ' ' } **  31;
    const nofetch = b.option(
        bool,
        "nofetch",
        "disable fetching from main on every build"
    ) orelse false;
    const noclean = b.option(
        bool,
        "noclean",
        "disable cleaning the zigwin32gen repo on every build.\n" ++ desc_line_prefix ++
        "useful if you know zigwin32gen doesn't have junk and\n" ++ desc_line_prefix ++
        "you're wanting a faster edit/test for release.zig."
    ) orelse false;

    const gen_repo = b.path("zigwin32gen");

    const sha_file = blk: {
        const exe = b.addExecutable(.{
            .name = "fetchmain",
            .root_source_file = b.path("src/fetchmain.zig"),
            .target = target,
            .optimize = optimize,
        });
        const run = b.addRunArtifact(exe);
        run.has_side_effects = if (nofetch) false else true;
        run.addDirectoryArg(gen_repo);
        const sha_file = run.addOutputFileArg("mainsha");
        b.step("fetchmain", (
            "Fetches the main branch in zigwin32gen\n" ++ desc_line_prefix ++
            "and stores its sha in a file for other\n" ++ desc_line_prefix ++
            "steps to use as an input."
        )).dependOn(&run.step);
        break :blk sha_file;
    };

    {
        const exe = b.addExecutable(.{
            .name = "release",
            .root_source_file = b.path("src/release.zig"),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.addDirectoryArg(gen_repo);
        run.addFileArg(sha_file);
        run.addFileArg(b.path("releases.txt"));
        run.addDirectoryArg(b.path("zigwin32"));
        run.addArg(if (noclean) "noclean" else "clean");

        const run_step = b.step("release", "Release the latest generated code.");
        run_step.dependOn(&run.step);
    }
}

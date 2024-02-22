const builtin = @import("builtin");
const std = @import("std");
const Build = std.Build;
const Step = std.Build.Step;
const CrossTarget = std.zig.CrossTarget;
const patchstep = @import("patchstep.zig");

pub fn build(b: *Build) !void {
    patchstep.init(b.allocator);

    const maybe_fetch_option = b.option(
        bool,
        "fetch",
        "Controls whether genzig fetches and updates it's local version branch before generating the bindings",
    );

    const gen_step = b.step("gen", "Generate and unit test the bindings");
    b.default_step = gen_step;
    const pass1_step = b.step("pass1", "Only perform pass1 of zig binding generation (generates pass1.json)");
    const gen_no_test_step = b.step("gen-no-test", "Generate the bindings but don't unit test them");
    const test_no_gen_step = b.step("test-no-gen", "Unit test the generated bindings without regenerating them");
    const examples_step = b.step("examples", "Build/run examples. Run 'gen' step first. Use -j1 to run one at a time");

    const optimize = b.standardOptimizeOption(.{});

    const win32json_dep = b.dependency("win32json", .{});

    const pass1: struct {
        run: *std.Build.Step.Run,
        out_file: std.Build.LazyPath,
    } = blk: {
        const pass1_exe = b.addExecutable(.{
            .name = "pass1",
            .root_source_file = .{ .path = "src/pass1.zig" },
            .optimize = optimize,
            .target = b.host,
        });

        const run = b.addRunArtifact(pass1_exe);
        patchstep.patch(&run.step, runStepMake);
        run.addDirectoryArg(win32json_dep.path(""));
        const out_file = run.addOutputFileArg("pass1.json");

        pass1_step.dependOn(&run.step);
        break :blk .{ .run = run, .out_file = out_file };
    };

    const run_genzig_step = blk: {
        const exe = b.addExecutable(.{
            .name = "genzig",
            .root_source_file = .{ .path = "src/genzig.zig" },
            .optimize = optimize,
            .target = b.host,
        });
        const run = b.addRunArtifact(exe);
        patchstep.patch(&run.step, runStepMake);
        run.step.dependOn(&pass1.run.step);
        run.addDirectoryArg(win32json_dep.path(""));
        run.addFileArg(pass1.out_file);
        run.addDirectoryArg(.{ .path = b.pathFromRoot("src") });
        run.addDirectoryArg(.{ .path = b.pathFromRoot("zigwin32") });
        const fetch_enabled = if (maybe_fetch_option) |o| o else true;
        run.addArg(if (fetch_enabled) "fetch" else "nofetch");
        break :blk &run.step;
    };
    gen_no_test_step.dependOn(run_genzig_step);

    for ([_]bool{ false, true }) |with_gen| {
        const test_step = b.addTest(.{
            .root_source_file = .{ .path = "zigwin32/win32.zig" },
            .target = b.host,
            .optimize = optimize,
        });
        if (builtin.os.tag != .windows) {
            // code that depends on DLL's must be PIC, windows does this by default so this
            // makes things work on other platforms
            test_step.force_pic = true;
        }
        if (with_gen) {
            test_step.step.dependOn(run_genzig_step);
            gen_step.dependOn(&test_step.step);
        } else {
            test_no_gen_step.dependOn(&test_step.step);
        }
    }

    const win32 = b.createModule(.{
        .root_source_file = .{ .path = "zigwin32/win32.zig" },
    });
    const arches: []const ?[]const u8 = &[_]?[]const u8{
        null,
        "x86",
        "x86_64",
        "aarch64",
    };

    try addExample(b, arches, optimize, win32, "helloworld", .Console, examples_step);
    try addExample(b, arches, optimize, win32, "wasapi", .Console, examples_step);
    try addExample(b, arches, optimize, win32, "net", .Console, examples_step);

    try addExample(b, arches, optimize, win32, "helloworld-window", .Windows, examples_step);
    try addExample(b, arches, optimize, win32, "d2dcircle", .Windows, examples_step);
    try addExample(b, arches, optimize, win32, "opendialog", .Windows, examples_step);
}

fn runStepMake(
    step: *Step,
    prog_node: *std.Progress.Node,
    original_make_fn: patchstep.MakeFn
) anyerror!void {
    original_make_fn(step, prog_node) catch |err| switch (err) {
        // just exit if subprocess failed with error exit code
        error.UnexpectedExitCode => std.os.exit(0xff),
        else => |e| return e,
    };
}

fn concat(b: *Build, slices: []const []const u8) []u8 {
    return std.mem.concat(b.allocator, u8, slices) catch unreachable;
}

fn addExample(
    b: *Build,
    arches: []const ?[]const u8,
    optimize: std.builtin.Mode,
    win32: *std.Build.Module,
    root: []const u8,
    subsystem: std.Target.SubSystem,
    examples_step: *Step,
) !void {
    const basename = concat(b, &.{ root, ".zig" });
    for (arches) |cross_arch_opt| {
        const name = if (cross_arch_opt) |arch| concat(b, &.{ root, "-", arch}) else root;

        const arch_os_abi = if (cross_arch_opt) |arch| concat(b, &.{ arch, "-windows"}) else "native";
        const target_query = std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi }) catch unreachable;
        const target = b.resolveTargetQuery(target_query);
        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = b.pathJoin(&.{ "examples", basename}) },
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        exe.subsystem = subsystem;
        exe.root_module.addImport("win32", win32);
        examples_step.dependOn(&exe.step);

        const desc_suffix: []const u8 = if (cross_arch_opt) |_| "" else " for the native target";
        const build_desc = b.fmt("Build {s}{s}", .{name, desc_suffix});
        b.step(concat(b, &.{ name, "-build" }), build_desc).dependOn(&exe.step);

        const run_cmd = b.addRunArtifact(exe);
        const run_desc = b.fmt("Run {s}{s}", .{name, desc_suffix});
        b.step(name, run_desc).dependOn(&run_cmd.step);

        if (builtin.os.tag == .windows) {
            if (cross_arch_opt == null) {
                examples_step.dependOn(&run_cmd.step);
            }
        }
    }
}

const builtin = @import("builtin");
const std = @import("std");

pub fn build(_: *std.Build) void {}

pub const Autoexit = enum { no, yes };
const Subsystem = enum { console, windows };

pub fn addExamples(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    win32: *std.Build.Module,
    examples: std.Build.LazyPath,
    autoexit: Autoexit,
) void {
    const arches: []const ?[]const u8 = &[_]?[]const u8{
        null,
        "x86",
        "x86_64",
        "aarch64",
    };
    const examples_step = b.step("examples", "Build/run examples. Use -j1 to run one at a time");

    try addExample(b, arches, optimize, win32, examples, "helloworld", .console, examples_step, autoexit);
    try addExample(b, arches, optimize, win32, examples, "wasapi", .console, examples_step, autoexit);
    try addExample(b, arches, optimize, win32, examples, "net", .console, examples_step, autoexit);
    try addExample(b, arches, optimize, win32, examples, "tests", .console, examples_step, autoexit);

    try addExample(b, arches, optimize, win32, examples, "helloworld-window", .windows, examples_step, autoexit);
    try addExample(b, arches, optimize, win32, examples, "d2dcircle", .windows, examples_step, autoexit);
    try addExample(b, arches, optimize, win32, examples, "opendialog", .windows, examples_step, autoexit);
    try addExample(b, arches, optimize, win32, examples, "unionpointers", .windows, examples_step, autoexit);
    try addExample(b, arches, optimize, win32, examples, "testwindow", .windows, examples_step, autoexit);
}

/// Adds the tests in the repo's test directory that work on any zig version.
pub fn addTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    win32: *std.Build.Module,
    tests: std.Build.LazyPath,
) void {
    {
        const helpers = b.addTest(.{
            .name = "helpers",
            .root_module = b.createModule(.{
                .root_source_file = tests.path(b, "helpers.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        helpers.root_module.addImport("win32", win32);
        test_step.dependOn(&b.addRunArtifact(helpers).step);
    }
    for ([_][]const u8{ "x86_64-windows", "aarch64-windows" }) |arch_os_abi| {
        const target_query = std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi }) catch unreachable;
        const everything = b.addTest(.{
            .name = b.fmt("everything-{s}", .{arch_os_abi}),
            .root_module = b.createModule(.{
                .root_source_file = tests.path(b, "everything.zig"),
                .target = b.resolveTargetQuery(target_query),
                .optimize = optimize,
            }),
        });
        everything.root_module.addImport("win32", win32);
        // compile only, see test/everything.zig
        test_step.dependOn(&everything.step);
    }
}

fn addExample(
    b: *std.Build,
    arches: []const ?[]const u8,
    optimize: std.builtin.OptimizeMode,
    win32: *std.Build.Module,
    examples: std.Build.LazyPath,
    root: []const u8,
    subsystem: Subsystem,
    examples_step: *std.Build.Step,
    autoexit: Autoexit,
) !void {
    const basename = b.fmt("{s}.zig", .{root});
    for (arches) |cross_arch_opt| {
        const name = if (cross_arch_opt) |arch| b.fmt("{s}-{s}", .{ root, arch }) else root;

        const arch_os_abi = if (cross_arch_opt) |arch| b.fmt("{s}-windows", .{arch}) else "native";
        const target_query = std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi }) catch unreachable;
        const target = b.resolveTargetQuery(target_query);
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = examples.path(b, basename),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
            }),
            .win32_manifest = examples.path(b, "win32.manifest"),
        });
        // zig 0.17.0 moved std.Target.SubSystem to std.zig.Subsystem and lowercased its fields
        exe.subsystem = if (@hasDecl(std.zig, "Subsystem")) switch (subsystem) {
            .console => .console,
            .windows => .windows,
        } else switch (subsystem) {
            .console => .Console,
            .windows => .Windows,
        };
        exe.root_module.addImport("win32", win32);
        examples_step.dependOn(&exe.step);
        exe.pie = true;

        const desc_suffix: []const u8 = if (cross_arch_opt) |_| "" else " for the native target";
        const build_desc = b.fmt("Build {s}{s}", .{ name, desc_suffix });
        b.step(b.fmt("{s}-build", .{name}), build_desc).dependOn(&exe.step);

        const run_cmd = b.addRunArtifact(exe);
        if (autoexit == .yes) run_cmd.addArg("--autoexit");
        const run_desc = b.fmt("Run {s}{s}", .{ name, desc_suffix });
        b.step(name, run_desc).dependOn(&run_cmd.step);

        if (builtin.os.tag == .windows) {
            if (cross_arch_opt == null) {
                examples_step.dependOn(&run_cmd.step);
            }
        }
    }
}

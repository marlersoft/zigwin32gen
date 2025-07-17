const builtin = @import("builtin");
const std = @import("std");

pub fn addExamples(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    win32: *std.Build.Module,
    examples: std.Build.LazyPath,
) void {
    const arches: []const ?[]const u8 = &[_]?[]const u8{
        null,
        "x86",
        "x86_64",
        "aarch64",
    };
    const examples_step = b.step("examples", "Build/run examples. Use -j1 to run one at a time");

    try addExample(b, examples_step, arches, optimize, win32, examples, "helloworld", .Console, &.{});
    try addExample(b, examples_step, arches, optimize, win32, examples, "wasapi", .Console, &.{"ole32"});
    try addExample(b, examples_step, arches, optimize, win32, examples, "net", .Console, &.{"ws2_32"});
    try addExample(b, examples_step, arches, optimize, win32, examples, "tests", .Console, &.{});
    try addExample(b, examples_step, arches, optimize, win32, examples, "helloworld-window", .Windows, &.{ "user32", "gdi32" });
    try addExample(b, examples_step, arches, optimize, win32, examples, "d2dcircle", .Windows, &.{ "user32", "gdi32", "d2d1" });
    try addExample(b, examples_step, arches, optimize, win32, examples, "opendialog", .Windows, &.{ "user32", "ole32" });
    try addExample(b, examples_step, arches, optimize, win32, examples, "unionpointers", .Windows, &.{"user32"});
    try addExample(b, examples_step, arches, optimize, win32, examples, "testwindow", .Windows, &.{ "user32", "gdi32" });
}

fn addExample(
    b: *std.Build,
    examples_step: *std.Build.Step,
    arches: []const ?[]const u8,
    optimize: std.builtin.OptimizeMode,
    win32: *std.Build.Module,
    examples: std.Build.LazyPath,
    root: []const u8,
    subsystem: std.Target.SubSystem,
    system_libraries: []const []const u8,
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
            .win32_manifest = if (subsystem == .Windows) examples.path(b, "win32.manifest") else null,
        });
        exe.subsystem = subsystem;
        exe.root_module.addImport("win32", win32);
        examples_step.dependOn(&exe.step);
        exe.pie = true;
        for (system_libraries) |system_library| exe.linkSystemLibrary(system_library);

        const desc_suffix: []const u8 = if (cross_arch_opt) |_| "" else " for the native target";
        const build_desc = b.fmt("Build {s}{s}", .{ name, desc_suffix });
        b.step(b.fmt("{s}-build", .{name}), build_desc).dependOn(&exe.step);

        const run_cmd = b.addRunArtifact(exe);
        const run_desc = b.fmt("Run {s}{s}", .{ name, desc_suffix });
        b.step(name, run_desc).dependOn(&run_cmd.step);

        if (builtin.os.tag == .windows) {
            if (cross_arch_opt == null) {
                examples_step.dependOn(&run_cmd.step);
            }
        }
    }
}

const builtin = @import("builtin");
const std = @import("std");

pub fn addExamples(
    b: *std.Build,
    optimize: std.builtin.Mode,
    win32: *std.Build.Module,
) void {
    const arches: []const ?[]const u8 = &[_]?[]const u8{
        null,
        "x86",
        "x86_64",
        "aarch64",
    };
    const examples_step = b.step("examples", "Build/run examples. Use -j1 to run one at a time");

    try addExample(b, arches, optimize, win32, "helloworld", .Console, examples_step);
    try addExample(b, arches, optimize, win32, "wasapi", .Console, examples_step);
    try addExample(b, arches, optimize, win32, "net", .Console, examples_step);
    try addExample(b, arches, optimize, win32, "tests", .Console, examples_step);

    try addExample(b, arches, optimize, win32, "helloworld-window", .Windows, examples_step);
    try addExample(b, arches, optimize, win32, "d2dcircle", .Windows, examples_step);
    try addExample(b, arches, optimize, win32, "opendialog", .Windows, examples_step);
    try addExample(b, arches, optimize, win32, "unionpointers", .Windows, examples_step);
    try addExample(b, arches, optimize, win32, "testwindow", .Windows, examples_step);
}

fn addExample(
    b: *std.Build,
    arches: []const ?[]const u8,
    optimize: std.builtin.Mode,
    win32: *std.Build.Module,
    root: []const u8,
    subsystem: std.Target.SubSystem,
    examples_step: *std.Build.Step,
) !void {
    const basename = b.fmt("{s}.zig", .{root});
    for (arches) |cross_arch_opt| {
        const name = if (cross_arch_opt) |arch| b.fmt("{s}-{s}", .{ root, arch }) else root;

        const arch_os_abi = if (cross_arch_opt) |arch| b.fmt("{s}-windows", .{arch}) else "native";
        const target_query = std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi }) catch unreachable;
        const target = b.resolveTargetQuery(target_query);
        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.pathJoin(&.{ "examples", basename })),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .win32_manifest = if (subsystem == .Windows) b.path("examples/win32.manifest") else null,
        });
        exe.subsystem = subsystem;
        exe.root_module.addImport("win32", win32);
        examples_step.dependOn(&exe.step);
        exe.pie = true;

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

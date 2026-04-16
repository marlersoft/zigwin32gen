const builtin = @import("builtin");
const std = @import("std");
const Build = std.Build;
const Step = std.Build.Step;
const CrossTarget = std.zig.CrossTarget;
const buildcommon = @import("0.14.1/common.zig");

comptime {
    const required_zig = "0.15.2";
    const v = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (builtin.zig_version.order(v) != .eq) @compileError(
        "zig version " ++ required_zig ++ " is required to ensure zigwin32 output is always the same",
    );
}

pub fn build(b: *Build) !void {
    const default_steps = "install diff test";
    b.default_step = b.step(
        "default",
        "The default step, equivalent to: " ++ default_steps,
    );
    const autoexit = b.option(bool, "autoexit", "Automatically exit examples without waiting for the user to close them.") orelse false;
    const test_step = b.step("test", "Run all the tests (except the examples)");
    const unittest_step = b.step("unittest", "Unit test the generated bindings");
    test_step.dependOn(unittest_step);
    const desc_line_prefix = [_]u8{' '} ** 31;
    const diff_step = b.step(
        "diff",
        ("Updates 'diffrepo' then installs the latest generated\n" ++
            desc_line_prefix ++
            "files so they can be diffed via git."),
    );
    addDefaultStepDeps(b, default_steps);

    {
        const release_step = b.step("release", "Generate the bindings and run tests for a release");
        release_step.dependOn(test_step);
        release_step.dependOn(b.getInstallStep());
    }

    const pass1_step = b.step(
        "pass1",
        "Only perform pass1 of zig binding generation.\n" ++ desc_line_prefix ++
            "(generates pass1.json in .zig-cache)",
    );
    const gen_step = b.step("gen", "Generate the bindings (in .zig-cache)");
    const optimize = b.standardOptimizeOption(.{});

    const win32json_dep = b.dependency("win32json", .{});

    const pass1_out_file = blk: {
        const pass1_exe = b.addExecutable(.{
            .name = "pass1",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/pass1.zig"),
                .optimize = optimize,
                .target = b.graph.host,
            }),
        });

        const run = b.addRunArtifact(pass1_exe);
        run.addDirectoryArg(win32json_dep.path(""));
        const out_file = run.addOutputFileArg("pass1.json");

        pass1_step.dependOn(&run.step);
        break :blk out_file;
    };

    const zigexports = blk: {
        const exe = b.addExecutable(.{
            .name = "genzigexports",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/genzigexports.zig"),
                .target = b.graph.host,
            }),
        });
        exe.root_module.addImport("win32_stub", b.createModule(.{
            .root_source_file = b.path("src/static/win32.zig"),
        }));

        const run = b.addRunArtifact(exe);
        break :blk run.addOutputFileArg("zigexports.zig");
    };

    const gen_out_dir = blk: {
        const exe = b.addExecutable(.{
            .name = "genzig",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/genzig.zig"),
                .optimize = optimize,
                .target = b.graph.host,
            }),
        });
        exe.root_module.addImport(
            "zigexports",
            b.createModule(.{ .root_source_file = zigexports }),
        );
        const run = b.addRunArtifact(exe);
        run.addFileArg(b.path("extra.txt"));
        run.addDirectoryArg(win32json_dep.path(""));
        run.addFileArg(pass1_out_file);
        run.addFileArg(b.path("ComOverloads.txt"));
        const out_dir = run.addOutputDirectoryArg(".");
        gen_step.dependOn(&run.step);
        break :blk out_dir;
    };

    b.step(
        "show-path",
        "Print the zigwin32 cache directory",
    ).dependOn(&PrintLazyPath.create(b, gen_out_dir).step);

    b.installDirectory(.{
        .source_dir = gen_out_dir,
        .install_dir = .prefix,
        .install_subdir = ".",
    });

    {
        const diff_exe = b.addExecutable(.{
            .name = "diff",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/diff.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const diff = b.addRunArtifact(diff_exe);
        // fetches from zigwin32 github and also modifies the contents
        // of the 'diffrepo' subdirectory so definitely has side effects
        diff.has_side_effects = true;
        diff.addArg("--zigbuild");
        // make this a normal string arg, we don't want the build system
        // trying to hash this as an input or something
        diff.addArg(b.pathFromRoot("diffrepo"));
        diff.addDirectoryArg(gen_out_dir);
        if (b.args) |args| {
            diff.addArgs(args);
        }
        diff_step.dependOn(&diff.step);
    }

    // TODO: running the test binary needs import libraries (e.g. bcp47mrm)
    // that aren't bundled with Zig, refAllDecls in the generated win32.zig
    // forces every extern decl to link. Flip once that's resolved.
    const run_unittest = false;
    for ([_][]const u8{ "x86_64-windows", "aarch64-windows" }) |arch_os_abi| {
        const target_query = std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi }) catch unreachable;
        const target = b.resolveTargetQuery(target_query);
        const unittest = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = gen_out_dir.path(b, "win32.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        unittest.pie = true;
        const runnable = run_unittest and builtin.os.tag == .windows and
            target.result.cpu.arch == builtin.cpu.arch;
        if (runnable) {
            unittest_step.dependOn(&b.addRunArtifact(unittest).step);
        } else {
            unittest_step.dependOn(&unittest.step);
        }
    }

    const win32 = b.createModule(.{
        .root_source_file = gen_out_dir.path(b, "win32.zig"),
    });

    buildcommon.addExamples(b, optimize, win32, b.path("examples"), if (autoexit) .yes else .no);

    // Exercise the Zig compiler's COM overload handling against the generated
    // Windows bindings for each arch. Run the exe when the target matches
    // the host; otherwise just compile-check.
    {
        const comoverload_step = b.step("comoverload", "");
        for ([_][]const u8{ "x86_64-windows", "aarch64-windows" }) |arch_os_abi| {
            const target_query = std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi }) catch unreachable;
            const target = b.resolveTargetQuery(target_query);
            const exe = b.addExecutable(.{
                .name = b.fmt("comoverload-{s}", .{arch_os_abi}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/comoverload.zig"),
                    .target = target,
                }),
            });
            exe.root_module.addImport("win32", win32);
            const runnable = builtin.os.tag == .windows and
                target.result.cpu.arch == builtin.cpu.arch;
            if (runnable) {
                const run = b.addRunArtifact(exe);
                comoverload_step.dependOn(&run.step);
                test_step.dependOn(&run.step);
            } else {
                comoverload_step.dependOn(&exe.step);
                test_step.dependOn(&exe.step);
            }
        }
    }
    {
        const compile = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build-exe",
            "-target",
            "x86_64-windows",
            "--dep",
            "win32",
        });
        compile.addPrefixedFileArg("-Mroot=", b.path("test/badcomoverload.zig"));
        compile.addPrefixedFileArg("-Mwin32=", gen_out_dir.path(b, "win32.zig"));
        compile.addCheck(.{
            .expect_stderr_match = "COM method 'GetAttributeValue' must be called using one of the following overload names: GetAttributeValueString, GetAttributeValueObj, GetAttributeValuePod",
        });
        test_step.dependOn(&compile.step);
    }
}

const PrintLazyPath = struct {
    step: Step,
    lazy_path: Build.LazyPath,
    pub fn create(
        b: *Build,
        lazy_path: Build.LazyPath,
    ) *PrintLazyPath {
        const print = b.allocator.create(PrintLazyPath) catch unreachable;
        print.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = "print the given lazy path",
                .owner = b,
                .makeFn = make,
            }),
            .lazy_path = lazy_path,
        };
        lazy_path.addStepDependencies(&print.step);
        return print;
    }
    fn make(step: *Step, opt: std.Build.Step.MakeOptions) !void {
        _ = opt;
        const print: *PrintLazyPath = @fieldParentPtr("step", step);

        const stdout = std.fs.File.stdout();
        var writer = stdout.writer(&.{});
        try writer.interface.print("{s}\n", .{print.lazy_path.getPath(step.owner)});
    }
};

fn addDefaultStepDeps(b: *std.Build, default_steps: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, default_steps, ' ');
    while (it.next()) |step_name| {
        const step = b.top_level_steps.get(step_name) orelse std.debug.panic(
            "step '{s}' not added yet",
            .{step_name},
        );
        b.default_step.dependOn(&step.step);
    }
}

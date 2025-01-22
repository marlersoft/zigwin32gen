const std = @import("std");

pub fn main() !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 3) {
        std.log.err("expected 3 cmdline arguments but got {}", .{cmd_args.len});
        return 0xff;
    }
    const out_path = cmd_args[0];
    const zig_exe = cmd_args[1];
    const win32_stub_path = cmd_args[2];

    try std.fs.cwd().deleteTree(out_path);
    try std.fs.cwd().makeDir(out_path);

    const root_file_path = try std.fs.path.join(arena, &.{ out_path, "root.zig" });
    // no need to free

    {
        const file = try std.fs.cwd().createFile(root_file_path, .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("generatefile.zig"));
    }

    const result = blk: {
        const root_mod_arg = try std.fmt.allocPrint(arena, "-Mroot={s}", .{root_file_path});
        defer arena.free(root_mod_arg);
        const win32_zig_mod_arg = try std.fmt.allocPrint(arena, "-Mwin32_stub={s}", .{win32_stub_path});
        defer arena.free(win32_zig_mod_arg);
        break :blk try std.process.Child.run(.{
            .argv = &.{
                zig_exe,
                "run",
                "--dep",
                "win32_stub",
                root_mod_arg,
                win32_zig_mod_arg,
            },
            .allocator = arena,
        });
    };
    try std.io.getStdErr().writer().writeAll(result.stderr);
    try std.io.getStdOut().writer().writeAll(result.stdout);
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.log.err("zig compile failed with exit code {}", .{code});
            return code;
        },
        else => std.debug.panic("zig terminated with {}", .{result}),
    }

    const zigexports_out = try std.fs.path.join(arena, &.{ out_path, "zigexports.zig" });
    defer arena.free(zigexports_out);

    {
        const file = try std.fs.cwd().createFile(zigexports_out, .{});
        defer file.close();
        try file.writeAll(result.stdout);
    }

    return 0;
}

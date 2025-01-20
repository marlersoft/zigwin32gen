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
    const zig_file = cmd_args[2];

    try std.fs.cwd().deleteTree(out_path);
    try std.fs.cwd().makeDir(out_path);

    const win32_dir_path = try std.fs.path.join(arena, &.{ out_path, "win32" });
    defer arena.free(win32_dir_path);
    try std.fs.cwd().makeDir(win32_dir_path);

    {
        const win32_src_path = try std.fs.path.join(arena, &.{ out_path, "win32.zig" });
        defer arena.free(win32_src_path);
        const file = try std.fs.cwd().createFile(win32_src_path, .{});
        defer file.close();
        // these types don't need to be correct, they're just placeholders to get our
        // zig.zig compiling enough so we can read it's public declarations
        try file.writeAll(
            \\pub const foundation = struct {
            \\    pub const BOOL = i32;
            \\    pub const WIN32_ERROR = enum {};
            \\    pub const HRESULT = i32;
            \\    pub const HWND = *opaque{};
            \\    pub const HANDLE = @import("std").os.windows.HANDLE;
            \\    pub const LPARAM = isize;
            \\    pub const POINT = struct{ };
            \\};
            \\pub const ui = struct {
            \\    pub const windows_and_messaging = struct {
            \\        pub const MESSAGEBOX_STYLE = struct{ };
            \\    };
            \\};
            \\
        );
    }

    const zig_file_out = try std.fs.path.join(arena, &.{ win32_dir_path, "zig.zig" });
    defer arena.free(zig_file_out);
    try std.fs.cwd().copyFile(zig_file, std.fs.cwd(), zig_file_out, .{});

    const root_file_path = try std.fs.path.join(arena, &.{ out_path, "root.zig" });
    // no need to free

    {
        const file = try std.fs.cwd().createFile(root_file_path, .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("generatefile.zig"));
    }

    const result = try std.process.Child.run(.{
        .argv = &.{ zig_exe, "run", root_file_path },
        .allocator = arena,
    });
    {
        const stdout_fixed1 = try std.mem.replaceOwned(u8, arena, result.stderr, zig_file_out, zig_file);
        defer arena.free(stdout_fixed1);
        const stdout_fixed2 = try std.mem.replaceOwned(u8, arena, result.stderr, root_file_path, "generatezigexports.zig");
        defer arena.free(stdout_fixed2);
        std.log.info("zig_file_out '{s}'", .{zig_file_out});
        std.log.info("root_file_path '{s}'", .{root_file_path});
        try std.io.getStdErr().writer().writeAll(stdout_fixed2);
    }
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

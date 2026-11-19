const std = @import("std");

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn usage(io: std.Io, zigbuild: bool) !void {
    const options = "[--nofetch|-n]";
    var out_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &out_buf);
    const stderr = &stderr_writer.interface;
    const parts: struct {
        diffrepo: []const u8,
        generated: []const u8,
    } = blk: {
        if (zigbuild) {
            try stderr.print("Usage: zig build diff -- {s}\n", .{options});
            break :blk .{
                .diffrepo = "the 'diffrepo' subdirectory",
                .generated = "the latest generated release",
            };
        }
        try stderr.print("Usage: diff.exe {s} DIFF_REPO GENERATED_PATH\n", .{options});
        break :blk .{
            .diffrepo = "DIFF_REPO",
            .generated = "GENERATED_PATH",
        };
    };
    try stderr.print(
        \\
        \\Updates {s} and installs {s}
        \\on top for diffing purposes.
        \\
        \\ --nofetch | -n   Disable fetching the latest 'main' branch for
        \\                  {0s}.
        \\
    ,
        .{ parts.diffrepo, parts.generated },
    );
    try stderr.flush();
}

const max_pos_args = 2;

pub fn main(init_options: std.process.Init.Minimal) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var threaded: std.Io.Threaded = .init(arena, .{ .environ = init_options.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var opt: struct {
        // indicates user is running from 'zig build diff' which affects
        // the usage output.
        zigbuild: bool = false,
        fetch: bool = true,
    } = .{};

    var pos_args: [max_pos_args][:0]const u8 = undefined;
    var pos_arg_count: usize = 0;
    {
        var it = try init_options.args.iterateAllocator(arena);
        // don't care about freeing args
        _ = it.skip(); // program name
        while (it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                if (pos_arg_count < max_pos_args) pos_args[pos_arg_count] = arg;
                pos_arg_count += 1;
            } else if (std.mem.eql(u8, arg, "--zigbuild")) {
                opt.zigbuild = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try usage(io, opt.zigbuild);
                std.process.exit(1);
            } else if (std.mem.eql(u8, arg, "--nofetch") or std.mem.eql(u8, arg, "-n")) {
                opt.fetch = false;
            } else fatal("unknown cmline option '{s}'", .{arg});
        }
    }
    if (pos_arg_count == 0) {
        try usage(io, opt.zigbuild);
        std.process.exit(1);
    }
    if (pos_arg_count != max_pos_args) fatal("expected {} positional cmdline arguments but got {}", .{ max_pos_args, pos_arg_count });
    const diff_repo = pos_args[0];
    const generated_path = pos_args[1];

    try makeRepo(io, diff_repo);

    if (opt.fetch) {
        try run(io, "git fetch", &.{ "git", "-C", diff_repo, "fetch", "origin", "main" });
    }
    try run(io, "git clean", &.{ "git", "-C", diff_repo, "clean", "-xffd" });
    try run(io, "git reset", &.{ "git", "-C", diff_repo, "reset", "--hard" });
    try run(io, "git checkout", &.{ "git", "-C", diff_repo, "checkout", "origin/main" });
    try run(io, "git clean", &.{ "git", "-C", diff_repo, "clean", "-xffd" });

    {
        var dir = try std.Io.Dir.cwd().openDir(io, diff_repo, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            std.log.info("rm -rf '{s}/{s}'", .{ diff_repo, entry.name });
            try dir.deleteTree(io, entry.name);
        }
    }

    std.log.info("copying generated files from '{s}'...", .{generated_path});
    try copyDir(
        io,
        std.Io.Dir.cwd(),
        generated_path,
        std.Io.Dir.cwd(),
        diff_repo,
    );

    try run(io, "git status", &.{ "git", "-C", diff_repo, "status" });
}

pub fn makeRepo(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => try gitInit(io, path),
        else => |e| return e,
    };
}
fn gitInit(io: std.Io, repo: []const u8) !void {
    var tmp_repo_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_repo = std.fmt.bufPrint(&tmp_repo_buf, "{s}.initializing", .{repo}) catch fatal(
        "path too long '{s}'",
        .{repo},
    );
    try std.Io.Dir.cwd().deleteTree(io, tmp_repo);
    try std.Io.Dir.cwd().createDir(io, tmp_repo, .default_dir);
    try run(io, "git init", &.{
        "git",
        "-C",
        tmp_repo,
        "init",
    });
    const zigwin32_repo_url = "https://github.com/marlersoft/zigwin32";
    try run(io, "git init", &.{
        "git",
        "-C",
        tmp_repo,
        "remote",
        "add",
        "origin",
        zigwin32_repo_url,
    });
    try std.Io.Dir.rename(.cwd(), tmp_repo, .cwd(), repo, io);
}

const FormatArgv = struct {
    argv: []const []const u8,
    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        var prefix: []const u8 = "";
        for (self.argv) |arg| {
            try writer.print("{s}{s}", .{ prefix, arg });
            prefix = " ";
        }
    }
};
pub fn fmtArgv(argv: []const []const u8) FormatArgv {
    return .{ .argv = argv };
}

const FormatTerm = struct {
    term: std.process.Child.Term,
    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        switch (self.term) {
            .exited => |code| try writer.print("exited with code {}", .{code}),
            .signal => |sig| try writer.print("exited with signal {t}", .{sig}),
            .stopped => |sig| try writer.print("stopped with signal {t}", .{sig}),
            .unknown => |sig| try writer.print("terminated abnormally with signal {}", .{sig}),
        }
    }
};
pub fn fmtTerm(term: std.process.Child.Term) FormatTerm {
    return .{ .term = term };
}

pub fn run(
    io: std.Io,
    name: []const u8,
    argv: []const []const u8,
) !void {
    std.log.info("{f}", .{fmtArgv(argv)});
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    if (!term.success()) {
        fatal("{s} {f}", .{ name, fmtTerm(term) });
    }
}

fn copyDir(
    io: std.Io,
    src_parent_dir: std.Io.Dir,
    src_path: []const u8,
    dst_parent_dir: std.Io.Dir,
    dst_path: []const u8,
) !void {
    var dst_dir = try dst_parent_dir.openDir(io, dst_path, .{});
    defer dst_dir.close(io);
    var src_dir = try src_parent_dir.openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                try dst_dir.createDir(io, entry.name, .default_dir);
                try copyDir(io, src_dir, entry.name, dst_dir, entry.name);
            },
            .file => try src_dir.copyFile(
                entry.name,
                dst_dir,
                entry.name,
                io,
                .{},
            ),
            else => |kind| fatal("unsupported file kind '{s}'", .{@tagName(kind)}),
        }
    }
}

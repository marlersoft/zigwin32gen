const std = @import("std");
const Io = std.Io;

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn usage(io: Io, zigbuild: bool) !void {
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

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var threaded: Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var opt: struct {
        // indicates user is running from 'zig build diff' which affects
        // the usage output.
        zigbuild: bool = false,
        fetch: bool = true,
    } = .{};

    const cmd_pos_args = blk: {
        const all_args = try std.process.argsAlloc(arena);
        // don't care about freeing args
        var pos_arg_count: usize = 0;
        var arg_index: usize = 1;
        while (arg_index < all_args.len) {
            const arg = all_args[arg_index];
            arg_index += 1;
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[pos_arg_count] = arg;
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
        break :blk all_args[0..pos_arg_count];
    };
    if (cmd_pos_args.len == 0) {
        try usage(io, opt.zigbuild);
        std.process.exit(1);
    }
    if (cmd_pos_args.len != 2) fatal("expected 2 positional cmdline arguments but got {}", .{cmd_pos_args.len});
    const diff_repo = cmd_pos_args[0];
    const generated_path = cmd_pos_args[1];

    try makeRepo(io, diff_repo);

    if (opt.fetch) {
        try run(arena, io, "git fetch", &.{ "git", "-C", diff_repo, "fetch", "origin", "main" });
    }
    try run(arena, io, "git clean", &.{ "git", "-C", diff_repo, "clean", "-xffd" });
    try run(arena, io, "git reset", &.{ "git", "-C", diff_repo, "reset", "--hard" });
    try run(arena, io, "git checkout", &.{ "git", "-C", diff_repo, "checkout", "origin/main" });
    try run(arena, io, "git clean", &.{ "git", "-C", diff_repo, "clean", "-xffd" });

    const cwd = std.Io.Dir.cwd();
    {
        var dir = try cwd.openDir(io, diff_repo, .{ .iterate = true });
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
        cwd,
        generated_path,
        cwd,
        diff_repo,
        io,
    );

    try run(arena, io, "git status", &.{ "git", "-C", diff_repo, "status" });
}

pub fn makeRepo(io: Io, path: []const u8) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => try gitInit(io, path),
        else => |e| return e,
    };
}
fn gitInit(io: Io, repo: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const tmp_repo = try std.mem.concat(allocator, u8, &.{ repo, ".initializing" });
    defer allocator.free(tmp_repo);
    try cwd.deleteTree(io, tmp_repo);
    try cwd.createDir(io, tmp_repo, .default_dir);
    try run(allocator, io, "git init", &.{
        "git",
        "-C",
        tmp_repo,
        "init",
    });
    const zigwin32_repo_url = "https://github.com/marlersoft/zigwin32";
    try run(allocator, io, "git init", &.{
        "git",
        "-C",
        tmp_repo,
        "remote",
        "add",
        "origin",
        zigwin32_repo_url,
    });
    try cwd.rename(tmp_repo, cwd, repo, io);
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

pub fn childProcFailed(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code != 0,
        .Signal => true,
        .Stopped => true,
        .Unknown => true,
    };
}
const FormatTerm = struct {
    term: std.process.Child.Term,
    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        switch (self.term) {
            .Exited => |code| try writer.print("exited with code {}", .{code}),
            .Signal => |sig| try writer.print("exited with signal {}", .{sig}),
            .Stopped => |sig| try writer.print("stopped with signal {}", .{sig}),
            .Unknown => |sig| try writer.print("terminated abnormally with signal {}", .{sig}),
        }
    }
};
pub fn fmtTerm(term: std.process.Child.Term) FormatTerm {
    return .{ .term = term };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    name: []const u8,
    argv: []const []const u8,
) !void {
    var child = std.process.Child.init(argv, allocator);
    std.log.info("{f}", .{fmtArgv(child.argv)});
    try child.spawn(io);
    const term = try child.wait(io);
    if (childProcFailed(term)) {
        fatal("{s} {f}", .{ name, fmtTerm(term) });
    }
}

fn copyDir(
    src_parent_dir: std.Io.Dir,
    src_path: []const u8,
    dst_parent_dir: std.Io.Dir,
    dst_path: []const u8,
    io: Io,
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
                try copyDir(src_dir, entry.name, dst_dir, entry.name, io);
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

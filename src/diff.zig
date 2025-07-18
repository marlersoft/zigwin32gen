const std = @import("std");

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn usage(zigbuild: bool) !void {
    const options = "[--nofetch|-n]";

    var buf: [64]u8 = undefined;
    const w = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStderrWriter();

    const parts: struct {
        diffrepo: []const u8,
        generated: []const u8,
    } = blk: {
        if (zigbuild) {
            try w.print("Usage: zig build diff -- {s}\n", .{options});
            break :blk .{
                .diffrepo = "the 'diffrepo' subdirectory",
                .generated = "the latest generated release",
            };
        }
        try w.print("Usage: diff.exe {s} DIFF_REPO GENERATED_PATH\n", .{options});
        break :blk .{
            .diffrepo = "DIFF_REPO",
            .generated = "GENERATED_PATH",
        };
    };
    try w.print(
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
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

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
                try usage(opt.zigbuild);
                std.process.exit(1);
            } else if (std.mem.eql(u8, arg, "--nofetch") or std.mem.eql(u8, arg, "-n")) {
                opt.fetch = false;
            } else fatal("unknown cmline option '{s}'", .{arg});
        }
        break :blk all_args[0..pos_arg_count];
    };
    if (cmd_pos_args.len == 0) {
        try usage(opt.zigbuild);
        std.process.exit(1);
    }
    if (cmd_pos_args.len != 2) fatal("expected 2 positional cmdline arguments but got {}", .{cmd_pos_args.len});
    const diff_repo = cmd_pos_args[0];
    const generated_path = cmd_pos_args[1];

    try makeRepo(diff_repo);

    if (opt.fetch) {
        try run(arena, "git fetch", &.{ "git", "-C", diff_repo, "fetch", "origin", "main" });
    }
    try run(arena, "git clean", &.{ "git", "-C", diff_repo, "clean", "-xffd" });
    try run(arena, "git reset", &.{ "git", "-C", diff_repo, "reset", "--hard" });
    try run(arena, "git checkout", &.{ "git", "-C", diff_repo, "checkout", "origin/main" });
    try run(arena, "git clean", &.{ "git", "-C", diff_repo, "clean", "-xffd" });

    {
        var dir = try std.fs.cwd().openDir(diff_repo, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            std.log.info("rm -rf '{s}/{s}'", .{ diff_repo, entry.name });
            try dir.deleteTree(entry.name);
        }
    }

    std.log.info("copying generated files from '{s}'...", .{generated_path});
    try copyDir(
        std.fs.cwd(),
        generated_path,
        std.fs.cwd(),
        diff_repo,
    );

    try run(arena, "git status", &.{ "git", "-C", diff_repo, "status" });
}

pub fn makeRepo(path: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => try gitInit(path),
        else => |e| return e,
    };
}
fn gitInit(repo: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tmp_repo = try std.mem.concat(allocator, u8, &.{ repo, ".initializing" });
    defer allocator.free(tmp_repo);
    try std.fs.cwd().deleteTree(tmp_repo);
    try std.fs.cwd().makeDir(tmp_repo);
    try run(allocator, "git init", &.{
        "git",
        "-C",
        tmp_repo,
        "init",
    });
    const zigwin32_repo_url = "https://github.com/marlersoft/zigwin32";
    try run(allocator, "git init", &.{
        "git",
        "-C",
        tmp_repo,
        "remote",
        "add",
        "origin",
        zigwin32_repo_url,
    });
    try std.fs.cwd().rename(tmp_repo, repo);
}

const FormatArgv = struct {
    argv: []const []const u8,
    pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
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
    pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
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
    name: []const u8,
    argv: []const []const u8,
) !void {
    var child = std.process.Child.init(argv, allocator);
    std.log.info("{f}", .{fmtArgv(child.argv)});
    try child.spawn();
    const term = try child.wait();
    if (childProcFailed(term)) {
        fatal("{s} {f}", .{ name, fmtTerm(term) });
    }
}

fn copyDir(
    src_parent_dir: std.fs.Dir,
    src_path: []const u8,
    dst_parent_dir: std.fs.Dir,
    dst_path: []const u8,
) !void {
    var dst_dir = try dst_parent_dir.openDir(dst_path, .{});
    defer dst_dir.close();
    var src_dir = try src_parent_dir.openDir(src_path, .{ .iterate = true });
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                try dst_dir.makeDir(entry.name);
                try copyDir(src_dir, entry.name, dst_dir, entry.name);
            },
            .file => try src_dir.copyFile(
                entry.name,
                dst_dir,
                entry.name,
                .{},
            ),
            else => |kind| fatal("unsupported file kind '{s}'", .{@tagName(kind)}),
        }
    }
}

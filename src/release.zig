const std = @import("std");
const common = @import("common.zig");
const fatal = common.fatal;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

fn oom(e: error{OutOfMemory}) noreturn {
    fatal("{s}", .{@errorName(e)});
}

pub fn main() !u8 {
    const all_args = try std.process.argsAlloc(allocator);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 5) {
        std.log.err("expected 4 cmdline arguments but got {}", .{cmd_args.len});
        return 1;
    }
    const gen_repo = cmd_args[0];
    const main_sha_file_path = cmd_args[1];
    const releases_file_path = cmd_args[2];
    const zigwin32_repo = cmd_args[3];
    const clean_arg = cmd_args[4];

    const do_clean = if (
        std.mem.eql(u8, clean_arg, "noclean")
    ) false else if (
        std.mem.eql(u8, clean_arg, "clean")
    ) true else fatal("unexpected clean cmdline argument '{s}'", .{clean_arg});

    const main_sha = switch (try common.readSha(main_sha_file_path)) {
        .invalid => |reason| fatal(
            "read sha from '{s}' failed: {s}", .{main_sha_file_path, reason}
        ),
        .good => |sha| sha,
    };
    std.log.info("main: {s}", .{&main_sha});

    try common.run(allocator, "git ", &.{
        "git", "checkout", "HEAD", "--", releases_file_path
    });

    // check if this commit has already been released
    if (try isReleased(releases_file_path, main_sha)) {
        std.log.info("commit {s}: already released", .{main_sha});
        return 0;
    }

    const revlist_full = blk: {
        const argv = [_][]const u8 {
            "git",
            "-C", gen_repo,
            "rev-list",
            &main_sha,
        };
        std.log.info("{}", .{common.fmtArgv(&argv)});
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
        });
        // don't free stdout, we're using it
        //defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.stderr.len > 0) {
            try std.io.getStdErr().writer().writeAll(result.stderr);
        }
        if (common.childProcFailed(result.term))
            fatal("git rev-list {}", .{common.fmtTerm(result.term)});
        break :blk result.stdout;
    };
    defer allocator.free(revlist_full);

    const revlist = blk: {
        var it = std.mem.splitAny(u8, revlist_full, "\r\n");
        const first = it.first();
        if (!std.mem.eql(u8, first, &main_sha)) fatal(
            "expected first commit rev-list to be '{s}' but is '{s}'",
            .{ &main_sha, first},
        );
        break :blk std.mem.trimRight(u8, it.rest(), "\n");
    };

    // verify revs are valid SHAs
    {
        var it = std.mem.splitAny(u8, revlist, "\r\n");
        while (it.next()) |rev| {
            if (rev.len != 40) fatal(
                "invalid rev from rev-list output '{s}'", .{rev}
            );
        }
    }


    const releases_text = try readReleases(releases_file_path);
    defer allocator.free(releases_text);
    const latest_release: Release = blk: {
        var line_no: u32 = 1;
        var lines_it = std.mem.splitScalar(
            u8,
            std.mem.trimRight(u8, releases_text, "\n"),
            '\n',
        );
        var latest: ?Release = null;
        while (lines_it.next()) |line| : (line_no += 1) {
            const result = switch (parseLine(line)) {
                .err => |msg| fatal(
                    "{s}: line {}: {s}",
                    .{releases_file_path, line_no, msg},
                ),
                .ok => |ok| ok,
            };
            latest = .{
                .number = line_no,
                .gen_commit = result.gen_commit,
                .result_commit = result.result_commit,
            };
        }
        break :blk latest orelse fatal(
            "{s}: has no releases", .{releases_file_path}
        );
    };
    std.log.info("latest release: {s}", .{latest_release.gen_commit});

    // make sure the latest release is an ancestor of ours
    const ahead = blk: {
        var ahead: u32 = 1;
        var it = std.mem.splitAny(u8, revlist, "\r\n");
        while (it.next()) |rev| : (ahead += 1) {
            if (std.mem.eql(u8, latest_release.gen_commit, rev))
                break :blk ahead;
        }
        fatal(
            "latest release commit {s} is not a parent of main commit {s}",
            .{ latest_release.gen_commit, &main_sha },
        );
    };
    std.log.info("main is {} commit(s) ahead of latest release", .{ahead});

    if (do_clean) {
        try common.run(allocator, "git clean", &.{
            "git", "-C", gen_repo, "clean", "-xffd",
        });
    }
    try common.run(allocator, "git reset", &.{
        "git", "-C", gen_repo, "reset", "--hard"
    });
    try common.run(allocator, "git checkout", &.{
        "git", "-C", gen_repo, "checkout", &main_sha,
    });
    if (do_clean) {
        try common.run(allocator, "git clean", &.{
            "git", "-C", gen_repo, "clean", "-xffd",
        });
    }

    const zig_out = try std.fs.path.join(allocator, &.{gen_repo, "zig-out"});
    defer allocator.free(zig_out);
    try std.fs.cwd().deleteTree(zig_out);

    const build_zig = try std.fs.path.join(allocator, &.{gen_repo, "build.zig"});
    defer allocator.free(build_zig);

    try common.run(allocator, "zig build", &.{
        "zig",
        "build",
        "--build-file",
        build_zig,
        "release",
    });

    try common.makeRepo(zigwin32_repo);


    const have_commit = blk: {
        const argv = [_][]const u8 {
            "git",
            "-C", zigwin32_repo,
            "cat-file",
            "-t", latest_release.result_commit,
        };
        std.log.info("{}", .{common.fmtArgv(&argv)});
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.stderr.len > 0) {
            try std.io.getStdErr().writer().writeAll(result.stderr);
        }
        if (common.childProcFailed(result.term)) {
            std.log.info(
                "git cat-file {}",
                .{common.fmtTerm(result.term)}
            );
            break :blk false;
        }
        const stdout = std.mem.trimRight(u8, result.stdout, "\r\n");
        std.debug.assert(std.mem.eql(u8, stdout, "commit"));
        break :blk true;
    };

    const zigwin32_repo_url = "https://github.com/marlersoft/zigwin32";
    if (have_commit) {
        std.log.info("skipping git fetch in zigwin32 repo, we already have the release commit", .{});
    } else {
        try common.run(allocator, "git fetch", &.{
            "git",
            "-C", zigwin32_repo,
            "fetch",
            zigwin32_repo_url,
            latest_release.result_commit,
        });
    }

    try common.run(allocator, "git clean", &.{
        "git", "-C", zigwin32_repo, "clean", "-xffd",
    });
    try common.run(allocator, "git reset", &.{
        "git", "-C", zigwin32_repo, "reset", "--hard"
    });
    try common.run(allocator, "git checkout", &.{
        "git", "-C", zigwin32_repo, "checkout", latest_release.result_commit,
    });
    try common.run(allocator, "git clean", &.{
        "git", "-C", zigwin32_repo, "clean", "-xffd",
    });

    {
        var dir = try std.fs.cwd().openDir(zigwin32_repo, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            std.log.info("rm -rf '{s}/{s}'", .{zigwin32_repo, entry.name});
            try dir.deleteTree(entry.name);
        }
    }

    try copyDir(
        std.fs.cwd(), zig_out,
        std.fs.cwd(), zigwin32_repo,
    );

    try common.run(allocator, "git status", &.{
        "git", "-C", zigwin32_repo, "status"
    });
    try common.run(allocator, "git status", &.{
        "git", "-C", zigwin32_repo, "add", "."
    });

    {
        const commit_msg = try std.fmt.allocPrint(
            allocator,
            "release commit {s}",
            .{&main_sha},
        );
        defer allocator.free(commit_msg);
        try common.run(allocator, "git status", &.{
            "git", "-C", zigwin32_repo, "commit",
            "-m", commit_msg
        });
    }

    // verify we are now in a clean state
    {
        const argv = [_][]const u8 {
            "git",
            "-C", zigwin32_repo,
            "status",
            "--porcelain",
        };
        std.log.info("{}", .{common.fmtArgv(&argv)});
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
        });
        defer {
            allocator.free(result.stderr);
            allocator.free(result.stdout);
        }
        if (result.stderr.len > 0) {
            try std.io.getStdErr().writer().writeAll(result.stderr);
        }
        if (common.childProcFailed(result.term))
            fatal("git status {}", .{common.fmtTerm(result.term)});
        if (result.stdout.len != 0) fatal(
            "git status is showing the following changes after a commit!\n{s}\n",
            .{result.stdout},
        );
    }

    const git_rev_parse_stdout = blk: {
        const argv = [_][]const u8 {
            "git",
            "-C", zigwin32_repo,
            "rev-parse",
            "HEAD",
        };
        std.log.info("{}", .{common.fmtArgv(&argv)});
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
        });
        // keep result.stdout
        defer allocator.free(result.stderr);
        if (result.stderr.len > 0) {
            try std.io.getStdErr().writer().writeAll(result.stderr);
        }
        if (common.childProcFailed(result.term))
            fatal("git rev-parse {}", .{common.fmtTerm(result.term)});
        break :blk result.stdout;
    };
    defer allocator.free(git_rev_parse_stdout);
    const new_result_commit = std.mem.trimRight(u8, git_rev_parse_stdout, "\r\n");
    if (new_result_commit.len != 40) fatal(
        "git rev-parse printed invalid sha '{s}'",
        .{new_result_commit},
    );

    {
        var file = try std.fs.cwd().openFile(releases_file_path, .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writer().print("{s} {s}\n", .{&main_sha, new_result_commit});
    }

    std.log.info(
        (
            "push the release with these commands:\n" ++
            "git -C {s} push {s} {s}:main\n" ++
            "git add .\n" ++
            "git commit -m \"new release\"\n" ++
            "git push origin HEAD:release\n"
        ),
        .{
            zigwin32_repo,
            zigwin32_repo_url,
            new_result_commit,
        },
    );
    return 0;
}

fn isReleased(releases_file_path: []const u8, sha: [40]u8) !bool {
    const releases_text = try readReleases(releases_file_path);
    defer allocator.free(releases_text);
    const releases_text_trimmed = std.mem.trimRight(u8, releases_text, "\n");

    var line_no: u32 = 1;
    var lines_it = std.mem.splitScalar(u8, releases_text_trimmed, '\n');
    while (lines_it.next()) |line| : (line_no += 1) {
        const release = switch (parseLine(line)) {
            .err => |msg| fatal(
                "{s}: line {}: {s}",
                .{releases_file_path, line_no, msg},
            ),
            .ok => |release| release,
        };
        if (std.mem.eql(u8, release.gen_commit, &sha))
            return true;
    }
    return false;
}

fn readReleases(file_path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    return try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
}

const Release = struct {
    number: u32,
    gen_commit: []const u8,
    result_commit: []const u8,
};
const ParseResult = union(enum) {
    err: []const u8,
    ok: struct {
        gen_commit: []const u8,
        result_commit: []const u8,
    },
};
fn parseLine(line: []const u8) ParseResult {
    var field_it = std.mem.splitScalar(u8, line, ' ');
    const gen_commit = field_it.first();
    if (gen_commit.len != 40) return .{
        .err = std.fmt.allocPrint(
            allocator, "invalid gen commit: '{s}'", .{gen_commit}
        ) catch |e| oom(e),
    };
    const result_commit = field_it.next() orelse return .{
        .err = std.fmt.allocPrint(
            allocator, "missing ' ' to separate commit fields", .{}
        ) catch |e| oom(e),
    };
    if (field_it.next()) |_| return .{
        .err = std.fmt.allocPrint(
            allocator, "too many fields separated by ' '", .{}
        ) catch |e| oom(e),
    };
    if (result_commit.len != 40) return .{
        .err = std.fmt.allocPrint(
            allocator, "invalid result commit: '{s}'", .{result_commit}
        ) catch |e| oom(e),
    };
    return .{
        .ok = .{
            .gen_commit = gen_commit,
            .result_commit = result_commit,
        },
    };
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
                try copyDir(
                    src_dir, entry.name, dst_dir, entry.name
                );
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

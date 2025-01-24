const std = @import("std");
const common = @import("common.zig");
const fatal = common.fatal;

const zigwin32_repo_url = "https://github.com/marlersoft/zigwin32";

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

    const do_clean = if (std.mem.eql(u8, clean_arg, "noclean"))
        false
    else if (std.mem.eql(u8, clean_arg, "clean"))
        true
    else
        fatal("unexpected clean cmdline argument '{s}'", .{clean_arg});

    const main_sha = switch (try common.readSha(main_sha_file_path)) {
        .invalid => |reason| fatal("read sha from '{s}' failed: {s}", .{ main_sha_file_path, reason }),
        .good => |sha| sha,
    };
    std.log.info("main: {s}", .{&main_sha});

    if (false) {
        try common.run(allocator, "git ", &.{ "git", "checkout", "HEAD", "--", releases_file_path });
    }

    var count: u32 = 0;
    while (true) : (count += 1) {
        std.log.info("--------------------------------------------------", .{});
        const release = (try generateOneCommit(
            gen_repo,
            releases_file_path,
            zigwin32_repo,
            do_clean,
            main_sha,
            count,
        )) orelse {
            break;
        };
        {
            var file = try std.fs.cwd().openFile(releases_file_path, .{ .mode = .read_write });
            defer file.close();
            try file.seekFromEnd(0);
            try file.writer().print("pass {s} {s}\n", .{ &release.gen_commit, &release.result_commit });
        }
    }

    std.log.info("--------------------------------------------------", .{});
    std.log.info("generated {} release entries", .{count});
    std.log.info("--------------------------------------------------", .{});
    const latest_release = try readLatestRelease(releases_file_path);
    std.log.warn(
        "TODO: check if there are any changes to commit (i.e. git status releases.txt and check commit for zigwin32 repo)",
        .{},
    );
    std.log.info(
        ("push the release with these commands:\n" ++
            "git -C {s} push {s} {s}:main\n" ++
            "git add .\n" ++
            "git commit -m \"new release\"\n" ++
            "git push origin HEAD:release\n"),
        .{
            zigwin32_repo,
            zigwin32_repo_url,
            latest_release.result_commit,
        },
    );
    return 0;
}

fn generateOneCommit(
    gen_repo: []const u8,
    releases_file_path: []const u8,
    zigwin32_repo: []const u8,
    do_clean: bool,
    main_sha: [40]u8,
    commit_count: u32,
) !?struct { gen_commit: [40]u8, result_commit: [40]u8 } {
    const revlist_full = blk: {
        const argv = [_][]const u8{
            "git",
            "-C",
            gen_repo,
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
            .{ &main_sha, first },
        );
        break :blk std.mem.trimRight(u8, it.rest(), "\n");
    };

    // verify revs are valid SHAs
    {
        var it = std.mem.splitAny(u8, revlist, "\r\n");
        while (it.next()) |rev| {
            if (rev.len != 40) fatal("invalid rev from rev-list output '{s}'", .{rev});
        }
    }

    const latest_release = try readLatestRelease(releases_file_path);
    std.log.info("latest release: {s}", .{latest_release.gen_commit});
    if (std.mem.eql(u8, &latest_release.gen_commit, &main_sha))
        return null;

    const gen_commit, const gen_commit_depth = blk: {
        var previous: [40]u8 = main_sha;
        var count: u32 = 1;
        var it = std.mem.splitAny(u8, revlist, "\r\n");
        while (it.next()) |rev| : (count += 1) {
            std.debug.assert(rev.len == 40);
            if (std.mem.eql(u8, &latest_release.gen_commit, rev)) {
                break :blk .{ previous, count };
            }
            previous = rev[0..40].*;
        }
        fatal(
            "latest release commit {s} is not a parent of main commit {s}",
            .{ latest_release.gen_commit, &main_sha },
        );
    };
    std.log.info("--------------------------------------------------", .{});
    std.log.info("generating commit {} ({} after this): {s}", .{ commit_count + 1, gen_commit_depth - 1, gen_commit });
    std.log.info("--------------------------------------------------", .{});
    // TODO: maybe print the git log to stdout for convenience in the log

    if (do_clean) {
        try common.run(allocator, "git clean", &.{
            "git", "-C", gen_repo, "clean", "-xffd",
        });
    }
    try common.run(allocator, "git reset", &.{ "git", "-C", gen_repo, "reset", "--hard" });
    try common.run(allocator, "git checkout", &.{
        "git", "-C", gen_repo, "checkout", &gen_commit,
    });
    if (do_clean) {
        try common.run(allocator, "git clean", &.{
            "git", "-C", gen_repo, "clean", "-xffd",
        });
    }

    const zig_out = try std.fs.path.join(allocator, &.{ gen_repo, "zig-out" });
    defer allocator.free(zig_out);
    try std.fs.cwd().deleteTree(zig_out);

    const build_zig = try std.fs.path.join(allocator, &.{ gen_repo, "build.zig" });
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
        const argv = [_][]const u8{
            "git",
            "-C",
            zigwin32_repo,
            "cat-file",
            "-t",
            &latest_release.result_commit,
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
            std.log.info("git cat-file {}", .{common.fmtTerm(result.term)});
            break :blk false;
        }
        const stdout = std.mem.trimRight(u8, result.stdout, "\r\n");
        std.debug.assert(std.mem.eql(u8, stdout, "commit"));
        break :blk true;
    };

    if (have_commit) {
        std.log.info("skipping git fetch in zigwin32 repo, we already have this commit", .{});
    } else {
        try common.run(allocator, "git fetch", &.{
            "git",
            "-C",
            zigwin32_repo,
            "fetch",
            zigwin32_repo_url,
            &latest_release.result_commit,
        });
    }

    try common.run(allocator, "git clean", &.{
        "git", "-C", zigwin32_repo, "clean", "-xffd",
    });
    try common.run(allocator, "git reset", &.{ "git", "-C", zigwin32_repo, "reset", "--hard" });
    try common.run(allocator, "git checkout", &.{
        "git", "-C", zigwin32_repo, "checkout", &latest_release.result_commit,
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
            std.log.info("rm -rf '{s}/{s}'", .{ zigwin32_repo, entry.name });
            try dir.deleteTree(entry.name);
        }
    }

    try copyDir(
        std.fs.cwd(),
        zig_out,
        std.fs.cwd(),
        zigwin32_repo,
    );

    {
        const status = try common.gitStatusPorcelain(allocator, zigwin32_repo);
        defer allocator.free(status);
        const trimmed = std.mem.trimRight(u8, status, "\r\n");
        if (trimmed.len == 0) {
            std.log.info("this commit has no changes to release", .{});
            return .{ .gen_commit = gen_commit, .result_commit = latest_release.result_commit[0..40].* };
        }
    }

    try common.run(allocator, "git status", &.{ "git", "-C", zigwin32_repo, "status" });
    try common.run(allocator, "git status", &.{ "git", "-C", zigwin32_repo, "add", "." });

    {
        const body = try gitLog(gen_repo, gen_commit, "--pretty=%B");
        defer allocator.free(body);
        const author = try gitLog(gen_repo, gen_commit, "--pretty=%an <%ae>");
        defer allocator.free(author);
        const date = try gitLog(gen_repo, gen_commit, "--pretty=%aD");
        try common.run(allocator, "git status", &.{
            "git",
            "-C",
            zigwin32_repo,
            "commit",
            "-m",
            body,
            "--author",
            author,
            "--date",
            date,
        });
    }

    // verify we are now in a clean state
    {
        const status = try common.gitStatusPorcelain(allocator, zigwin32_repo);
        defer allocator.free(status);
        if (status.len != 0) fatal(
            "git status is showing the following changes after a commit!\n{s}\n",
            .{status},
        );
    }

    const git_rev_parse_stdout = blk: {
        const argv = [_][]const u8{
            "git",
            "-C",
            zigwin32_repo,
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
    return .{ .gen_commit = gen_commit, .result_commit = new_result_commit[0..40].* };
}

fn readLatestRelease(file_path: []const u8) !Release {
    const releases_text = blk: {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        break :blk try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    };
    defer allocator.free(releases_text);

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
                .{ file_path, line_no, msg },
            ),
            .ok => |ok| ok,
        };
        latest = .{
            .number = line_no,
            .gen_commit = result.gen_commit,
            .result_commit = result.result_commit,
        };
    }
    return latest orelse fatal("{s}: has no releases", .{file_path});
}

fn shaDotDotSha(a: [40]u8, b: [40]u8) [82]u8 {
    var result: [82]u8 = undefined;
    @memcpy(result[0..40], &a);
    result[40] = '.';
    result[41] = '.';
    @memcpy(result[42..], &b);
    return result;
}

fn gitRevListCount(repo: []const u8, a: [40]u8, b: [40]u8) !u32 {
    const shas_arg = shaDotDotSha(a, b);
    const argv = [_][]const u8{
        "git",
        "-C",
        repo,
        "rev-list",
        "--count",
        &shas_arg,
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
    if (common.childProcFailed(result.term))
        fatal("git rev-list --count {}", .{common.fmtTerm(result.term)});
    const count_str = std.mem.trimRight(u8, result.stdout, "\n\r");
    return std.fmt.parseInt(u32, count_str, 10) catch std.debug.panic(
        "failed to parsse 'git rev-list --count' output as a number: '{s}'",
        .{count_str},
    );
}

fn gitLog(repo: []const u8, commit: [40]u8, format: []const u8) ![]const u8 {
    const argv = [_][]const u8{
        "git",
        "-C",
        repo,
        "log",
        "-1",
        format,
        &commit,
    };
    std.log.info("{}", .{common.fmtArgv(&argv)});
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
    });
    defer allocator.free(result.stderr);
    if (result.stderr.len > 0) {
        try std.io.getStdErr().writer().writeAll(result.stderr);
    }
    if (common.childProcFailed(result.term)) fatal("git log {}", .{common.fmtTerm(result.term)});
    return result.stdout;
}

const GenStatus = enum {
    pass,
    fail,
};
const Release = struct {
    number: u32,
    gen_commit: [40]u8,
    result_commit: [40]u8,
};
const ParseResult = union(enum) {
    err: []const u8,
    ok: struct {
        status: GenStatus,
        gen_commit: [40]u8,
        result_commit: [40]u8,
    },
};
fn parseLine(line: []const u8) ParseResult {
    var field_it = std.mem.splitScalar(u8, line, ' ');
    const status_str = field_it.first();
    const status: GenStatus = blk: {
        if (std.mem.eql(u8, status_str, "pass")) break :blk .pass;
        if (std.mem.eql(u8, status_str, "fail")) break :blk .fail;
        return .{ .err = std.fmt.allocPrint(allocator, "line does not being with 'pass' or 'fail', got '{s}'", .{status_str}) catch |e| oom(e) };
    };

    const gen_commit = field_it.next() orelse return .{
        .err = std.fmt.allocPrint(allocator, "missing ' ' to separate status/commit fields", .{}) catch |e| oom(e),
    };
    if (gen_commit.len != 40) return .{
        .err = std.fmt.allocPrint(allocator, "invalid gen commit: '{s}'", .{gen_commit}) catch |e| oom(e),
    };
    const result_commit = field_it.next() orelse return .{
        .err = std.fmt.allocPrint(allocator, "missing ' ' to separate commit fields", .{}) catch |e| oom(e),
    };
    if (field_it.next()) |_| return .{
        .err = std.fmt.allocPrint(allocator, "too many fields separated by ' '", .{}) catch |e| oom(e),
    };
    if (result_commit.len != 40) return .{
        .err = std.fmt.allocPrint(allocator, "invalid result commit: '{s}'", .{result_commit}) catch |e| oom(e),
    };
    return .{
        .ok = .{
            .status = status,
            .gen_commit = gen_commit[0..40].*,
            .result_commit = result_commit[0..40].*,
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

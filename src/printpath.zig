//! Prints its single command-line argument (a path) to stdout.
//! Used by the build to show cache paths of generated files.
pub fn main(init: std.process.Init.Minimal) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const path = blk: {
        var it = try init.args.iterateAllocator(arena);
        _ = it.skip(); // program name
        const path = it.next();
        if (path == null or it.next() != null) {
            std.log.err("usage: printpath PATH", .{});
            std.process.exit(0xff);
        }
        break :blk path.?;
    };

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    print(&stdout.interface, path) catch return stdout.err.?;
}

fn print(w: *std.Io.Writer, path: []const u8) error{WriteFailed}!void {
    try w.print("{s}\n", .{path});
    try w.flush();
}

const std = @import("std");

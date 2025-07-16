const std = @import("std");
const win32_stub = @import("win32_stub");
const zig = win32_stub.zig;

// make win32/zig.zig happy
pub const UNICODE = true;

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const all_args = try std.process.argsAlloc(arena);
    // don't care about freeing args

    const cmd_args = all_args[1..];
    if (cmd_args.len != 1) {
        std.log.err("expected 1 cmdline argument but got {}", .{cmd_args.len});
        std.process.exit(0xff);
    }
    const out_file_path = cmd_args[0];

    const out_file = try std.fs.cwd().createFile(out_file_path, .{});
    defer out_file.close();

    var buf: [4096]u8 = undefined;
    var out_file_writer = out_file.writer(&buf);
    var w = &out_file_writer.interface;

    try generate(w);
    try w.flush();
}

fn generate(writer: *std.io.Writer) !void {
    try writer.writeAll("pub const Kind = enum { constant, type, function };\n");
    try writer.writeAll("pub const Decl = struct { kind: Kind, name: []const u8};\n");
    try writer.writeAll("pub const declarations = [_]Decl{\n");
    inline for (comptime std.meta.declarations(zig)) |decl| {
        const field_type_info = @typeInfo(@TypeOf(@field(zig, decl.name)));
        const kind = switch (comptime field_type_info) {
            .bool, .int, .@"enum" => "constant",
            .@"fn" => "function",
            .type => "type",
            else => @compileError(
                "zig.zig decl '" ++ decl.name ++ "' has unsupported type info: " ++ @tagName(field_type_info),
            ),
        };
        try writer.print("    .{{ .kind = .{s}, .name = \"{s}\" }},\n", .{ kind, decl.name });
    }
    try writer.writeAll("};\n");
}

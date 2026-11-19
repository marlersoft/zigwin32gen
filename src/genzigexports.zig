const std = @import("std");
const win32_stub = @import("win32_stub");
const zig = win32_stub.zig;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const out_file_path = blk: {
        var it = try init.args.iterateAllocator(arena);
        _ = it.skip(); // program name
        const out_file_path = it.next();
        if (out_file_path == null or it.next() != null) {
            std.log.err("usage: genzigexports OUT_FILE", .{});
            std.process.exit(0xff);
        }
        break :blk out_file_path.?;
    };

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const out_file = try std.Io.Dir.cwd().createFile(io, out_file_path, .{});
    defer out_file.close(io);

    var out_buf: [4096]u8 = undefined;
    var w = out_file.writer(io, &out_buf);
    generate(&w.interface) catch return w.err.?;
}
fn generate(writer: *std.Io.Writer) error{WriteFailed}!void {
    try writer.writeAll("pub const Kind = enum { constant, type, function };\n");
    try writer.writeAll("pub const Decl = struct { kind: Kind, name: []const u8};\n");
    try writer.writeAll("pub const declarations = [_]Decl{\n");
    inline for (comptime @typeInfo(zig).@"struct".decl_names) |decl_name| {
        const field_type_info = @typeInfo(@TypeOf(@field(zig, decl_name)));
        const kind = switch (comptime field_type_info) {
            .bool, .int, .@"enum" => "constant",
            .@"fn" => "function",
            .type => "type",
            else => @compileError(
                "zig.zig decl '" ++ decl_name ++ "' has unsupported type info: " ++ @tagName(field_type_info),
            ),
        };
        try writer.print("    .{{ .kind = .{s}, .name = \"{s}\" }},\n", .{ kind, decl_name });
    }
    try writer.writeAll("};\n");
    try writer.flush();
}

const std = @import("std");
const win32_stub = @import("win32_stub");
const zig = win32_stub.zig;

// make win32/zig.zig happy
pub const UNICODE = true;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("pub const Kind = enum { constant, type, function };\n");
    try stdout.writeAll("pub const Decl = struct { kind: Kind, name: []const u8};\n");
    try stdout.writeAll("pub const declarations = [_]Decl{\n");
    inline for (comptime std.meta.declarations(zig)) |decl| {
        const field_type_info = @typeInfo(@TypeOf(@field(zig, decl.name)));
        const kind = switch (comptime field_type_info) {
            .Bool, .Int, .Enum => "constant",
            .Fn => "function",
            .Type => "type",
            else => @compileError(
                "zig.zig decl '" ++ decl.name ++ "' has unsupported type info: " ++ @tagName(field_type_info),
            ),
        };
        try stdout.print("    .{{ .kind = .{s}, .name = \"{s}\" }},\n", .{ kind, decl.name });
    }
    try stdout.writeAll("};\n");
}

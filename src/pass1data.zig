const std = @import("std");
const metadata = @import("metadata.zig");
const jsonextra = @import("jsonextra.zig");

pub const Root = jsonextra.ArrayHashMap(TypeMap);

pub fn parseRoot(
    allocator: std.mem.Allocator,
    json_filename: []const u8,
    content: []const u8,
) Root {
    var diagnostics = std.json.Diagnostics{};
    var scanner = std.json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    scanner.enableDiagnostics(&diagnostics);
    return std.json.parseFromTokenSourceLeaky(
        Root,
        allocator,
        &scanner,
        .{},
    ) catch |err| {
        std.log.err(
            "{s}:{}:{}: {s}",
            .{
                json_filename,
                diagnostics.getLine(),
                diagnostics.getColumn(),
                @errorName(err),
            },
        );
        @panic("json error");
    };
}

pub const TypeMap = jsonextra.ArrayHashMap(Type);

pub const TypeKind = enum {
    Integral,
    Enum,
    Struct,
    Union,
    Pointer,
    FunctionPointer,
    Com,
};
const type_kinds = std.StaticStringMap(TypeKind).initComptime(.{
    .{ "Integral", .Integral },
    .{ "Enum", .Enum },
    .{ "Struct", .Struct },
    .{ "Union", .Union },
    .{ "Pointer", .Pointer },
    .{ "FunctionPointer", .FunctionPointer },
    .{ "Com", .Com },
});

const EmptyStruct = struct { };
pub const Type = union(TypeKind) {
    Integral: EmptyStruct,
    Enum: EmptyStruct,
    Struct: EmptyStruct,
    Union: EmptyStruct,
    Pointer: EmptyStruct,
    FunctionPointer: EmptyStruct,
    Com: Com,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Type {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        switch (try metadata.jsonParseUnionKind(TypeKind, "Type", source, type_kinds)) {
            .Integral => return .{ .Integral = try metadata.parseUnionObject(EmptyStruct, allocator, source, options) },
            .Enum => return .{ .Enum = try metadata.parseUnionObject(EmptyStruct, allocator, source, options) },
            .Struct => return .{ .Struct = try metadata.parseUnionObject(EmptyStruct, allocator, source, options) },
            .Union => return .{ .Union = try metadata.parseUnionObject(EmptyStruct, allocator, source, options) },
            .Pointer => return .{ .Pointer = try metadata.parseUnionObject(EmptyStruct, allocator, source, options) },
            .FunctionPointer => return .{ .FunctionPointer = try metadata.parseUnionObject(EmptyStruct, allocator, source, options) },
            .Com => return .{ .Com = try metadata.parseUnionObject(Com, allocator, source, options) },
        }
    }
};

pub const Com = struct {
    Interface: ?metadata.TypeRef,
};

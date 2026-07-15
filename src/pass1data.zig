//! The pass1 index model: a per-api map of type name -> category, built in
//! memory by pass1.buildIndex.

const std = @import("std");
const metadata = @import("metadata.zig");

pub const Root = std.StringArrayHashMap(TypeMap);
pub const TypeMap = std.StringArrayHashMap(Type);

pub const TypeKind = enum {
    Integral,
    Enum,
    Struct,
    Union,
    Pointer,
    FunctionPointer,
    Com,
};

const EmptyStruct = struct {};
pub const Type = union(TypeKind) {
    Integral: EmptyStruct,
    Enum: EmptyStruct,
    Struct: EmptyStruct,
    Union: EmptyStruct,
    Pointer: EmptyStruct,
    FunctionPointer: EmptyStruct,
    Com: Com,
};

pub const Com = struct {
    Interface: ?metadata.TypeRef,
};

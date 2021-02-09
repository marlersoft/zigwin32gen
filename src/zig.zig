//! This module is maintained by hand and is copied to the generated code directory
const std = @import("std");
const testing = std.testing;

const root = @import("root");
pub const UnicodeMode = enum { ansi, wide, unspecified };
// WORKAROUND: https://github.com/ziglang/zig/issues/7979
// using root.UNICODE causes an erroneous dependency loop, so I'm hardcoding to .wide for now
pub const unicode_mode = UnicodeMode.wide;
//pub const unicode_mode : UnicodeMode = if (@hasDecl(root, "UNICODE")) (if (root.UNICODE) .wide else .ansi) else .unspecified;

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Guid = extern struct {
    bytes: [16]u8,
};

pub fn FAILED(hr: @import("api/com.zig").HRESULT) bool {
    return hr < 0;
}

//
// I used this typedConstant function with the old metadata (https://github.com/marler8997/windows-api)
// but I may not need it with the new metadata (https://github.com/marlersoft/win32json)
//
///// Converts comptime values to the given type.
///// Note that this function is called at compile time rather than converting constant values earlier at code generation time.
///// The reason for doing it a compile time is because genzig.zig generates all constants as they are encountered which can
///// be before it knows the constant's type definition, so we delay the convession to compile-time where the compiler knows
///// all type definition.
//pub fn typedConstant(comptime T: type, comptime value: anytype) T {
//    const target_type_error = @as([]const u8, "typedConstant cannot convert to " ++ @typeName(T));
//    const value_type_error = @as([]const u8, "typedConstant cannot convert " ++ @typeName(@TypeOf(value)) ++ " to " ++ @typeName(T));
//    switch (@typeInfo(T)) {
//        .Int => |target_type_info| {
//            if (value >= std.math.maxInt(T)) {
//                if (target_type_info.is_signed) {
//                    const UnsignedT = @Type(std.builtin.TypeInfo { .Int = .{ .is_signed = false, .bits = target_type_info.bits }});
//                    return @bitCast(T, @as(UnsignedT, value));
//                }
//            }
//            return value;
//        },
//        .Pointer => |target_type_info| {
//            switch (target_type_info.size) {
//                .One, .Many, .C => {
//                    switch (@typeInfo(@TypeOf(value))) {
//                        .ComptimeInt => |_| {
//                            const usize_value = if (value >= 0) value else @bitCast(usize, @as(isize, value));
//                            return @intToPtr(T, usize_value);
//                        },
//                        else => @compileError(value_type_error),
//                    }
//                },
//                else => target_type_error,
//            }
//        },
//        .Optional => |target_type_info| {
//            switch(@typeInfo(target_type_info.child)) {
//                .Pointer => return typedConstant(target_type_info.child, value),
//                else => target_type_error,
//            }
//        },
//        else => @compileError(target_type_error),
//    }
//}
//test "typedConstant" {
//    testing.expectEqual(@bitCast(usize, @as(isize, -1)),  @ptrToInt(typedConstant(?*opaque{}, -1)));
//    testing.expectEqual(@bitCast(usize, @as(isize, -12)),  @ptrToInt(typedConstant(?*opaque{}, -12)));
//    testing.expectEqual(@as(u32, 0xffffffff), typedConstant(u32, 0xffffffff));
//    testing.expectEqual(@bitCast(i32, @as(u32, 0x80000000)), typedConstant(i32, 0x80000000));
//}
//
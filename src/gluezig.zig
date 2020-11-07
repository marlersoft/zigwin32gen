//! This module is maintained by hand and is copied to the generated code directory
const std = @import("std");
const testing = std.testing;

/// Converts comptime values to the given type.
/// Note that this function is called at compile time rather than converting constant values earlier at code generation time.
/// The reason for doing it a compile time is because genzig.zig generates all constants as they are encountered which can
/// be before it knows the constant's type definition, so we delay the convession to compile-time where the compiler knows
/// all type definition.
pub fn typedConstant(comptime T: type, comptime value: anytype) T {
    const target_type_error = @as([]const u8, "typedConstant cannot convert to " ++ @typeName(T));
    const value_type_error = @as([]const u8, "typedConstant cannot convert " ++ @typeName(@TypeOf(value)) ++ " to " ++ @typeName(T));
    switch (@typeInfo(T)) {
        .Int => |target_type_info| {
            return value;
        },
        .Pointer => |target_type_info| {
            switch (target_type_info.size) {
                .One, .Many, .C => {
                    switch (@typeInfo(@TypeOf(value))) {
                        .ComptimeInt => |_| {
                            const usize_value = if (value >= 0) value else @bitCast(usize, @as(isize, value));
                            return @intToPtr(T, usize_value);
                        },
                        else => @compileError(value_type_error),
                    }
                },
                else => target_type_error,
            }
        },
        .Optional => |target_type_info| {
            switch(@typeInfo(target_type_info.child)) {
                .Pointer => return typedConstant(target_type_info.child, value),
                else => target_type_error,
            }
        },
        else => @compileError(target_type_error),
    }
}
test "typedConstant" {
    testing.expectEqual(@bitCast(usize, @as(isize, -1)),  @ptrToInt(typedConstant(?*opaque{}, -1)));
    testing.expectEqual(@bitCast(usize, @as(isize, -12)),  @ptrToInt(typedConstant(?*opaque{}, -12)));
    testing.expectEqual(@as(u32, 0xffffffff), typedConstant(u32, 0xffffffff));
}

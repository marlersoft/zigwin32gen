//! This module is maintained by hand and is copied to the generated code directory
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const root = @import("root");
pub const UnicodeMode = enum { ansi, wide, unspecified };
// WORKAROUND: https://github.com/ziglang/zig/issues/7979
// using root.UNICODE causes an erroneous dependency loop, so I'm hardcoding to .wide for now
pub const unicode_mode = UnicodeMode.wide;
//pub const unicode_mode : UnicodeMode = if (@hasDecl(root, "UNICODE")) (if (root.UNICODE) .wide else .ansi) else .unspecified;

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub usingnamespace switch (unicode_mode) {
    .ansi => struct {
        pub const TCHAR = u8;
        pub fn _T(comptime str: []const u8) *const [str.len:0]u8 { return str; }
    },
    .wide => struct {
        pub const TCHAR = u16;
        pub const _T = L;
    },
    .unspecified => if (builtin.is_test) struct {} else struct {
        pub const TCHAR = @compileError("'TCHAR' requires that UNICODE be set to true or false in the root module");
        pub const _T = @compileError("'_T' requires that UNICODE be set to true or false in the root module");
    },
};

pub const Arch = enum { X86, X64, Arm64 };
pub const arch: Arch = switch (builtin.target.cpu.arch) {
    .i386 => .X86,
    .x86_64 => .X64,
    .arm, .armeb => .Arm64,
    else => @compileError("unable to determine win32 arch"),
};

pub const Guid = std.os.windows.GUID;

pub const PropertyKey = extern struct {
    fmtid: Guid,
    pid: u32,
    pub fn init(fmtid: []const u8, pid: u32) PropertyKey {
        return .{
            .fmtid = Guid.parse(fmtid),
            .pid = pid,
        };
    }
};

pub fn FAILED(hr: @import("foundation.zig").HRESULT) bool {
    return hr < 0;
}
pub fn SUCCEEDED(hr: @import("foundation.zig").HRESULT) bool {
    return hr >= 0;
}

// These constants were removed from the metadata to allow each projection
// to define them however they like (see https://github.com/microsoft/win32metadata/issues/530)
pub const FALSE: @import("foundation.zig").BOOL = 0;
pub const TRUE: @import("foundation.zig").BOOL = 1;

/// Converts comptime values to the given type.
/// Note that this function is called at compile time rather than converting constant values earlier at code generation time.
/// The reason for doing it a compile time is because genzig.zig generates all constants as they are encountered which can
/// be before it knows the constant's type definition, so we delay the convession to compile-time where the compiler knows
/// all type definition.
pub fn typedConst(comptime T: type, comptime value: anytype) T {
    return typedConst2(T, T, value);
}

pub fn typedConst2(comptime ReturnType: type, comptime SwitchType: type, comptime value: anytype) ReturnType {
    const target_type_error = @as([]const u8, "typedConst cannot convert to " ++ @typeName(ReturnType));
    const value_type_error = @as([]const u8, "typedConst cannot convert " ++ @typeName(@TypeOf(value)) ++ " to " ++ @typeName(ReturnType));

    switch (@typeInfo(SwitchType)) {
        .Int => |target_type_info| {
            if (value >= std.math.maxInt(SwitchType)) {
                if (target_type_info.signedness == .signed) {
                    const UnsignedT = @Type(std.builtin.TypeInfo{ .Int = .{ .signedness = .unsigned, .bits = target_type_info.bits } });
                    return @bitCast(SwitchType, @as(UnsignedT, value));
                }
            }
            return value;
        },
        .Pointer => |target_type_info| switch (target_type_info.size) {
            .One, .Many, .C => {
                switch (@typeInfo(@TypeOf(value))) {
                    .ComptimeInt, .Int => {
                        const usize_value = if (value >= 0) value else @bitCast(usize, @as(isize, value));
                        return @intToPtr(ReturnType, usize_value);
                    },
                    else => @compileError(value_type_error),
                }
            },
            else => target_type_error,
        },
        .Optional => |target_type_info| switch (@typeInfo(target_type_info.child)) {
            .Pointer => return typedConst2(ReturnType, target_type_info.child, value),
            else => target_type_error,
        },
        .Enum => |_| switch (@typeInfo(@TypeOf(value))) {
            .Int => return @intToEnum(ReturnType, value),
            else => target_type_error,
        },
        else => @compileError(target_type_error),
    }
}
test "typedConst" {
    try testing.expectEqual(@bitCast(usize, @as(isize, -1)), @ptrToInt(typedConst(?*opaque {}, -1)));
    try testing.expectEqual(@bitCast(usize, @as(isize, -12)), @ptrToInt(typedConst(?*opaque {}, -12)));
    try testing.expectEqual(@as(u32, 0xffffffff), typedConst(u32, 0xffffffff));
    try testing.expectEqual(@bitCast(i32, @as(u32, 0x80000000)), typedConst(i32, 0x80000000));
}

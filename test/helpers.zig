//! Tests for the hand-written helpers in win32/zig.zig. These live outside the
//! generated bindings so they don't bloat them, and since only the root module's
//! tests are collected, this binary only links what these tests use and can be run.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const win32 = @import("win32");
const zig = win32.zig;

test "Guid" {
    try testing.expect(std.mem.eql(u8, switch (builtin.target.cpu.arch.endian()) {
        .big => "\x01\x23\x45\x67\x89\xAB\xEF\x10\x32\x54\x76\x98\xba\xdc\xfe\x91",
        .little => "\x67\x45\x23\x01\xAB\x89\x10\xEF\x32\x54\x76\x98\xba\xdc\xfe\x91",
    }, &zig.Guid.initString("01234567-89AB-EF10-3254-7698badcfe91").Bytes));
}

test "loword/hiword" {
    try testing.expectEqual(@as(u16, 0x5678), zig.loword(@as(u32, 0x12345678)));
    try testing.expectEqual(@as(u16, 0x1234), zig.hiword(@as(u32, 0x12345678)));
    try testing.expectEqual(@as(u16, 0x1234), zig.loword(@as(u16, 0x1234)));
    try testing.expectEqual(@as(u16, 0xfffe), zig.loword(@as(i32, -2)));
    try testing.expectEqual(@as(u16, 0xffff), zig.hiword(@as(i32, -2)));
    try testing.expectEqual(@as(u16, 0xfffe), zig.loword(@as(isize, -2)));
    try testing.expectEqual(@as(u16, 0xffff), zig.hiword(@as(isize, -2)));
}

test "lparam points" {
    const lparam: isize = @bitCast(@as(usize, 0x0004fffd));
    try testing.expectEqual(@as(i16, -3), zig.xFromLparam(lparam));
    try testing.expectEqual(@as(i16, 4), zig.yFromLparam(lparam));
    const point = zig.pointFromLparam(lparam);
    try testing.expectEqual(@as(i32, -3), point.x);
    try testing.expectEqual(@as(i32, 4), point.y);
}

test "typedConst" {
    try testing.expectEqual(@as(usize, @bitCast(@as(isize, -1))), @intFromPtr(zig.typedConst(?*opaque {}, -1)));
    try testing.expectEqual(@as(usize, @bitCast(@as(isize, -12))), @intFromPtr(zig.typedConst(?*opaque {}, -12)));
    try testing.expectEqual(@as(u32, 0xffffffff), zig.typedConst(u32, 0xffffffff));
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80000000))), zig.typedConst(i32, 0x80000000));
}

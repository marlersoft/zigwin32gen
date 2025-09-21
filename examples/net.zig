//! test basic network functionality
const std = @import("std");

const win32 = @import("win32").everything;

pub fn main() void {
    const s = win32.socket(@intFromEnum(win32.AF_INET), win32.SOCK_STREAM, @intFromEnum(win32.IPPROTO_TCP));
    if (s == win32.INVALID_SOCKET) {
        std.log.err("socket failed, error={}", .{win32.GetLastError()});
    }
}

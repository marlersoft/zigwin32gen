//! test basic network functionality
const std = @import("std");
const win32 = @import("win32");

pub fn main() void {
    const s = win32.networking.win_sock.socket(
        @intFromEnum(win32.networking.win_sock.AF_INET),
        win32.networking.win_sock.SOCK_STREAM,
        @intFromEnum(win32.networking.win_sock.IPPROTO_TCP),
    );

    if (s == win32.networking.win_sock.INVALID_SOCKET) {
        std.log.err("socket failed, error={f}", .{win32.foundation.GetLastError()});
    }
}

//! test basic network functionality
const std = @import("std");

const win32 = @import("win32");
const win_sock = win32.networking.win_sock;

pub fn main() void {
    const s = win_sock.socket(@intFromEnum(win_sock.AF_INET), win_sock.SOCK_STREAM, @intFromEnum(win_sock.IPPROTO_TCP));
    if (s == win_sock.INVALID_SOCKET) {
        std.log.err("socket failed, error={f}", .{win32.foundation.GetLastError()});
    }
}

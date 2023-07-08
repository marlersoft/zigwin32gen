//! test basic network functionality
const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").networking.win_sock;
    usingnamespace @import("win32").network_management.ip_helper;
};

pub fn main() void {
    const s = win32.socket(@enumToInt(win32.AF_INET), win32.SOCK_STREAM, @enumToInt(win32.IPPROTO_TCP));
    if (s == win32.INVALID_SOCKET) {
        std.log.err("socket failed with {}", .{win32.GetLastError()});
    }
}

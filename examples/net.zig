//! test basic network functionality
const std = @import("std");

const win32 = @import("win32").everything;

pub fn main() void {
    {
        var wsa: win32.WSAData = undefined;
        const err = win32.WSAStartup(0x0202, &wsa);
        if (err != 0) std.debug.panic("WSAStartup failed, error={}", .{err});
    }

    const s = win32.socket(@intFromEnum(win32.AF_INET), win32.SOCK_STREAM, @intFromEnum(win32.IPPROTO_TCP));
    if (s == win32.INVALID_SOCKET) {
        std.log.err("socket failed, error={f}", .{win32.GetLastError()});
    }
}

//! test basic network functionality
const std = @import("std");

const win32 = @import("win32");
usingnamespace win32.system.diagnostics.debug;
usingnamespace win32.networking.win_sock;
usingnamespace win32.network_management.ip_helper;

pub fn main() void {
    const s = socket(@enumToInt(AF_INET), SOCK_STREAM, @enumToInt(IPPROTO_TCP));
    if (s == INVALID_SOCKET) {
        std.log.err("socket failed with {}", .{GetLastError()});
    }
}

//! test basic network functionality
const std = @import("std");

const win32 = @import("win32");
usingnamespace win32.system.diagnostics.debug;
usingnamespace win32.networking.win_sock;
usingnamespace win32.network_management.ip_helper;

pub fn main() void {
    const s = socket(@enumToInt(AF_INET), SOCK_STREAM, @enumToInt(IPPROTO_TCP));
    // workaround https://github.com/microsoft/win32metadata/issues/583
    if (s == @intToPtr(SOCKET, INVALID_SOCKET)) {
        std.log.err("socket failed with {}", .{GetLastError()});
    }
}

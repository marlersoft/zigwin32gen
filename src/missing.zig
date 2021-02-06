//! Includes definitions that are currently missing from win32metadata

const win32 = @import("../win32.zig");

// TODO: should there be an issue for this in win32metadata?
pub const INVALID_HANDLE_VALUE = @intToPtr(win32.api.system_services.HANDLE, @bitCast(usize, @as(isize, -1)));

const std = @import("std");
test "" {
    std.testing.refAllDecls(@This());
}

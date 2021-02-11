//! Includes definitions that are currently missing from win32metadata

const win32 = @import("../win32.zig");

// TODO: should there be an issue for this in win32metadata?
//       not sure how it will define this as a const because it's not a primitive type
pub const INVALID_HANDLE_VALUE = @intToPtr(win32.api.system_services.HANDLE, @bitCast(usize, @as(isize, -1)));


// The CLSCTX_ALL value is missing, see https://github.com/microsoft/win32metadata/issues/203
pub const CLSCTX_ALL = @intToEnum(win32.api.com.CLSCTX,
    @enumToInt(win32.api.com.CLSCTX_INPROC_SERVER) |
    @enumToInt(win32.api.com.CLSCTX_INPROC_HANDLER) |
    @enumToInt(win32.api.com.CLSCTX_LOCAL_SERVER) |
    @enumToInt(win32.api.com.CLSCTX_REMOTE_SERVER));

// The SetWindowLongPtr and GetWindowLongPtr variants are missing because they are 64-bit only
// See: https://github.com/microsoft/win32metadata/issues/142 (SetWindowLongPtr/GetWindowLongPtr are missing)
pub extern "USER32" fn SetWindowLongPtrA(
    hWnd: win32.api.windows_and_messaging.HWND,
    nIndex: i32,
    dwNewLong: isize,
) callconv(@import("std").os.windows.WINAPI) i32;

pub extern "USER32" fn SetWindowLongPtrW(
    hWnd: win32.api.windows_and_messaging.HWND,
    nIndex: i32,
    dwNewLong: isize,
) callconv(@import("std").os.windows.WINAPI) i32;

pub extern "USER32" fn GetWindowLongPtrA(
    hWnd: win32.api.windows_and_messaging.HWND,
    nIndex: i32,
) callconv(@import("std").os.windows.WINAPI) isize;

pub extern "USER32" fn GetWindowLongPtrW(
    hWnd: win32.api.windows_and_messaging.HWND,
    nIndex: i32,
) callconv(@import("std").os.windows.WINAPI) isize;

pub usingnamespace switch (@import("zig.zig").unicode_mode) {
    .ansi => struct {
        pub const SetWindowLongPtr = SetWindowLongPtrA;
        pub const GetWindowLongPtr = GetWindowLongPtrA;
    },
    .wide => struct {
        pub const SetWindowLongPtr = SetWindowLongPtrW;
        pub const GetWindowLongPtr = GetWindowLongPtrW;
    },
    .unspecified => if (@import("builtin").is_test) struct {
        pub const SetWindowLongPtr = *opaque{};
        pub const GetWindowLongPtr = *opaque{};
    } else struct {
        pub const SetWindowLongPtr = @compileError("'SetWindowLongPtr' requires that UNICODE be set to true or false in the root module");
        pub const GetWindowLongPtr = @compileError("'GetWindowLongPtr' requires that UNICODE be set to true or false in the root module");
    },
};

// The following flags seem to be missing, issue here: https://github.com/microsoft/win32metadata/issues/217
pub const PROCESS_ALL_ACCESS = (
    @enumToInt(win32.api.file_system.STANDARD_RIGHTS_REQUIRED) |
    @enumToInt(win32.api.file_system.SYNCHRONIZE) |
    0xFFF
);
pub const PROCESS_CREATE_PROCESS = 0x0080;
pub const PROCESS_CREATE_THREAD = 0x0002;
pub const PROCESS_DUP_HANDLE = 0x0040;
pub const PROCESS_QUERY_INFORMATION = 0x0400;
pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
pub const PROCESS_SET_INFORMATION = 0x0200;
pub const PROCESS_SET_QUOTA = 0x0100;
pub const PROCESS_SUSPEND_RESUME = 0x0800;
pub const PROCESS_TERMINATE = 0x0001;
pub const PROCESS_VM_OPERATION = 0x0008;
pub const PROCESS_VM_READ = 0x0010;
pub const PROCESS_VM_WRITE = 0x0020;

const std = @import("std");
test "" {
    std.testing.refAllDecls(@This());
}

const std = @import("std");

const win32 = @import("win32");
const wm = win32.ui.windows_and_messaging;

const L = win32.zig.L;
const GetLastError = win32.foundation.GetLastError;

pub const UNICODE = true;
pub const panic = win32.zig.messageBoxThenPanic(.{ .title = "Unionpointers Example Panic", .trace = true });

pub export fn wWinMain(
    hInstance: win32.foundation.HINSTANCE,
    _: ?win32.foundation.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(.winapi) c_int {
    _ = pCmdLine;
    _ = nCmdShow;

    for (0..20) |atom| {
        // we don't care if this works, we're just verifying @ptrFromInt(atom)
        // doesn't trigger a runtime panic
        if (wm.CreateWindowEx(
            .{},
            @ptrFromInt(atom),
            L("Test Window"),
            .{},
            0,
            0,
            0,
            0,
            null,
            null,
            hInstance,
            null,
        )) |hwnd| {
            std.log.info("atom={} CreateWindow success", .{atom});
            if (0 == wm.DestroyWindow(hwnd)) win32.zig.panicWin32(
                "DestroyWindow",
                GetLastError(),
            );
        } else {
            std.log.info("atom={} CreateWindow failed, error={f} (this is fine)", .{ atom, GetLastError() });
        }
    }

    {
        const CLASS_NAME = L("Sample Window Class");
        const wc: wm.WNDCLASS = .{
            .style = .{},
            .lpfnWndProc = WindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hInstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            // TODO: this field is not marked as options so we can't use null atm
            .lpszMenuName = L("Some Menu Name"),
            .lpszClassName = CLASS_NAME,
        };

        const atom = wm.RegisterClass(&wc);
        if (0 == atom) win32.zig.panicWin32("RegisterClass", GetLastError());
        const hwnd = wm.CreateWindowEx(
            .{},
            @ptrFromInt(atom),
            L("Test Window"),
            .{},
            0,
            0,
            0,
            0,
            null, // Parent window
            null, // Menu
            hInstance, // Instance handle
            null, // Additional application data
        ) orelse win32.zig.panicWin32("CreateWindow", GetLastError());
        if (0 == wm.DestroyWindow(hwnd)) win32.zig.panicWin32("DestroyWindow", GetLastError());
    }

    {
        // Well this sucks...ptr and const cast?
        const old_cursor = wm.SetCursor(@constCast(@ptrCast(wm.IDC_ARROW)));
        defer _ = wm.SetCursor(old_cursor);
        _ = wm.SetCursor(@constCast(@ptrCast(wm.IDC_IBEAM)));
        _ = wm.SetCursor(@constCast(@ptrCast(wm.IDC_WAIT)));
    }

    std.log.info("success!", .{});
    return 0;
}

fn WindowProc(
    hwnd: win32.foundation.HWND,
    uMsg: u32,
    wParam: win32.foundation.WPARAM,
    lParam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    switch (uMsg) {
        wm.WM_DESTROY => {
            wm.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return wm.DefWindowProc(hwnd, uMsg, wParam, lParam);
}

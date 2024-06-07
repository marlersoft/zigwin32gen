const std = @import("std");

pub const UNICODE = true;
const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
};
const L = win32.L;
const HWND = win32.HWND;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    if (std.fmt.allocPrintZ(std.heap.page_allocator, fmt, args)) |msg| {
        _ = win32.MessageBoxA(null, msg, "Fatal Error", .{});
    } else |e| switch(e) {
        error.OutOfMemory => _ = win32.MessageBoxA(null, "Out of memory", "Fatal Error", .{}),
    }
    std.process.exit(1);
}

pub export fn wWinMain(
    hInstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(std.os.windows.WINAPI) c_int
{
    _ = pCmdLine;
    _ = nCmdShow;


    for (0 .. 20) |atom| {
        // we don't care if this works, we're just verifying @ptrFromInt(atom)
        // doesn't trigger a runtime panic
        if (win32.CreateWindowEx(
            .{},
            @ptrFromInt(atom),
            L("Test Window"),
            .{},
            0, 0,
            0, 0,
            null,
            null,
            hInstance,
            null,
        )) |hwnd| {
            std.log.info("atom={} CreateWindow success", .{atom});
            if (0 == win32.DestroyWindow(hwnd))
                fatal("DestroyWindow failed, error={s}", .{@tagName(win32.GetLastError())});
        } else {
            std.log.info("atom={} CreateWindow failed with {s} (this is fine)", .{atom, @tagName(win32.GetLastError())});
        }
    }
    {
        const CLASS_NAME = L("Sample Window Class");
        const wc = win32.WNDCLASS {
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
        const atom = win32.RegisterClass(&wc);
        if (0 == atom)
            fatal("RegisterClass failed, error={s}", .{@tagName(win32.GetLastError())});
        const hwnd = win32.CreateWindowEx(
            .{},
            @ptrFromInt(atom),
            L("Test Window"),
            .{},
            0, 0,
            0, 0,
            null,       // Parent window
            null,       // Menu
            hInstance,  // Instance handle
            null        // Additional application data
        ) orelse fatal("CreateWindow failed, error={s}", .{@tagName(win32.GetLastError())});
        if (0 == win32.DestroyWindow(hwnd))
            fatal("DestroyWindow failed, error={s}", .{@tagName(win32.GetLastError())});
    }

    {
        // Well this sucks...ptr and const cast?
        const old_cursor = win32.SetCursor(@constCast(@ptrCast(win32.IDC_ARROW)));
        defer _ = win32.SetCursor(old_cursor);
        _ = win32.SetCursor(@constCast(@ptrCast(win32.IDC_IBEAM)));
        _ = win32.SetCursor(@constCast(@ptrCast(win32.IDC_WAIT)));
    }


    std.log.info("success!", .{});
    return 0;
}


fn WindowProc(
    hwnd: HWND ,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProc(hwnd, uMsg, wParam, lParam);
}

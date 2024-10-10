const std = @import("std");
const WINAPI = std.os.windows.WINAPI;

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
) callconv(WINAPI) c_int
{
    _ = pCmdLine;
    _ = nCmdShow;

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

    if (0 == win32.RegisterClass(&wc))
        fatal("RegisterClass failed with {}", .{win32.GetLastError().fmt()});

    const hwnd = win32.CreateWindowEx(
        .{},
        CLASS_NAME,
        L("Hello Windows"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, // Position
        400, 200,   // Size
        null,       // Parent window
        null,       // Menu
        hInstance,  // Instance handle
        null        // Additional application data
    ) orelse fatal("CreateWindow failedwith {}", .{win32.GetLastError().fmt()});

    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var msg : win32.MSG = undefined;
    while (win32.GetMessage(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }
    return @intCast(msg.wParam);
}

fn WindowProc(
    hwnd: HWND ,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps);
            _ = win32.FillRect(hdc, &ps.rcPaint, @ptrFromInt(@intFromEnum(win32.COLOR_WINDOW)+1));
            _ = win32.TextOutA(hdc, 20, 20, "Hello", 5);
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProc(hwnd, uMsg, wParam, lParam);
}

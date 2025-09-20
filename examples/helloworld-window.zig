const std = @import("std");

pub const UNICODE = true;
const win32 = @import("win32").everything;
// Needed for unicode aliases
const ui_window = @import("win32").ui.windows_and_messaging;

const L = win32.L;
const HWND = win32.HWND;

pub export fn wWinMain(
    hInstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(.winapi) c_int {
    _ = pCmdLine;
    _ = nCmdShow;

    const CLASS_NAME = L("Sample Window Class");
    const wc = ui_window.WNDCLASS{
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

    if (0 == ui_window.RegisterClass(&wc))
        win32.panicWin32("RegisterClass", win32.GetLastError());

    const hwnd = ui_window.CreateWindowEx(.{}, CLASS_NAME, L("Hello Windows"), win32.WS_OVERLAPPEDWINDOW, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, // Position
        400, 200, // Size
        null, // Parent window
        null, // Menu
        hInstance, // Instance handle
        null // Additional application data
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var msg: win32.MSG = undefined;
    while (ui_window.GetMessage(&msg, null, 0, 0) != 0) {
        _ = ui_window.TranslateMessage(&msg);
        _ = ui_window.DispatchMessage(&msg);
    }
    return @intCast(msg.wParam);
}

fn WindowProc(
    hwnd: HWND,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (uMsg) {
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps);
            _ = win32.FillRect(hdc, &ps.rcPaint, @ptrFromInt(@intFromEnum(win32.COLOR_WINDOW) + 1));
            _ = win32.TextOutA(hdc, 20, 20, "Hello", 5);
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }
    return ui_window.DefWindowProc(hwnd, uMsg, wParam, lParam);
}

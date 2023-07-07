//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/HelloWorld/cpp/main.cpp
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
};
const L = win32.L;
const HINSTANCE = win32.HINSTANCE;
const CW_USEDEFAULT = win32.CW_USEDEFAULT;
const MSG = win32.MSG;
const HWND = win32.HWND;

pub export fn wWinMain(hInstance: HINSTANCE, _: ?HINSTANCE, pCmdLine: [*:0]u16, nCmdShow: u32) callconv(WINAPI) c_int {
    _ = pCmdLine;

    // Register the window class.
    const CLASS_NAME = L("Sample Window Class");

    const wc = win32.WNDCLASS{
        .style = @as(win32.WNDCLASS_STYLES, @enumFromInt(0)),
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

    _ = win32.RegisterClass(&wc);

    // Create the window.

    const hwnd = win32.CreateWindowEx(@as(win32.WINDOW_EX_STYLE, @enumFromInt(0)), // Optional window styles.
        CLASS_NAME, // Window class
        L("Learn to Program Windows"), // Window text
        win32.WS_OVERLAPPEDWINDOW, // Window style

    // Size and position
        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, null, // Parent window
        null, // Menu
        hInstance, // Instance handle
        null // Additional application data
    );
    if (hwnd == null) {
        return 0;
    }

    _ = win32.ShowWindow(hwnd, @as(win32.SHOW_WINDOW_CMD, @enumFromInt(nCmdShow)));

    // Run the message loop.
    var msg: MSG = undefined;
    while (win32.GetMessage(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }

    return 0;
}

fn WindowProc(hwnd: HWND, uMsg: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps);

            // All painting occurs here, between BeginPaint and EndPaint.
            _ = win32.FillRect(hdc, &ps.rcPaint, @as(win32.HBRUSH, @ptrFromInt(@as(usize, @intFromEnum(win32.COLOR_WINDOW) + 1))));
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }

    return win32.DefWindowProc(hwnd, uMsg, wParam, lParam);
}

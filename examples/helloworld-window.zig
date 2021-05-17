//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/HelloWorld/cpp/main.cpp
pub const UNICODE = true;

const WINAPI = @import("std").os.windows.WINAPI;

usingnamespace @import("win32").zig;
usingnamespace @import("win32").api.system.system_services;
usingnamespace @import("win32").api.ui.windows_and_messaging;
usingnamespace @import("win32").api.graphics.gdi;

pub export fn wWinMain(hInstance: HINSTANCE, _: HINSTANCE, pCmdLine: [*:0]u16, nCmdShow: u32) callconv(WINAPI) c_int
{

    // Register the window class.
    const CLASS_NAME = L("Sample Window Class");

    const wc = WNDCLASS {
        .style = @intToEnum(WNDCLASS_STYLES, 0),
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        // TODO: autogen bindings don't allow for null, should win32metadata allow Option for fields? Or should all strings allow NULL?
        .lpszMenuName = L("Some Menu Name"),
        .lpszClassName = CLASS_NAME,
    };

    _ = RegisterClass(&wc);

    // Create the window.

    const hwnd = CreateWindowEx(
        @intToEnum(WINDOW_EX_STYLE, 0), // Optional window styles.
        CLASS_NAME,                     // Window class
        L("Learn to Program Windows"),  // Window text
        WS_OVERLAPPEDWINDOW,            // Window style

        // Size and position
        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,

        null,       // Parent window
        null,       // Menu
        hInstance,  // Instance handle
        null        // Additional application data
    );
    if (hwnd == null)
    {
        return 0;
    }

    _ = ShowWindow(hwnd, @intToEnum(SHOW_WINDOW_CMD, nCmdShow));

    // Run the message loop.
    var msg : MSG = undefined;
    while (GetMessage(&msg, null, 0, 0) != 0)
    {
        _ = TranslateMessage(&msg);
        _ = DispatchMessage(&msg);
    }

    return 0;
}

fn WindowProc(hwnd: HWND , uMsg: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT
{
    switch (uMsg)
    {
        WM_DESTROY =>
        {
            PostQuitMessage(0);
            return 0;
        },
        WM_PAINT =>
        {
            var ps: PAINTSTRUCT = undefined;
            const hdc = BeginPaint(hwnd, &ps);

            // All painting occurs here, between BeginPaint and EndPaint.
            _ = FillRect(hdc, &ps.rcPaint, @intToPtr(HBRUSH, @as(usize, @enumToInt(COLOR_WINDOW)+1)));
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

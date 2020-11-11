//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/HelloWorld/cpp/main.cpp
pub const UNICODE = true;

usingnamespace @import("windows").everything;

// TODO: define this in windows headers:
const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

pub export fn wWinMain(hInstance: HINSTANCE, _: HINSTANCE, pCmdLine: PWSTR, nCmdShow: c_int) callconv(.Stdcall) c_int
{

    // Register the window class.
    const CLASS_NAME = L("Sample Window Class");

    const wc = WNDCLASS {
        .style = 0,
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
    };

    _ = RegisterClass(&wc);

    // Create the window.

    const hwnd = CreateWindowEx(
        0,                              // Optional window styles.
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

    _ = ShowWindow(hwnd, nCmdShow);

    // Run the message loop.
    var msg : MSG = undefined;
    while (GetMessage(&msg, null, 0, 0) != 0)
    {
        _ = TranslateMessage(&msg);
        _ = DispatchMessage(&msg);
    }

    return 0;
}

fn WindowProc(hwnd: HWND , uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.Stdcall) LRESULT
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
            _ = FillRect(hdc, &ps.rcPaint, @intToPtr(HBRUSH, @as(usize, COLOR_WINDOW+1)));
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

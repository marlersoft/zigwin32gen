//! This example is ported from : https://github.com/microsoft/Windows-classic-samples/blob/master/Samples/Win7Samples/begin/LearnWin32/HelloWorld/cpp/main.cpp

//#ifndef UNICODE
//#define UNICODE
//#endif 

usingnamespace @import("windows").everything;

pub export fn wWinMain(hInstance: HINSTANCE, _: HINSTANCE, pCmdLine: PWSTR, nCmdShow: c_int) callconv(.Stdcall) c_int {
    // Register the window class.
    //const wchar_t CLASS_NAME[]  = L"Sample Window Class";
    const CLASS_NAME = [_]u16 {
        'S', 'a', 'm', 'p', 'l', 'e', ' ', 'W', 'i', 'n', 'd', 'o', 'w', ' ', 'C', 'l', 'a', 's', 's', 0
    };
    
    var wc = WNDCLASS {
        .style = 0,
        .lpfnWndProc = WindowProc,
        .hInstance = hInstance,
        .lpszClassName = CLASS_NAME,
    };

    //wc.lpfnWndProc   = WindowProc;
    //wc.hInstance     = hInstance;
    //wc.lpszClassName = CLASS_NAME;

    //RegisterClass(&wc);

    //// Create the window.

    //HWND hwnd = CreateWindowEx(
    //    0,                              // Optional window styles.
    //    CLASS_NAME,                     // Window class
    //    L"Learn to Program Windows",    // Window text
    //    WS_OVERLAPPEDWINDOW,            // Window style

    //    // Size and position
    //    CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,

    //    NULL,       // Parent window    
    //    NULL,       // Menu
    //    hInstance,  // Instance handle
    //    NULL        // Additional application data
    //    );

    //if (hwnd == NULL)
    //{
    //    return 0;
    //}

    //ShowWindow(hwnd, nCmdShow);

    //// Run the message loop.
    //MSG msg = { };
    //while (GetMessage(&msg, NULL, 0, 0))
    //{
    //    TranslateMessage(&msg);
    //    DispatchMessage(&msg);
    //}

    return 0;
}

fn WindowProc(hwnd: HWND , uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.Stdcall) LRESULT {
    switch (uMsg)
    {
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const hdc = BeginPaint(hwnd, &ps);
            defer EndPaint(hwnd, &ps);

            // All painting occurs here, between BeginPaint and EndPaint.
            FillRect(hdc, &ps.rcPaint, (HBRUSH) (COLOR_WINDOW+1));
            return 0;
        },
    }

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

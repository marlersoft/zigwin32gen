const std = @import("std");

const win32 = @import("win32").everything;
const L = win32.L;
const HWND = win32.HWND;

pub const panic = win32.messageBoxThenPanic(.{ .title = "Zigwin32 TestWindow Panic" });

pub export fn wWinMain(
    hInstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(.winapi) c_int {
    _ = pCmdLine;
    _ = nCmdShow;

    std.debug.assert(0x5678 == win32.loword(@as(i32, 0x12345678)));
    std.debug.assert(0x1234 == win32.hiword(@as(i32, 0x12345678)));

    const CLASS_NAME = L("ZigTestWindow");
    const wc = win32.WNDCLASSW{
        .style = .{},
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = @sizeOf(usize),
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        // TODO: this field is not marked as options so we can't use null atm
        .lpszMenuName = L("Some Menu Name"),
        .lpszClassName = CLASS_NAME,
    };

    if (0 == win32.RegisterClassW(&wc))
        win32.panicWin32("RegisterClass", win32.GetLastError());

    const hwnd = win32.CreateWindowExW(
        .{},
        CLASS_NAME,
        L("Zigwin32 Test Window"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT, // x
        win32.CW_USEDEFAULT, // y
        0, // width
        0, // height
        null, // parent window
        null, // menu
        hInstance,
        null, // Additional application data
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    const dpi = win32.dpiFromHwnd(hwnd);

    // just test the api works
    _ = win32.scaleFromDpi(f32, dpi);
    _ = win32.scaleFromDpi(f64, dpi);
    _ = win32.scaleFromDpi(f128, dpi);
    _ = win32.scaleDpi(i32, 100, dpi);
    _ = win32.scaleDpi(f32, 100, dpi);

    if (0 == win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        win32.scaleDpi(i32, 600, dpi),
        win32.scaleDpi(i32, 400, dpi),
        .{ .NOMOVE = 1 },
    )) std.debug.panic("SetWindowPos failed, error={f}", .{win32.GetLastError()});

    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
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
        win32.WM_CREATE => {
            if (win32.has_window_longptr) {
                std.debug.assert(0 == win32.setWindowLongPtrW(hwnd, 0, 0x1234));
                std.debug.assert(0x1234 == win32.getWindowLongPtrW(hwnd, 0));
            }
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_DPICHANGED => win32.invalidateHwnd(hwnd),
        win32.WM_PAINT => {
            // some of these methods aren't really doing anything, just
            // testing various apis.
            _ = win32.pointFromLparam(lParam);

            const client_size = win32.getClientSize(hwnd);
            _ = client_size;

            const hdc, const ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            {
                const tmp_hdc = win32.CreateCompatibleDC(hdc);
                win32.deleteDc(tmp_hdc);
            }

            {
                const brush = win32.createSolidBrush(0xff00ffff);
                defer win32.deleteObject(brush);
                win32.fillRect(hdc, ps.rcPaint, brush);
            }

            var y: i32 = 10;

            {
                const msg = win32.L("A window for testing things.");
                win32.textOutW(hdc, 20, y, msg);
                y += win32.getTextExtentW(hdc, msg).cy;
            }
            {
                const msg = "Testing TextOutA";
                win32.textOutA(hdc, 20, y, msg);
                y += win32.getTextExtentA(hdc, msg).cy;
            }

            {
                var buf: [100]u8 = undefined;
                const text = std.fmt.bufPrint(
                    @ptrCast(&buf),
                    "dpi is {}",
                    .{win32.dpiFromHwnd(hwnd)},
                ) catch unreachable;
                win32.textOutA(hdc, 20, y, text);
            }

            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

const std = @import("std");
const WINAPI = std.os.windows.WINAPI;

const win32 = @import("win32").everything;
const L = win32.L;
const HWND = win32.HWND;

threadlocal var thread_is_panicing = false;
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            std.heap.page_allocator,
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "Ddui Example: Panic", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub export fn wWinMain(
    hInstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(WINAPI) c_int {
    _ = pCmdLine;
    _ = nCmdShow;

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
        std.debug.panic("RegisterClass failed with {}", .{win32.GetLastError().fmt()});

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
    ) orelse std.debug.panic("CreateWindow failed with {}", .{win32.GetLastError().fmt()});

    const dpi = win32.dpiFromHwnd(hwnd);
    if (0 == win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        win32.scaleDpi(i32, 600, dpi),
        win32.scaleDpi(i32, 400, dpi),
        .{ .NOMOVE = 1 },
    )) std.debug.panic(
        "SetWindowPos failed with {}",
        .{win32.GetLastError().fmt()},
    );

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
) callconv(WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_CREATE => {
            std.debug.assert(0 == win32.setWindowLongPtrW(hwnd, 0, 0x1234));
            std.debug.assert(0x1234 == win32.getWindowLongPtrW(hwnd, 0));
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_DPICHANGED => win32.invalidateHwnd(hwnd),
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps);
            _ = win32.FillRect(hdc, &ps.rcPaint, @ptrFromInt(@intFromEnum(win32.COLOR_WINDOW) + 1));
            const msg = win32.L("A window for testing things.");
            _ = win32.TextOutW(hdc, 20, 20, msg.ptr, msg.len);
            {
                var buf: [100]u8 = undefined;
                const text = std.fmt.bufPrint(
                    @ptrCast(&buf),
                    "dpi is {}",
                    .{win32.dpiFromHwnd(hwnd)},
                ) catch unreachable;
                // TODO: the text.ptr argument doesn't require null termination, fix the binding
                _ = win32.TextOutA(hdc, 20, 50, @ptrCast(text.ptr), @intCast(text.len));
            }
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam);
}
